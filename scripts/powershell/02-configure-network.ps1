[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$MgmtVlan,
    [int]$StorageVlan1,
    [int]$StorageVlan2,
    [string]$MgmtGateway,
    [string]$DnsServer,
    [switch]$Apply,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b = $PSBoundParameters
$MgmtVlan     = Resolve-Setting -Name 'MgmtVlan'     -Bound $b -Current $MgmtVlan     -ConfigKey 'MgmtVlan'     -Config $cfg; if (-not $MgmtVlan) { $MgmtVlan = 230 }
$StorageVlan1 = Resolve-Setting -Name 'StorageVlan1' -Bound $b -Current $StorageVlan1 -ConfigKey 'StorageVlan1' -Config $cfg; if (-not $StorageVlan1) { $StorageVlan1 = 711 }
$StorageVlan2 = Resolve-Setting -Name 'StorageVlan2' -Bound $b -Current $StorageVlan2 -ConfigKey 'StorageVlan2' -Config $cfg; if (-not $StorageVlan2) { $StorageVlan2 = 712 }
$MgmtGateway  = Resolve-Setting -Name 'MgmtGateway'  -Bound $b -Current $MgmtGateway  -ConfigKey 'Gateway'      -Config $cfg; if (-not $MgmtGateway) { $MgmtGateway = '10.8.230.1' }
$DnsServer    = Resolve-Setting -Name 'DnsServer'    -Bound $b -Current $DnsServer    -ConfigKey 'DnsServer'    -Config $cfg; if (-not $DnsServer) { $DnsServer = '10.8.230.51' }

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
catch { Write-Err $_.Exception.Message; Complete-Ui -Failed; throw }
