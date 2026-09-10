<#
.SYNOPSIS
    ZCOFFEE vNext dependency and support preflight.
.DESCRIPTION
    Read-only by default. Validates the desired spec against node state, SBE,
    hardware profile, Arc state, and optional Azure residue. It never deletes RBAC
    or Azure resources.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SpecFile,
    [Parameter(Mandatory)][string]$ProfileFile,
    [string]$SubscriptionId,
    [string]$TenantId,
    [switch]$UseExistingAzLogin,
    [switch]$SkipArc,
    [switch]$SkipAzure,
    [switch]$SkipSbe,
    [switch]$UseGui
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\ui-common.ps1')
. (Join-Path $PSScriptRoot 'zcoffee-spec.ps1')
. (Join-Path $PSScriptRoot 'zcoffee-timing.ps1')

$loaded = & (Join-Path $PSScriptRoot 'zcoffee-spec.ps1') -SpecFile $SpecFile -ProfileFile $ProfileFile
$spec=$loaded.Spec; $profile=$loaded.Profile
if($profile.supportStatus -and $profile.supportStatus -match 'experimental'){ Write-Warning ('Hardware profile is experimental: ' + $profile.supportStatus) }
$nodes=@($spec.nodes | ForEach-Object { $_.hostIp })
if (-not $nodes.Count) { throw 'Spec contains no nodes.' }
$adminUser = if ($spec.identity.localAdminUser) { [string]$spec.identity.localAdminUser } else { 'Administrator' }
$cred=Get-LabNodeCredential -User (if ($adminUser -match '[\\@]') {$adminUser} else {'.\'+$adminUser})
$errors=New-Object System.Collections.ArrayList
$warnings=New-Object System.Collections.ArrayList
$results=New-Object System.Collections.ArrayList
function Add-Result { param($name,$status,$detail) [void]$results.Add([pscustomobject]@{Check=$name;Status=$status;Detail=$detail}); if($status -eq 'FAIL'){[void]$errors.Add(($name + ": " + $detail))} elseif($status -eq 'WARN'){[void]$warnings.Add(($name + ": " + $detail))} }

$expectedBuild=[string]$spec.preflight.expectedOsBuild
$mgmt=@($profile.expectedAdapters.management); $storage=@($profile.expectedAdapters.storage)
$nodeCheck={ param($expected,$mgmt,$storage,$requireSbe)
  $cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $build="$($cv.CurrentBuild).$($cv.UBR)"
  $adapters=@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Name)
  $missing=@($mgmt+$storage | Where-Object { $_ -notin $adapters.Name })
  $sbe=@(Get-ChildItem -Path 'C:\SBE' -File -ErrorAction SilentlyContinue)
  [pscustomobject]@{Node=$env:COMPUTERNAME;Build=$build;BuildOk=($build -eq $expected);MissingAdapters=$missing;SbeCount=$sbe.Count;SbeOk=(!$requireSbe -or $sbe.Count -gt 0);ArcStatus=(((& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show -j 2>$null|Out-String)|ConvertFrom-Json).status);GatewayMode=(& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" config get connection.type 2>$null|Out-String).Trim()}
}
foreach($ip in $nodes){ try{$r=Invoke-Command -ComputerName $ip -Credential $cred -Authentication Negotiate -Port 5985 -ScriptBlock $nodeCheck -ArgumentList $expectedBuild,$mgmt,$storage,[bool]$spec.preflight.requireSbeFiles -ErrorAction Stop; [void]$results.Add($r); if(-not $r.BuildOk){Add-Result "OS $ip" 'FAIL' "Expected $expectedBuild, found $($r.Build)"}; if(-not $SkipSbe -and -not $r.SbeOk){Add-Result "SBE $ip" 'FAIL' 'C:\SBE is missing or empty'}; if(@($r.MissingAdapters).Count -gt 0){Add-Result "Hardware $ip" 'FAIL' "Missing adapters: $($r.MissingAdapters -join ', ')"}; if(-not $SkipArc){if($r.ArcStatus -ne 'Connected'){Add-Result "Arc $ip" 'FAIL' "Status=$($r.ArcStatus)"}; if($spec.arc.requireGatewayMode -and $r.GatewayMode -ne 'gateway'){Add-Result "ArcGateway $ip" 'FAIL' "Mode=$($r.GatewayMode)"}}}catch{Add-Result "WinRM $ip" 'FAIL' $_.Exception.Message}}
if(-not $SkipAzure -and -not $SkipArc){Import-Module Az.Accounts -ErrorAction Stop; Import-Module Az.Resources -ErrorAction Stop; $ctx=Get-AzContext; if($SubscriptionId -and $ctx.Subscription.Id -ne $SubscriptionId){Add-Result 'AzureContext' 'FAIL' 'Subscription mismatch'}; foreach($n in @($spec.nodes.name)){try{$m=Get-AzConnectedMachine -ResourceGroupName $spec.deployment.resourceGroup -Name $n -ErrorAction Stop; if($m.Status -ne 'Connected'){Add-Result "AzureArc $n" 'FAIL' "Status=$($m.Status)"}}catch{Add-Result "AzureArc $n" 'FAIL' $_.Exception.Message}}}
$results | Format-Table -AutoSize
Write-Host ("SUMMARY: {0} failures, {1} warnings" -f $errors.Count,$warnings.Count)
if($errors.Count){throw ($errors -join ' | ')}


