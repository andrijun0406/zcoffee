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
    [switch]$AutoApprove
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

function Wait-ArmResourceGone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$TimeoutSeconds = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $present = Get-AzResource -ResourceId $ResourceId -ErrorAction SilentlyContinue
        if (-not $present) {
            Write-Host "$Description is absent." -ForegroundColor DarkYellow
            return
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $Description to be deleted."
}

function Invoke-ArmDelete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$ApiVersion = '2023-10-03'
    )

    $restCommand = Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue
    if (-not $restCommand) {
        throw 'Invoke-AzRestMethod is unavailable. Install/import Az.Accounts before running recovery.'
    }

    $path = '{0}?api-version={1}' -f $ResourceId.TrimEnd('?'), $ApiVersion
    Write-Host "Deleting $Description via ARM REST..." -ForegroundColor Yellow

    try {
        $response = Invoke-AzRestMethod -Method DELETE -Path $path -ErrorAction Stop
        $status = if ($response.PSObject.Properties.Name -contains 'StatusCode') {
            [int]$response.StatusCode
        } else { 204 }

        if ($status -notin @(200, 202, 204)) {
            throw "ARM DELETE returned HTTP $status for $Description."
        }
    } catch {
        $message = $_.Exception.Message
        if ($message -match '404|NotFound|ResourceNotFound') {
            Write-Host "$Description is already absent." -ForegroundColor DarkYellow
        } else {
            throw "ARM DELETE failed for $Description : $message"
        }
    }
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

$extensionResources = @(
    Get-AzResource `
        -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.HybridCompute/machines/extensions' `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ResourceId -like "$machineResourceId/extensions/*"
        }
)

foreach ($extension in $extensionResources) {
    $extensionId = if ($extension.PSObject.Properties.Name -contains 'ResourceId' -and $extension.ResourceId) {
        [string]$extension.ResourceId
    } elseif ($extension.PSObject.Properties.Name -contains 'Id' -and $extension.Id) {
        [string]$extension.Id
    } else {
        throw "Could not determine resource ID for extension $($extension.Name)."
    }

    Invoke-ArmDelete `
        -ResourceId $extensionId `
        -Description "$NodeName extension $($extension.Name)"

    Wait-ArmResourceGone `
        -ResourceId $extensionId `
        -Description "$NodeName extension $($extension.Name)"
}

Write-Host 'Enumerating the targeted Azure Arc resource before deletion...' -ForegroundColor Cyan
$machine = Get-AzResource -ResourceId $machineResourceId -ErrorAction SilentlyContinue
if ($machine) {
    Invoke-ArmDelete `
        -ResourceId $machineResourceId `
        -Description "$NodeName Arc resource"
} else {
    Write-Host "Azure Arc machine $NodeName is already absent." -ForegroundColor Yellow
}

$deadline = (Get-Date).AddMinutes(10)
do {
    $remaining = Get-AzResource -ResourceId $machineResourceId -ErrorAction SilentlyContinue
    if (-not $remaining) { break }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)

if ($remaining) {
    throw "Timed out waiting for Azure Arc resource deletion: $NodeName"
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
