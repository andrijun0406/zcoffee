<#
.SYNOPSIS
Create a read-only SMB (CIFS) share on THIS PC exposing the isos folder, plus a
dedicated low-privilege local user for the iDRAC to authenticate with.

Experimental (try-cifs branch): lets `racadm remoteimage` mount the Golden Image
over CIFS instead of HTTP, to test whether SMB streams the boot image more
reliably than the HTTP server over the Sangfor VPN.

Run elevated. Reverse reachability still applies: the iDRAC must reach this PC on
TCP 445. On a client VPN that blocks inbound 445, use the jump host instead.
#>
[CmdletBinding()]
param(
    [string]$ShareName = 'labisos',
    [string]$IsoFolder = '..\..\..\isos',
    [string]$ShareUser = 'isoreader',
    [SecureString]$SharePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run as Administrator.'
}

$folder = (Resolve-Path $IsoFolder -ErrorAction Stop).Path
if (-not (Test-Path $folder -PathType Container)) { throw "ISO folder not found: $folder" }

if (-not $SharePassword) {
    $SharePassword = Read-Host -Prompt "Set a password for local share user '$ShareUser'" -AsSecureString
}

# Create or update a dedicated local user (not an admin).
$existing = Get-LocalUser -Name $ShareUser -ErrorAction SilentlyContinue
if (-not $existing) {
    New-LocalUser -Name $ShareUser -Password $SharePassword -FullName 'ISO Share Reader' `
        -Description 'Read-only iDRAC ISO share' -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    Write-Host "Created local user $ShareUser"
} else {
    $existing | Set-LocalUser -Password $SharePassword
    Write-Host "Updated password for existing local user $ShareUser"
}

# Create the read-only share.
$share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($share) { Remove-SmbShare -Name $ShareName -Force }
New-SmbShare -Name $ShareName -Path $folder -ReadAccess $ShareUser | Out-Null
Write-Host "Shared '$folder' as \\$env:COMPUTERNAME\$ShareName (read access: $ShareUser)"

# Allow inbound SMB (TCP 445) for the iDRAC to reach this PC.
if (-not (Get-NetFirewallRule -DisplayName 'AzureLocal ISO SMB 445' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'AzureLocal ISO SMB 445' -Direction Inbound `
        -Action Allow -Protocol TCP -LocalPort 445 | Out-Null
    Write-Host 'Added inbound firewall rule for TCP 445.'
}

Write-Host ''
Write-Host 'CIFS UNC to use with mount-cifs-iso.ps1:'
Write-Host "  //<this-PC-VPN-IP>/$ShareName/<golden-image>.iso"
