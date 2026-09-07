<#
.SYNOPSIS
    Delete ZCOFFEE resources left by a failed Stage 4/5 run.

.DESCRIPTION
    Preserves the resource group and Arc Gateway, then submits independent
    deletes for stale Arc machines and Azure Local deployment artifacts.
    Deletes are submitted in one quick pass; Azure processes them independently.
    The script polls each target with a hard timeout and never waits forever.

    Preserved by design:
      - Resource group
      - Arc Gateway zcoffee-arcgw
      - Service principal and role assignments
      - User access

    Removed by default:
      - azljkt01n1 and azljkt01n2 Arc machine resources
      - azljkt01wit witness storage
      - azljkt01diag diagnostic storage
      - azljkt01kv deployment Key Vault

.NOTES
    Windows PowerShell 5.1 compatible.
    Run only after confirming no Microsoft.AzureStackHCI cluster exists.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [string]$ResourceGroupName = 'azljkt01rg',
    [string]$ArcGatewayName = 'zcoffee-arcgw',
    [string]$TenantId,

    [int]$TimeoutMinutes = 20,
    [ValidateRange(1, 60)]
    [int]$PollSeconds = 3,

    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -Path $logDir -ItemType Directory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$inventoryPath = Join-Path $logDir "stale-cleanup-inventory-$stamp.csv"
$rolesPath = Join-Path $logDir "stale-cleanup-role-assignments-$stamp.csv"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Test-ArmNotFound {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    return ($ErrorRecord.Exception.Message -match '(?i)404|not.?found|resourcenotfound')
}

function New-ArmPath {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )
    return ('{0}?api-version={1}' -f $ResourceId, $ApiVersion)
}

function Get-ArmResourceState {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Target
    )

    $path = New-ArmPath -ResourceId $Target.Id -ApiVersion $Target.Api

    try {
        $response = Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop
        $content = $null
        if ($response.Content) {
            try { $content = $response.Content | ConvertFrom-Json } catch { }
        }

        $state = $null
        if ($content -and $content.properties) {
            $state = $content.properties.provisioningState
        }

        return [pscustomobject]@{
            Exists           = $true
            ProvisioningState = $state
            StatusCode       = $response.StatusCode
        }
    }
    catch {
        if (Test-ArmNotFound $_) {
            return [pscustomobject]@{
                Exists            = $false
                ProvisioningState = $null
                StatusCode        = 404
            }
        }
        throw
    }
}

function Submit-ArmDelete {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Target
    )

    $path = New-ArmPath -ResourceId $Target.Id -ApiVersion $Target.Api

    try {
        $before = Get-ArmResourceState -Target $Target
        if (-not $before.Exists) {
            Write-Ok "$($Target.Name): already absent"
            return [pscustomobject]@{
                Target    = $Target
                Submitted = $false
                Complete  = $true
                Failed    = $false
            }
        }

        $response = Invoke-AzRestMethod -Method DELETE -Path $path -ErrorAction Stop
        Write-Info "$($Target.Name): delete submitted (HTTP $($response.StatusCode))"

        return [pscustomobject]@{
            Target    = $Target
            Submitted = $true
            Complete  = $false
            Failed    = $false
        }
    }
    catch {
        if (Test-ArmNotFound $_) {
            Write-Ok "$($Target.Name): already absent"
            return [pscustomobject]@{
                Target    = $Target
                Submitted = $false
                Complete  = $true
                Failed    = $false
            }
        }

        Write-Warn "$($Target.Name): delete submission failed - $($_.Exception.Message)"
        return [pscustomobject]@{
            Target    = $Target
            Submitted = $false
            Complete  = $false
            Failed    = $true
            Error     = $_.Exception.Message
        }
    }
}

try {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        throw 'No Az context is available. Sign in first with Connect-AzAccount.'
    }

    $setContext = @{ SubscriptionId = $SubscriptionId; ErrorAction = 'Stop' }
    if ($TenantId) { $setContext['Tenant'] = $TenantId }
    Set-AzContext @setContext | Out-Null
    Write-Ok "Using subscription $SubscriptionId"

    $base = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    $gatewayId = "$base/providers/Microsoft.HybridCompute/gateways/$ArcGatewayName"
    $gateway = Get-AzResource -ResourceId $gatewayId -ErrorAction SilentlyContinue
    if (-not $gateway) {
        throw "Expected Arc Gateway not found: $gatewayId. Cleanup stopped."
    }
    Write-Ok "Preserving Arc Gateway: $gatewayId"

    $clusterId = "$base/providers/Microsoft.AzureStackHCI/clusters/azljkt01clu"
    $cluster = Get-AzResource -ResourceId $clusterId -ErrorAction SilentlyContinue
    if ($cluster) {
        throw "Azure Local cluster exists: $clusterId. Use the supported decommission path first."
    }
    Write-Ok 'No Azure Local cluster resource found.'

    $locks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue)
    if ($locks.Count -gt 0) {
        $locks | Format-List
        throw 'Resource locks exist. Review/remove only approved locks before cleanup.'
    }

    $inventory = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    $inventory |
        Select-Object Name, ResourceType, ResourceId |
        Export-Csv -Path $inventoryPath -NoTypeInformation

    $roles = @(Get-AzRoleAssignment -Scope $base -ErrorAction SilentlyContinue)
    $roles |
        Select-Object RoleAssignmentId, ObjectId, ObjectType, DisplayName, RoleDefinitionName, Scope |
        Export-Csv -Path $rolesPath -NoTypeInformation

    Write-Info "Inventory saved to $inventoryPath"
    Write-Info "Role inventory saved to $rolesPath"

    $targets = @(
        [pscustomobject]@{
            Name = 'azljkt01n1 Arc machine'
            Id   = "$base/providers/Microsoft.HybridCompute/machines/azljkt01n1"
            Api  = '2023-10-03-preview'
        },
        [pscustomobject]@{
            Name = 'azljkt01n2 Arc machine'
            Id   = "$base/providers/Microsoft.HybridCompute/machines/azljkt01n2"
            Api  = '2023-10-03-preview'
        },
        [pscustomobject]@{
            Name = 'azljkt01wit witness storage'
            Id   = "$base/providers/Microsoft.Storage/storageAccounts/azljkt01wit"
            Api  = '2023-01-01'
        },
        [pscustomobject]@{
            Name = 'azljkt01diag diagnostic storage'
            Id   = "$base/providers/Microsoft.Storage/storageAccounts/azljkt01diag"
            Api  = '2023-01-01'
        },
        [pscustomobject]@{
            Name = 'azljkt01kv deployment Key Vault'
            Id   = "$base/providers/Microsoft.KeyVault/vaults/azljkt01kv"
            Api  = '2021-06-01-preview'
        }
    )

    if (-not $AutoApprove) {
        Write-Host ''
        Write-Host 'The following lab-owned resources will be deleted:' -ForegroundColor Yellow
        $targets | Select-Object Name, Id | Format-Table -AutoSize
        $answer = Read-Host 'Type DELETE-ZCOFFEE-STALE to continue'
        if ($answer -cne 'DELETE-ZCOFFEE-STALE') {
            throw 'Cleanup cancelled.'
        }
    }

    # Submit all independent deletes in one pass. No target is waited on here.
    $results = @()
    foreach ($target in $targets) {
        $results += Submit-ArmDelete -Target $target
    }

    $pending = @($results | Where-Object { $_.Submitted -and -not $_.Complete })
    $failed = @($results | Where-Object { $_.Failed })
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastState = @{}

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $next = @()

        foreach ($item in $pending) {
            $target = $item.Target
            try {
                $state = Get-ArmResourceState -Target $target
                if (-not $state.Exists) {
                    Write-Ok "$($target.Name): deleted"
                    continue
                }

                $stateText = if ($state.ProvisioningState) { $state.ProvisioningState } else { 'present' }
                if (-not $lastState.ContainsKey($target.Id) -or $lastState[$target.Id] -ne $stateText) {
                    Write-Info "$($target.Name): still present ($stateText)"
                    $lastState[$target.Id] = $stateText
                }
                $next += $item
            }
            catch {
                Write-Warn "$($target.Name): status check failed - $($_.Exception.Message)"
                $next += $item
            }
        }

        $pending = @($next)
        if ($pending.Count -gt 0) {
            Start-Sleep -Seconds $PollSeconds
        }
    }

    if ($pending.Count -gt 0) {
        Write-Warn "Cleanup timeout after $TimeoutMinutes minute(s). Remaining resources:"
        $pending | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Target.Name
                Id   = $_.Target.Id
            }
        } | Format-Table -AutoSize
    }

    if ($failed.Count -gt 0) {
        Write-Warn 'One or more delete submissions failed; review the warnings above.'
    }

    if ($pending.Count -eq 0 -and $failed.Count -eq 0) {
        Write-Ok 'Stale-resource cleanup completed.'
    }

    Write-Info 'The resource group, Arc Gateway, service principal, and role assignments were preserved.'
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
