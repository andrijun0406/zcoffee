<#
.SYNOPSIS
    Remove stale Arc state for one node and re-register it for Azure Local.
.DESCRIPTION
    Targeted recovery for a pre-cluster node whose Arc agent is Connected but lacks
    AzureLocal partner metadata. Preserves the shared Arc Gateway and all other nodes.
    Requires an existing Azure context and the updated 04-register-arc.ps1.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$NodeName = 'azljkt01n2',
    [string]$NodeIP = '10.8.230.235',
    [string]$ResourceGroupName = 'azljkt01rg',
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$TargetSolutionVersion = '12.2604.1003',
    [string]$ArcGatewayID,
    [string]$ArcGatewayName = 'zcoffee-arcgw',
    [string]$LocalAdminUser = 'Administrator',
    [SecureString]$LocalAdminPassword,
    [switch]$UseExistingAzLogin,
    [switch]$AutoApprove
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

if (-not $SubscriptionId) { throw 'SubscriptionId is required.' }
if (-not $TenantId) { throw 'TenantId is required.' }
if (-not $LocalAdminPassword) {
    $LocalAdminPassword = (Get-LabNodeCredential -User $LocalAdminUser).Password
}
$authUser = $LocalAdminUser; if ($authUser -notmatch '[\\@]') { $authUser = ".\\$authUser" }
$cred = [System.Management.Automation.PSCredential]::new($authUser, $LocalAdminPassword)

if (-not $ArcGatewayID) {
    $stateFile = Join-Path $PSScriptRoot 'config\arc-gateway.local.json'
    if (Test-Path $stateFile) { $ArcGatewayID = [string]((Get-Content $stateFile -Raw | ConvertFrom-Json).resourceId) }
}
if (-not $ArcGatewayID) { throw 'ArcGatewayID is required or must exist in config\arc-gateway.local.json.' }

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop
Import-Module Az.ConnectedMachine -ErrorAction Stop
if ($UseExistingAzLogin) {
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No existing Az context. Sign in first.' }
}
Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId -ErrorAction Stop | Out-Null

$machine = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $NodeName -ErrorAction SilentlyContinue
if (-not $machine) { Write-Host "Azure Arc machine $NodeName is already absent." -ForegroundColor Yellow }

$extensions = @(Get-AzConnectedMachineExtension -ResourceGroupName $ResourceGroupName -MachineName $NodeName -ErrorAction SilentlyContinue)
$confirmation = if ($AutoApprove) { 'YES' } else {
    Read-Host "This removes only $NodeName and its Arc extensions, then disconnects/re-registers it. Type YES"
}
if ($confirmation -cne 'YES') { throw 'Recovery cancelled.' }

foreach ($ext in $extensions) {
    if ($PSCmdlet.ShouldProcess("$NodeName extension $($ext.Name)", 'Remove')) {
        Remove-AzConnectedMachineExtension -ResourceGroupName $ResourceGroupName -MachineName $NodeName -Name $ext.Name -Force -ErrorAction Stop
    }
}
if ($machine -and $PSCmdlet.ShouldProcess("$NodeName Arc resource", 'Remove')) {
    Remove-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $NodeName -Force -ErrorAction Stop
}

Invoke-Command -ComputerName $NodeIP -Credential $cred -Authentication Negotiate -Port 5985 -ScriptBlock {
    $exe = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    if (Test-Path $exe) {
        & $exe disconnect --force-local-only 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "azcmagent disconnect failed with exit code $LASTEXITCODE" }
    }
} | Out-Host

$deadline = (Get-Date).AddMinutes(10)
do {
    $remaining = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $NodeName -ErrorAction SilentlyContinue
    if (-not $remaining) { break }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)
if ($remaining) { throw "Timed out waiting for Azure Arc resource deletion: $NodeName" }

$stage4 = Join-Path $PSScriptRoot '04-register-arc.ps1'
& $stage4 -Mode Register -Apply -NodeIPs $NodeIP -SubscriptionId $SubscriptionId -TenantId $TenantId `
    -ResourceGroupName $ResourceGroupName -TargetSolutionVersion $TargetSolutionVersion `
    -UseArcGateway -ArcGatewayID $ArcGatewayID -ArcGatewayName $ArcGatewayName `
    -UseExistingAzLogin -LocalAdminUser $LocalAdminUser -LocalAdminPassword $LocalAdminPassword
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Stage 4 re-registration failed with exit code $LASTEXITCODE" }
Write-Host "$NodeName recovery and Azure Local partner registration completed." -ForegroundColor Green
