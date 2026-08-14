[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ISOFile,

    [string]$ExpectedISOHash,

    [Parameter(Mandatory)]
    [string]$HttpHost,

    [ValidateRange(1,65535)]
    [int]$HttpPort = 8080,

    [string]$RACADMPath = 'racadm',

    [string[]]$iDRACIPs = @('10.8.230.84','10.8.230.86')
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
    throw "HttpHost is not assigned to this computer: $HttpHost"
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
Write-Host "ISO: $resolvedIso"
Write-Host "RACADM: $racadm"
Write-Host "HTTP bind address: $HttpHost`:$HttpPort"
