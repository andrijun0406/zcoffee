<#
.SYNOPSIS
    Remove ZCOFFEE Azure Local residue after a failed Stage 4/5 run.

.DESCRIPTION
    Lab-only cleanup. Preserves the resource group, service principal assignments,
    user access, and Arc Gateway. Removes node Arc resources, Azure Local-managed
    resource-group role assignments, and named failed-deployment artifacts.

    Deletes are submitted independently, then polled with a hard timeout.
    No action is taken without the typed confirmation token.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [string]$TenantId,
    [string]$ResourceGroupName = 'azljkt01rg',
    [string[]]$NodeNames = @('azljkt01n1','azljkt01n2'),
    [string[]]$NodeIPs = @('10.8.230.232','10.8.230.235'),
    [string]$LocalAdminUser = 'Administrator',
    [SecureString]$LocalAdminPassword,
    [int]$TimeoutMinutes = 20,
    [int]$PollSeconds = 5,
    [switch]$SkipLocalDisconnect,
    [switch]$ContinueOnNodeDisconnectFailure,
    [switch]$RemoveResourceLocks,
    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ("[ZCOFFEE] 07-cleanup-stale-resources.ps1 starting: {0}" -f $PSCommandPath)
Write-Host ("[ZCOFFEE] PowerShell: {0}" -f $PSVersionTable.PSVersion)

trap {
    Write-Host ("[ERR] Cleanup failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    break
}

$uiPath = Join-Path $PSScriptRoot 'ui-common.ps1'
if (Test-Path -Path $uiPath -PathType Leaf) {
    . $uiPath
    Write-Host ("[ZCOFFEE] Loaded shared UI: {0}" -f $uiPath)
} else {
    Write-Host ("[WARN] Shared UI not found: {0}" -f $uiPath) -ForegroundColor Yellow
}

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop
Write-Host '[ZCOFFEE] Az modules loaded.'

function Write-StageInfo([string]$Message) {
    if (Get-Command Write-Info -ErrorAction SilentlyContinue) { Write-Info $Message }
    else { Write-Host "[INFO] $Message" }
}
function Write-StageWarn([string]$Message) {
    if (Get-Command Write-Warn -ErrorAction SilentlyContinue) { Write-Warn $Message }
    else { Write-Warning $Message }
}
function Write-StageOk([string]$Message) {
    if (Get-Command Write-Ok -ErrorAction SilentlyContinue) { Write-Ok $Message }
    else { Write-Host "[OK]   $Message" -ForegroundColor Green }
}
function Write-StageErr([string]$Message) {
    if (Get-Command Write-Err -ErrorAction SilentlyContinue) { Write-Err $Message }
    else { Write-Host "[ERR]  $Message" -ForegroundColor Red }
}

function Get-ArmPath {
    param([string]$ResourceId, [string]$ApiVersion)
    return ('{0}?api-version={1}' -f $ResourceId, $ApiVersion)
}

function Test-ArmResourceExists {
    param([string]$ResourceId, [string]$ApiVersion)
    $path = Get-ArmPath $ResourceId $ApiVersion
    try {
        $response = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
        $status = $null
        if ($response -and ($response.PSObject.Properties.Name -contains 'StatusCode')) {
            $status = [int]$response.StatusCode
        }
        if ($null -ne $status -and $status -eq 404) { return $false }
        return $true
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match '404|NotFound') { return $false }
        throw ("ARM existence probe failed for {0}: {1}" -f $ResourceId, $message)
    }
}

function Submit-ArmDelete {
    param([string]$Name, [string]$ResourceId, [string]$ApiVersion)
    if (-not (Test-ArmResourceExists $ResourceId $ApiVersion)) {
        Write-StageInfo ("{0}: already absent" -f $Name)
        return $false
    }
    $response = Invoke-AzRestMethod -Method DELETE -Path (Get-ArmPath $ResourceId $ApiVersion) -ErrorAction Stop
    Write-StageInfo ("{0}: delete submitted (HTTP {1})" -f $Name, $response.StatusCode)
    return $true
}

function Wait-ArmAbsent {
    param([object[]]$Items, [datetime]$Deadline)
    $pending = [System.Collections.ArrayList]::new()
    foreach ($item in $Items) { [void]$pending.Add($item) }

    while ($pending.Count -gt 0 -and (Get-Date) -lt $Deadline) {
        for ($i = $pending.Count - 1; $i -ge 0; $i--) {
            $item = $pending[$i]
            try {
                $exists = Test-ArmResourceExists $item.ResourceId $item.ApiVersion
                if (-not $exists) {
                    Write-StageOk ("{0}: deleted" -f $item.Name)
                    $pending.RemoveAt($i)
                }
            }
            catch {
                Write-StageWarn ("{0}: status check failed: {1}" -f $item.Name, $_.Exception.Message)
            }
        }
        if ($pending.Count -gt 0) { Start-Sleep -Seconds $PollSeconds }
    }

    return @($pending)
}

$base = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$logRoot = Join-Path $PSScriptRoot 'logs'
New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runRoot = Join-Path $logRoot ("cleanup-stale-resources-{0}" -f $stamp)
New-Item -Path $runRoot -ItemType Directory -Force | Out-Null

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $ctx) {
    throw 'No Az context exists. Connect to Azure before running cleanup.'
}
Write-Host ("[INFO] Az context: account={0}; subscription={1}; tenant={2}" -f $ctx.Account.Id, $ctx.Subscription.Id, $ctx.Tenant.Id)
if (-not $ctx.Subscription -or $ctx.Subscription.Id -ne $SubscriptionId) {
    throw ("Current Az context is not subscription {0}. Connect/select it before running cleanup." -f $SubscriptionId)
}
if ($TenantId -and $ctx.Tenant -and $ctx.Tenant.Id -ne $TenantId) {
    throw ("Current Az context tenant is {0}, expected {1}." -f $ctx.Tenant.Id, $TenantId)
}

$clusterId = "$base/providers/Microsoft.AzureStackHCI/clusters/azljkt01clu"
try {
    $clusterExists = Test-ArmResourceExists $clusterId '2025-09-15-preview'
    if ($clusterExists) {
        Write-StageWarn ("Cluster probe: {0} returned 200; cleanup is blocked." -f $clusterId)
        throw 'Azure Local cluster exists. Use the supported decommission/unregister workflow; cleanup is blocked.'
    }
    Write-StageInfo ("Cluster probe: {0} returned 404; no cluster resource found." -f $clusterId)
}
catch {
    if ($_.Exception.Message -match 'Azure Local cluster exists') { throw }
    throw
}

try { $resources = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop) } catch { throw ("Resource inventory failed: {0}" -f $_.Exception.Message) }
$resources | Select-Object Name, ResourceType, ResourceId, ResourceGroupName |
    Export-Csv (Join-Path $runRoot 'resources-before.csv') -NoTypeInformation

$roleScope = $base
$managedRoleNames = @(
    'Azure Connected Machine Resource Manager',
    'Azure Stack HCI Device Management Role',
    'Azure Stack HCI Connected InfraVMs',
    'Key Vault Secrets Officer',
    'Key Vault Certificates Officer'
)
$roles = @(Get-AzRoleAssignment -Scope $roleScope | Where-Object { $_.Scope -ieq $roleScope })
$managedRoles = @($roles | Where-Object { $_.RoleDefinitionName -in $managedRoleNames })
$roles | Select-Object RoleAssignmentId, ObjectId, ObjectType, DisplayName, RoleDefinitionName, Scope |
    Export-Csv (Join-Path $runRoot 'role-assignments-before.csv') -NoTypeInformation

Write-StageInfo ("Preserving resource group {0}, Arc Gateway, service-principal subscription roles, and user access." -f $ResourceGroupName)
Write-StageInfo ("Planned node Arc removals: {0}" -f ($NodeNames -join ', '))
Write-StageInfo ("Planned managed RG role removals: {0}" -f $managedRoles.Count)

$confirmToken = 'DELETE-ZCOFFEE-LAB-RESIDUE'
if (-not $AutoApprove) {
    $answer = Read-Host ("Type {0} to continue" -f $confirmToken)
    if ($answer -cne $confirmToken) { throw 'Cleanup cancelled.' }
}

if (Get-Command Initialize-Ui -ErrorAction SilentlyContinue) {
    Initialize-Ui -StageName '07-cleanup-stale-resources' -TotalSteps 5 -UseGui:$false
}

$deleteItems = [System.Collections.ArrayList]::new()
try {
    if (Get-Command Invoke-Step -ErrorAction SilentlyContinue) {
        Invoke-Step 'Disconnect local Arc state' {
            if (-not $SkipLocalDisconnect) {
                $authUser = $LocalAdminUser
                if ($authUser -notmatch '[\\@]') { $authUser = ".\\$authUser" }
                if ($null -eq $LocalAdminPassword) {
                    $nodeCred = Get-LabNodeCredential -User $authUser
                } else {
                    $nodeCred = [PSCredential]::new($authUser, $LocalAdminPassword)
                }
                foreach ($ip in $NodeIPs) {
                    try {
                        Write-StageInfo ("Disconnecting local Arc state on {0}" -f $ip)
                        Invoke-Command -ComputerName $ip -Credential $nodeCred -ErrorAction Stop -ScriptBlock {
                            $exe = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\\azcmagent.exe'
                            $state = ((& $exe show -j 2>$null | Out-String) | ConvertFrom-Json -ErrorAction SilentlyContinue)
                            if ($state -and $state.status -eq 'Connected') { & $exe disconnect --force-local-only }
                        } | Out-Null
                        Write-StageOk ("Local Arc state handled on {0}" -f $ip)
                    }
                    catch {
                        if ($ContinueOnNodeDisconnectFailure) { Write-StageWarn ("{0}: disconnect failed, continuing: {1}" -f $ip, $_.Exception.Message) }
                        else { throw }
                    }
                }
            } else { Write-StageInfo 'Skipping local Arc disconnect by request.' }
        }
    }
    else { Write-StageInfo 'No UI helper loaded; continuing.' }

    if (Get-Command Invoke-Step -ErrorAction SilentlyContinue) {
        Invoke-Step 'Check locks and submit deletes' {
            $locks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue)
            if ($locks.Count -gt 0 -and -not $RemoveResourceLocks) {
                throw 'Resource locks exist. Review them or rerun with -RemoveResourceLocks.'
            }
            if ($RemoveResourceLocks) {
                foreach ($lock in $locks) {
                    Remove-AzResourceLock -LockId $lock.LockId -Force -ErrorAction Stop
                    Write-StageInfo ("Removed resource lock {0}" -f $lock.Name)
                }
            }

            foreach ($name in $NodeNames) {
                $id = "$base/providers/Microsoft.HybridCompute/machines/$name"
                if (Submit-ArmDelete "$name Arc machine" $id '2023-10-03-preview') {
                    [void]$deleteItems.Add([pscustomobject]@{ Name="$name Arc machine"; ResourceId=$id; ApiVersion='2023-10-03-preview' })
                }
            }

            foreach ($role in $managedRoles) {
                $id = $role.RoleAssignmentId
                if (Submit-ArmDelete ("Role assignment {0}/{1}" -f $role.RoleDefinitionName, $role.ObjectId) $id '2022-04-01') {
                    [void]$deleteItems.Add([pscustomobject]@{ Name="Role assignment $($role.RoleDefinitionName)/$($role.ObjectId)"; ResourceId=$id; ApiVersion='2022-04-01' })
                }
            }

            $artifactSpecs = @(
                @{ Name='Key Vault'; ResourceId="$base/providers/Microsoft.KeyVault/vaults/azljkt01kv"; ApiVersion='2021-06-01-preview' },
                @{ Name='Witness storage'; ResourceId="$base/providers/Microsoft.Storage/storageAccounts/azljkt01wit"; ApiVersion='2023-01-01' },
                @{ Name='Diagnostic storage'; ResourceId="$base/providers/Microsoft.Storage/storageAccounts/azljkt01diag"; ApiVersion='2023-01-01' }
            )
            foreach ($item in $artifactSpecs) {
                if (Submit-ArmDelete $item.Name $item.ResourceId $item.ApiVersion) { [void]$deleteItems.Add([pscustomobject]$item) }
            }
        }
    }

    if (Get-Command Invoke-Step -ErrorAction SilentlyContinue) {
        Invoke-Step 'Wait for cleanup with hard timeout' {
            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            $remaining = @(Wait-ArmAbsent $deleteItems $deadline)
            if ($remaining.Count -gt 0) {
                $remaining | Select-Object Name, ResourceId | Export-Csv (Join-Path $runRoot 'remaining.csv') -NoTypeInformation
                throw ("Cleanup timed out after {0} minutes. Remaining: {1}" -f $TimeoutMinutes, (($remaining.Name) -join ', '))
            }
        }
    }

    $after = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    $after | Select-Object Name, ResourceType, ResourceId, ResourceGroupName |
        Export-Csv (Join-Path $runRoot 'resources-after.csv') -NoTypeInformation

    Write-StageOk 'Cleanup completed. Arc Gateway and resource group were preserved.'
    if (Get-Command Complete-Ui -ErrorAction SilentlyContinue) { Complete-Ui -FinalMessage 'ZCOFFEE stale-resource cleanup completed.' }
}
catch {
    Write-StageErr $_.Exception.Message
    if (Get-Command Complete-Ui -ErrorAction SilentlyContinue) { Complete-Ui -Failed -FinalMessage 'ZCOFFEE cleanup failed.' }
    throw
}
