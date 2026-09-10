<# ZCOFFEE vNext deployment timing helpers. #>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ZcoffeeTimingState {
    param([string]$DeploymentId = (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [ordered]@{ DeploymentId=$DeploymentId; Started=(Get-Date).ToUniversalTime().ToString('o'); Stages=New-Object System.Collections.ArrayList }
}
function Start-ZcoffeeTimedStage {
    param([hashtable]$State,[Parameter(Mandatory)][string]$Name,[string]$Phase='Deployment')
    $entry=[ordered]@{ Name=$Name; Phase=$Phase; Start=(Get-Date).ToUniversalTime().ToString('o'); End=$null; DurationSeconds=$null; Status='Running' }
    [void]$State.Stages.Add($entry); $entry
}
function Complete-ZcoffeeTimedStage {
    param([hashtable]$Entry,[ValidateSet('Succeeded','Failed','Skipped')][string]$Status='Succeeded')
    $end=Get-Date; $Entry.End=$end.ToUniversalTime().ToString('o'); $Entry.DurationSeconds=[math]::Round(($end-[datetime]$Entry.Start).TotalSeconds,1); $Entry.Status=$Status
}
function Save-ZcoffeeTimingState {
    param([hashtable]$State,[Parameter(Mandatory)][string]$Path)
    $State.Finished=(Get-Date).ToUniversalTime().ToString('o')
    $dir=Split-Path -Path $Path -Parent
    if ($dir) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $State | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding UTF8
}
