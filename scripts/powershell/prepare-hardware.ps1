<#
.SYNOPSIS
Per-node hardware preparation worker for Azure Local (Jakarta Lab 01).
Runs BEFORE OS deployment. Two independent, opt-in operations:

  1. Firmware compliance:
     -FirmwareCheckOnly : compare installed firmware to a catalog (non-destructive report)
     -UpdateFirmware    : apply updates from the catalog (reboots the node)
     -UpdateBios        : apply a SINGLE BIOS DUP only (targeted; does not touch other components)
     -UpdateIdrac       : apply a SINGLE iDRAC DUP only (targeted; iDRAC self-reboots)

  2. BOSS boot virtual disk (DESTRUCTIVE):
     -RecreateBossVd    : delete existing BOSS VD(s) and create a fresh RAID-1 OS boot VD

  3. Secure Boot (UEFI):
     -DisableSecureBoot : TEMP install workaround for old BIOS cert stores (BIOS job + reboot)
     -EnableSecureBoot  : re-enable after a BIOS update (required for the validated cluster)

Called by 01-deploy-os.ps1 once per node iDRAC. Can also be run standalone.

.NOTES
Support matrix: pulling "latest" from downloads.dell.com can push firmware NEWER
than the Dell Azure Local support matrix. For strict compliance, point -CatalogUrl
at a Dell Repository Manager (DRM) catalog pinned to the validated versions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NodeIP,
    [string]$iDRACUser = 'root',
    [SecureString]$iDRACPassword,
    [string]$RACADMPath = 'racadm',
    [switch]$NoCertWarn,

    # Firmware
    [switch]$FirmwareCheckOnly,
    [switch]$UpdateFirmware,
    [string]$CatalogUrl = 'downloads.dell.com/Catalog',  # HTTPS repository path (host/path), or a DRM catalog path
    [string]$CatalogFile = 'Catalog.xml.gz',             # catalog file name in the repository

    # BIOS-only targeted update (single DUP). Use this to refresh the BIOS/Secure Boot certificate
    # store WITHOUT pulling every other component to catalog-latest (which can overshoot the
    # Dell Azure Local support matrix). Point at a specific BIOS Dell Update Package (.EXE).
    [switch]$UpdateBios,                                   # apply a single BIOS DUP (reboots the node)
    [string]$BiosDupFile,                                  # BIOS DUP file name, e.g. BIOS_xxxxx_WN64_1.21.1.EXE
    [string]$BiosRepoUrl,                                  # HTTP/HTTPS repo path hosting the BIOS DUP (host/path)
    [string]$BiosRepoProtocol = 'HTTPS',                   # HTTP or HTTPS

    # iDRAC-only targeted update (single DUP). Mirrors -UpdateBios: refresh just the iDRAC/LC
    # firmware without pulling every component to catalog-latest. iDRAC 7.30.x already supports
    # dual RFS media, so this is for future maintenance, not required to install.
    [switch]$UpdateIdrac,                                  # apply a single iDRAC DUP (iDRAC self-reboots)
    [string]$IdracDupFile,                                 # iDRAC DUP file name, e.g. iDRAC_xxxxx_WN64_7.30.30.51.EXE
    [string]$IdracRepoUrl,                                 # HTTP/HTTPS repo path hosting the iDRAC DUP (host/path)
    [string]$IdracRepoProtocol = 'HTTPS',                  # HTTP or HTTPS

    # BOSS boot VD (destructive)
    [switch]$RecreateBossVd,
    [string]$BossRaidLevel = 'r1',
    [switch]$Force,               # skip the interactive destructive confirmation

    # Secure Boot (UEFI). Old BIOS cert stores can reject a newly-signed Golden Image bootloader,
    # causing "Boot Failed: Virtual Optical Drive". Disable to install, re-enable after BIOS update.
    [switch]$DisableSecureBoot,   # set SecureBoot=Disabled (BIOS config job + power-cycle)
    [switch]$EnableSecureBoot,    # set SecureBoot=Enabled  (required for the validated Azure Local cluster)

    # Context (for messages / confirmation)
    [string]$NodeName = '',
    [string]$ServiceTag = '',

    [int]$JobTimeoutMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RACADM {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).Path }
    $c = Get-Command $Path -CommandType Application -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    throw "RACADM executable was not found: $Path"
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory)][SecureString]$SecureString)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Runs racadm; returns @{ Output=<string>; ExitCode=<int> }. Never throws on non-zero.
function Invoke-RACADMRaw {
    param([Parameter(Mandatory)][string[]]$CommandArguments)
    $base = @('-r', $NodeIP, '-u', $iDRACUser, '-p', $script:pw)
    if ($NoCertWarn) { $base += '--nocertwarn' }
    $all = $base + $CommandArguments
    $out = & $script:racadm @all 2>&1
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { $_.ToString().Replace($script:pw, '<redacted>') }) -join [Environment]::NewLine
    return @{ Output = $text; ExitCode = $code }
}

# Runs racadm; throws (with redaction) on non-zero.
function Invoke-RACADM {
    param([Parameter(Mandatory)][string[]]$CommandArguments)
    $r = Invoke-RACADMRaw -CommandArguments $CommandArguments
    if ($r.ExitCode -ne 0) { throw "RACADM failed on $NodeIP ($($CommandArguments -join ' ')): $($r.Output)" }
    return $r.Output
}

function Wait-RacadmJob {
    param([Parameter(Mandatory)][string]$JobId, [int]$TimeoutMinutes = 60)
    Write-Host "  Tracking job $JobId (timeout ${TimeoutMinutes}m). The node may reboot during this job."
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $r = Invoke-RACADMRaw -CommandArguments @('jobqueue', 'view', '-i', $JobId)
        $status = ''
        $pct = ''
        foreach ($line in ($r.Output -split "`n")) {
            if ($line -match 'Status\s*=\s*(.+)')          { $status = $Matches[1].Trim() }
            if ($line -match 'Percent Complete\s*=\s*(.+)') { $pct    = $Matches[1].Trim() }
        }
        if ($status) { Write-Host "    $JobId : $status $pct" }
        switch -Regex ($status) {
            'Completed'                 { Write-Host "  Job $JobId completed."; return $true }
            'Failed|Cancel|Warning'     { throw "Job $JobId ended with status: $status`n$($r.Output)" }
        }
    }
    throw "Job $JobId did not complete within $TimeoutMinutes minutes."
}

# ---------------- Firmware ----------------

function Invoke-FirmwareCheck {
    Write-Host "== Firmware compliance check on $NodeIP (catalog: $CatalogUrl) =="
    Write-Host "  Requesting catalog comparison (non-destructive)..."
    # -f <catalog> -e <repo path> : where to read the catalog; -a FALSE + --verifycatalog : compare only, apply nothing
    $r = Invoke-RACADMRaw -CommandArguments @('update', '-f', $CatalogFile, '-e', $CatalogUrl, '-t', 'HTTPS', '-a', 'FALSE', '--verifycatalog')
    Write-Host $r.Output
    Start-Sleep -Seconds 10
    Write-Host "  Comparison report (installed vs. available):"
    $report = Invoke-RACADMRaw -CommandArguments @('update', 'viewreport')
    Write-Host $report.Output
    Write-Host "  NOTE: 'Available Version' is the catalog version, not necessarily the Azure Local support-matrix version."
}

function Invoke-FirmwareUpdate {
    Write-Host "== Firmware update on $NodeIP (catalog: $CatalogUrl) =="
    Write-Warn2 "Firmware updates reboot the node and can take significant time over the network."
    # -a TRUE : apply applicable updates; --reboot : graceful reboot so staged updates complete
    $out = Invoke-RACADM -CommandArguments @('update', '-f', $CatalogFile, '-e', $CatalogUrl, '-t', 'HTTPS', '-a', 'TRUE', '--reboot')
    Write-Host $out
    $jids = [regex]::Matches($out, 'JID_\d+') | ForEach-Object { $_.Value } | Select-Object -Unique
    if (-not $jids) {
        Write-Host "  No update job was created. The node may already match the catalog."
        return
    }
    foreach ($j in $jids) { Wait-RacadmJob -JobId $j -TimeoutMinutes $JobTimeoutMinutes }
    Write-Host "  Firmware update job(s) finished on $NodeIP."
}

function Invoke-BiosUpdate {
    if (-not $BiosDupFile) { throw "-UpdateBios requires -BiosDupFile (the BIOS DUP file name, e.g. BIOS_xxxxx_WN64_1.21.1.EXE)." }
    if (-not $BiosRepoUrl) { throw "-UpdateBios requires -BiosRepoUrl (HTTP/HTTPS repo path hosting the BIOS DUP)." }
    Write-Host "== BIOS-only update on $NodeIP =="
    Write-Host "  DUP: $BiosDupFile   Repo: ${BiosRepoProtocol}://$BiosRepoUrl"
    Write-Warn2 "BIOS update reboots the node and can take several minutes."
    # Install a single DUP: -f <dup> -e <repo> -t <proto> -a TRUE apply; --reboot so the staged update completes
    $out = Invoke-RACADM -CommandArguments @('update', '-f', $BiosDupFile, '-e', $BiosRepoUrl, '-t', $BiosRepoProtocol, '-a', 'TRUE', '--reboot')
    Write-Host $out
    $jids = [regex]::Matches($out, 'JID_\d+') | ForEach-Object { $_.Value } | Select-Object -Unique
    if (-not $jids) {
        Write-Host "  No BIOS update job was created. The BIOS may already match this DUP version."
        return
    }
    foreach ($j in $jids) { Wait-RacadmJob -JobId $j -TimeoutMinutes $JobTimeoutMinutes }
    Write-Host "  BIOS update job(s) finished on $NodeIP. Re-enable Secure Boot with -EnableSecureBoot when ready."
}

function Invoke-IdracUpdate {
    if (-not $IdracDupFile) { throw "-UpdateIdrac requires -IdracDupFile (the iDRAC DUP file name, e.g. iDRAC_xxxxx_WN64_7.30.30.51.EXE)." }
    if (-not $IdracRepoUrl) { throw "-UpdateIdrac requires -IdracRepoUrl (HTTP/HTTPS repo path hosting the iDRAC DUP)." }
    Write-Host "== iDRAC-only update on $NodeIP =="
    Write-Host "  DUP: $IdracDupFile   Repo: ${IdracRepoProtocol}://$IdracRepoUrl"
    Write-Warn2 "iDRAC update reboots the iDRAC itself; connectivity drops briefly during the update."
    # Install a single DUP: -f <dup> -e <repo> -t <proto> -a TRUE apply. iDRAC firmware applies immediately
    # and the iDRAC self-reboots; no host --reboot flag is needed.
    $out = Invoke-RACADM -CommandArguments @('update', '-f', $IdracDupFile, '-e', $IdracRepoUrl, '-t', $IdracRepoProtocol, '-a', 'TRUE')
    Write-Host $out
    $jids = [regex]::Matches($out, 'JID_\d+') | ForEach-Object { $_.Value } | Select-Object -Unique
    if (-not $jids) {
        Write-Host "  No iDRAC update job was created. The iDRAC may already match this DUP version."
        return
    }
    foreach ($j in $jids) { Wait-RacadmJob -JobId $j -TimeoutMinutes $JobTimeoutMinutes }
    Write-Host "  iDRAC update job(s) finished on $NodeIP."
}

function Write-Warn2 { param([string]$m) Write-Host "  WARNING: $m" -ForegroundColor Yellow }

# ---------------- BOSS boot VD ----------------

function Get-BossControllerFqdd {
    $r = Invoke-RACADM -CommandArguments @('storage', 'get', 'controllers', '-o', '-p', 'Name')
    $current = $null
    $boss = $null
    foreach ($line in ($r -split "`n")) {
        $t = $line.Trim()
        if ($t -match '=') {
            if ($t -match 'Name\s*=\s*(.+)') {
                $name = $Matches[1].Trim()
                if ($name -match '(?i)BOSS') { $boss = [pscustomobject]@{ Fqdd = $current; Name = $name } }
            }
        }
        elseif ($t -match '^[\w]+\.[\w]+\.[\w\-]+$') {
            $current = $t
        }
    }
    if (-not $boss) { throw "No BOSS controller found on $NodeIP. Controllers reported:`n$r" }
    return $boss
}

function Get-StorageFqdds {
    param([Parameter(Mandatory)][ValidateSet('vdisks','pdisks')][string]$Type,
          [Parameter(Mandatory)][string]$ControllerFqdd)
    $r = Invoke-RACADMRaw -CommandArguments @('storage', 'get', $Type, '--refkey', $ControllerFqdd)
    # FQDD forms this must handle:
    #   VD:                    Disk.Virtual.0:AHCI.SL.6-1
    #   PD (BOSS/AHCI M.2):    Disk.Direct.0-0:AHCI.SL.6-1   <-- BOSS SSDs live here
    #   PD (PERC/backplane):   Disk.Bay.0:Enclosure.Internal.0-1:RAID.SL.3-1
    $pattern = if ($Type -eq 'vdisks') { '^Disk\.Virtual\.' } else { '^Disk\.(Direct|Bay)\.' }
    $items = @()
    foreach ($line in ($r.Output -split "`n")) {
        $t = $line.Trim()
        if ($t -match $pattern) { $items += $t }
    }
    return , $items
}

function Invoke-RecreateBossVd {
    Write-Host "== BOSS boot VD recreation on $NodeIP =="
    $ctrl = Get-BossControllerFqdd
    Write-Host "  BOSS controller: $($ctrl.Name)  [$($ctrl.Fqdd)]"

    $vds = Get-StorageFqdds -Type vdisks -ControllerFqdd $ctrl.Fqdd
    $pds = Get-StorageFqdds -Type pdisks -ControllerFqdd $ctrl.Fqdd
    Write-Host "  Existing virtual disks: $([string]::Join(', ', $vds))"
    Write-Host "  Physical disks (M.2):   $([string]::Join(', ', $pds))"

    if ($pds.Count -lt 2) { throw "BOSS controller reports fewer than 2 physical disks; cannot build $BossRaidLevel. Found: $($pds.Count)." }

    # ---- Destructive action notice (no prompt) ----
    # Passing -RecreateBossVd is itself the explicit opt-in; we do NOT prompt.
    Write-Host ''
    Write-Host "  !! DESTRUCTIVE: deleting all BOSS virtual disks on $NodeIP and wiping the OS boot volume." -ForegroundColor Red
    Write-Host "  !! Node: $NodeName  ServiceTag: $ServiceTag  iDRAC: $NodeIP" -ForegroundColor Red
    Write-Host "  Proceeding automatically (-RecreateBossVd was supplied)." -ForegroundColor Yellow

    # ---- Delete existing VDs, then commit with a power-cycle job ----
    if ($vds.Count -gt 0) {
        foreach ($vd in $vds) {
            Write-Host "  Deleting VD: $vd"
            $null = Invoke-RACADM -CommandArguments @('storage', "deletevd:$vd")
        }
        $out = Invoke-RACADM -CommandArguments @('jobqueue', 'create', $ctrl.Fqdd, '-r', 'pwrcycle', '-s', 'TIME_NOW', '-e', 'TIME_NA')
        $jid = ([regex]::Match($out, 'JID_\d+')).Value
        if (-not $jid) { throw "Could not obtain a job ID for VD deletion on $NodeIP.`n$out" }
        Wait-RacadmJob -JobId $jid -TimeoutMinutes $JobTimeoutMinutes
    }

    # ---- Create fresh RAID-1 boot VD ----
    $pdkey = [string]::Join(',', $pds[0..1])
    Write-Host "  Creating $BossRaidLevel boot VD on $($ctrl.Fqdd) using: $pdkey"
    $null = Invoke-RACADM -CommandArguments @("storage", "createvd:$($ctrl.Fqdd)", '-rl', $BossRaidLevel, "-pdkey:$pdkey", '-name', 'OS')
    $out = Invoke-RACADM -CommandArguments @('jobqueue', 'create', $ctrl.Fqdd, '-r', 'pwrcycle', '-s', 'TIME_NOW', '-e', 'TIME_NA')
    $jid = ([regex]::Match($out, 'JID_\d+')).Value
    if (-not $jid) { throw "Could not obtain a job ID for VD creation on $NodeIP.`n$out" }
    Wait-RacadmJob -JobId $jid -TimeoutMinutes $JobTimeoutMinutes

    # ---- Verify ----
    $vds2 = Get-StorageFqdds -Type vdisks -ControllerFqdd $ctrl.Fqdd
    if ($vds2.Count -lt 1) { throw "BOSS VD creation reported success but no VD is present on $NodeIP." }
    Write-Host "  BOSS boot VD ready on $NodeIP : $([string]::Join(', ', $vds2))"
}

# ---------------- Secure Boot (UEFI) ----------------

function Get-SecureBootState {
    # Returns 'Enabled' | 'Disabled' | 'Unknown'
    $r = Invoke-RACADMRaw -CommandArguments @('get', 'BIOS.SysSecurity.SecureBoot')
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match 'SecureBoot\s*=\s*(\w+)') { return $Matches[1].Trim() }
    }
    return 'Unknown'
}

function Get-BootMode {
    $r = Invoke-RACADMRaw -CommandArguments @('get', 'BIOS.BiosBootSettings.BootMode')
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match 'BootMode\s*=\s*(\w+)') { return $Matches[1].Trim() }
    }
    return 'Unknown'
}

function Set-SecureBoot {
    param([Parameter(Mandatory)][ValidateSet('Enabled','Disabled')][string]$Desired)

    $mode = Get-BootMode
    Write-Host "  BootMode: $mode   (Azure Local requires UEFI; do NOT switch to BIOS/Legacy)"
    if ($mode -notmatch '(?i)uefi') {
        Write-Warn2 "BootMode is '$mode', not UEFI. Secure Boot only applies in UEFI mode."
    }

    $current = Get-SecureBootState
    Write-Host "== Secure Boot on $NodeIP : current=$current desired=$Desired =="
    if ($current -eq $Desired) {
        Write-Host "  Secure Boot already $Desired. No change."
        return
    }

    if ($Desired -eq 'Disabled') {
        Write-Host "  !! Disabling Secure Boot is a TEMPORARY install workaround." -ForegroundColor Yellow
        Write-Host "  !! Re-enable it (and update BIOS) before Stage 5 cluster deployment." -ForegroundColor Yellow
    }

    $null = Invoke-RACADM -CommandArguments @('set', 'BIOS.SysSecurity.SecureBoot', $Desired)
    # Commit the pending BIOS change via a config job + power-cycle
    $out = Invoke-RACADM -CommandArguments @('jobqueue', 'create', 'BIOS.Setup.1-1', '-r', 'pwrcycle', '-s', 'TIME_NOW')
    $jid = ([regex]::Match($out, 'JID_\d+')).Value
    if (-not $jid) { throw "Could not obtain a BIOS config job ID on $NodeIP.`n$out" }
    Wait-RacadmJob -JobId $jid -TimeoutMinutes $JobTimeoutMinutes

    $after = Get-SecureBootState
    if ($after -ne $Desired) { throw "Secure Boot is '$after' after the config job; expected '$Desired' on $NodeIP." }
    Write-Host "  Secure Boot is now $after on $NodeIP."
}

# ---------------- Main ----------------

if (-not ($FirmwareCheckOnly -or $UpdateFirmware -or $RecreateBossVd -or $DisableSecureBoot -or $EnableSecureBoot)) {
    Write-Host "No hardware-prep action requested for $NodeIP (nothing to do)."
    return
}

if (-not $iDRACPassword) {
    $iDRACPassword = Read-Host -Prompt "Enter the iDRAC password for '$iDRACUser' on $NodeIP" -AsSecureString
}

$script:racadm = Resolve-RACADM -Path $RACADMPath
$script:pw = $null
try {
    $script:pw = Convert-SecureStringToPlainText -SecureString $iDRACPassword

    # Confirm connectivity first
    $null = Invoke-RACADM -CommandArguments @('getsysinfo')
    Write-Host "iDRAC connectivity verified: $NodeIP"

    if ($DisableSecureBoot -and $EnableSecureBoot) {
        throw "Specify only one of -DisableSecureBoot or -EnableSecureBoot for $NodeIP."
    }

    # Order matters:
    #   1. Firmware update first (refreshes the Secure Boot certificate store).
    #   2. BOSS recreate (clean boot target).
    #   3. Secure Boot change last: DisableSecureBoot right before an install boot;
    #      EnableSecureBoot as a post-firmware hardening step.
    if ($UpdateFirmware)     { Invoke-FirmwareUpdate }
    if ($UpdateBios)         { Invoke-BiosUpdate }
    if ($UpdateIdrac)        { Invoke-IdracUpdate }
    if ($FirmwareCheckOnly)  { Invoke-FirmwareCheck }
    if ($RecreateBossVd)     { Invoke-RecreateBossVd }
    if ($DisableSecureBoot)  { Set-SecureBoot -Desired 'Disabled' }
    if ($EnableSecureBoot)   { Set-SecureBoot -Desired 'Enabled' }

    Write-Host "Hardware preparation finished for $NodeIP."
}
finally {
    $script:pw = $null
}
