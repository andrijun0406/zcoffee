[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$NodeName = 'azljkt01n2',
    [string]$NodeIP = '10.8.230.235',
    [string]$ResourceGroupName = 'azljkt01rg',
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$TenantId,
    [string]$TargetSolutionVersion = '12.2604.1003',
    [Parameter(Mandatory = $true)][string]$ArcGatewayID,
    [string]$ArcGatewayName = 'zcoffee-arcgw',
    [string]$LocalAdminUser = 'Administrator',
    [SecureString]$LocalAdminPassword,
    [switch]$UseExistingAzLogin,
    [switch]$AutoApprove,
    [switch]$RemoveMachineResourceLocks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

if (-not $LocalAdminPassword) {
    $LocalAdminPassword = (Get-LabNodeCredential -User $LocalAdminUser).Password
}

$authUser = $LocalAdminUser
if ($authUser -notmatch '[\\@]') { $authUser = ".\\$authUser" }
$cred = [System.Management.Automation.PSCredential]::new($authUser, $LocalAdminPassword)

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

if ($UseExistingAzLogin) {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No existing Az context. Sign in first.' }
}
Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId -ErrorAction Stop | Out-Null

$machineResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$NodeName"

$confirmation = if ($AutoApprove) { 'YES' } else {
    Read-Host "This removes only $NodeName and its Arc extensions, then disconnects/re-registers it. Type YES"
}
if ($confirmation -cne 'YES') { throw 'Recovery cancelled.' }

function Invoke-ArmRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )

    $restCommand = Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue
    if (-not $restCommand) {
        throw 'Invoke-AzRestMethod is unavailable. Install/import Az.Accounts before running recovery.'
    }

    $path = '{0}?api-version={1}' -f $ResourceId.TrimEnd([char[]]@('/','?')), $ApiVersion
    try {
        return Invoke-AzRestMethod -Method $Method -Path $path -ErrorAction Stop
    } catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = '{0} {1}' -f $detail, $_.ErrorDetails.Message
        }
        throw "ARM $Method failed for $ResourceId : $detail"
    }
}

function Get-ArmResponseStatus {
    param([Parameter(Mandatory = $true)]$Response)
    if ($Response.PSObject.Properties.Name -contains 'StatusCode') {
        return [int]$Response.StatusCode
    }
    return 200
}

function Get-ArmResponseJson {
    param([Parameter(Mandatory = $true)]$Response)
    if ($Response.PSObject.Properties.Name -contains 'Content' -and $Response.Content) {
        try { return ($Response.Content | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Wait-ArmResourceGone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $present = Get-AzResource -ResourceId $ResourceId -ErrorAction SilentlyContinue
        if (-not $present) {
            Write-Host "$Description is absent." -ForegroundColor DarkYellow
            return
        }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $Description to be deleted."
}

function Remove-ArmResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )

    Write-Host "Deleting $Description via ARM REST..." -ForegroundColor Yellow
    $response = Invoke-ArmRequest -Method DELETE -ResourceId $ResourceId -ApiVersion $ApiVersion
    $status = Get-ArmResponseStatus -Response $response
    if ($status -notin @(200, 202, 204)) {
        throw "ARM DELETE returned HTTP $status for $Description."
    }
}

function Get-MachineLocks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResourceId)

    $lockCollectionId = '{0}/providers/Microsoft.Authorization/locks' -f $ResourceId.TrimEnd('/')
    $response = Invoke-ArmRequest `
        -Method GET `
        -ResourceId $lockCollectionId `
        -ApiVersion '2016-09-01'
    $body = Get-ArmResponseJson -Response $response
    if ($body -and $body.value) { return @($body.value) }
    return @()
}

Write-Host "Disconnecting local Arc state on $NodeName before Azure resource cleanup..." -ForegroundColor Cyan
Invoke-Command `
    -ComputerName $NodeIP `
    -Credential $cred `
    -Authentication Negotiate `
    -Port 5985 `
    -ScriptBlock {
        $exe = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
        if (-not (Test-Path -LiteralPath $exe)) {
            throw "azcmagent.exe not found on $env:COMPUTERNAME"
        }

        $status = $null
        try {
            $json = ((& $exe show -j 2>$null | Out-String) | ConvertFrom-Json)
            $status = [string]$json.status
        } catch { }

        if ($status -eq 'Connected') {
            & $exe disconnect --force-local-only 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "azcmagent disconnect failed with exit code $LASTEXITCODE"
            }
        } else {
            Write-Host "Local Arc state is already disconnected (status: $status)." -ForegroundColor DarkYellow
        }
    } | Out-Host

$locks = @(Get-MachineLocks -ResourceId $machineResourceId)
if ($locks.Count -gt 0 -and -not $RemoveMachineResourceLocks) {
    $lockNames = ($locks | ForEach-Object { $_.name }) -join ', '
    throw "Resource lock(s) exist on $NodeName ($lockNames). Remove them in Azure or rerun with -RemoveMachineResourceLocks after review."
}

if ($locks.Count -gt 0) {
    foreach ($lock in $locks) {
        $lockId = [string]$lock.id
        if (-not $lockId) { throw "A machine lock was found but its resource ID could not be determined." }
        Remove-ArmResource `
            -ResourceId $lockId `
            -Description "$NodeName machine resource lock" `
            -ApiVersion '2016-09-01'
        Wait-ArmResourceGone `
            -ResourceId $lockId `
            -Description "$NodeName machine resource lock"
    }
}

Write-Host "Deleting the parent Arc machine resource for $NodeName..." -ForegroundColor Cyan
$machine = Get-AzResource -ResourceId $machineResourceId -ErrorAction SilentlyContinue
if ($machine) {
    # Azure Local-managed child extensions are intentionally not deleted one by one.
    # The documented repair flow deletes the faulty Arc machine resource.
    Remove-ArmResource `
        -ResourceId $machineResourceId `
        -Description "$NodeName Arc machine resource" `
        -ApiVersion '2023-10-03-preview'
    Wait-ArmResourceGone `
        -ResourceId $machineResourceId `
        -Description "$NodeName Arc machine resource"
} else {
    Write-Host "Azure Arc machine $NodeName is already absent." -ForegroundColor Yellow
}

$stage4 = Join-Path $PSScriptRoot '04-register-arc.ps1'
if (-not (Test-Path -LiteralPath $stage4)) {
    throw "Stage 4 script not found: $stage4"
}

$stage4Command = Get-Command -Name $stage4 -ErrorAction Stop
if (-not ($stage4Command.Parameters.Keys -contains 'TargetSolutionVersion')) {
    throw '04-register-arc.ps1 does not support -TargetSolutionVersion. Replace Stage 4 with the updated gateway-aware version first.'
}

Write-Host "Re-registering $NodeName with Azure Local solution $TargetSolutionVersion and the existing Arc Gateway..." -ForegroundColor Cyan
& $stage4 `
    -Mode Register `
    -Apply `
    -NodeIPs $NodeIP `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupName $ResourceGroupName `
    -TargetSolutionVersion $TargetSolutionVersion `
    -UseArcGateway `
    -ArcGatewayID $ArcGatewayID `
    -ArcGatewayName $ArcGatewayName `
    -UseExistingAzLogin `
    -LocalAdminUser $LocalAdminUser `
    -LocalAdminPassword $LocalAdminPassword

if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Stage 4 re-registration failed with exit code $LASTEXITCODE"
}

Write-Host "$NodeName recovery and Azure Local partner registration completed." -ForegroundColor Green
