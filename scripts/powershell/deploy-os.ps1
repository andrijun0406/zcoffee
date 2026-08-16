[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NodeIP,

    [string]$iDRACUser = 'root',

    [SecureString]$iDRACPassword,

    [Parameter(Mandatory)]
    [ValidatePattern('^https?://')]
    [string]$ISOUrl,

    [string]$RACADMPath = 'racadm',

    [switch]$StartInstallation,

    [switch]$NoCertWarn,

    [ValidatePattern('^https?://')]
    [string]$AutounattendUrl
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

$uri = [Uri]::new($ISOUrl)

if ($uri.Host -in @('localhost', '127.0.0.1', '::1')) {
    throw 'ISOUrl must use an address reachable from the iDRAC, not localhost.'
}

if ($uri.Scheme -notin @('http', 'https')) {
    throw 'ISOUrl must use HTTP or HTTPS.'
}

$RacadmExe = Resolve-RACADM -Path $RACADMPath
$iDRACPasswordPlain = $null

try {
    $iDRACPasswordPlain = Convert-SecureStringToPlainText `
        -SecureString $iDRACPassword

    Write-Host "Using RACADM: $RacadmExe"
    Test-RACADMConnection

    Write-Host "Mounting ISO on $NodeIP"

    $null = Invoke-RACADM -CommandArguments @(
        'remoteimage',
        '-c',
        '-l',
        $ISOUrl
    )

    Write-Host "Remote ISO mounted successfully on $NodeIP"

    if ($AutounattendUrl) {
        Write-Host "Attaching Autounattend image via RFS2 on $NodeIP"
        $detachArgs = @('-r', $NodeIP, '-u', $iDRACUser, '-p', $iDRACPasswordPlain)
        if ($NoCertWarn) { $detachArgs += '--nocertwarn' }
        & $RacadmExe @detachArgs remoteimage2 -d 2>&1 | Out-Null
        $null = Invoke-RACADM -CommandArguments @('remoteimage2', '-c', '-l', $AutounattendUrl)
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
