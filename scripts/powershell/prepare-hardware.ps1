<#
.SYNOPSIS
Per-node hardware preparation worker for Azure Local (Jakarta Lab 01).
Runs BEFORE OS deployment. Two independent, opt-in operations:

  1. Firmware compliance:
     -FirmwareCheckOnly : compare installed firmware to a catalog (non-destructive report)
     -UpdateFirmware    : apply updates from the catalog (reboots the node)

  2. BOSS boot virtual disk (DESTRUCTIVE):
     -RecreateBossVd    : delete existing BOSS VD(s) and create a fresh RAID-1 OS boot VD

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

    # BOSS boot VD (destructive)
    [switch]$RecreateBossVd,
    [string]$BossRaidLevel = 'r1',
    [switch]$Force,               # skip the interactive destructive confirmation

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
    $items = @()
    foreach ($line in ($r.Output -split "`n")) {
        $t = $line.Trim()
        # VD FQDD: Disk.Virtual.0:AHCI.Slot.6-1 ; PD FQDD: Disk.Bay.0:Enclosure...:AHCI.Slot.6-1
        if ($t -match '^Disk\.(Virtual|Bay)\..+') { $items += $t }
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

    # ---- Destructive confirmation ----
    if (-not $Force) {
        $label = if ($ServiceTag) { $ServiceTag } elseif ($NodeName) { $NodeName } else { $NodeIP }
        Write-Host ''
        Write-Host "  !! DESTRUCTIVE: this DELETES all BOSS virtual disks on $NodeIP and wipes the OS boot volume." -ForegroundColor Red
        Write-Host "  !! Node: $NodeName  ServiceTag: $ServiceTag  iDRAC: $NodeIP" -ForegroundColor Red
        $answer = Read-Host "  To proceed, type the node identifier exactly ($label)"
        if ($answer -ne $label) { throw "Confirmation mismatch (expected '$label'). Aborting BOSS recreation on $NodeIP." }
    }
    else {
        Write-Host "  -Force supplied; skipping interactive confirmation." -ForegroundColor Yellow
    }

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

# ---------------- Main ----------------

if (-not ($FirmwareCheckOnly -or $UpdateFirmware -or $RecreateBossVd)) {
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

    if ($FirmwareCheckOnly) { Invoke-FirmwareCheck }
    if ($UpdateFirmware)    { Invoke-FirmwareUpdate }
    if ($RecreateBossVd)    { Invoke-RecreateBossVd }

    Write-Host "Hardware preparation finished for $NodeIP."
}
finally {
    $script:pw = $null
}
