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
    [switch]$UseArcGateway,
    [string]$ArcGatewayID,
    [string]$ArcGatewayName,
    [string]$TargetSolutionVersion,
    [string[]]$NodeIPs,
    [ValidateSet('HTTP','HTTPS')]
    [string]$Transport = 'HTTP',
    [int]$Port,
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
$script:nodeCredential = $null

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
$UseArcGateway     = [bool](Resolve-Setting -Name 'UseArcGateway' -Bound $b -Current ([bool]$UseArcGateway) -ConfigKey 'UseArcGateway' -Config $cfg)
$ArcGatewayName    = Resolve-Setting -Name 'ArcGatewayName' -Bound $b -Current $ArcGatewayName -ConfigKey 'ArcGatewayName' -Config $cfg
$ArcGatewayID      = Resolve-Setting -Name 'ArcGatewayID' -Bound $b -Current $ArcGatewayID -ConfigKey 'ArcGatewayID' -Config $cfg
$TargetSolutionVersion = Resolve-Setting -Name 'TargetSolutionVersion' -Bound $b -Current $TargetSolutionVersion -ConfigKey 'TargetSolutionVersion' -Config $cfg
if (-not $Port) { $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 } }
if (-not $b.ContainsKey('NodeIPs')) { if ($cfg.ContainsKey('Nodes')) { $NodeIPs = @($cfg.Nodes | ForEach-Object { $_.HostIP }) } }

if (-not $SubscriptionId) { throw 'SubscriptionId is required. Pass -SubscriptionId (from your private runbook).' }

# Deploy mode requires the explicit safety switch.
if ($DeploymentMode -eq 'Deploy' -and -not $EnableDeployment) {
    throw 'Deploy mode is disabled by default. Re-run with -DeploymentMode Deploy -EnableDeployment after review.'
}

$totalSteps = 5
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

        if ($script:UseArcGateway) {
            $statePath = Join-Path $PSScriptRoot 'config\arc-gateway.local.json'
            if (-not $script:ArcGatewayID -and (Test-Path $statePath -PathType Leaf)) {
                try { $script:ArcGatewayID = [string]((Get-Content $statePath -Raw | ConvertFrom-Json).resourceId) } catch { }
            }
            if (-not $script:ArcGatewayID) {
                throw 'UseArcGateway is enabled but no Arc Gateway ID is available. Run Stage 4 Register first.'
            }
            $gw = Get-AzResource -ResourceId $script:ArcGatewayID -ErrorAction Stop
            if ($gw.ResourceType -ne 'Microsoft.HybridCompute/gateways') { throw 'Configured ArcGatewayID is not a Microsoft.HybridCompute/gateways resource.' }
            if ($gw.ResourceId -notmatch "^/subscriptions/$([regex]::Escape($script:SubscriptionId))/") {
                throw 'Arc Gateway must be in the Azure Local deployment subscription.'
            }
            $script:ArcGatewayID = $gw.ResourceId
            Write-Ok "Arc Gateway validated: $script:ArcGatewayID"
        }

        # Parse the parameter file and check adapter names / arcNodeResourceIds.
        # Persist the parsed parameter document for later Invoke-Step blocks.
        # Invoke-Step may execute its scriptblock in a child/local scope; using
        # script scope prevents StrictMode from reporting $pf as undefined.
        $script:parameterFileObject = Get-Content $script:ParameterFile -Raw | ConvertFrom-Json
        $pv = $script:parameterFileObject.parameters

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

        $templateJson = Get-Content $script:TemplateFile -Raw | ConvertFrom-Json
        $templateParameterNames = @($templateJson.parameters.PSObject.Properties.Name)
        Write-Info "ARM template parameters loaded: $($templateParameterNames.Count)"
        $hasGatewayIdParameter = $templateParameterNames -contains 'arcGatewayId'
        $hasUseGatewayParameter = $templateParameterNames -contains 'useArcGateway'
        if ($script:UseArcGateway -and ($hasGatewayIdParameter -xor $hasUseGatewayParameter)) {
            throw 'ARM template must declare both arcGatewayId and useArcGateway, or neither.'
        }
        if ($script:UseArcGateway -and $hasGatewayIdParameter) {
            $script:gatewayTemplateOverrides = @{ arcGatewayId = $script:ArcGatewayID; useArcGateway = $true }
            Write-Ok 'ARM template exposes Arc Gateway parameters; runtime overrides will be supplied.'
        } elseif ($script:UseArcGateway) {
            $script:gatewayTemplateOverrides = @{}
            Write-Info 'ARM template has no Arc Gateway parameters; using Stage 4 Arc machine association.'
        } else {
            $script:gatewayTemplateOverrides = @{}
        }

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

            if ($script:TargetSolutionVersion -and $script:NodeIPs) {
                if (-not $script:nodeCredential) {
                    if ($b.ContainsKey('LocalAdminPassword') -and $null -ne $script:LocalAdminPassword) {
                        $script:nodeCredential = [System.Management.Automation.PSCredential]::new(".\$script:LocalAdminUser", $script:LocalAdminPassword)
                    } else { $script:nodeCredential = Get-LabNodeCredential -User $script:LocalAdminUser }
                }
                $nodeByName = @{}
                if ($cfg.ContainsKey('Nodes')) { foreach ($n in $cfg.Nodes) { $nodeByName[$n.Name] = $n.HostIP } }
                foreach ($id in $arcIds) {
                    $name = ($id -split '/')[-1]
                    if (-not $nodeByName.ContainsKey($name)) { throw "No HostIP mapping found for Arc node $name." }
                    $conn = @{ ComputerName=$nodeByName[$name]; Credential=$script:nodeCredential; Port=$script:Port; Authentication='Negotiate'; ErrorAction='Stop' }
                    if ($script:Transport -eq 'HTTPS') { $conn['UseSSL']=$true }
                    $state = Invoke-Command @conn -ScriptBlock {
                        $exe = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
                        $j = ((& $exe show -j 2>$null | Out-String) | ConvertFrom-Json)
                        $p = (& $exe partnerconfig get SolutionVersion --partner AzureLocal 2>&1 | Out-String).Trim()
                        [pscustomobject]@{ Status=[string]$j.status; Gateway=((& $exe config get connection.type 2>&1 | Out-String).Trim()); Partner=$p }
                    }
                    if ($state.Status -ne 'Connected') { throw "Arc node $name is not Connected." }
                    if ($script:UseArcGateway -and $state.Gateway -notmatch '(?i)^gateway$') { throw "Arc node $name is not using gateway mode." }
                    if ($state.Partner -notmatch "(?m)^\s*$([regex]::Escape($script:TargetSolutionVersion))\s*$") { throw "Arc node $name lacks AzureLocal partner SolutionVersion $script:TargetSolutionVersion. Run Stage 4 Register." }
                    Write-Ok "Arc node composite readiness verified: $name"
                }
            }
        }
    }

    # -----------------------------------------------------------------
    Invoke-Step 'Prepare secure deployment parameters' {
        if (-not $b.ContainsKey('LocalAdminPassword') -or $null -eq $script:LocalAdminPassword) {
            $script:LocalAdminPassword = Read-Host -Prompt "Enter the local admin password for '$script:LocalAdminUser' (exists on both nodes)" -AsSecureString
        }
        # Build one TemplateParameterObject from the JSON file, then apply
        # runtime overrides. ARM cmdlets do not allow TemplateParameterFile
        # and TemplateParameterObject in the same parameter set.
        function ConvertTo-ArmParameterValue {
            param([AllowNull()][object]$Value)

            if ($null -eq $Value) { return $null }
            if ($Value -is [System.Collections.IDictionary]) {
                $h = @{}
                foreach ($key in $Value.Keys) {
                    $h[$key] = ConvertTo-ArmParameterValue $Value[$key]
                }
                return $h
            }
            if ($Value -is [pscustomobject]) {
                $h = @{}
                foreach ($prop in $Value.PSObject.Properties) {
                    $h[$prop.Name] = ConvertTo-ArmParameterValue $prop.Value
                }
                return $h
            }
            if (($Value -is [System.Collections.IEnumerable]) -and
                -not ($Value -is [string]) -and
                -not ($Value -is [System.Security.SecureString])) {
                $items = @()
                foreach ($item in $Value) {
                    $items += ,(ConvertTo-ArmParameterValue $item)
                }
                return $items
            }
            return $Value
        }

        $script:templateParameterObject = @{}
        foreach ($property in $script:parameterFileObject.parameters.PSObject.Properties) {
            $entry = $property.Value
            if ($entry -and ($entry.PSObject.Properties.Name -contains 'value')) {
                $script:templateParameterObject[$property.Name] =
                    ConvertTo-ArmParameterValue $entry.value
            }
        }
        $script:templateParameterObject['localAdminUserName'] = $script:LocalAdminUser
        $script:templateParameterObject['localAdminPassword'] = $script:LocalAdminPassword

        if ($script:gatewayTemplateOverrides -and $script:gatewayTemplateOverrides.Count -gt 0) {
            foreach ($k in $script:gatewayTemplateOverrides.Keys) {
                $script:templateParameterObject[$k] = $script:gatewayTemplateOverrides[$k]
            }
        }
        Write-Ok "Local admin '$script:LocalAdminUser' credential prepared for injection (never logged)."
        Write-Info 'If the template also requires a separate deployment/LCM credential, add it here.'
    }

    # -----------------------------------------------------------------
    if ($DeploymentMode -eq 'Validate') {
        Invoke-Step 'Run non-mutating ARM validation (Test-AzResourceGroupDeployment)' {
            $r = Test-AzResourceGroupDeployment `
                    -ResourceGroupName $script:ResourceGroupName `
                    -TemplateFile $script:TemplateFile `
                    -TemplateParameterObject $script:templateParameterObject `
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
                -TemplateParameterObject $script:templateParameterObject `
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
                -TemplateParameterObject $script:templateParameterObject `
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
