[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$NodeNames = @('azljkt01n1','azljkt01n2'),
    [string]$DnsServer = '10.8.230.51',
    [string]$DnsSuffix = 'zcoffee.com',
    [string]$LocalAdminUser = 'LabAdmin',
    [switch]$Apply,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

Initialize-Ui -StageName '03-prepare-node' -TotalSteps 2 -UseGui:$UseGui

try {
    Invoke-Step 'Report node preparation plan' {
        Write-Info "Nodes: $($NodeNames -join ', ')"
        Write-Info "DNS suffix: $DnsSuffix"
        Write-Info "DNS server: $DnsServer"
        Write-Info "Local administrative user: $LocalAdminUser"
    }

    Invoke-Step 'Apply node preparation (guarded)' {
        if (-not $Apply) {
            Write-Warn 'Placeholder mode. No node preparation changes were made.'
            Write-Info 'Planned: hostname, DNS A records, local identity, firewall, firmware, SBE readiness, validation.'
            return
        }
        throw 'Stage 03 Apply is intentionally not implemented yet. Add idempotent node configuration first.'
    }

    Complete-Ui -FinalMessage 'Node preparation stage finished (placeholder).'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed
    throw
}
