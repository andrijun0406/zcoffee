[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$MgmtVlan = 230,
    [int]$StorageVlan1 = 711,
    [int]$StorageVlan2 = 712,
    [string]$MgmtGateway = '10.8.230.1',
    [string]$DnsServer = '10.8.230.51',
    [switch]$Apply,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

Initialize-Ui -StageName '02-configure-network' -TotalSteps 2 -UseGui:$UseGui

try {
    Invoke-Step 'Report intended host networking design' {
        Write-Info "Management VLAN: $MgmtVlan"
        Write-Info "Storage VLANs: $StorageVlan1, $StorageVlan2"
        Write-Info "Gateway: $MgmtGateway"
        Write-Info "DNS: $DnsServer"
    }

    Invoke-Step 'Apply host networking (guarded)' {
        if (-not $Apply) {
            Write-Warn 'Placeholder mode. No host networking changes were made.'
            Write-Info 'Confirm exact adapter names and Network ATC intents before enabling -Apply.'
            return
        }
        throw 'Stage 02 Apply is intentionally not implemented yet. Validate the design first.'
    }

    Complete-Ui -FinalMessage 'Network stage finished (placeholder).'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed
    throw
}
