<#
.SYNOPSIS
    Builds a tiny Autounattend.xml ISO for hands-off Azure Local (Dell golden image) OS install.

.DESCRIPTION
    Creates an unattend answer file and packages it into a small ISO using the native
    Windows IMAPI2 COM API (no Windows ADK and no Python required). The ISO is meant to be
    mounted as a SECOND iDRAC virtual media device (RFS2 / 'racadm remoteimage2') alongside the
    Dell golden image (RFS1). Windows Setup auto-discovers Autounattend.xml at the media root.

    Scope (deliberately minimal and lab-safe):
      - windowsPE pass  : sets en-US locale/keyboard and auto-accepts the EULA
                          (skips the first language screen and 'Install now' / license screens).
      - oobeSystem pass : sets the built-in Administrator password, en-US locale, and
                          'SE Asia Standard Time' time zone (satisfies the first sign-in gate).

    NOT automated on purpose:
      - Disk selection ("Where do you want to install Windows?") is left INTERACTIVE.
        With 2x SSD + 6x HDD + BOSS present, auto-selecting a disk risks wiping the wrong one.
        The operator selects the BOSS RAID-1 volume once, via the iDRAC virtual console.
      - Hostname, IP, and DNS are intentionally left to Stage 3 (03-prepare-node.ps1).

.NOTES
    The administrator password is stored in the answer file as base64 (Windows unattend
    obfuscation, NOT encryption). Treat the generated ISO as a secret. Windows also copies
    the answer file to C:\Windows\Panther after install; clean it up post-deployment.
#>
[CmdletBinding()]
param(
    [SecureString]$AdministratorPassword,
    [string]$OutputIso = (Join-Path $PSScriptRoot 'autounattend.iso'),
    [string]$TimeZone = 'SE Asia Standard Time',
    [string]$Locale = 'en-US',
    [string]$OwnerName = 'Azure Local Lab',
    [string]$Organization = 'zcoffee'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PasswordComplexity {
    param([string]$Plain)
    $problems = @()
    if ($Plain.Length -lt 14) { $problems += 'at least 14 characters' }
    if ($Plain -cnotmatch '[A-Z]') { $problems += 'an uppercase letter' }
    if ($Plain -cnotmatch '[a-z]') { $problems += 'a lowercase letter' }
    if ($Plain -notmatch '\d')     { $problems += 'a number' }
    if ($Plain -notmatch '[^A-Za-z0-9]') { $problems += 'a special character' }
    return $problems
}

# --- Acquire and validate the administrator password ---
if (-not $PSBoundParameters.ContainsKey('AdministratorPassword') -or $null -eq $AdministratorPassword) {
    $AdministratorPassword = Read-Host -Prompt 'Enter the local Administrator password to set (min 14 chars)' -AsSecureString
}

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdministratorPassword)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$issues = Test-PasswordComplexity -Plain $plain
if ($issues.Count -gt 0) {
    throw ("Password does not meet Azure Local complexity. It needs " + ($issues -join ', ') + '.')
}

# Windows unattend obfuscation for AdministratorPassword: base64( UTF16LE( password + 'AdministratorPassword' ) )
$adminB64 = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($plain + 'AdministratorPassword'))
$plain = $null

# --- Build the answer file ---
$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>$Locale</UILanguage>
      </SetupUILanguage>
      <InputLocale>$Locale</InputLocale>
      <SystemLocale>$Locale</SystemLocale>
      <UILanguage>$Locale</UILanguage>
      <UserLocale>$Locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>$OwnerName</FullName>
        <Organization>$Organization</Organization>
      </UserData>
      <!--
        NO DiskConfiguration / ImageInstall by design.
        Setup will stop only at the disk-selection screen so the operator can pick the
        BOSS RAID-1 volume. This prevents accidental wipe of the S2D data disks.
      -->
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$Locale</InputLocale>
      <SystemLocale>$Locale</SystemLocale>
      <UILanguage>$Locale</UILanguage>
      <UserLocale>$Locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>$TimeZone</TimeZone>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$adminB64</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <NetworkLocation>Work</NetworkLocation>
      </OOBE>
    </component>
  </settings>

</unattend>
"@

# --- Stage the file, then build the ISO natively via IMAPI2 ---
$staging = Join-Path ([IO.Path]::GetTempPath()) ("unattend_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$writerType = 'AzLocalIso.IsoWriter'
if (-not ($writerType -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace AzLocalIso {
    public static class IsoWriter {
        public static void Create(string path, object comStream, int blockSize, int totalBlocks) {
            IStream stream = (IStream)comStream;
            using (FileStream fs = File.OpenWrite(path)) {
                byte[] buffer = new byte[blockSize];
                IntPtr read = Marshal.AllocHGlobal(sizeof(int));
                try {
                    while (totalBlocks-- > 0) {
                        stream.Read(buffer, blockSize, read);
                        int got = Marshal.ReadInt32(read);
                        fs.Write(buffer, 0, got);
                    }
                    fs.Flush();
                }
                finally {
                    Marshal.FreeHGlobal(read);
                }
            }
        }
    }
}
'@
}

try {
    Set-Content -Path (Join-Path $staging 'Autounattend.xml') -Value $xml -Encoding UTF8
    # Some Setup variants look for lowercase; provide both for safety.
    Copy-Item (Join-Path $staging 'Autounattend.xml') (Join-Path $staging 'autounattend.xml') -Force

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3   # ISO9660 (1) + Joliet (2)
    $fsi.VolumeName = 'UNATTEND'
    $fsi.Root.AddTree($staging, $false)

    $result = $fsi.CreateResultImage()
    if (Test-Path $OutputIso) { Remove-Item $OutputIso -Force }
    [AzLocalIso.IsoWriter]::Create($OutputIso, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)

    $sizeKb = [math]::Round((Get-Item $OutputIso).Length / 1KB, 1)
    Write-Host "Created Autounattend ISO: $OutputIso ($sizeKb KB)" -ForegroundColor Green
    Write-Host "Time zone: $TimeZone   Locale: $Locale" -ForegroundColor Cyan
    Write-Host "Treat this ISO as a secret (it contains the obfuscated admin password)." -ForegroundColor Yellow
    Write-Host "It is covered by .gitignore; do not commit it." -ForegroundColor Yellow
}
finally {
    Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
    $xml = $null
    $adminB64 = $null
}
