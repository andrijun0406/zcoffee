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

    Answer-file scope matches make-autounattend-iso.ps1 (locale, timezone, admin password;
    disk selection stays interactive to protect the S2D data disks).

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
    [string]$StagingDir                          # override staging folder (default: beside OutputIso)
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
    $rc = Start-Process -FilePath robocopy.exe `
        -ArgumentList @("`"$drive\`"", "`"$StagingDir`"", '/E', '/COPY:DAT', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', '/NJH', '/NJS') `
        -Wait -PassThru -WindowStyle Hidden
    # robocopy exit codes < 8 are success (0-7). >=8 is a real failure.
    if ($rc.ExitCode -ge 8) { throw "robocopy failed copying ISO contents (exit $($rc.ExitCode))." }
    Write-Step "Copy complete (robocopy exit $($rc.ExitCode))." 'Green'

    # --- Drop Autounattend.xml at the staging root ---
    $xmlPath = Join-Path $StagingDir 'Autounattend.xml'
    Set-Content -LiteralPath $xmlPath -Value $xml -Encoding UTF8
    Write-Step "Autounattend.xml written to staging root."

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
