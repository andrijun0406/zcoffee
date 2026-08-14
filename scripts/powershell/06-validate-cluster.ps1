[CmdletBinding()]
param(
    [string]$ClusterName,
    [string[]]$NodeNames,
    [switch]$SkipStorageChecks,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b = $PSBoundParameters
$ClusterName = Resolve-Setting -Name 'ClusterName' -Bound $b -Current $ClusterName -ConfigKey 'ClusterName' -Config $cfg; if (-not $ClusterName) { $ClusterName = 'azljkt01clu' }
if (-not $b.ContainsKey('NodeNames')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeNames = @($cfg.Nodes | ForEach-Object { $_.Name }) }
    else { $NodeNames = @('azljkt01n1','azljkt01n2') }
}

Initialize-Ui -StageName '06-validate-cluster' -TotalSteps 4 -UseGui:$UseGui

try {
    Invoke-Step 'Check clustering tools and cluster object' {
        if (-not (Get-Command Get-Cluster -ErrorAction SilentlyContinue)) { throw 'Failover Clustering tools are not installed on this management host.' }
        $script:cluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
        Write-Info "Cluster found: $ClusterName"
    }
    Invoke-Step 'Verify cluster node membership and state' {
        $nodes = Get-ClusterNode -Cluster $script:cluster
        $expected = ($NodeNames | Sort-Object) -join '|'
        $actual = ($nodes.Name | Sort-Object) -join '|'
        if ($expected -ne $actual) { throw "Node mismatch. Expected: $expected; actual: $actual" }
        $down = $nodes | Where-Object State -ne 'Up'
        if ($down) { throw "Nodes not Up: $($down.Name -join ', ')" }
        $nodes | Format-Table Name, State, NodeWeight | Out-Host
    }
    Invoke-Step 'Verify quorum' {
        Get-ClusterQuorum -Cluster $script:cluster | Format-List | Out-Host
    }
    Invoke-Step 'Verify Storage Spaces Direct health' {
        if ($SkipStorageChecks) { Write-Warn 'Storage checks skipped by request.'; return }
        if (Get-Command Get-StoragePool -ErrorAction SilentlyContinue) {
            Get-StoragePool -IsPrimordial $false | Format-Table FriendlyName, HealthStatus, OperationalStatus | Out-Host
        }
        if (Get-Command Get-VirtualDisk -ErrorAction SilentlyContinue) {
            Get-VirtualDisk | Format-Table FriendlyName, HealthStatus, OperationalStatus, ResiliencySettingName | Out-Host
        }
    }
    Complete-Ui -FinalMessage 'Cluster validation finished.'
}
catch { Write-Err $_.Exception.Message; Complete-Ui -Failed; throw }
