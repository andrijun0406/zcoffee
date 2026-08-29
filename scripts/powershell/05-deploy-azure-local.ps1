<#
.SYNOPSIS
    Stage 5 - Azure Local CLOUD DEPLOYMENT via ARM. This is the stage that actually builds the
    cluster: SET switch, storage vNICs, RDMA/iWARP, storage auto-IP, Storage Spaces Direct, the
    failover cluster, and the Azure Local instance - all driven by the ARM template's
    intentList / storageNetworkList (NOT by a host script).

.DESCRIPTION
    Uses Az PowerShell (reuses the Stage 4 login on this jump host - no separate Azure CLI
    dependency). Flow:
      1. Validate tooling (Az.Accounts/Az.Resources) and the template + parameter files.
      2. Reuse or establish the Azure context; select subscription.
      3. PRE-FLIGHT GATES (read-only) - refuse to deploy unless these pass:
           - resource group exists,
           - both Arc nodes exist AND report Status=Connected,
           - arcNodeResourceIds in the parameter file resolve to those machines,
           - required secrets are being supplied at runtime (not from the committed file).
      4. Inject secrets securely at runtime (localAdminUserName/password) as override parameters.
      5. Validate mode  -> Test-AzResourceGroupDeployment (non-mutating).
         Deploy mode    -> New-AzResourceGroupDeployment -WhatIf, typed DEPLOY confirmation,
                           then the real deployment.

    Deploy is gated behind -EnableDeployment AND a typed "DEPLOY" confirmation. Validate is default.

.NOTES
    Prerequisites (documented in docs/deployment-guide.md):
      - Stages 2-4 green; both nodes Arc-Connected; Secure Boot re-enabled; storage DACs linked.
      - Jump host: Az.Accounts, Az.Resources (installed for Stage 4).
      - Secrets (local admin password) come from the private runbook at runtime, never the repo.
#>
[CmdletBinding()]
param(
    [ValidateSet('Validate','Deploy')]
    [string]$DeploymentMode = 'Validate',
    [switch]$EnableDeployment,
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$TemplateFile,
    [Parameter(Mandatory)][string]$ParameterFile,
    [string]$DeploymentName,
    [string]$Region,
    [switch]$UseExistingAzLogin,
    # Unattended service-principal / managed-identity auth (zero-touch).
    [string]$ServicePrincipalId,
    [SecureString]$ServicePrincipalSecret,
    [string]$CertificateThumbprint,
    [switch]$UseManagedIdentity,
    # Local admin credential that exists on ALL nodes (used by the deployment).
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    # Skip the Arc-Connected pre-flight gate (NOT recommended; only for re-runs mid-deploy).
    [switch]$SkipArcCheck,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b   = $PSBoundParameters

$SubscriptionId    = Resolve-Setting -Name 'SubscriptionId'    -Bound $b -Current $SubscriptionId    -ConfigKey 'SubscriptionId' -Config $cfg
$TenantId          = Resolve-Setting -Name 'TenantId'          -Bound $b -Current $TenantId          -ConfigKey 'TenantId'       -Config $cfg
$ResourceGroupName = Resolve-Setting -Name 'ResourceGroupName' -Bound $b -Current $ResourceGroupName -ConfigKey 'ResourceGroup'  -Config $cfg
if (-not $ResourceGroupName) { $ResourceGroupName = 'azljkt01rg' }
$DeploymentName    = Resolve-Setting -Name 'DeploymentName'    -Bound $b -Current $DeploymentName    -ConfigKey 'DeploymentName' -Config $cfg
if (-not $DeploymentName) { $DeploymentName = 'azljkt01dep' }
$Region            = Resolve-Setting -Name 'Region'            -Bound $b -Current $Region            -ConfigKey 'Region'         -Config $cfg
if (-not $Region) { $Region = 'southeastasia' }
$LocalAdminUser    = Resolve-Setting -Name 'LocalAdminUser'    -Bound $b -Current $LocalAdminUser    -ConfigKey 'LocalAdminUser' -Config $cfg
if (-not $LocalAdminUser) { $LocalAdminUser = 'Administrator' }

if (-not $SubscriptionId) { throw 'SubscriptionId is required. Pass -SubscriptionId (from your private runbook).' }

# Deploy mode requires the explicit safety switch.
if ($DeploymentMode -eq 'Deploy' -and -not $EnableDeployment) {
    throw 'Deploy mode is disabled by default. Re-run with -DeploymentMode Deploy -EnableDeployment after review.'
}

$totalSteps = 4
if ($DeploymentMode -eq 'Deploy') { $totalSteps = 6 }
Initialize-Ui -StageName '05-deploy-azure-local' -TotalSteps $totalSteps -UseGui:$UseGui

try {
    # -----------------------------------------------------------------
    Invoke-Step 'Validate tooling and input files' {
        foreach ($m in @('Az.Accounts','Az.Resources')) {
            if (-not (Get-Module -ListAvailable -Name $m)) {
                throw "$m not found on this host. Install-Module $m -Scope CurrentUser"
            }
        }
        Import-Module Az.Accounts -ErrorAction Stop
        Import-Module Az.Resources -ErrorAction Stop
        if (-not (Test-Path $script:TemplateFile -PathType Leaf))  { throw "ARM template not found: $script:TemplateFile" }
        if (-not (Test-Path $script:ParameterFile -PathType Leaf)) { throw "Parameter file not found: $script:ParameterFile" }
        $script:TemplateFile  = (Resolve-Path $script:TemplateFile).Path
        $script:ParameterFile = (Resolve-Path $script:ParameterFile).Path
        Write-Ok "Template: $script:TemplateFile"
        Write-Ok "Parameters: $script:ParameterFile"
    }

    # -----------------------------------------------------------------
    Invoke-Step 'Establish Azure context and select subscription' {
        if (-not $script:TenantId) { throw 'TenantId is required (pass -TenantId).' }
        $ctx = Connect-AzForStage -TenantId $script:TenantId -SubscriptionId $script:SubscriptionId `
            -ServicePrincipalId $script:ServicePrincipalId -ServicePrincipalSecret $script:ServicePrincipalSecret `
            -CertificateThumbprint $script:CertificateThumbprint -UseManagedIdentity:$script:UseManagedIdentity `
            -UseExistingAzLogin:$script:UseExistingAzLogin
        if ($script:TenantId -and $ctx.Tenant.Id -ne $script:TenantId) {
            throw "Tenant mismatch. Expected $script:TenantId; context is $($ctx.Tenant.Id)."
        }
        Write-Ok "Signed in as $($ctx.Account.Id); subscription $script:SubscriptionId; region $script:Region."
    }

    # -----------------------------------------------------------------
    Invoke-Step 'Pre-flight gates (RG, Arc nodes Connected, parameter sanity)' {
        # Resource group
        $rg = Get-AzResourceGroup -Name $script:ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) { throw "Resource group '$script:ResourceGroupName' not found. Stage 4 (Arc) creates it; run Stage 4 Register first." }
        Write-Ok "Resource group present: $script:ResourceGroupName ($($rg.Location))"

        # Parse the parameter file and check adapter names / arcNodeResourceIds.
        $pf = Get-Content $script:ParameterFile -Raw | ConvertFrom-Json
        $pv = $pf.parameters

        # Adapter-name sanity vs config (the mismatch that would fail deployment).
        $cfgMgmt = if ($cfg.ContainsKey('MgmtAdapters')) { @($cfg.MgmtAdapters) } else { @() }
        try {
            $armMgmt = @(($pv.intentList.value | Where-Object { $_.name -eq 'MgmtCompute' }).adapter)
            foreach ($a in $armMgmt) {
                if ($cfgMgmt.Count -and ($cfgMgmt -notcontains $a)) {
                    Write-Warn "ARM mgmt adapter '$a' not in lab-config MgmtAdapters ($($cfgMgmt -join ', ')). Confirm exact Windows names."
                }
            }
            Write-Ok "ARM mgmt adapters: $($armMgmt -join ', ')"
        } catch { Write-Warn 'Could not parse intentList adapters from the parameter file.' }

        # Secrets must NOT be baked into the committed file.
        $laUser = "$($pv.localAdminUserName.value)"
        if ($laUser -match 'REPLACE_WITH' -or [string]::IsNullOrWhiteSpace($laUser)) {
            Write-Info 'localAdminUserName is a placeholder in the file (expected) - injected at runtime.'
        }
        if ($null -ne $pv.localAdminPassword.value -and "$($pv.localAdminPassword.value)" -ne '') {
            Write-Warn 'localAdminPassword has a value in the parameter file. Secrets should be injected at runtime, not committed.'
        }

        # Arc node resource IDs
        $arcIds = @($pv.arcNodeResourceIds.value)
        if (-not $arcIds -or $arcIds.Count -lt 2) { throw 'arcNodeResourceIds must list both node resource IDs.' }
        $script:arcIds = $arcIds

        if ($script:SkipArcCheck) {
            Write-Warn 'Skipping Arc-Connected gate (-SkipArcCheck).'
        }
        else {
            foreach ($id in $arcIds) {
                $name = ($id -split '/')[-1]
                $m = Get-AzResource -ResourceId $id -ErrorAction SilentlyContinue
                if (-not $m) { throw "Arc machine not found: $name ($id). Run Stage 4 Register until both nodes exist." }
                $status = $null
                try {
                    $full = Get-AzConnectedMachine -ResourceGroupName $script:ResourceGroupName -Name $name -ErrorAction Stop
                    $status = $full.Status
                } catch {
                    # Az.ConnectedMachine may be absent; fall back to the generic resource property.
                    $status = $m.Properties.status
                }
                if ("$status" -ne 'Connected') {
                    throw "Arc node '$name' status='$status' (need 'Connected'). Complete Stage 4 Register and let the agent connect."
                }
                Write-Ok "Arc node Connected: $name"
            }
        }
    }

    # -----------------------------------------------------------------
    Invoke-Step 'Prepare secure deployment parameters' {
        if (-not $b.ContainsKey('LocalAdminPassword') -or $null -eq $script:LocalAdminPassword) {
            $script:LocalAdminPassword = Read-Host -Prompt "Enter the local admin password for '$script:LocalAdminUser' (exists on both nodes)" -AsSecureString
        }
        # Override parameters injected at runtime (take precedence over the parameter file).
        $script:overrides = @{
            localAdminUserName = $script:LocalAdminUser
            localAdminPassword = $script:LocalAdminPassword
        }
        $script:ov = $script:overrides
        Write-Ok "Local admin '$script:LocalAdminUser' credential prepared for injection (never logged)."
        Write-Info 'If the template also requires a separate deployment/LCM credential, add it here.'
    }

    # -----------------------------------------------------------------
    if ($DeploymentMode -eq 'Validate') {
        Invoke-Step 'Run non-mutating ARM validation (Test-AzResourceGroupDeployment)' {
            $r = Test-AzResourceGroupDeployment `
                    -ResourceGroupName $script:ResourceGroupName `
                    -TemplateFile $script:TemplateFile `
                    -TemplateParameterFile $script:ParameterFile `
                    @ov `
                    -ErrorAction Stop 4>$null
            if ($r) {
                Write-Warn "Validation reported issues:"
                foreach ($e in $r) { Write-Warn " - [$($e.Code)] $($e.Message)" }
                throw 'ARM validation returned errors (see above). Fix parameters/template before deploying.'
            }
            Write-Ok 'ARM validation passed. No Azure Local instance was created.'
        }
        Complete-Ui -FinalMessage 'ARM validation finished.'
        return
    }

    # -----------------------------------------------------------------
    # Deploy mode
    Invoke-Step 'Preview changes (What-If)' {
        Write-Info 'Running What-If (this can take a few minutes)...'
        $wi = Get-AzResourceGroupDeploymentWhatIfResult `
                -ResourceGroupName $script:ResourceGroupName `
                -TemplateFile $script:TemplateFile `
                -TemplateParameterFile $script:ParameterFile `
                @ov `
                -ErrorAction Stop
        $wi | Out-Host
    }

    Invoke-Step 'Confirm and submit the deployment' {
        Write-Warn 'This creates the Azure Local instance and configures BOTH nodes (SET switch, S2D, cluster).'
        $confirm = Read-Host 'Type DEPLOY to submit the ARM deployment'
        if ($confirm -cne 'DEPLOY') { throw 'Deployment cancelled by operator.' }

        $dep = New-AzResourceGroupDeployment `
                -ResourceGroupName $script:ResourceGroupName `
                -Name $script:DeploymentName `
                -TemplateFile $script:TemplateFile `
                -TemplateParameterFile $script:ParameterFile `
                @ov `
                -ErrorAction Stop
        Write-Ok "Deployment submitted: $($dep.DeploymentName) - provisioning state: $($dep.ProvisioningState)"
        Write-Info 'Azure Local cloud deployment runs for 1-3 hours. Track it in the portal (Azure Local instance) or with Get-AzResourceGroupDeployment.'
    }

    Complete-Ui -FinalMessage 'ARM deployment submitted.'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Azure Local deployment stage failed.'
    throw
}
