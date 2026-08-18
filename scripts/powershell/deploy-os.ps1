[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NodeIP,

    [string]$iDRACUser = 'root',

    [SecureString]$iDRACPassword,

    [string]$ISOUrl,

    [string]$RACADMPath = 'racadm',

    [switch]$StartInstallation,

    [switch]$NoCertWarn,

    [string]$AutounattendUrl,

    # Detach RFS1 (and RFS2) then exit. Leaves the iDRAC clean after a mount-only/check-only run.
    [switch]$DetachOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-RunningAsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run with Administrator privileges.'
    }
}

function Resolve-RACADM {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $command = Get-Command $Path `
        -CommandType Application `
        -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    throw "RACADM executable was not found: $Path"
}

function Convert-SecureStringToPlainText {
    param(
        [Parameter(Mandatory)]
        [SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $SecureString)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-RACADM {
    param(
        [Parameter(Mandatory)]
        [string[]]$CommandArguments
    )

    $arguments = @(
        '-r', $NodeIP,
        '-u', $iDRACUser,
        '-p', $iDRACPasswordPlain
    )

    if ($NoCertWarn) {
        $arguments += '--nocertwarn'
    }

    $arguments += $CommandArguments

    $output = & $RacadmExe @arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $safeOutput = ($output | ForEach-Object {
            $_.ToString().Replace(
                $iDRACPasswordPlain,
                '<redacted>')
        }) -join [Environment]::NewLine

        throw "RACADM command failed for $NodeIP. Output: $safeOutput"
    }

    return $output
}

# Best-effort detach; never throws (the slot may already be empty).
function Remove-RemoteImage {
    param([Parameter(Mandatory)][string]$Slot)   # 'remoteimage' or 'remoteimage2'

    $racArgs = @('-r', $NodeIP, '-u', $iDRACUser, '-p', $iDRACPasswordPlain)
    if ($NoCertWarn) { $racArgs += '--nocertwarn' }
    & $RacadmExe @racArgs $Slot -d 2>&1 | Out-Null
}

# Returns raw text of "<slot> -s" (e.g. "Remote File Share is Enabled/Disabled").
function Get-RemoteImageState {
    param([Parameter(Mandatory)][string]$Slot)

    $racArgs = @('-r', $NodeIP, '-u', $iDRACUser, '-p', $iDRACPasswordPlain)
    if ($NoCertWarn) { $racArgs += '--nocertwarn' }
    return (& $RacadmExe @racArgs $Slot -s 2>&1 | Out-String)
}

# Poll until a slot reports Disabled (detach is asynchronous on iDRAC).
function Wait-RemoteImageDisabled {
    param(
        [Parameter(Mandatory)][string]$Slot,
        [int]$TimeoutSec = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $state = Get-RemoteImageState -Slot $Slot
        if ($state -match 'Disabled') { return $true }
        Start-Sleep -Seconds 3
    }
    Write-Host "WARNING: $Slot on $NodeIP did not report Disabled within ${TimeoutSec}s." -ForegroundColor Yellow
    return $false
}

# Connect a remote image with retries (the connect can briefly race a pending
# detach and return "Unable to perform requested operation").
function Connect-RemoteImage {
    param(
        [Parameter(Mandatory)][string]$Slot,
        [Parameter(Mandatory)][string]$Url,
        [int]$Retries = 4
    )

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $racArgs = @('-r', $NodeIP, '-u', $iDRACUser, '-p', $iDRACPasswordPlain)
        if ($NoCertWarn) { $racArgs += '--nocertwarn' }
        $out = & $RacadmExe @racArgs $Slot -c -l $Url 2>&1
        if ($LASTEXITCODE -eq 0) { return }

        $safe = ($out | ForEach-Object { $_.ToString().Replace($iDRACPasswordPlain, '<redacted>') }) -join [Environment]::NewLine
        if ($attempt -lt $Retries) {
            Write-Host "  $Slot connect attempt $attempt failed; re-checking share state and retrying..." -ForegroundColor Yellow
            [void](Wait-RemoteImageDisabled -Slot $Slot -TimeoutSec 30)
            Start-Sleep -Seconds 3
        }
        else {
            throw "RACADM $Slot connect failed for $NodeIP after $Retries attempts. Output: $safe"
        }
    }
}

function Test-RACADMConnection {
    Write-Host "Testing iDRAC connectivity: $NodeIP"

    $null = Invoke-RACADM -CommandArguments @('getsysinfo')

    Write-Host "iDRAC connectivity verified: $NodeIP"
}

Ensure-RunningAsAdministrator

if (-not $PSBoundParameters.ContainsKey('iDRACPassword') -or
    $null -eq $iDRACPassword) {
    $iDRACPassword = Read-Host `
        -Prompt "Enter the iDRAC password for '$iDRACUser'" `
        -AsSecureString
}

# ISOUrl is required only when we are actually mounting.
if (-not $DetachOnly) {
    if (-not $ISOUrl) { throw 'ISOUrl is required unless -DetachOnly is specified.' }

    $uri = [Uri]::new($ISOUrl)
    if ($uri.Host -in @('localhost', '127.0.0.1', '::1')) {
        throw 'ISOUrl must use an address reachable from the iDRAC, not localhost.'
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        throw 'ISOUrl must use HTTP or HTTPS.'
    }
}

$RacadmExe = Resolve-RACADM -Path $RACADMPath
$iDRACPasswordPlain = $null

try {
    $iDRACPasswordPlain = Convert-SecureStringToPlainText `
        -SecureString $iDRACPassword

    Write-Host "Using RACADM: $RacadmExe"
    Test-RACADMConnection

    if ($DetachOnly) {
        Write-Host "Detaching remote media on $NodeIP"
        Remove-RemoteImage -Slot 'remoteimage2'
        Remove-RemoteImage -Slot 'remoteimage'
        Write-Host "Remote media detached on $NodeIP (RFS1/RFS2 cleared)."
        return
    }

    # Make the mount idempotent: clear any stale share left by a prior run,
    # then WAIT until each slot actually reports Disabled. 'remoteimage -d' is
    # asynchronous ("Disable Remote File Started ... check status using -s"),
    # so mounting too soon fails with "Unable to perform requested operation".
    Write-Host "Clearing any stale remote media on $NodeIP before mount"
    Remove-RemoteImage -Slot 'remoteimage2'
    Remove-RemoteImage -Slot 'remoteimage'
    [void](Wait-RemoteImageDisabled -Slot 'remoteimage'  -TimeoutSec 60)
    [void](Wait-RemoteImageDisabled -Slot 'remoteimage2' -TimeoutSec 60)

    Write-Host "Mounting ISO on $NodeIP"
    Connect-RemoteImage -Slot 'remoteimage' -Url $ISOUrl
    Write-Host "Remote ISO mounted successfully on $NodeIP"

    if ($AutounattendUrl) {
        Write-Host "Attaching Autounattend image via RFS2 on $NodeIP"
        Connect-RemoteImage -Slot 'remoteimage2' -Url $AutounattendUrl
        Write-Host "Autounattend image attached via RFS2 on $NodeIP"
    }

    if ($StartInstallation) {
        Write-Host 'Setting one-time boot to virtual CD/DVD'

        $null = Invoke-RACADM -CommandArguments @(
            'set',
            'iDRAC.ServerBoot.FirstBootDevice',
            'VCD-DVD'
        )

        $null = Invoke-RACADM -CommandArguments @(
            'set',
            'iDRAC.ServerBoot.BootOnce',
            '1'
        )

        Write-Host "Power-cycling $NodeIP to start the Golden Image installer"

        $null = Invoke-RACADM -CommandArguments @(
            'serveraction',
            'powercycle'
        )

        Write-Host "Installation boot initiated on $NodeIP"
    }
    else {
        Write-Host 'Installation was not started. Use -StartInstallation to boot from the ISO.'
    }
}
finally {
    $iDRACPasswordPlain = $null
}
