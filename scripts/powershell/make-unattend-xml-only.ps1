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
    Autounattend.xml as a secret.
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
    [int]$BootDiskMaxSizeGB = 0,
    [switch]$BakeNetworkConfig,                  # opt IN to bake hostname + static IP/VLAN + WinRM/RDP (specialize pass)
    [int]$MgmtPrefixLength = 24,
    [switch]$AsIso,
    [string]$OutputIso   = (Join-Path $PSScriptRoot 'autounattend.iso'),
    [string]$OscdimgPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Load lab-config.psd1 (single source of truth) for the network bake ---
$__cfgPath = Join-Path $PSScriptRoot 'config\lab-config.psd1'
$labCfg = if (Test-Path $__cfgPath) { Import-PowerShellDataFile -Path $__cfgPath } else { @{} }

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

# --- Build the per-node network bootstrap (specialize pass) or leave empty ---
$netSpecializeXml = ''
if ($BakeNetworkConfig) {
    $nodes = @()
    if ($labCfg.ContainsKey('Nodes')) { $nodes = @($labCfg.Nodes) }
    if (-not $nodes -or $nodes.Count -eq 0) { throw 'BakeNetworkConfig requires Nodes in lab-config.psd1 (ServiceTag + HostIP + Name).' }

    $gw   = if ($labCfg.ContainsKey('Gateway'))   { $labCfg.Gateway }   else { '10.8.230.1' }
    $dns  = if ($labCfg.ContainsKey('DnsServer')) { $labCfg.DnsServer } else { '10.8.230.51' }
    $vlan = if ($labCfg.ContainsKey('MgmtVlan'))  { $labCfg.MgmtVlan }  else { 230 }
    $mgmtAdapterName = if ($labCfg.ContainsKey('MgmtAdapters')) { @($labCfg.MgmtAdapters)[0] } else { 'Integrated NIC 1 Port 1-1' }

    $mapLines = ($nodes | ForEach-Object { "  '$($_.ServiceTag)' = @{ Name = '$($_.Name)'; Ip = '$($_.HostIP)' }" }) -join "`r`n"

    Write-Host "Network bake: ON. Per service tag ->" -ForegroundColor Yellow
    foreach ($n in $nodes) { Write-Host ("    {0}  ->  {1}  {2}" -f $n.ServiceTag, $n.Name, $n.HostIP) -ForegroundColor Yellow }
    Write-Host "  Adapter '$mgmtAdapterName', VLAN $vlan, gw $gw, dns $dns, /$MgmtPrefixLength; WinRM + RDP enabled." -ForegroundColor Yellow

    $spScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$log = "`$env:SystemDrive\Windows\Temp\netbootstrap.log"
function W(`$m){ `$t=(Get-Date).ToString('HH:mm:ss'); Add-Content -Path `$log -Value "`$t `$m" }
W '=== network bootstrap (specialize) ==='
`$map = @{
$mapLines
}
`$tag = (Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue).SerialNumber
if (-not `$tag) { `$tag = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber }
`$tag = "`$tag".Trim()
W "Service tag: `$tag"
`$cfg = `$map[`$tag]
if (-not `$cfg) { W "No mapping for tag '`$tag' - leaving network unchanged."; exit 0 }
W "Target host=`$(`$cfg.Name) ip=`$(`$cfg.Ip)"
try { Rename-Computer -NewName `$cfg.Name -Force -ErrorAction Stop; W "Renamed -> `$(`$cfg.Name) (applies on reboot)" } catch { W "rename: `$(`$_.Exception.Message)" }
`$ad = Get-NetAdapter -Name '$mgmtAdapterName' -ErrorAction SilentlyContinue
if (-not `$ad) { `$ad = Get-NetAdapter | Where-Object { `$_.InterfaceDescription -match 'QL41232' -and `$_.Status -eq 'Up' } | Select-Object -First 1 }
if (-not `$ad) { `$ad = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' -and `$_.Name -notmatch 'SLOT 2|Embedded' } | Select-Object -First 1 }
if (-not `$ad) { W 'No management adapter found - abort network cfg.'; exit 0 }
W "Adapter: `$(`$ad.Name)"
try { Set-NetAdapterAdvancedProperty -Name `$ad.Name -DisplayName 'VLAN ID' -DisplayValue '$vlan' -ErrorAction Stop; W "VLAN ID = $vlan"; Start-Sleep -Seconds 5 } catch { W "vlan: `$(`$_.Exception.Message)" }
`$ad  = Get-NetAdapter -Name `$ad.Name -ErrorAction SilentlyContinue
`$idx = `$ad.InterfaceIndex
try {
  Remove-NetIPAddress -InterfaceIndex `$idx -AddressFamily IPv4 -Confirm:`$false -ErrorAction SilentlyContinue
  Remove-NetRoute -InterfaceIndex `$idx -DestinationPrefix '0.0.0.0/0' -Confirm:`$false -ErrorAction SilentlyContinue
  New-NetIPAddress -InterfaceIndex `$idx -IPAddress `$cfg.Ip -PrefixLength $MgmtPrefixLength -DefaultGateway '$gw' -ErrorAction Stop | Out-Null
  W "IP `$(`$cfg.Ip)/$MgmtPrefixLength gw $gw"
} catch { W "ip: `$(`$_.Exception.Message)" }
try { Set-DnsClientServerAddress -InterfaceIndex `$idx -ServerAddresses '$dns' -ErrorAction Stop; W "DNS $dns" } catch { W "dns: `$(`$_.Exception.Message)" }
try { Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop; W 'PSRemoting enabled' } catch { W "psremoting: `$(`$_.Exception.Message)" }
try { Set-NetConnectionProfile -InterfaceIndex `$idx -NetworkCategory Private -ErrorAction SilentlyContinue; W 'profile Private' } catch {}
try {
  Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -ErrorAction Stop
  Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
  W 'RDP enabled'
} catch { W "rdp: `$(`$_.Exception.Message)" }
W 'network bootstrap done.'
exit 0
"@
    $spB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($spScript))
    $spRun = "cmd /c powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $spB64"
    $netSpecializeXml = @"
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>$spRun</Path>
          <Description>Bootstrap hostname, VLAN, static IP, WinRM and RDP</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
"@
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
$netSpecializeXml  <settings pass="oobeSystem">
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

if ($AsIso) {
    # Resolve oscdimg (Server Core has no IMAPI2; oscdimg is the reliable path).
    $oscdimg = $OscdimgPath
    if (-not $oscdimg) {
        $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
        if ($cmd) { $oscdimg = $cmd.Source }
    }
    if (-not $oscdimg) {
        $default = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
        if (Test-Path $default) { $oscdimg = $default }
    }
    if (-not $oscdimg -or -not (Test-Path $oscdimg)) {
        throw "oscdimg.exe not found. Install the Windows ADK Deployment Tools or pass -OscdimgPath. (Do NOT use make-autounattend-iso.ps1 on Server Core; its IMAPI2 COM is not registered.)"
    }
    Write-Host ("Using oscdimg: {0}" -f $oscdimg) -ForegroundColor Cyan

    # Stage the single Autounattend.xml at the root of a temp folder and pack a small data ISO.
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("ua_iso_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Copy-Item -LiteralPath (Resolve-Path $OutputXml).Path -Destination (Join-Path $stage 'Autounattend.xml') -Force
        $isoDir = Split-Path -Path $OutputIso -Parent
        if ($isoDir -and -not (Test-Path $isoDir)) { New-Item -ItemType Directory -Path $isoDir -Force | Out-Null }
        # -u2 = UDF; -l sets a volume label. No boot image (this is a data ISO read by Setup, not booted).
        & $oscdimg '-u2' '-udfver102' '-lUNATTEND' $stage $OutputIso
        if ($LASTEXITCODE -ne 0) { throw "oscdimg failed (exit $LASTEXITCODE)." }
        Write-Host ("Autounattend ISO written to: {0}" -f (Resolve-Path $OutputIso).Path) -ForegroundColor Green
        Write-Host 'Mount it to a node ALREADY booted into Setup via: racadm ... remoteimage2 -c -l http://<server>:<port>/autounattend.iso' -ForegroundColor Yellow
    }
    finally {
        Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
