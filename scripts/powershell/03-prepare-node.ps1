[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$NodeNames,
    [string]$DnsServer,
    [string]$DnsSuffix,
    [string]$LocalAdminUser,
    [switch]$Apply,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b = $PSBoundParameters
if (-not $b.ContainsKey('NodeNames')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeNames = @($cfg.Nodes | ForEach-Object { $_.Name }) }
    else { $NodeNames = @('azljkt01n1','azljkt01n2') }
}
$DnsServer      = Resolve-Setting -Name 'DnsServer'      -Bound $b -Current $DnsServer      -ConfigKey 'DnsServer'      -Config $cfg; if (-not $DnsServer) { $DnsServer = '10.8.230.51' }
$DnsSuffix      = Resolve-Setting -Name 'DnsSuffix'      -Bound $b -Current $DnsSuffix      -ConfigKey 'DnsSuffix'      -Config $cfg; if (-not $DnsSuffix) { $DnsSuffix = 'zcoffee.com' }
$LocalAdminUser = Resolve-Setting -Name 'LocalAdminUser' -Bound $b -Current $LocalAdminUser -ConfigKey 'LocalAdminUser' -Config $cfg; if (-not $LocalAdminUser) { $LocalAdminUser = 'LabAdmin' }

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
catch { Write-Err $_.Exception.Message; Complete-Ui -Failed; throw }
