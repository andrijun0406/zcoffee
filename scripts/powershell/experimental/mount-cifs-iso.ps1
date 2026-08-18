<#
.SYNOPSIS
Standalone CIFS mount test (try-cifs branch). Mounts a Golden Image ISO from a
CIFS/SMB share to one or more iDRAC nodes via `racadm remoteimage`, optionally
setting one-time VCD-DVD boot and power-cycling.

This is deliberately standalone (not wired into bootstrap-cluster.ps1) so you can
test the CIFS transport in isolation. If CIFS proves reliable, we fold a
-ShareProtocol switch into the main deploy-os.ps1.

RACADM CIFS form:
  racadm -r <idrac> -u <idracuser> -p <idracpass> remoteimage -c \
    -l //<host>/<share>/<image>.iso -u <shareuser> -p <sharepass>
The -u/-p AFTER remoteimage are the SHARE credentials; the -u/-p before it are
the iDRAC credentials.
#>
[CmdletBinding()]
param(
    [string[]]$iDRACIPs = @('10.8.230.84','10.8.230.86'),
    [string]$iDRACUser = 'root',
    [SecureString]$iDRACPassword,

    # UNC path to the ISO, e.g. //2.2.2.9/labisos/AzureLocal...iso
    [Parameter(Mandatory)][string]$UncIsoPath,
    [string]$ShareUser,
    [SecureString]$SharePassword,

    # Optional Autounattend ISO on the same/another share (RFS2).
    [string]$UncAutounattendPath,

    [string]$RACADMPath = 'racadm',
    [switch]$NoCertWarn,
    [switch]$StartInstallation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Plain([SecureString]$s) {
    if (-not $s) { return $null }
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

if (-not $iDRACPassword) {
    $iDRACPassword = Read-Host -Prompt "iDRAC password for '$iDRACUser'" -AsSecureString
}
if (-not $SharePassword) {
    $SharePassword = Read-Host -Prompt "Share password (blank for guest)" -AsSecureString
}

$exe = (Get-Command $RACADMPath -ErrorAction SilentlyContinue).Source
if (-not $exe) { if (Test-Path $RACADMPath) { $exe = (Resolve-Path $RACADMPath).Path } }
if (-not $exe) { throw "RACADM not found: $RACADMPath" }

$idpw = ConvertTo-Plain $iDRACPassword
$shpw = ConvertTo-Plain $SharePassword

function Invoke-Rac {
    param([string]$NodeIP,[string[]]$Tail)
    $base = @('-r',$NodeIP,'-u',$iDRACUser,'-p',$idpw)
    if ($NoCertWarn) { $base += '--nocertwarn' }
    $shown = ($base + $Tail) -join ' '
    $shown = $shown.Replace($idpw,'***'); if ($shpw) { $shown = $shown.Replace($shpw,'***') }
    Write-Host "RACADM> $exe $shown" -ForegroundColor DarkGray
    $out = & $exe @base @Tail 2>&1
    return @{ Code = $LASTEXITCODE; Out = ($out -join [Environment]::NewLine) }
}

function Connect-Cifs {
    param([string]$NodeIP,[string]$Slot,[string]$Unc)
    $tail = @($Slot,'-c','-l',$Unc)
    if ($ShareUser) { $tail += @('-u',$ShareUser) }
    if ($shpw)      { $tail += @('-p',$shpw) }
    for ($i=1; $i -le 4; $i++) {
        $r = Invoke-Rac -NodeIP $NodeIP -Tail $tail
        if ($r.Code -eq 0) { return }
        Write-Host "  $Slot connect attempt $i failed:" -ForegroundColor Yellow
        Write-Host ($r.Out.Replace($idpw,'***')) -ForegroundColor Yellow
        if ($i -lt 4) {
            & $exe -r $NodeIP -u $iDRACUser -p $idpw @($(if($NoCertWarn){'--nocertwarn'})) $Slot -d 2>&1 | Out-Null
            Start-Sleep -Seconds 5
        } else { throw "CIFS $Slot connect failed on $NodeIP after 4 attempts." }
    }
}

try {
    foreach ($node in $iDRACIPs) {
        Write-Host "=== $node ===" -ForegroundColor Cyan
        # Clear stale shares first.
        Invoke-Rac -NodeIP $node -Tail @('remoteimage2','-d') | Out-Null
        Invoke-Rac -NodeIP $node -Tail @('remoteimage','-d')  | Out-Null
        Start-Sleep -Seconds 5

        Write-Host "Mounting CIFS ISO (RFS1) on $node"
        Connect-Cifs -NodeIP $node -Slot 'remoteimage' -Unc $UncIsoPath

        if ($UncAutounattendPath) {
            Write-Host "Mounting CIFS Autounattend (RFS2) on $node"
            Connect-Cifs -NodeIP $node -Slot 'remoteimage2' -Unc $UncAutounattendPath
        }

        if ($StartInstallation) {
            Invoke-Rac -NodeIP $node -Tail @('set','iDRAC.ServerBoot.FirstBootDevice','VCD-DVD') | Out-Null
            Invoke-Rac -NodeIP $node -Tail @('set','iDRAC.ServerBoot.BootOnce','1') | Out-Null
            Invoke-Rac -NodeIP $node -Tail @('serveraction','powercycle') | Out-Null
            Write-Host "Install boot initiated on $node" -ForegroundColor Green
        } else {
            Write-Host "Mounted (no install). Verify: racadm -r $node ... remoteimage -s" -ForegroundColor Green
        }
    }
}
finally {
    $idpw = $null; $shpw = $null
}
