[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Validate','Register')]
    [string]$Mode = 'Validate',
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName = 'azljkt01rg',
    [string[]]$NodeNames = @('azljkt01n1','azljkt01n2'),
    [switch]$Apply,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

Initialize-Ui -StageName '04-register-arc' -TotalSteps 2 -UseGui:$UseGui

try {
    Invoke-Step 'Report Arc/SBE plan' {
        Write-Info "Mode: $Mode"
        Write-Info "Nodes: $($NodeNames -join ', ')"
        Write-Info 'Planned checks: Azure context, resource providers, RBAC, Arc registration, post-reboot health, Dell SBE readiness.'
    }

    Invoke-Step 'Register with Azure Arc (guarded)' {
        if ($Mode -eq 'Validate') {
            Write-Warn 'Validate mode. No Arc registration was performed.'
            return
        }
        if (-not $Apply) { throw 'Register mode requires -Apply.' }
        throw 'Stage 04 Register is intentionally not implemented yet. Use the release-matched Arc initialization procedure.'
    }

    Complete-Ui -FinalMessage 'Arc stage finished (placeholder).'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed
    throw
}
