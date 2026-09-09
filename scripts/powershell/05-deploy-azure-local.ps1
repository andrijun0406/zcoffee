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

    # Required only for HTTPS WinRM listeners using self-signed certificates.
    [switch]$SkipCertCheck,

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

    # Detect managed RBAC automatically; cleanup is never implicit.
    [switch]$CleanupExistingRoleAssignments,

    # Explicitly continue despite potential stale managed assignments.
    [switch]$IgnoreExistingRoleAssignments,

    # Allow an intentional rerun when a prior/partial Azure Local cluster object remains.
    # This never deletes the cluster; it only changes the preflight from block to warning.
    [switch]$IgnoreExistingDeploymentArtifacts,

    [switch]$UseGui

)



Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ui-common.ps1')



$cfg = Import-LabConfig

$b   = $PSBoundParameters

$script:nodeCredential = $null
$script:runtimeParameterFile = $null



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

# Normalize the local account once so WinRM and DPAPI credential lookup use
# the same explicit workgroup identity (for example, .\Administrator).
$script:authUser = $LocalAdminUser
$script:CleanupExistingRoleAssignments = [bool]$CleanupExistingRoleAssignments
$script:IgnoreExistingRoleAssignments = [bool]$IgnoreExistingRoleAssignments
$script:IgnoreExistingDeploymentArtifacts = [bool]$IgnoreExistingDeploymentArtifacts
if ($script:authUser -notmatch '[\\@]') { $script:authUser = ".\\$script:authUser" }

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

if ($CleanupExistingRoleAssignments -and $IgnoreExistingRoleAssignments) {
    throw 'Use only one of -CleanupExistingRoleAssignments or -IgnoreExistingRoleAssignments.'
}

if ($CleanupExistingRoleAssignments -and $DeploymentMode -ne 'Deploy') {
    throw '-CleanupExistingRoleAssignments is allowed only with -DeploymentMode Deploy.'
}

if ($CleanupExistingRoleAssignments -and -not $EnableDeployment) {
    throw '-CleanupExistingRoleAssignments requires -EnableDeployment.'
}



$totalSteps = 5

if ($DeploymentMode -eq 'Deploy') { $totalSteps = 6 }

Initialize-Ui -StageName '05-deploy-azure-local' -TotalSteps $totalSteps -UseGui:$UseGui



# Azure Local managed role assignment helpers.
# Detection is automatic; deletion requires explicit cleanup switch + confirmation.
$script:azureLocalManagedRoleNames = @(
    'Azure Connected Machine Resource Manager',
    'Azure Stack HCI Device Management Role',
    'Azure Stack HCI Connected InfraVMs',
    'Key Vault Secrets Officer',
    'Key Vault Certificates Officer'
)

function Get-CurrentArcPrincipalIds {
    param([Parameter(Mandatory)][string[]]$ArcResourceIds)

    $result = @()
    foreach ($arcId in $ArcResourceIds) {
        $path = '{0}?api-version=2023-10-03-preview' -f $arcId
        try {
            $response = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
            $doc = $response.Content | ConvertFrom-Json
            # Arc machine identity can be transiently absent immediately after
            # registration. Treat a partially hydrated resource as unresolved,
            # not as a null-reference failure.
            $identity = $doc.identity
            if ($null -ne $identity) {
                $principal = [string]$identity.principalId
                if (-not [string]::IsNullOrWhiteSpace($principal)) {
                    $result += $principal
                }
            }
        }
        catch {
            Write-Warn ("Could not resolve current Arc principal for {0}: {1}" -f $arcId, $_.Exception.Message)
        }
    }
    return @($result)
}

function Get-AzureLocalManagedRoleAssignments {
    param([Parameter(Mandatory)][string]$ResourceGroupScope)

    # Query the RG scope once, then filter immediately in the pipeline. This keeps
    # customer/resource-group RBAC outside the Azure Local managed-role set.
    return @(
        Get-AzRoleAssignment -Scope $ResourceGroupScope -ErrorAction Stop |
            Where-Object {
                $_.Scope -ieq $ResourceGroupScope -and
                $_.RoleDefinitionName -in $script:azureLocalManagedRoleNames
            }
    )
}

function Remove-AzureLocalManagedRoleAssignments {
    param([Parameter(Mandatory)][object[]]$Assignments)

    foreach ($assignment in $Assignments) {
        $path = '{0}?api-version=2022-04-01' -f $assignment.RoleAssignmentId
        try {
            $result = Invoke-AzRestMethod -Method DELETE -Path $path -ErrorAction Stop
            Write-Info "Submitted stale role-assignment delete: $($assignment.RoleDefinitionName) / $($assignment.ObjectId) (HTTP $($result.StatusCode))"
        }
        catch {
            if ($_.Exception.Message -notmatch '404|NotFound') {
                throw "Failed deleting role assignment $($assignment.RoleAssignmentId): $($_.Exception.Message)"
            }
        }
    }

    $deadline = (Get-Date).AddMinutes(5)
    $pending = @($Assignments)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $next = @()
        foreach ($assignment in $pending) {
            $path = '{0}?api-version=2022-04-01' -f $assignment.RoleAssignmentId
            try {
                Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop | Out-Null
                $next += $assignment
            }
            catch {
                if ($_.Exception.Message -match '404|NotFound') {
                    Write-Info "Deleted stale role assignment: $($assignment.RoleAssignmentId)"
                }
                else {
                    $next += $assignment
                }
            }
        }
        $pending = @($next)
        if ($pending.Count -gt 0) { Start-Sleep -Seconds 5 }
    }

    if ($pending.Count -gt 0) {
        throw "Timed out waiting for stale role-assignment deletion: $(($pending | ForEach-Object { $_.RoleAssignmentId }) -join '; ')"
    }

    # REST GETs only prove the individual DELETE operations settled. Use the
    # authoritative RBAC query to verify that the targeted assignments are gone.
    $verifyScope = [string]$Assignments[0].Scope
    $deletedIds = @($Assignments | ForEach-Object {
        ([string]$_.RoleAssignmentId).ToLowerInvariant()
    })
    $remaining = @(
        Get-AzureLocalManagedRoleAssignments -ResourceGroupScope $verifyScope |
            Where-Object {
                $deletedIds -contains ([string]$_.RoleAssignmentId).ToLowerInvariant()
            }
    )
    if ($remaining.Count -gt 0) {
        throw "RBAC still reports targeted role assignments after cleanup: $(($remaining | ForEach-Object { $_.RoleAssignmentId }) -join '; ')"
    }
    Write-Ok "Verified removal of $($Assignments.Count) targeted role assignments through Get-AzRoleAssignment."
}

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

        # Use splatting instead of backtick continuation. Windows PowerShell 5.1
        # treats a blank line after a backtick as the end of the command, which
        # can make -ServicePrincipalId appear to be a standalone command.
        $authArgs = @{
            TenantId       = $script:TenantId
            SubscriptionId = $script:SubscriptionId
        }
        if ($script:ServicePrincipalId) {
            $authArgs['ServicePrincipalId'] = $script:ServicePrincipalId
        }
        if ($null -ne $script:ServicePrincipalSecret) {
            $authArgs['ServicePrincipalSecret'] = $script:ServicePrincipalSecret
        }
        if ($script:CertificateThumbprint) {
            $authArgs['CertificateThumbprint'] = $script:CertificateThumbprint
        }
        if ($script:UseManagedIdentity) {
            $authArgs['UseManagedIdentity'] = $true
        }
        if ($script:UseExistingAzLogin) {
            $authArgs['UseExistingAzLogin'] = $true
        }
        $ctx = Connect-AzForStage @authArgs

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


        # Detect residue from prior failed deployments without deleting it automatically.
        # A cluster object can represent a failed/recoverable deployment, so do not
        # delete it here. Block by default, or require an explicit override to proceed.
        $clusterResidue = @(Get-AzResource -ResourceGroupName $script:ResourceGroupName -ResourceType 'Microsoft.AzureStackHCI/clusters' -ErrorAction SilentlyContinue)
        if ($clusterResidue.Count -gt 0) {
            Write-Warn "Existing Azure Local cluster residue detected: $($clusterResidue.Name -join ', ')."
            if (-not $script:IgnoreExistingDeploymentArtifacts) {
                throw "Existing Azure Local cluster residue detected. Review/decommission it, or rerun with -IgnoreExistingDeploymentArtifacts for an intentional recovery attempt."
            }
            Write-Warn 'Continuing because -IgnoreExistingDeploymentArtifacts was supplied; no cluster resource was deleted.'
        }

        $residue = @(Get-AzResource -ResourceGroupName $script:ResourceGroupName -ErrorAction SilentlyContinue | Where-Object {
            $_.ResourceType -in @(
                'Microsoft.KeyVault/vaults',
                'Microsoft.Storage/storageAccounts',
                'Microsoft.Resources/deployments'
            )
        })
        if ($residue.Count -gt 0) {
            Write-Warn "Existing deployment artifacts detected and may be reused: $($residue.Name -join ', ')."
        }

        # A reimage changes system-assigned principal IDs while Arc resource IDs stay
        # stable. Azure forbids updating immutable role-assignment principal/scope fields.
        $roleScope = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)"
        $existingManagedAssignments = @(Get-AzureLocalManagedRoleAssignments -ResourceGroupScope $roleScope)
        $currentPrincipalIds = @(Get-CurrentArcPrincipalIds -ArcResourceIds $arcIds)
        # The HCI resource-provider identity is a legitimate managed principal too.
        # It is not one of the two Arc machine identities, so it must be allow-listed
        # separately; otherwise a healthy provider role is falsely reported as stale.
        $providerPrincipalId = $null
        try {
            if ($pv.hciResourceProviderObjectID -and $pv.hciResourceProviderObjectID.value) {
                $providerPrincipalId = [string]$pv.hciResourceProviderObjectID.value
            }
        } catch { }
        $allowedPrincipalIds = @($currentPrincipalIds + $providerPrincipalId) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique

        $potentialConflicts = @($existingManagedAssignments | Where-Object {
            $allowedPrincipalIds -notcontains ([string]$_.ObjectId)
        })

        if ($existingManagedAssignments.Count -gt 0) {
            Write-Warn "Existing Azure Local managed role assignments detected: $($existingManagedAssignments.Count)."
            foreach ($assignment in $existingManagedAssignments) {
                $oid = [string]$assignment.ObjectId
                $classification = if ($potentialConflicts -contains $assignment) {
                    'potential-stale-conflict'
                } elseif ($providerPrincipalId -and $oid -eq $providerPrincipalId) {
                    'hci-resource-provider'
                } else {
                    'current-principal'
                }
                Write-Warn ("  {0}: {1} / {2} / {3}" -f $classification, $assignment.RoleDefinitionName, $assignment.ObjectId, $assignment.RoleAssignmentId)
            }
        }

        if ($providerPrincipalId) {
            Write-Info ("Allowed HCI resource-provider principal: {0}" -f $providerPrincipalId)
        }

        if ($potentialConflicts.Count -gt 0) {
            if ($script:CleanupExistingRoleAssignments) {
                $confirmation = Read-Host 'Type REPAIR-STALE-ROLE-ASSIGNMENTS to delete only these RG-scoped managed assignments'
                if ($confirmation -cne 'REPAIR-STALE-ROLE-ASSIGNMENTS') {
                    throw 'Stale role-assignment cleanup cancelled.'
                }
                Remove-AzureLocalManagedRoleAssignments -Assignments $potentialConflicts
                Write-Ok "Removed $($potentialConflicts.Count) stale Azure Local managed role assignments."
            }
            elseif ($script:IgnoreExistingRoleAssignments) {
                Write-Warn 'Continuing despite potential stale role assignments because -IgnoreExistingRoleAssignments was supplied.'
            }
            else {
                # Preserve an operator-reviewable record before blocking. This is
                # intentionally non-secret RBAC metadata only.
                $logDir = Join-Path $PSScriptRoot 'logs'
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
                $conflictCsv = Join-Path $logDir 'stale-role-assignments.csv'
                $potentialConflicts |
                    Select-Object RoleAssignmentId, ObjectId, RoleDefinitionName, Scope |
                    Export-Csv -Path $conflictCsv -NoTypeInformation
                Write-Warn "Detected conflicts exported to: $conflictCsv"
                $summary = ($potentialConflicts | ForEach-Object { "$($_.RoleDefinitionName) [$($_.ObjectId)]" }) -join '; '
                throw "Potential stale Azure Local role assignments may cause RoleAssignmentUpdateNotPermitted: $summary. Use -CleanupExistingRoleAssignments for explicit lab cleanup or -IgnoreExistingRoleAssignments to proceed without deletion."
            }
        }
        elseif ($existingManagedAssignments.Count -gt 0) {
            Write-Info 'Existing managed assignments target current Arc principals; no stale conflict detected.'
        }
        else {
            Write-Ok 'No existing RG-scoped Azure Local managed role assignments detected.'
        }



        $script:templateJson = Get-Content $script:TemplateFile -Raw | ConvertFrom-Json

        $templateParameterNames = @($script:templateJson.parameters.PSObject.Properties.Name)

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



            # Always validate the node-side Arc postconditions. TargetSolutionVersion
            # only controls whether partner metadata is enforceable.
            if ($script:NodeIPs) {

                if (-not $script:nodeCredential) {

                    if ($b.ContainsKey('LocalAdminPassword') -and $null -ne $script:LocalAdminPassword) {

                        $script:nodeCredential = [System.Management.Automation.PSCredential]::new($script:authUser, $script:LocalAdminPassword)

                    } else { $script:nodeCredential = Get-LabNodeCredential -User $script:authUser }

                }

                $nodeByName = @{}

                if ($cfg.ContainsKey('Nodes')) { foreach ($n in $cfg.Nodes) { $nodeByName[$n.Name] = $n.HostIP } }

                foreach ($id in $arcIds) {

                    $name = ($id -split '/')[-1]

                    if (-not $nodeByName.ContainsKey($name)) { throw "No HostIP mapping found for Arc node $name." }

                    $conn = @{ ComputerName=$nodeByName[$name]; Credential=$script:nodeCredential; Port=$script:Port; Authentication='Negotiate'; ErrorAction='Stop' }

                    if ($script:Transport -eq 'HTTPS') {

                        $conn['UseSSL'] = $true

                        if ($script:SkipCertCheck) {
                            # Match Stage 4 behavior for self-signed WinRM HTTPS listeners.
                            $conn['SessionOption'] = New-PSSessionOption `
                                -SkipCACheck `
                                -SkipCNCheck
                        }
                    }

                    $state = Invoke-Command @conn -ScriptBlock {

                        $exe = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"

                        $j = ((& $exe show -j 2>$null | Out-String) | ConvertFrom-Json)



                        # TargetSolutionVersion/partnerconfig is capability-dependent. Older

                        # AzSHCI.ARCInstaller builds can successfully onboard and use Arc

                        # Gateway without exposing this parameter or partner metadata.

                        $init = Get-Command Invoke-AzStackHciArcInitialization -ErrorAction SilentlyContinue

                        $targetSupported = [bool]($init -and $init.Parameters.ContainsKey('TargetSolutionVersion'))

                        $partner = $null

                        $arcModule = @(Get-Module -ListAvailable -Name AzSHCI.ARCInstaller |
                            Sort-Object Version -Descending | Select-Object -First 1)

                        $arcInstallerVersion = if ($arcModule.Count -gt 0) {
                            [string]$arcModule[0].Version
                        } else {
                            'unknown'
                        }

                        if ($targetSupported) {

                            $partner = (& $exe partnerconfig get SolutionVersion --partner AzureLocal 2>&1 | Out-String).Trim()

                        }



                        [pscustomobject]@{

                            Status                 = [string]$j.status

                            Gateway                = ((& $exe config get connection.type 2>&1 | Out-String).Trim())

                            Partner                = $partner

                            TargetSolutionSupported = $targetSupported

                            ArcInstallerVersion      = $arcInstallerVersion

                        }

                    }



                    # Operational readiness is based on the actual Arc agent state and

                    # Azure-side Connected status. Partner metadata is checked only when

                    # the installed initializer explicitly supports TargetSolutionVersion.

                    if ($state.Status -ne 'Connected') { throw "Arc node $name is not Connected." }

                    $gatewayMode = if ($null -eq $state.Gateway) { '' } else { ([string]$state.Gateway).Trim() }

                    if ($script:UseArcGateway -and $gatewayMode -notmatch '(?i)^gateway$') {
                        throw "Arc node $name is not using gateway mode (reported '$gatewayMode')."
                    }



                    Write-Info "Arc node $name postconditions: Status=$($state.Status); GatewayMode=$gatewayMode; ArcInstaller=$($state.ArcInstallerVersion)"

                    if ($script:TargetSolutionVersion -and $state.TargetSolutionSupported) {

                        if ($state.Partner -notmatch "(?m)^\s*$([regex]::Escape($script:TargetSolutionVersion))\s*$") {

                            throw "Arc node $name lacks AzureLocal partner SolutionVersion $script:TargetSolutionVersion. Run Stage 4 Register."

                        }

                        Write-Ok "Arc node composite readiness verified: $name (partner $($script:TargetSolutionVersion))"

                    }

                    elseif ($script:TargetSolutionVersion -and -not $state.TargetSolutionSupported) {

                        Write-Warn "Arc node $name initializer does not support TargetSolutionVersion (AzSHCI.ARCInstaller $($state.ArcInstallerVersion)); partner metadata check skipped."

                        Write-Ok "Arc node operational readiness verified: $name"

                    }

                    else {

                        Write-Ok "Arc node operational readiness verified: $name"

                    }

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

        # The parameter file defaults deploymentMode to Validate. Override it at
        # runtime so Deploy mode cannot accidentally submit a validation deployment.
        if ($script:templateParameterObject.ContainsKey('deploymentMode')) {
            $script:templateParameterObject['deploymentMode'] = [string]$DeploymentMode
            Write-Info "ARM deploymentMode override: $DeploymentMode"
        }


        # Build one temporary ARM parameter file for Validate, What-If, and Deploy.
        # v13: unwrap nested ARM value wrappers before serialization and preserve
        # dictionary/object values without unary-comma wrapping.
        # v9: unwrap nested ARM value wrappers before serialization.
        # This keeps ARM array types (for example dnsServers) identical across all paths
        # and avoids Az.Resources TemplateParameterObject serialization differences.
        function ConvertTo-ArmRuntimeValue {
            param([AllowNull()][object]$Value)

            if ($null -eq $Value) { return $null }

            if ($Value -is [System.Security.SecureString]) {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
                try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            }

            # Handle arrays/enumerables BEFORE PSCustomObject. In Windows PowerShell 5.1,
            # inspecting an array through PSObject can otherwise turn it into a property
            # dictionary, which ARM then receives as an object instead of an array.
            if (($Value -is [System.Collections.IEnumerable]) -and
                -not ($Value -is [string]) -and
                -not ($Value -is [System.Collections.IDictionary])) {
                $items = New-Object System.Collections.ArrayList
                foreach ($item in $Value) {
                    [void]$items.Add((ConvertTo-ArmRuntimeValue $item))
                }
                return ,([object[]]$items.ToArray())
            }

            if ($Value -is [System.Collections.IDictionary]) {
                $h = [ordered]@{}
                foreach ($key in $Value.Keys) {
                    $h[$key] = ConvertTo-ArmRuntimeValue $Value[$key]
                }
                return $h
            }

            if ($Value -is [pscustomobject]) {
                $h = [ordered]@{}
                foreach ($prop in $Value.PSObject.Properties) {
                    $h[$prop.Name] = ConvertTo-ArmRuntimeValue $prop.Value
                }
                return $h
            }

            return $Value
        }

        # Normalize ARM array parameters at the source boundary. PowerShell 5.1
        # can unwrap a one-item function result and can also preserve a JSON
        # object wrapper as an OrderedDictionary. Rebuild each array directly
        # from the raw parameter-file value as a real System.Object[].
        foreach ($meta in $script:templateJson.parameters.PSObject.Properties) {
            if ([string]$meta.Value.type -ne 'array') { continue }
            if (-not ($script:templateParameterObject.Keys -contains $meta.Name)) { continue }

            $rawProp = $script:parameterFileObject.parameters.PSObject.Properties[$meta.Name]
            $rawValue = $null
            if ($null -ne $rawProp -and $rawProp.Value -and
                ($rawProp.Value.PSObject.Properties.Name -contains 'value')) {
                $rawValue = $rawProp.Value.value
            }

            # Prefer the raw JSON array when present. These are the authoritative
            # values for dnsServers, dnsZones, intentList, storageNetworkList,
            # physicalNodesSettings, and arcNodeResourceIds in this template.
            if ($null -ne $rawValue) {
                $rawItems = @($rawValue)
                $arrayValue = New-Object object[] $rawItems.Count
                for ($i = 0; $i -lt $rawItems.Count; $i++) {
                    $arrayValue[$i] = $rawItems[$i]
                }
                $script:templateParameterObject[$meta.Name] = $arrayValue
                continue
            }

            $v = $script:templateParameterObject[$meta.Name]
            if ($null -eq $v) {
                $script:templateParameterObject[$meta.Name] = (New-Object object[] 0)
            }
            elseif ($v -is [string] -or
                    -not ($v -is [System.Collections.IEnumerable])) {
                $script:templateParameterObject[$meta.Name] = [object[]]@($v)
            }
            else {
                $items = @($v)
                $arrayValue = New-Object object[] $items.Count
                for ($i = 0; $i -lt $items.Count; $i++) {
                    $arrayValue[$i] = $items[$i]
                }
                $script:templateParameterObject[$meta.Name] = $arrayValue
            }
        }

        $runtimeDoc = [ordered]@{
            '$schema' = if ($script:parameterFileObject.PSObject.Properties.Name -contains '$schema') {
                [string]$script:parameterFileObject.'$schema'
            } else {
                'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            }
            contentVersion = if ($script:parameterFileObject.PSObject.Properties.Name -contains 'contentVersion') {
                [string]$script:parameterFileObject.contentVersion
            } else {
                '1.0.0.0'
            }
            parameters = [ordered]@{}
        }

        # ARM parameter values can arrive as nested wrappers such as
        # @{ value = @{ value = @('10.8.230.51') } }.  Unwrap only the
        # parameter-value wrapper at this final boundary, then force every
        # template-declared array to a real object[] before JSON serialization.
        function Unwrap-ArmParameterValue {
            param([AllowNull()][object]$Value)

            while ($Value -is [System.Collections.IDictionary] -and
                   @($Value.Keys).Count -eq 1 -and
                   (@($Value.Keys) -contains 'value')) {
                $Value = $Value['value']
            }

            return $Value
        }

        $arrayParameterNames = @(
            $script:templateJson.parameters.PSObject.Properties |
                Where-Object { [string]$_.Value.type -eq 'array' } |
                ForEach-Object { $_.Name }
        )

        # Build the runtime document from the original parameter-file values first.
        # This avoids serializing the intermediate ARM parameter-object wrappers.
        foreach ($key in $script:templateParameterObject.Keys) {
            $rawValue = $null
            $hasSourceValue = $false

            $sourceProp = $script:parameterFileObject.parameters.PSObject.Properties[$key]
            if ($null -ne $sourceProp -and $null -ne $sourceProp.Value -and
                ($sourceProp.Value.PSObject.Properties.Name -contains 'value')) {
                $rawValue = $sourceProp.Value.value
                $hasSourceValue = $true
            }

            # Runtime values take precedence over the source parameter file.
            if ($key -eq 'deploymentMode') {
                # The source parameter file defaults to Validate. The selected
                # runtime mode must win in the generated file used by Validate,
                # What-If, and Deploy.
                $rawValue = [string]$DeploymentMode
            }
            elseif ($key -eq 'localAdminUserName') {
                $rawValue = $script:LocalAdminUser
            }
            elseif ($key -eq 'localAdminPassword') {
                $rawValue = $script:LocalAdminPassword
            }
            elseif ($script:gatewayTemplateOverrides -and
                    ($script:gatewayTemplateOverrides.Keys -contains $key)) {
                $rawValue = $script:gatewayTemplateOverrides[$key]
            }
            elseif (-not $hasSourceValue) {
                $rawValue = $script:templateParameterObject[$key]
            }

            $rawValue = Unwrap-ArmParameterValue $rawValue

            if ($key -eq 'dnsServers') {
                $rawType = if ($null -eq $rawValue) { 'NULL' } else { $rawValue.GetType().FullName }
                $rawCount = if (($rawValue -is [System.Collections.IEnumerable]) -and
                                -not ($rawValue -is [string]) -and
                                -not ($rawValue -is [System.Collections.IDictionary])) { @($rawValue).Count } else { '-' }
                Write-Info ("dnsServers after source unwrap: type={0}; Count={1}" -f $rawType, $rawCount)
            }

            if ($arrayParameterNames -contains $key) {
                if ($null -eq $rawValue) {
                    $items = @()
                }
                elseif (($rawValue -is [System.Collections.IDictionary]) -and
                        (@($rawValue.Keys) -contains 'value') -and
                        @($rawValue.Keys).Count -eq 1) {
                    $items = @((Unwrap-ArmParameterValue $rawValue['value']))
                }
                elseif (($rawValue -is [System.Collections.IEnumerable]) -and
                        -not ($rawValue -is [string])) {
                    $items = @($rawValue)
                }
                else {
                    $items = @($rawValue)
                }

                $arrayValue = New-Object object[] $items.Count
                for ($i = 0; $i -lt $items.Count; $i++) {
                    $arrayValue[$i] = Unwrap-ArmParameterValue $items[$i]
                }
                $rawValue = $arrayValue
            }

            $safeValue = ConvertTo-ArmRuntimeValue $rawValue
            if ($key -eq 'dnsServers') {
                $safeType = if ($null -eq $safeValue) { 'NULL' } else { $safeValue.GetType().FullName }
                $safeCount = if (($safeValue -is [System.Collections.IEnumerable]) -and
                                 -not ($safeValue -is [string]) -and
                                 -not ($safeValue -is [System.Collections.IDictionary])) { @($safeValue).Count } else { '-' }
                Write-Info ("dnsServers after runtime conversion: type={0}; Count={1}" -f $safeType, $safeCount)
            }
            $runtimeDoc.parameters[$key] = [ordered]@{ value = $safeValue }
        }

        # Final authoritative override: the source parameter file defaults to Validate,
        # so enforce the operator-selected mode after the complete reconstruction pass.
        if ($runtimeDoc.parameters.Keys -contains 'deploymentMode') {
            $runtimeDoc.parameters['deploymentMode']['value'] = [string]$DeploymentMode
            Write-Info ("Runtime deploymentMode value: {0}" -f $runtimeDoc.parameters['deploymentMode']['value'])
        }

        $runtimeParameterFileName = 'zcoffee-arm-parameters-{0}-{1}.json' -f `
            $script:DeploymentName, ([Guid]::NewGuid().ToString('N'))
        $script:runtimeParameterFile = Join-Path ([IO.Path]::GetTempPath()) $runtimeParameterFileName
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $runtimeJson = $serializer.Serialize($runtimeDoc)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($script:runtimeParameterFile, $runtimeJson, $utf8NoBom)

        # Persist a redacted copy for forensic review. The temporary runtime file
        # contains the injected local-admin password and is removed in finally;
        # this debug copy preserves the exact JSON shape without the secret.
        $debugLogRoot = Join-Path $PSScriptRoot 'logs'
        if (-not (Test-Path -Path $debugLogRoot -PathType Container)) {
            New-Item -Path $debugLogRoot -ItemType Directory -Force | Out-Null
        }
        $debugRuntimeDoc = $serializer.DeserializeObject($runtimeJson)
        if ($debugRuntimeDoc -and $debugRuntimeDoc['parameters'] -and
            $debugRuntimeDoc['parameters']['localAdminPassword']) {
            $debugRuntimeDoc['parameters']['localAdminPassword']['value'] = '<redacted>'
        }
        $debugRuntimePath = Join-Path $debugLogRoot 'runtime-arm-debug.json'
        $debugJson = $serializer.Serialize($debugRuntimeDoc)
        [IO.File]::WriteAllText($debugRuntimePath, $debugJson, $utf8NoBom)
        Write-Info "Redacted runtime ARM debug file: $debugRuntimePath"
        Write-Info ("Runtime debug deploymentMode value: {0}" -f $debugRuntimeDoc['parameters']['deploymentMode']['value'])

        Write-Info "Runtime ARM parameter file: $script:runtimeParameterFile"
        Write-Info "Runtime ARM parameter count: $($runtimeDoc.parameters.Count)"
        if ($runtimeDoc.parameters.Keys -contains 'dnsServers') {
            $dnsEntry = $runtimeDoc.parameters['dnsServers']
            $dnsRuntime = $dnsEntry['value']
            if ($null -ne $dnsRuntime) {
                $dnsType = $dnsRuntime.GetType().FullName
                $dnsCount = if ($dnsRuntime -is [System.Collections.ICollection]) { $dnsRuntime.Count } else { '-' }
                Write-Info "Runtime dnsServers shape: $dnsType; Count=$dnsCount"
            }
            else {
                Write-Warn 'Runtime dnsServers is NULL.'
            }
        }

        # Read the exact serialized representation with JavaScriptSerializer.
        # JavaScriptSerializer may materialize a JSON array as object[], ArrayList,
        # or another IEnumerable implementation; do not require System.Array.
        $serializedDoc = $serializer.DeserializeObject($runtimeJson)
        $serializedDns = $serializedDoc['parameters']['dnsServers']['value']
        $serializedDnsType = if ($null -eq $serializedDns) { 'NULL' } else { $serializedDns.GetType().FullName }
        $serializedDnsCount = if ($serializedDns -is [System.Collections.IEnumerable] -and
                                   -not ($serializedDns -is [string]) -and
                                   -not ($serializedDns -is [System.Collections.IDictionary])) {
            @($serializedDns).Count
        } else {
            '-'
        }
        Write-Info ("Serialized dnsServers runtime type: {0}; Count={1}" -f $serializedDnsType, $serializedDnsCount)

        if ($null -eq $serializedDns) {
            throw 'Runtime ARM parameter file serialized dnsServers.value as NULL.'
        }
        if ($serializedDns -is [string]) {
            throw 'Runtime ARM parameter file serialized dnsServers.value as a scalar string.'
        }
        if ($serializedDns -is [System.Collections.IDictionary]) {
            throw ("Runtime ARM parameter file serialized dnsServers.value as an object ({0}), not an array." -f $serializedDnsType)
        }
        if (-not ($serializedDns -is [System.Collections.IEnumerable])) {
            throw ("Runtime ARM parameter file serialized dnsServers.value as unexpected type: {0}" -f $serializedDnsType)
        }

        Write-Ok "Local admin '$script:LocalAdminUser' credential prepared for injection (never logged)."

        Write-Info 'If the template also requires a separate deployment/LCM credential, add it here.'

    }



    # -----------------------------------------------------------------

    if ($DeploymentMode -eq 'Validate') {

        Invoke-Step 'Run non-mutating ARM validation (Test-AzResourceGroupDeployment)' {

            $validationArgs = @{
                ResourceGroupName       = $script:ResourceGroupName
                TemplateFile            = $script:TemplateFile
                TemplateParameterFile   = $script:runtimeParameterFile
                ErrorAction             = 'Stop'
            }
            $r = Test-AzResourceGroupDeployment @validationArgs 4>$null

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

        # What-If must receive the same explicit template/parameter contract as
        # Test-AzResourceGroupDeployment. Use splatting because Windows PowerShell
        # 5.1 can break backtick-continued commands at blank lines and then emit
        # the misleading 'TemplateFile not supplied' dynamic-parameter error.
        if (-not (Test-Path -Path $script:TemplateFile -PathType Leaf)) {
            throw "What-If template disappeared: $script:TemplateFile"
        }

        $whatIfCommand = Get-Command Get-AzResourceGroupDeploymentWhatIfResult `
            -ErrorAction Stop
        if (-not $whatIfCommand.Parameters.ContainsKey('TemplateFile') -or
            -not $whatIfCommand.Parameters.ContainsKey('TemplateParameterFile')) {
            throw 'Installed Az.Resources What-If cmdlet does not support TemplateFile + TemplateParameterFile.'
        }

        if (-not (Test-Path -Path $script:runtimeParameterFile -PathType Leaf)) {
            throw "Runtime ARM parameter file missing: $script:runtimeParameterFile"
        }

        if ($script:DeploymentMode -eq 'Deploy') {
            $armMode = [string]$script:templateParameterObject['deploymentMode']
            if ($armMode -ne 'Deploy') {
                throw "ARM deploymentMode is '$armMode'; refusing to preview or submit a non-Deploy payload."
            }
        }

        Write-Info "What-If TemplateFile: $script:TemplateFile"
        Write-Info "What-If Parameter Count: $($script:templateParameterObject.Count)"
        Write-Info "What-If ARM deploymentMode: $($script:templateParameterObject['deploymentMode'])"

        $whatIfArgs = @{
            ResourceGroupName       = $script:ResourceGroupName
            TemplateFile            = $script:TemplateFile
            TemplateParameterFile   = $script:runtimeParameterFile
            ErrorAction             = 'Stop'
        }
        $wi = Get-AzResourceGroupDeploymentWhatIfResult @whatIfArgs

        $wi | Out-Host

    }



    Invoke-Step 'Confirm and submit the deployment' {

        Write-Warn 'This creates the Azure Local instance and configures BOTH nodes (SET switch, S2D, cluster).'

        $confirm = Read-Host 'Type DEPLOY to submit the ARM deployment'

        if ($confirm -cne 'DEPLOY') { throw 'Deployment cancelled by operator.' }



        $deploymentArgs = @{
            ResourceGroupName       = $script:ResourceGroupName
            Name                    = $script:DeploymentName
            TemplateFile            = $script:TemplateFile
            TemplateParameterFile   = $script:runtimeParameterFile
            ErrorAction             = 'Stop'
        }
        $dep = New-AzResourceGroupDeployment @deploymentArgs

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
finally {

    if ($script:runtimeParameterFile -and (Test-Path -Path $script:runtimeParameterFile -PathType Leaf)) {
        Remove-Item -Path $script:runtimeParameterFile -Force -ErrorAction SilentlyContinue
        $script:runtimeParameterFile = $null
    }

}

