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

    This script rebuilds the ISO natively with Windows IMAPI2 (no Windows ADK, no Python):
      - Mounts the source golden ISO read-only (Mount-DiskImage).
      - Copies its entire file tree into the new image, PLUS Autounattend.xml at the root.
      - Enables UDF (the install.wim/.esd inside can exceed the 4 GB ISO9660 per-file limit).
      - Re-assigns the UEFI El Torito boot image (efi\microsoft\boot\efisys_noprompt.bin,
        falling back to efisys.bin) so the result stays UEFI-bootable. 'noprompt' also removes
        the "Press any key to boot from CD/DVD" gate for hands-off installs.

    Answer-file scope matches make-autounattend-iso.ps1 (locale, timezone, admin password;
    disk selection stays interactive to protect the S2D data disks).

.NOTES
    - The admin password is stored in the answer file as base64 (unattend obfuscation, NOT
      encryption). Treat the OUTPUT ISO as a secret; it is covered by .gitignore.
    - Rebuilding an ~8 GB ISO takes time and free disk space equal to the ISO size.
    - VALIDATE the first output by booting one node before relying on it for both.
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
    [string]$VolumeName   = 'AZLOCAL_UA'
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

Write-Step "make-golden-with-unattend starting."
Write-Step "Source golden ISO: $GoldenIso"
Write-Step "Output ISO:        $OutputIso"

if (-not (Test-Path $GoldenIso -PathType Leaf)) { throw "Golden ISO not found: $GoldenIso" }
$GoldenIso = (Resolve-Path $GoldenIso).Path

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
      <!-- No DiskConfiguration by design: Setup stops only at the disk-selection
           screen so the operator picks the BOSS RAID-1 volume, protecting the S2D disks. -->
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

# --- Native IStream-from-file helper (for the UEFI boot image) ---
if (-not ('AzLocalIso.Native' -as [type])) {
    Write-Step "Compiling native helpers (Add-Type -> csc.exe). First run can take 10-30s..." 'Yellow'
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace AzLocalIso {
    public static class Native {
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        static extern int SHCreateStreamOnFileEx(
            string file, uint grfMode, uint dwAttributes, bool fCreate, IStream pstmTemplate, out IStream ppstm);

        // STGM_READ = 0, FILE_ATTRIBUTE_NORMAL = 0x80
        public static IStream StreamFromFile(string path) {
            IStream s;
            int hr = SHCreateStreamOnFileEx(path, 0u, 0x80u, false, null, out s);
            if (hr != 0) throw new IOException("SHCreateStreamOnFileEx failed 0x" + hr.ToString("X8") + " for " + path);
            return s;
        }
    }
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
                finally { Marshal.FreeHGlobal(read); }
            }
        }
    }
}
'@
    Write-Step "Native helpers compiled." 'Green'
}
else { Write-Step "Native helpers already loaded; skipping compile." }

$mounted = $null
$fsi = $null
$stagingXml = $null
try {
    # --- Mount the golden ISO read-only ---
    Write-Step "Mounting golden ISO read-only..."
    $mounted = Mount-DiskImage -ImagePath $GoldenIso -PassThru
    Start-Sleep -Seconds 2
    $vol = ($mounted | Get-Volume)
    $drive = ($vol.DriveLetter + ':')
    if (-not $vol.DriveLetter) { throw 'Could not determine the mounted ISO drive letter.' }
    Write-Step "Golden ISO mounted at $drive"

    # --- Locate the UEFI boot image inside the ISO ---
    $noprompt = Join-Path $drive 'efi\microsoft\boot\efisys_noprompt.bin'
    $prompt   = Join-Path $drive 'efi\microsoft\boot\efisys.bin'
    if     (Test-Path $noprompt) { $efiBoot = $noprompt; Write-Step "Using UEFI boot image: efisys_noprompt.bin (no 'press any key' prompt)." }
    elseif (Test-Path $prompt)   { $efiBoot = $prompt;   Write-Step "efisys_noprompt.bin not found; using efisys.bin ('press any key' prompt will appear)." 'Yellow' }
    else { throw "No UEFI boot image found under $drive\efi\microsoft\boot\. Is this a UEFI Windows/Azure Local ISO?" }

    # --- Stage Autounattend.xml ---
    $stagingXml = Join-Path ([IO.Path]::GetTempPath()) ("Autounattend_" + [Guid]::NewGuid().ToString('N') + '.xml')
    Set-Content -LiteralPath $stagingXml -Value $xml -Encoding UTF8
    Write-Step "Answer file staged."

    # --- Build the new image with IMAPI2 (ISO9660 + Joliet + UDF for >4GB files) ---
    Write-Step "Creating IMAPI2 file system image (ISO9660 + Joliet + UDF)..."
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 7            # 1 ISO9660 + 2 Joliet + 4 UDF
    try { $fsi.UDFRevision = 0x102 } catch { }   # UDF 1.02 (matches Windows install media)
    $fsi.VolumeName = $VolumeName

    Write-Step "Adding golden ISO contents to the image (this can take several minutes for ~8 GB)..."
    $fsi.Root.AddTree($drive, $false)

    Write-Step "Adding Autounattend.xml at the image root..."
    $fsi.Root.AddFile('Autounattend.xml', [AzLocalIso.Native]::StreamFromFile($stagingXml))

    # --- Assign the UEFI El Torito boot image ---
    Write-Step "Assigning UEFI (EFI) El Torito boot image..."
    $boot = New-Object -ComObject IMAPI2FS.BootOptions
    $boot.AssignBootImage([AzLocalIso.Native]::StreamFromFile($efiBoot))
    $boot.PlatformId = 0xEF      # EFI
    $boot.Emulation  = 0         # EmulationNone
    $boot.Manufacturer = 'Microsoft'
    $fsi.BootImageOptions = $boot

    Write-Step "Rendering ISO image stream (CreateResultImage)..."
    $result = $fsi.CreateResultImage()
    $totalBlocks = $result.TotalBlocks
    $blockSize   = $result.BlockSize
    $sizeGb = [math]::Round(($totalBlocks * $blockSize) / 1GB, 2)
    Write-Step ("Image ready: {0} blocks x {1} bytes (~{2} GB). Writing to disk..." -f $totalBlocks, $blockSize, $sizeGb)

    $outDir = Split-Path -Parent $OutputIso
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    if (Test-Path $OutputIso) { Write-Step "Removing existing $OutputIso before write..."; Remove-Item $OutputIso -Force }

    [AzLocalIso.IsoWriter]::Create($OutputIso, $result.ImageStream, $blockSize, $totalBlocks)

    $sizeGbOut = [math]::Round((Get-Item $OutputIso).Length / 1GB, 2)
    Write-Step "ISO write complete." 'Green'
    Write-Host ""
    Write-Host "Created unattended golden ISO: $OutputIso ($sizeGbOut GB)" -ForegroundColor Green
    Write-Host "Locale: $Locale   TimeZone: $TimeZone" -ForegroundColor Cyan
    Write-Host "Boot: UEFI El Torito (single RFS mount, no RFS2 needed)." -ForegroundColor Cyan
    Write-Host "Treat this ISO as a secret (it contains the obfuscated admin password); it is gitignored." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Deploy with a SINGLE RFS mount:" -ForegroundColor Cyan
    Write-Host "  .\bootstrap-cluster.ps1 -Stage 01-deploy-os -HttpHost <server-ip> ``" -ForegroundColor Gray
    Write-Host "    -ISOFile $OutputIso -StartInstallation -NoCertWarn" -ForegroundColor Gray
}
finally {
    if ($stagingXml -and (Test-Path $stagingXml)) { Remove-Item $stagingXml -Force -ErrorAction SilentlyContinue }
    if ($fsi) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fsi) }
    if ($mounted) {
        Write-Step "Dismounting golden ISO..."
        Dismount-DiskImage -ImagePath $GoldenIso -ErrorAction SilentlyContinue | Out-Null
    }
    $xml = $null; $adminB64 = $null
    Write-Step "Done." 'Green'
}
