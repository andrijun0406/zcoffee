<#
.SYNOPSIS
    Download and stage the Dell AX-15G Azure Local SBE bundle.

.DESCRIPTION
    Windows PowerShell 5.1-compatible downloader for the Dell SBE bundle.
    Downloads the ZIP, verifies SHA-256, extracts it, and validates that the
    extracted source contains an XML manifest and a ZIP/CAB/MSU payload.

    The extracted directory can be passed to stage-sbe.ps1 as -SbeSourcePath.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^https://')]
    [string]$Url = 'https://dl.dell.com/FOLDER14700241M/1/Bundle_SBE_Dell_AX-15G_5.0.2606.1510.zip',

    [string]$OutputDirectory = 'C:\zcoffee\sbe\AX650-2606',

    [string]$FileName = 'Bundle_SBE_Dell_AX-15G_5.0.2606.1510.zip',

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedSha256 = '388c377f792121772c09f48ae520e6ccdcf5dc6808570c424d271b7d14dd7bc8',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Warning $Message
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $downloadDirectory = Join-Path $OutputDirectory 'download'
    $extractDirectory = Join-Path $OutputDirectory 'contents'
    New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null

    $zipPath = Join-Path $downloadDirectory $FileName
    $partialPath = "$zipPath.partial"

    if ($Force -and (Test-Path -LiteralPath $extractDirectory)) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force
    }

    $needsDownload = $true
    if ((Test-Path -LiteralPath $zipPath) -and (-not $Force)) {
        $existingHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($existingHash -ieq $ExpectedSha256) {
            $needsDownload = $false
            Write-Ok "Existing SBE ZIP passed SHA-256 validation: $existingHash"
        }
        else {
            Write-Warn "Existing ZIP hash mismatch; downloading a fresh copy."
        }
    }

    if ($needsDownload) {
        if (Test-Path -LiteralPath $partialPath) {
            Remove-Item -LiteralPath $partialPath -Force
        }

        Write-Info "Downloading Dell SBE bundle from $Url"
        $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
        if ($bits) {
            Start-BitsTransfer `
                -Source $Url `
                -Destination $partialPath `
                -DisplayName 'Dell Azure Local SBE bundle' `
                -Priority High `
                -RetryInterval 30 `
                -RetryTimeout 3600 `
                -ErrorAction Stop
        }
        else {
            Invoke-WebRequest `
                -Uri $Url `
                -OutFile $partialPath `
                -UseBasicParsing `
                -ErrorAction Stop
        }

        Move-Item -LiteralPath $partialPath -Destination $zipPath -Force
        $downloadedHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($downloadedHash -ine $ExpectedSha256) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            throw "SHA-256 mismatch. Expected $ExpectedSha256 but received $downloadedHash."
        }
        Write-Ok "Downloaded ZIP passed SHA-256 validation: $downloadedHash"
    }

    if (-not (Test-Path -LiteralPath $extractDirectory)) {
        New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null
    }

    Write-Info "Extracting bundle to $extractDirectory"
    $expand = Get-Command Expand-Archive -ErrorAction SilentlyContinue
    if ($expand) {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDirectory -Force
    }
    else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDirectory)
    }

    $manifests = @(Get-ChildItem -LiteralPath $extractDirectory -Recurse -File -Filter '*.xml')
    $payloads = @(Get-ChildItem -LiteralPath $extractDirectory -Recurse -File |
        Where-Object { $_.Extension.ToLowerInvariant() -in @('.zip', '.cab', '.msu') })

    if ($manifests.Count -eq 0) {
        throw "Extracted SBE bundle contains no XML manifest: $extractDirectory"
    }
    if ($payloads.Count -eq 0) {
        throw "Extracted SBE bundle contains no ZIP/CAB/MSU payload: $extractDirectory"
    }

    Write-Ok "SBE bundle staged: $extractDirectory"
    Write-Host "Manifest count: $($manifests.Count)"
    Write-Host "Payload count : $($payloads.Count)"
    Write-Host "SbeSourcePath : $extractDirectory"
    Write-Host "ZipPath       : $zipPath"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
