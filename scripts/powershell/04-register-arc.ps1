[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Validate','Register')]
    [string]$Mode = 'Validate',
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName,
    [string[]]$NodeNames,
    [switch]$Apply,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b = $PSBoundParameters
$SubscriptionId    = Resolve-Setting -Name 'SubscriptionId'    -Bound $b -Current $SubscriptionId    -ConfigKey 'SubscriptionId' -Config $cfg
$TenantId          = Resolve-Setting -Name 'TenantId'          -Bound $b -Current $TenantId          -ConfigKey 'TenantId'       -Config $cfg
$ResourceGroupName = Resolve-Setting -Name 'ResourceGroupName' -Bound $b -Current $ResourceGroupName -ConfigKey 'ResourceGroup'  -Config $cfg; if (-not $ResourceGroupName) { $ResourceGroupName = 'azljkt01rg' }
if (-not $b.ContainsKey('NodeNames')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeNames = @($cfg.Nodes | ForEach-Object { $_.Name }) }
    else { $NodeNames = @('azljkt01n1','azljkt01n2') }
}

Initialize-Ui -StageName '04-register-arc' -TotalSteps 2 -UseGui:$UseGui

try {
    Invoke-Step 'Report Arc/SBE plan' {
        Write-Info "Mode: $Mode"
        Write-Info "Resource group: $ResourceGroupName"
        Write-Info "Nodes: $($NodeNames -join ', ')"
        Write-Info 'Planned checks: Azure context, resource providers, RBAC, Arc registration, post-reboot health, Dell SBE readiness.'
    }
    Invoke-Step 'Register with Azure Arc (guarded)' {
        if ($Mode -eq 'Validate') { Write-Warn 'Validate mode. No Arc registration was performed.'; return }
        if (-not $Apply) { throw 'Register mode requires -Apply.' }
        throw 'Stage 04 Register is intentionally not implemented yet. Use the release-matched Arc initialization procedure.'
    }
    Complete-Ui -FinalMessage 'Arc stage finished (placeholder).'
}
catch { Write-Err $_.Exception.Message; Complete-Ui -Failed; throw }
