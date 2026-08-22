<#
.SYNOPSIS
Stage the repo + Golden Image onto a jump host inside 10.8.230.0/24 (try-jumphost
branch), so Stage 1 runs from the DC LAN and the iDRAC reads the ISO at LAN speed
with the VPN removed from the boot path.

Copies over the jump host's admin share (C$) by default. Run elevated with
credentials that can write to the jump host.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JumpHost = '10.8.230.225',
    [PSCredential]$Credential,
    [string]$RepoRoot,
    [string]$IsoFolder,
    [string]$DestRoot = 'C$\LabInfra'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repo root is two levels up from this script (repo\scripts\powershell).
# Anchor to the script location so it does not depend on the current directory.
if (-not $RepoRoot)  { $RepoRoot  = Join-Path $PSScriptRoot '..\..' }
if (-not $IsoFolder) { $IsoFolder = Join-Path $RepoRoot 'isos' }
$repo = (Resolve-Path $RepoRoot).Path
$isos = (Resolve-Path $IsoFolder).Path
Write-Host ("Repo root:  " + $repo)
Write-Host ("ISO folder: " + $isos)
if (-not $Credential) { $Credential = Get-Credential -Message "Admin creds for jump host $JumpHost" }

$dest = "\\$JumpHost\$DestRoot"

# Map a temporary PSDrive with the supplied credentials.
$drive = 'JH'
if (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue) { Remove-PSDrive $drive -Force }
New-PSDrive -Name $drive -PSProvider FileSystem -Root $dest -Credential $Credential -ErrorAction Stop | Out-Null

try {
    Write-Host "Copying repo (excluding isos/logs) to $dest ..."
    robocopy $repo "$($drive):\" /E /XD isos logs .git /NFL /NDL /NJH /NJS /R:2 /W:5 | Out-Null

    Write-Host "Copying ISO(s) to $dest\isos ..."
    robocopy $isos "$($drive):\isos" *.iso /NFL /NDL /NJH /NJS /R:2 /W:5 | Out-Null

    Write-Host "Done. On the jump host, run Stage 1 with a DC-internal HttpHost:" -ForegroundColor Green
    Write-Host "  .\\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost $JumpHost ``" -ForegroundColor Green
    Write-Host "    -AutounattendIso ..\\..\\isos\\autounattend.iso -StartInstallation -NoCertWarn" -ForegroundColor Green
}
finally {
    Remove-PSDrive $drive -Force -ErrorAction SilentlyContinue
}
