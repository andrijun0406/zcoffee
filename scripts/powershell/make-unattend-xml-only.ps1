<#
.SYNOPSIS
    Emits ONLY an Autounattend.xml (no ISO, no oscdimg) so you can validate the answer file
    quickly against a running Windows Setup via  setup.exe /unattend:<path>  from the Shift+F10
    prompt, or by dropping it on a FAT32 USB stick.

.DESCRIPTION
    Rebuilding an ~8 GB slipstream ISO to test each answer-file change is slow. This script
    produces just the Autounattend.xml with the SAME schema and content that
    make-golden-with-unattend.ps1 bakes into the ISO, so once this file is validated live
    (Setup accepts it -> C:\Windows\Panther\unattend.xml appears), you can trust the same XML
    inside the ISO.

    Element order in the windowsPE Microsoft-Windows-Setup component follows the unattend schema
    sequence: ImageInstall -> RunSynchronous -> UserData. An out-of-order element makes Setup
    reject the ENTIRE answer file (no Panther\unattend.xml, apply-phase error 0x80070001-0x4003x).

    Answer-file scope: locale, timezone, admin password. Disk selection is INTERACTIVE by default.
    -AutoSelectBootDisk emits the EXPERIMENTAL WinPE RunSynchronous BOSS auto-partition step
    (validate before trusting it).

.NOTES
    Admin password is stored as base64 unattend obfuscation (NOT encryption). Treat the output
    Autounattend.xml as a secret. Tested on Windows 11 22H2 and Windows Server 2022.
#>
[CmdletBinding()]
param(
    [string]$OutputXml    = (Join-Path $PSScriptRoot 'Autounattend.xml'),
    [SecureString]$AdministratorPassword,
    [string]$TimeZone     = 'SE Asia Standard Time',
    [string]$Locale       = 'en-US',
    [string]$OwnerName    = 'Azure Local Lab',
    [string]$Organization = 'zcoffee',
    [switch]$AutoSelectBootDisk,
    [string]$BootDiskModelMatch = '(?i)boss',
    [int]$BootDiskMaxSizeGB = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PasswordComplexity {
    param([string]$Plain)
    $problems = @()
    if ($Plain.Length -lt 14)            { $problems += 'at least 14 characters' }
    if ($Plain -cnotmatch '[A-Z]')       { $problems += 'an uppercase letter' }
    if ($Plain -cnotmatch '[a-z]')       { $problems += 'a lowercase letter' }
    if ($Plain -notmatch '\d')           { $problems += 'a number' }
    if ($Plain -notmatch '[^A-Za-z0-9]') { $problems += 'a special character' }
    return $problems
}

if (-not $PSBoundParameters.ContainsKey('AdministratorPassword') -or $null -eq $AdministratorPassword) {
    Write-Host 'Enter the local Administrator password to set (min 14 chars):' -ForegroundColor Yellow
    $AdministratorPassword = Read-Host -AsSecureString
}
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdministratorPassword)
try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$issues = Test-PasswordComplexity -Plain $plain
if (@($issues).Count -gt 0) {
    throw ("Password does not meet Azure Local complexity. It needs " + ($issues -join ', ') + '.')
}

# Windows unattend obfuscation: base64( UTF16LE( password + 'AdministratorPassword' ) )
$adminB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'AdministratorPassword'))
$plain = $null

$diskSetupXml = ''
$imageInstallXml = ''
if ($AutoSelectBootDisk) {
    $ceiling = [int]$BootDiskMaxSizeGB
    $rx = $BootDiskModelMatch
    $peScript = @"
`$ErrorActionPreference = 'Stop'
`$log = "`$env:SystemDrive\Windows\Temp\bootdisk-select.log"
function W(`$m){ `$t = (Get-Date).ToString('HH:mm:ss'); Add-Content -Path `$log -Value "`$t `$m"; Write-Host `$m }
try {
  `$rx = '$rx'
  `$maxGb = $ceiling
  `$all = Get-Disk | Where-Object { `$_.BusType -ne 'USB' }
  foreach (`$d in `$all) { W ("disk {0}: '{1}' bus={2} size={3}GB" -f `$d.Number, `$d.FriendlyName, `$d.BusType, [math]::Round(`$d.Size/1GB)) }
  `$cand = `$all | Where-Object { `$_.FriendlyName -match `$rx -or `$_.Model -match `$rx }
  if (-not `$cand) {
    W "No disk matched /`$rx/ by name; falling back to smallest fixed disk."
    `$fixed = `$all | Where-Object { `$_.BusType -in 'SATA','RAID','NVMe','SAS' }
    if (`$maxGb -gt 0) { `$fixed = `$fixed | Where-Object { `$_.Size -le (`$maxGb * 1GB) } }
    if (`$fixed) { `$min = (`$fixed | Measure-Object -Property Size -Minimum).Minimum; `$cand = `$fixed | Where-Object { `$_.Size -eq `$min } }
  }
  `$n = @(`$cand).Count
  if (`$n -ne 1) { W "AMBIGUOUS: `$n candidate disks - stopping so the operator selects manually."; exit 2 }
  `$disk = `$cand[0]
  W ("Selected BOSS boot disk {0}: '{1}' ({2}GB)" -f `$disk.Number, `$disk.FriendlyName, [math]::Round(`$disk.Size/1GB))
  `$dp = @(
    "select disk `$(`$disk.Number)","clean","convert gpt",
    "create partition efi size=500","format fs=fat32 quick","assign letter=S",
    "create partition msr size=16",
    "create partition primary","format fs=ntfs quick label=Windows","assign letter=W","exit"
  ) -join "``r``n"
  `$dpf = "`$env:SystemDrive\Windows\Temp\boss-diskpart.txt"
  Set-Content -Path `$dpf -Value `$dp -Encoding ASCII
  W "Running diskpart to partition the BOSS disk..."
  diskpart /s `$dpf | Out-Null
  W "Boot disk prepared."
  exit 0
} catch { W ("ERROR: " + `$_.Exception.Message); exit 3 }
"@
    $peBytes = [Text.Encoding]::Unicode.GetBytes($peScript)
    $peB64   = [Convert]::ToBase64String($peBytes)
    $runCmd  = "cmd /c powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $peB64"
    $imageInstallXml = @"
      <ImageInstall>
        <OSImage>
          <InstallToAvailablePartition>true</InstallToAvailablePartition>
        </OSImage>
      </ImageInstall>
"@
    $diskSetupXml = @"
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>$runCmd</Path>
          <Description>Auto-select and partition the BOSS boot VD</Description>
          <WillReboot>Never</WillReboot>
        </RunSynchronousCommand>
      </RunSynchronous>
"@
    Write-Host 'Disk selection: AUTOMATIC (EXPERIMENTAL, unvalidated).' -ForegroundColor Yellow
} else {
    Write-Host 'Disk selection: INTERACTIVE (Setup pauses at the disk screen).' -ForegroundColor Yellow
}

$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
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
$imageInstallXml$diskSetupXml      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>$OwnerName</FullName>
        <Organization>$Organization</Organization>
      </UserData>
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

# Validate well-formedness before writing (catches XML mistakes locally).
try { [xml]$xml | Out-Null }
catch { throw "Generated XML is not well-formed: $($_.Exception.Message)" }

Set-Content -Path $OutputXml -Value $xml -Encoding UTF8
Write-Host ("Autounattend.xml written to: {0}" -f (Resolve-Path $OutputXml).Path) -ForegroundColor Green
Write-Host 'Treat this file as a secret (it contains the obfuscated admin password).' -ForegroundColor Yellow
