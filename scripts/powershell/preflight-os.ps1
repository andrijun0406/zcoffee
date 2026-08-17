[CmdletBinding()]
param(
    [string]$ISOFile,

    [string]$ExpectedISOHash,

    [string]$HttpHost,

    [ValidateRange(1,65535)]
    [int]$HttpPort = 8080,

    [string]$RACADMPath = 'racadm',

    [string[]]$iDRACIPs = @('10.8.230.84','10.8.230.86'),

    # When set, the ISO is already hosted at a DC-reachable URL, so this host
    # does not serve it. Skips the local ISO-file and HttpHost-assignment checks.
    [string]$ISOUrl,

    # When set, skips ALL ISO/HttpHost checks entirely (e.g. hardware-prep-only
    # runs like -FirmwareCheckOnly that never mount the image). Only RACADM and
    # iDRAC reachability are validated.
    [switch]$SkipIso
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    throw 'Run this preflight as Administrator.'
}

$resolvedIso = $null

if ($SkipIso) {
    Write-Host 'Hardware-prep-only run; skipping all ISO and HttpHost checks.'
}
elseif ($ISOUrl) {
    if ($ISOUrl -notmatch '^https?://') { throw "ISOUrl must be http/https: $ISOUrl" }
    Write-Host "ISO is provided via URL; skipping local ISO-file and HttpHost checks."
    Write-Host "ISO URL: $ISOUrl"
}
else {
    if (-not $ISOFile) { throw 'ISOFile is required unless -SkipIso or -ISOUrl is used.' }
    if (-not $HttpHost) { throw 'HttpHost is required unless -SkipIso or -ISOUrl is used.' }
    if (-not (Test-Path $ISOFile -PathType Leaf)) {
        throw "ISO file not found: $ISOFile"
    }
    $resolvedIso = (Resolve-Path $ISOFile).Path
    if ([IO.Path]::GetExtension($resolvedIso) -ne '.iso') {
        throw "File is not an ISO: $resolvedIso"
    }
    if ($ExpectedISOHash) {
        $actualHash = (Get-FileHash $resolvedIso -Algorithm SHA256).Hash
        if ($actualHash.ToUpperInvariant() -ne $ExpectedISOHash.ToUpperInvariant()) {
            throw "ISO hash mismatch. Expected $ExpectedISOHash; found $actualHash."
        }
    }
    $hostAddress = Get-NetIPAddress -IPAddress $HttpHost -ErrorAction SilentlyContinue
    if (-not $hostAddress) {
        throw "HttpHost is not assigned to this computer: $HttpHost. On a client VPN (e.g. Sangfor), run this on a jump host inside 10.8.230.0/24, or pass -ISOUrl to a DC-hosted ISO."
    }
}

$racadm = $null
if (Test-Path $RACADMPath -PathType Leaf) {
    $racadm = (Resolve-Path $RACADMPath).Path
}
else {
    $command = Get-Command $RACADMPath -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { $racadm = $command.Source }
}

if (-not $racadm) {
    throw "RACADM was not found: $RACADMPath"
}

foreach ($ip in $iDRACIPs) {
    Write-Host "Testing iDRAC HTTPS: $ip"
    $reachable = Test-NetConnection `
        -ComputerName $ip `
        -Port 443 `
        -InformationLevel Quiet `
        -WarningAction SilentlyContinue

    if (-not $reachable) {
        throw "iDRAC HTTPS is unreachable: $ip"
    }
}

Write-Host 'OS preflight passed.'
if ($resolvedIso) { Write-Host "ISO: $resolvedIso" }
Write-Host "RACADM: $racadm"
if (-not $SkipIso -and $HttpHost) { Write-Host "HTTP bind address: $HttpHost`:$HttpPort" }
