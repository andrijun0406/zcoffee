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
    [switch]$SkipIso,

    # Skip the inbound-firewall (TCP $HttpPort) check. Use only if you manage the
    # firewall yourself or serve the ISO from a DC host.
    [switch]$SkipFirewallCheck
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

function Test-InboundPortAllowed {
    # Returns $true if an ENABLED inbound Allow rule covers the given TCP port.
    # The iDRAC pulls the ISO from this PC over TCP $Port; without this rule the
    # remoteimage connect leaves a half-open session and the NEXT attempt fails
    # with RAC0718 ("Remote File Share service is busy").
    param([Parameter(Mandatory)][int]$Port)
    try {
        $rules = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction Stop
    } catch {
        return $null   # cmdlet unavailable; caller treats as "unknown"
    }
    foreach ($rule in $rules) {
        try {
            $pf = $rule | Get-NetFirewallPortFilter -ErrorAction Stop
        } catch { continue }
        if ($pf.Protocol -notin @('TCP','Any')) { continue }
        foreach ($lp in @($pf.LocalPort)) {
            if ($lp -in @('Any', $Port.ToString())) { return $true }
            if ($lp -is [string] -and $lp -match '-') {
                $parts = $lp -split '-'
                if ($parts.Count -eq 2) {
                    $lo=0;$hi=0
                    if ([int]::TryParse($parts[0],[ref]$lo) -and [int]::TryParse($parts[1],[ref]$hi)) {
                        if ($Port -ge $lo -and $Port -le $hi) { return $true }
                    }
                }
            }
        }
    }
    return $false
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

    if (-not $SkipFirewallCheck) {
        $fw = Test-InboundPortAllowed -Port $HttpPort
        $fixCmd = "New-NetFirewallRule -DisplayName 'AzureLocal ISO $HttpPort' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $HttpPort"
        if ($fw -eq $false) {
            throw "No enabled inbound firewall rule allows TCP $HttpPort on this PC. The iDRAC must reach http://$HttpHost`:$HttpPort to pull the ISO; without it the mount half-opens and the next attempt fails with RAC0718. Create the rule, then retry:`n  $fixCmd`n(Or bypass this check with -SkipFirewallCheck.)"
        }
        elseif ($null -eq $fw) {
            Write-Host "WARNING: Could not evaluate the Windows Firewall (cmdlets unavailable). Ensure inbound TCP $HttpPort is allowed for the iDRAC, or run: $fixCmd" -ForegroundColor Yellow
        }
        else {
            Write-Host "Inbound TCP $HttpPort is allowed by the firewall."
        }
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
