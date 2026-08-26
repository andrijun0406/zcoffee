<#
.SYNOPSIS
    Slipstreams an unattended Autounattend.xml INTO the Dell golden image ISO, producing a new
    single bootable ISO for fully-scripted Azure Local OS install over ONE iDRAC RFS mount.

.DESCRIPTION
    On R650 BIOS 1.12.1, mounting a SECOND iDRAC RFS image (remoteimage2) prevents the golden
    ISO on RFS1 from enumerating as a bootable UEFI device. So the classic "golden ISO on RFS1
    + Autounattend ISO on RFS2" approach cannot boot. The reliable single-RFS solution is to
    bake Autounattend.xml into the root of the golden ISO itself, so Windows Setup auto-discovers
    it from the one mounted image.

    This script rebuilds the ISO with oscdimg (Microsoft's supported tool for repacking bootable
    Windows media). oscdimg handles large UDF payloads (install.wim/.esd > 4 GB) and the dual
    BIOS+UEFI El Torito boot catalog correctly - unlike IMAPI2, which fails on large dual-boot
    Windows ISOs (error 0xC0AAB132 during CreateResultImage).

    Steps:
      - Mount the source golden ISO read-only (Mount-DiskImage).
      - Robocopy its full file tree into a writable staging folder.
      - Drop Autounattend.xml at the staging root.
      - oscdimg repacks staging -> new ISO with UDF + BIOS(etfsboot.com) + UEFI(efisys*.bin) boot.
        Prefers efisys_noprompt.bin (removes the "Press any key to boot" gate for hands-off install).

    Answer-file scope: locale, timezone, admin password. Disk selection is INTERACTIVE by default -
    Setup runs hands-off until the disk screen, where the operator picks the BOSS RAID-1 'OS' volume
    (~223 GB). This is the proven path. -AutoSelectBootDisk enables an EXPERIMENTAL WinPE step that
    auto-detects the BOSS VD by controller identity ('BOSS' friendly name, model-agnostic) and
    partitions it via diskpart; it is NOT yet validated on the Azure Local golden image and must be
    tested on a scratch node before use.

.REQUIREMENTS
    oscdimg.exe must be available. It ships with the Windows ADK "Deployment Tools" feature:
      https://learn.microsoft.com/windows-hardware/get-started/adk-install
    Default install path:
      C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe
    oscdimg.exe is a single ~2 MB standalone binary - you can also copy just that one file to the
    jump host and pass its path with -OscdimgPath. The script auto-detects it on PATH and in the
    common ADK locations.

.NOTES
    - The admin password is stored in the answer file as base64 (unattend obfuscation, NOT
      encryption). Treat the OUTPUT ISO as a secret; it is covered by .gitignore.
    - Rebuilding an ~8 GB ISO needs free disk space ~2x the ISO size (staging + output) and takes
      several minutes.
    - VALIDATE the first output by booting one node (single RFS) before relying on it for both.
#>
[CmdletBinding()]
param(
    [string]$GoldenIso   = (Join-Path $PSScriptRoot '..\..\isos\AzureLocal24H2.26100.32230.LCM.12.2604.1.3008_DellSBE.5.0.2606.1510_15G-Intel_A01.en-us.iso'),
    [string]$OutputIso   = (Join-Path $PSScriptRoot '..\..\isos\AzureLocal-unattend.iso'),
    [SecureString]$AdministratorPassword,
    [string]$TimeZone     = 'SE Asia Standard Time',
    [string]$Locale       = 'en-US',
    [string]$OwnerName    = 'Azure Local Lab',
    [string]$Organization = 'zcoffee',
    [string]$VolumeName   = 'AZLOCAL_UA',
    [string]$OscdimgPath,                        # explicit path to oscdimg.exe (optional)
    [string]$StagingDir,                         # override staging folder (default: beside OutputIso)

    # --- Automatic boot-disk (BOSS) selection ---
    # Default: auto-select and partition the BOSS boot VD during WinPE, so the install is fully
    # hands-off. Detection is by the BOSS controller's IDENTITY (its RAID-1 VD enumerates with a
    # 'BOSS' friendly name) - model-agnostic, so it works whether BOSS is 223 GB (R650 BOSS-S2),
    # 960 GB (R670 BOSS-N1), or any other size. No per-model size needs to be configured.
    [switch]$AutoSelectBootDisk,                 # opt IN to EXPERIMENTAL WinPE auto BOSS selection (default: interactive)
    [string]$BootDiskModelMatch = '(?i)boss',    # regex matched against disk FriendlyName/Model to find BOSS
    [int]$BootDiskMaxSizeGB = 700,                # ceiling (GB) for the SIZE-FALLBACK guess only; identity-matched BOSS is trusted at any size (R650 BOSS-S2 ~223GB, R670 BOSS-N1 ~960GB). R650 lab: BOSS~223, cacheSSD~800, HDD~2.4TB

    # --- Bake per-node network + remote access into the answer file (specialize pass) ---
    # Each node self-configures by reading its Dell service tag and matching lab-config.psd1:
    # sets hostname, VLAN 230 tag, static mgmt IP/GW/DNS, enables WinRM + RDP. This makes a
    # freshly imaged node reachable from the jump host with no iDRAC-console work.
    [switch]$BakeNetworkConfig,                  # opt IN to bake hostname + static IP/VLAN + WinRM/RDP
    [int]$MgmtPrefixLength = 24                  # management subnet prefix length (/24)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:__t0 = Get-Date
function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    $stamp = '{0:mm\:ss}' -f ((Get-Date) - $script:__t0)
    Write-Host ("[{0}] {1}" -f $stamp, $Message) -ForegroundColor $Color
}

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

function Resolve-Oscdimg {
    param([string]$Hint)
    if ($Hint) {
        if (Test-Path -LiteralPath $Hint -PathType Leaf) { return (Resolve-Path $Hint).Path }
        throw "oscdimg not found at -OscdimgPath: $Hint"
    }
    $cmd = Get-Command oscdimg.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

Write-Step "make-golden-with-unattend starting."
Write-Step "Source golden ISO: $GoldenIso"
Write-Step "Output ISO:        $OutputIso"

if (-not (Test-Path $GoldenIso -PathType Leaf)) { throw "Golden ISO not found: $GoldenIso" }
$GoldenIso = (Resolve-Path $GoldenIso).Path

# --- Load lab-config.psd1 (single source of truth) for network bake ---
$__cfgPath = Join-Path $PSScriptRoot 'config\lab-config.psd1'
$labCfg = if (Test-Path $__cfgPath) { Import-PowerShellDataFile -Path $__cfgPath } else { @{} }

# --- Resolve oscdimg first, before doing any heavy work ---
$oscdimg = Resolve-Oscdimg -Hint $OscdimgPath
if (-not $oscdimg) {
    throw @"
oscdimg.exe was not found. It is required to repack a bootable Windows ISO reliably.

Get it one of these ways:
  1. Install the Windows ADK 'Deployment Tools' feature:
     https://learn.microsoft.com/windows-hardware/get-started/adk-install
  2. Or copy just oscdimg.exe (a single ~2 MB file) from a machine that has the ADK, then re-run with:
     -OscdimgPath C:\path\to\oscdimg.exe

Default ADK location:
  C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe
"@
}
Write-Step "Using oscdimg: $oscdimg" 'Green'

# --- Acquire and validate the administrator password ---
if (-not $PSBoundParameters.ContainsKey('AdministratorPassword') -or $null -eq $AdministratorPassword) {
    Write-Step "Prompting for the local Administrator password (input is hidden)..." 'Yellow'
    $AdministratorPassword = Read-Host -Prompt 'Enter the local Administrator password to set (min 14 chars)' -AsSecureString
}
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdministratorPassword)
try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$issues = Test-PasswordComplexity -Plain $plain
if (@($issues).Count -gt 0) {
    throw ("Password does not meet Azure Local complexity. It needs " + ($issues -join ', ') + '.')
}
Write-Step "Password meets complexity requirements." 'Green'

# Windows unattend obfuscation: base64( UTF16LE( password + 'AdministratorPassword' ) )
$adminB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'AdministratorPassword'))
$plain = $null

# --- Build the boot-disk auto-selection block (default) or leave interactive ---
# When auto (default), a WinPE RunSynchronous command detects the BOSS boot VD by identity,
# then diskpart cleans it and lays down the UEFI/GPT partitions. Setup installs to that
# freshly-created Windows partition via InstallToAvailablePartition. If detection is ambiguous
# (0 or >1 candidates) the command exits non-zero, which safely stops before touching any disk
# instead of risking a wrong-disk install onto an S2D data disk.
$diskSetupXml = ''
$imageInstallXml = ''
$script:StageBootSelect = $false
$script:BootSelectScript = ''
if ($AutoSelectBootDisk) {
    $ceiling = if ([int]$BootDiskMaxSizeGB -gt 0) { [int]$BootDiskMaxSizeGB } else { 700 }
    $rx = $BootDiskModelMatch
    # PowerShell that runs INSIDE WinPE during Windows Setup (windowsPE pass).
    $peScript = @"
`$ErrorActionPreference = 'Stop'
`$log = "`$env:SystemDrive\Windows\Temp\bootdisk-select.log"
function W(`$m){ `$t=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Add-Content -Path `$log -Value "`$t  `$m"; Write-Host `$m }
try {
  `$maxGb = $ceiling
  # BOSS identity indicators (case-insensitive). Broader than a single 'boss' token so it also
  # catches 'Boot Optimized Storage', 'Dell BOSS', 'Dell BOSS-N1', 'Dell BOSS-S2', etc.
  `$idPatterns = @('$rx','boot optimized storage','dell boss','boss-n','boss-s')
  # Exclude removable buses (USB/SD/MMC) up front.
  `$all = Get-Disk | Where-Object { `$_.BusType -notin 'USB','SD','MMC' }
  foreach (`$d in `$all) {
    W ("disk {0}: name='{1}' model='{2}' bus={3} size={4}GB sn='{5}' path='{6}' loc='{7}' uid='{8}'" -f `$d.Number,`$d.FriendlyName,`$d.Model,`$d.BusType,[math]::Round(`$d.Size/1GB),`$d.SerialNumber,`$d.Path,`$d.Location,`$d.UniqueId)
  }
  # Disks already in an EXISTING (non-primordial) storage pool are S2D data devices - never touch them.
  # In a clean WinPE there is usually no pool, so this list is empty; on a re-image it protects data disks.
  `$pooledUids = @()
  try {
    `$pools = Get-StoragePool -IsPrimordial `$false -ErrorAction SilentlyContinue
    foreach (`$p in `$pools) { `$pooledUids += (Get-PhysicalDisk -StoragePool `$p -ErrorAction SilentlyContinue | Select-Object -ExpandProperty UniqueId -ErrorAction SilentlyContinue) }
    if (@(`$pooledUids).Count) { W ("Excluding existing-pool (S2D) disks: {0}" -f (`$pooledUids -join ',')) }
  } catch { }
  # --- Priority 1: BOSS identity across FriendlyName/Model/SerialNumber/Location/Path/UniqueId ---
  `$cand = `$all | Where-Object {
    `$f = "{0} {1} {2} {3} {4} {5}" -f `$_.FriendlyName,`$_.Model,`$_.SerialNumber,`$_.Location,`$_.Path,`$_.UniqueId
    `$hit = `$false; foreach (`$p in `$idPatterns) { if (`$f -match `$p) { `$hit = `$true } }; `$hit
  }
  if (`$cand) { W ("Priority1 BOSS identity match: {0} candidate(s)" -f @(`$cand).Count) }
  # --- Priority 2: fallback to smallest local FIXED disk (USB/SD/MMC already excluded) ---
  # IMPORTANT: the size ceiling ONLY guards this GUESS path. A positively identified BOSS
  # (Priority 1) is trusted at ANY size - R650 BOSS-S2 ~223GB, R670 BOSS-N1 ~960GB, etc.
  `$fromIdentity = [bool]`$cand
  if (-not `$cand) {
    W "Priority2 no BOSS identity; smallest local fixed-disk fallback (ceiling `$maxGb GB applies)."
    `$fixed = `$all | Where-Object { `$_.BusType -in 'SATA','RAID','NVMe','SAS','ATA' -and (`$_.Size/1GB) -le `$maxGb }
    if (`$fixed) { `$min = (`$fixed | Measure-Object -Property Size -Minimum).Minimum; `$cand = `$fixed | Where-Object { `$_.Size -eq `$min } }
  }
  # --- Priority 3: safety - never an S2D pool member; ceiling applies to the FALLBACK ONLY; require EXACTLY one ---
  `$cand = @(`$cand | Where-Object { `$pooledUids -notcontains `$_.UniqueId })
  if (-not `$fromIdentity) { `$cand = @(`$cand | Where-Object { (`$_.Size/1GB) -le `$maxGb }) }
  foreach (`$c in `$cand) { W ("Priority3 valid candidate: disk {0} '{1}' {2}GB (identityMatch=`$fromIdentity)" -f `$c.Number,`$c.FriendlyName,[math]::Round(`$c.Size/1GB)) }
  `$n = @(`$cand).Count
  if (`$n -ne 1) { W ("AMBIGUOUS/NONE: `$n candidate disk(s) after safety filters - STOP; operator selects manually. Never guessing."); exit 2 }
  `$disk = `$cand[0]
  if ((-not `$fromIdentity) -and ((`$disk.Size/1GB) -gt `$maxGb)) { W ("SAFETY: fallback disk exceeds `$maxGb GB - refusing."); exit 4 }
  W ("Selected BOSS boot disk {0}: '{1}' ({2}GB, bus={3})" -f `$disk.Number,`$disk.FriendlyName,[math]::Round(`$disk.Size/1GB),`$disk.BusType)
  `$dp = @(
    "select disk `$(`$disk.Number)","clean","convert gpt",
    "create partition efi size=500","format fs=fat32 quick","assign letter=S",
    "create partition msr size=16",
    "create partition primary","format fs=ntfs quick label=Windows","assign letter=W","exit"
  ) -join "``r``n"
  `$dpf = "`$env:SystemDrive\Windows\Temp\boss-diskpart.txt"
  Set-Content -Path `$dpf -Value `$dp -Encoding ASCII
  W 'Running diskpart to partition the BOSS disk...'
  diskpart /s `$dpf | Out-Null
  W 'Boot disk prepared.'
  exit 0
} catch { W ('ERROR: ' + `$_.Exception.Message); exit 3 }
"@
    # The unattend schema limits RunSynchronousCommand/Path to 259 chars. A base64 -EncodedCommand
    # of this script is multi-KB and exceeds it, which makes Setup reject the ENTIRE answer file
    # (0x80220005 "Value is invalid"). So stage the script as a file at the ISO root and invoke it
    # with a SHORT Path that searches the media drive letters from within WinPE.
    $script:StageBootSelect  = $true
    $script:BootSelectScript = $peScript
    $runCmd = 'cmd /c for %d in (C D E F G H I J) do @if exist %d:\bootselect.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File %d:\bootselect.ps1'
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
    $imageInstallXml = @"
      <ImageInstall>
        <OSImage>
          <InstallToAvailablePartition>true</InstallToAvailablePartition>
        </OSImage>
      </ImageInstall>
"@
    Write-Step "Disk selection: AUTOMATIC (EXPERIMENTAL, unvalidated). BOSS by identity /$rx/, diskpart in WinPE." 'Yellow'
    Write-Step "  If Setup errors at the apply phase or ignores the answer file, rebuild WITHOUT -AutoSelectBootDisk and pick BOSS manually." 'Yellow'
} else {
    Write-Step "Disk selection: INTERACTIVE (Setup will pause at the disk screen)." 'Yellow'
}

# --- Build the per-node network bootstrap (specialize pass) or leave empty ---
# A base64-encoded PowerShell script runs in the specialize pass. It reads the Dell service tag,
# maps it to hostname + management IP from lab-config.psd1, tags VLAN, sets a static IP/GW/DNS on
# the management adapter, and enables WinRM + RDP so the node is remotely reachable after install.
$netSpecializeXml = ''
$script:StageNetScripts = $false
$script:NetBootstrapScript = ''
if ($BakeNetworkConfig) {
    $nodes = @()
    if ($labCfg.ContainsKey('Nodes')) { $nodes = @($labCfg.Nodes) }
    if (-not $nodes -or $nodes.Count -eq 0) { throw 'BakeNetworkConfig requires Nodes in lab-config.psd1 (ServiceTag + HostIP + Name).' }

    $gw        = if ($labCfg.ContainsKey('Gateway'))     { $labCfg.Gateway }     else { '10.8.230.1' }
    $dns       = if ($labCfg.ContainsKey('DnsServer'))   { $labCfg.DnsServer }   else { '10.8.230.51' }
    $vlan      = if ($labCfg.ContainsKey('MgmtVlan'))    { $labCfg.MgmtVlan }    else { 230 }
    $mgmtAdapterName = if ($labCfg.ContainsKey('MgmtAdapters')) { @($labCfg.MgmtAdapters)[0] } else { 'Integrated NIC 1 Port 1-1' }

    $mapLines = ($nodes | ForEach-Object {
        $mac = if ($_.ContainsKey('MgmtMac')) { $_.MgmtMac } else { '' }
        "  '$($_.ServiceTag)' = @{ Name = '$($_.Name)'; Ip = '$($_.HostIP)'; Mac = '$mac' }"
    }) -join "`r`n"

    Write-Step "Network bake: ON. Per service tag ->" 'Yellow'
    foreach ($n in $nodes) { Write-Step ("    {0}  ->  {1}  {2}" -f $n.ServiceTag, $n.Name, $n.HostIP) 'Yellow' }
    Write-Step "  Adapter '$mgmtAdapterName', VLAN $vlan, gw $gw, dns $dns, /$MgmtPrefixLength; WinRM + RDP enabled." 'Yellow'

    $spScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$log = "`$env:SystemDrive\Windows\Temp\netbootstrap.log"
function W(`$m){ `$t=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Add-Content -Path `$log -Value "`$t  `$m" }
W '=== network bootstrap (SetupComplete) ==='
`$map = @{
$mapLines
}
# Goal #5: identify node by Dell service tag
`$tag = (Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue).SerialNumber
if (-not `$tag) { `$tag = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber }
`$tag = "`$tag".Trim()
W "Detected service tag: `$tag"
`$cfg = `$map[`$tag]
if (-not `$cfg) { W "No mapping for tag '`$tag' - leaving network unchanged."; exit 0 }
W "Selected node config: Name=`$(`$cfg.Name) IP=`$(`$cfg.Ip) Mac=`$(`$cfg.Mac)"
try { Rename-Computer -NewName `$cfg.Name -Force -ErrorAction Stop; W "Hostname -> `$(`$cfg.Name) (applies on reboot)" } catch { W "rename error: `$(`$_.Exception.Message)" }
# Goal #3+#4: wait up to 5 min for NIC drivers, then deterministic adapter selection
`$mgmtName = '$mgmtAdapterName'
`$ad = `$null
for (`$i=0; `$i -lt 30; `$i++) {
  if (`$cfg.Mac) {
    `$norm = (`$cfg.Mac -replace '[:\-\.]','').ToUpper()
    `$ad = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { (`$_.MacAddress -replace '[:\-\.]','').ToUpper() -eq `$norm } | Select-Object -First 1
    if (`$ad) { W "Adapter matched by MAC `$(`$cfg.Mac): `$(`$ad.Name)" }
  }
  if (-not `$ad) { `$ad = Get-NetAdapter -Name `$mgmtName -ErrorAction SilentlyContinue | Where-Object { `$_.Status -eq 'Up' } | Select-Object -First 1 }
  if (-not `$ad) { `$ad = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { `$_.InterfaceDescription -match 'QL41232' -and `$_.Status -eq 'Up' -and `$_.Name -notmatch 'SLOT 2' } | Sort-Object Name | Select-Object -First 1 }
  if (-not `$ad) { `$ad = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { `$_.Status -eq 'Up' -and `$_.Name -notmatch 'SLOT 2|Embedded' } | Sort-Object Name | Select-Object -First 1 }
  if (`$ad) { W "Management adapter after `$(`$i*10)s: `$(`$ad.Name) [`$(`$ad.InterfaceDescription)] MAC=`$(`$ad.MacAddress)"; break }
  W "Attempt `$(`$i+1)/30: no suitable Up adapter yet; waiting 10s for NIC drivers..."
  Start-Sleep -Seconds 10
}
if (-not `$ad) { W 'TIMEOUT: no management adapter after 5 minutes - abort network cfg.'; exit 0 }
try { Set-NetAdapterAdvancedProperty -Name `$ad.Name -DisplayName 'VLAN ID' -DisplayValue '$vlan' -ErrorAction Stop; W "VLAN ID = $vlan"; Start-Sleep -Seconds 5 } catch { W "vlan error: `$(`$_.Exception.Message)" }
`$ad  = Get-NetAdapter -Name `$ad.Name -ErrorAction SilentlyContinue
`$idx = `$ad.InterfaceIndex
try {
  Remove-NetIPAddress -InterfaceIndex `$idx -AddressFamily IPv4 -Confirm:`$false -ErrorAction SilentlyContinue
  Remove-NetRoute -InterfaceIndex `$idx -DestinationPrefix '0.0.0.0/0' -Confirm:`$false -ErrorAction SilentlyContinue
  New-NetIPAddress -InterfaceIndex `$idx -IPAddress `$cfg.Ip -PrefixLength $MgmtPrefixLength -DefaultGateway '$gw' -ErrorAction Stop | Out-Null
  W "IP `$(`$cfg.Ip)/$MgmtPrefixLength gw $gw"
} catch { W "ip error: `$(`$_.Exception.Message)" }
try { Set-DnsClientServerAddress -InterfaceIndex `$idx -ServerAddresses '$dns' -ErrorAction Stop; W "DNS $dns" } catch { W "dns error: `$(`$_.Exception.Message)" }
try { Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop; W 'WinRM/PSRemoting enabled' } catch { W "winrm error: `$(`$_.Exception.Message)" }
try { Set-NetConnectionProfile -InterfaceIndex `$idx -NetworkCategory Private -ErrorAction SilentlyContinue; W 'Network profile Private' } catch {}
try {
  Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -ErrorAction Stop
  Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
  W 'RDP enabled'
} catch { W "rdp error: `$(`$_.Exception.Message)" }
# Goal #6: success marker
try {
  New-Item -ItemType Directory -Path 'C:\Bootstrap' -Force | Out-Null
  `$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  @(
    "Timestamp   : `$stamp",
    "Hostname    : `$(`$cfg.Name)",
    "ServiceTag  : `$tag",
    "AssignedIP  : `$(`$cfg.Ip)/$MgmtPrefixLength",
    "MgmtAdapter : `$(`$ad.Name) [`$(`$ad.InterfaceDescription)] MAC=`$(`$ad.MacAddress)"
  ) | Set-Content -Path 'C:\Bootstrap\success.txt' -Encoding ASCII
  W 'Wrote C:\Bootstrap\success.txt'
} catch { W "marker error: `$(`$_.Exception.Message)" }
# Goal #7: final reboot so hostname + VLAN + profile settle
W 'network bootstrap done; rebooting in 15s.'
shutdown.exe /r /t 15 /c "zcoffee netbootstrap complete"
exit 0
"@
    # IMPORTANT: do NOT embed this script as a RunSynchronousCommand <Path> in the answer file.
    # A multi-KB -EncodedCommand exceeds the unattend schema Path length limit, and Setup then
    # rejects the ENTIRE Autounattend.xml (0x80220005 "Value is invalid"), failing the whole install.
    # Instead we stage the script as a file and run it via SetupComplete.cmd ($OEM$), which has no
    # length limit and is not schema-validated. The answer file stays the proven-good minimal shape.
    $script:NetBootstrapScript = $spScript
    $script:StageNetScripts = $true
    $netSpecializeXml = ''   # nothing injected into the answer file
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

$mounted = $null
try {
    # --- Mount the golden ISO read-only ---
    Write-Step "Mounting golden ISO read-only..."
    $mounted = Mount-DiskImage -ImagePath $GoldenIso -PassThru
    Start-Sleep -Seconds 2
    $vol = ($mounted | Get-Volume)
    if (-not $vol.DriveLetter) { throw 'Could not determine the mounted ISO drive letter.' }
    $drive = ($vol.DriveLetter + ':')
    Write-Step "Golden ISO mounted at $drive"

    # --- Locate boot images inside the ISO ---
    $efiNoPrompt = Join-Path $drive 'efi\microsoft\boot\efisys_noprompt.bin'
    $efiPrompt   = Join-Path $drive 'efi\microsoft\boot\efisys.bin'
    if     (Test-Path $efiNoPrompt) { $efiRel = 'efi\microsoft\boot\efisys_noprompt.bin'; Write-Step "UEFI boot image: efisys_noprompt.bin (no 'press any key' prompt)." }
    elseif (Test-Path $efiPrompt)   { $efiRel = 'efi\microsoft\boot\efisys.bin';          Write-Step "efisys_noprompt.bin not found; using efisys.bin ('press any key' prompt will appear)." 'Yellow' }
    else { throw "No UEFI boot image found under $drive\efi\microsoft\boot\. Is this a UEFI Windows/Azure Local ISO?" }

    $biosRel = $null
    if (Test-Path (Join-Path $drive 'boot\etfsboot.com')) { $biosRel = 'boot\etfsboot.com' }

    # --- Staging folder (needs ~ISO size free) ---
    if (-not $StagingDir) {
        $outDir = Split-Path -Parent $OutputIso
        if (-not $outDir) { $outDir = (Get-Location).Path }
        $StagingDir = Join-Path $outDir ('_ua_stage_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    }
    if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    Write-Step "Staging folder: $StagingDir"

    # --- Copy the full ISO tree to staging (robocopy handles long paths + retries) ---
    Write-Step "Copying golden ISO contents to staging (several minutes for ~8 GB)..."
    # NOTE: a quoted drive root like "I:\" is mangled to I:" by the C runtime ( \" = escaped quote ),
    # which robocopy rejects with exit 16 (nothing copied). Invoke robocopy directly so PowerShell
    # handles argument passing, and pass the drive root without a trailing-backslash-before-quote.
    $srcRoot = $drive + '\'   # e.g. I:\
    & robocopy.exe $srcRoot $StagingDir /E /COPY:DAT /R:2 /W:2 /NP /NFL /NDL /NJH /NJS | Out-Null
    $rcCode = $LASTEXITCODE
    # robocopy exit codes < 8 are success (0-7). >=8 is a real failure.
    if ($rcCode -ge 8) { throw "robocopy failed copying ISO contents (exit $rcCode)." }
    Write-Step "Copy complete (robocopy exit $rcCode)." 'Green'

    # Verify content actually landed (guards against a silent partial copy).
    $stagedCount = @(Get-ChildItem -LiteralPath $StagingDir -Force -ErrorAction SilentlyContinue).Count
    if ($stagedCount -eq 0) { throw "Staging folder is empty after robocopy; nothing copied from $srcRoot." }
    if (-not (Test-Path (Join-Path $StagingDir 'efi'))) { throw "Copied tree is missing the 'efi' folder; source copy incomplete." }

    # --- Drop Autounattend.xml at the staging root ---
    $xmlPath = Join-Path $StagingDir 'Autounattend.xml'
    Set-Content -LiteralPath $xmlPath -Value $xml -Encoding UTF8
    Write-Step "Autounattend.xml written to staging root."

    # --- Network bake: stage SetupComplete.cmd + netbootstrap.ps1 via $OEM$ (no answer-file length limit) ---
    if ($script:StageNetScripts) {
        # $OEM$\$$ maps to %WINDIR%, so files land in C:\Windows\Setup\Scripts on the target.
        $scriptsRel = Join-Path 'sources' (Join-Path '$OEM$' (Join-Path '$$' (Join-Path 'Setup' 'Scripts')))
        $scriptsDir = Join-Path $StagingDir $scriptsRel
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

        $ps1Path = Join-Path $scriptsDir 'netbootstrap.ps1'
        Set-Content -LiteralPath $ps1Path -Value $script:NetBootstrapScript -Encoding UTF8

        # SetupComplete.cmd is auto-run by Windows Setup at the end of install (headless, as SYSTEM).
        $cmdLines = @(
            '@echo off',
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\netbootstrap.ps1" >> "%WINDIR%\Temp\netbootstrap-cmd.log" 2>&1',
            'exit /b 0'
        )
        $cmdPath = Join-Path $scriptsDir 'SetupComplete.cmd'
        Set-Content -LiteralPath $cmdPath -Value ($cmdLines -join "`r`n") -Encoding ASCII
        Write-Step "Network bake staged via `$OEM`$: SetupComplete.cmd + netbootstrap.ps1 (runs post-setup, no answer-file length limit)." 'Green'
    }

    # --- Auto-select disk: stage bootselect.ps1 at the ISO ROOT (invoked by the short WinPE Path) ---
    if ($script:StageBootSelect) {
        $bsPath = Join-Path $StagingDir 'bootselect.ps1'
        Set-Content -LiteralPath $bsPath -Value $script:BootSelectScript -Encoding UTF8
        Write-Step "Auto-select staged: bootselect.ps1 at ISO root (short Path invokes it in WinPE)." 'Green'
    }

    # --- Dismount the source ISO (no longer needed once copied) ---
    Write-Step "Dismounting source golden ISO..."
    Dismount-DiskImage -ImagePath $GoldenIso -ErrorAction SilentlyContinue | Out-Null
    $mounted = $null

    # --- Build boot arguments (BIOS + UEFI when both present, else UEFI only) ---
    $biosFull = if ($biosRel) { Join-Path $StagingDir $biosRel } else { $null }
    $efiFull  = Join-Path $StagingDir $efiRel
    if ($biosFull) {
        $bootData = "2#p0,e,b$biosFull#pEF,e,b$efiFull"
        Write-Step "Boot catalog: BIOS (etfsboot.com) + UEFI (efisys)."
    } else {
        $bootData = "1#pEF,e,b$efiFull"
        Write-Step "Boot catalog: UEFI only (no etfsboot.com in source)." 'Yellow'
    }

    # --- Prepare output path ---
    $outDir2 = Split-Path -Parent $OutputIso
    if ($outDir2 -and -not (Test-Path $outDir2)) { New-Item -ItemType Directory -Path $outDir2 -Force | Out-Null }
    if (Test-Path $OutputIso) { Write-Step "Removing existing $OutputIso..."; Remove-Item $OutputIso -Force }

    # --- Run oscdimg ---
    #   -m           : ignore the default image size limit (large media)
    #   -o           : optimize storage by encoding duplicate files once
    #   -u2          : produce a pure UDF file system (supports >4 GB files)
    #   -udfver102   : UDF 1.02 (matches Windows install media)
    #   -l<label>    : volume label
    #   -bootdata    : boot catalog entries assembled above
    $oscArgs = @(
        '-m', '-o', '-u2', '-udfver102',
        "-l$VolumeName",
        "-bootdata:$bootData",
        "`"$StagingDir`"",
        "`"$OutputIso`""
    )
    Write-Step "Running oscdimg to build the bootable ISO..."
    Write-Host ("oscdimg> {0} {1}" -f $oscdimg, ($oscArgs -join ' ')) -ForegroundColor DarkGray
    $proc = Start-Process -FilePath $oscdimg -ArgumentList $oscArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "oscdimg failed with exit code $($proc.ExitCode)." }

    if (-not (Test-Path $OutputIso)) { throw "oscdimg reported success but no output ISO was produced." }
    $sizeGbOut = [math]::Round((Get-Item $OutputIso).Length / 1GB, 2)
    Write-Step "ISO build complete." 'Green'
    Write-Host ""
    Write-Host "Created unattended golden ISO: $OutputIso ($sizeGbOut GB)" -ForegroundColor Green
    Write-Host "Locale: $Locale   TimeZone: $TimeZone" -ForegroundColor Cyan
    Write-Host "Boot: $(if($biosRel){'BIOS + UEFI'}else{'UEFI'}) El Torito (single RFS mount, no RFS2 needed)." -ForegroundColor Cyan
    Write-Host "Disk: $(if($AutoSelectBootDisk){'AUTOMATIC (experimental WinPE BOSS auto-select)'}else{'INTERACTIVE (operator picks BOSS at the disk screen)'})." -ForegroundColor Cyan
    Write-Host "Network: $(if($BakeNetworkConfig){'BAKED (per-tag hostname/IP/VLAN + WinRM/RDP in specialize)'}else{'NOT baked (configure via iDRAC console or Stage 2 -Apply)'})." -ForegroundColor Cyan
    Write-Host "Treat this ISO as a secret (it contains the obfuscated admin password); it is gitignored." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Deploy with a SINGLE RFS mount:" -ForegroundColor Cyan
    Write-Host "  .\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost <server-ip> ``" -ForegroundColor Gray
    Write-Host "    -ISOFile $OutputIso -StartInstallation -NoCertWarn" -ForegroundColor Gray
}
finally {
    if ($mounted) {
        Write-Step "Dismounting golden ISO..."
        Dismount-DiskImage -ImagePath $GoldenIso -ErrorAction SilentlyContinue | Out-Null
    }
    if ($StagingDir -and (Test-Path $StagingDir)) {
        Write-Step "Cleaning up staging folder..."
        Remove-Item $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $xml = $null; $adminB64 = $null
    Write-Step "Done." 'Green'
}
