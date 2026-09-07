<#
.SYNOPSIS
    Download and stage the Dell AX-15G Azure Local SBE bundle.

.DESCRIPTION
    Windows PowerShell 5.1-compatible downloader with visible progress and bounded
    retries. The ZIP is downloaded to a .partial file, verified by SHA-256, then
    extracted only after checksum validation succeeds.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^https://')]
    [string]$Url = 'https://dl.dell.com/FOLDER14700241M/1/Bundle_SBE_Dell_AX-15G_5.0.2606.1510.zip',

    [string]$OutputDirectory = 'C:\zcoffee\sbe\AX650-2606',

    [string]$FileName = 'Bundle_SBE_Dell_AX-15G_5.0.2606.1510.zip',

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedSha256 = '388c377f792121772c09f48ae520e6ccdcf5dc6808570c424d271b7d14dd7bc8',

    [ValidateRange(1, 10)]
    [int]$MaxRetries = 3,

    [ValidateRange(1, 300)]
    [int]$RetryDelaySeconds = 15,

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

function Format-Bytes([Int64]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Download-WithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$SourceUrl,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $request = $null
    $response = $null
    $inputStream = $null
    $outputStream = $null

    try {
        $request = [System.Net.HttpWebRequest]::Create($SourceUrl)
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $true
        $request.Timeout = 60000
        $request.ReadWriteTimeout = 60000
        $request.UserAgent = 'ZCOFFEE-SBE-Downloader/1.0'
        $response = $request.GetResponse()

        $total = [Int64]$response.ContentLength
        $inputStream = $response.GetResponseStream()
        $outputStream = New-Object System.IO.FileStream(
            $DestinationPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)

        $buffer = New-Object byte[] (1024 * 1024)
        $received = [Int64]0
        $lastReport = Get-Date
        $lastBytes = [Int64]0
        $lastTime = Get-Date

        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $received += $read

            $now = Get-Date
            if (($now - $lastReport).TotalSeconds -ge 1) {
                $seconds = ($now - $lastTime).TotalSeconds
                if ($seconds -gt 0) {
                    $speed = [Int64](($received - $lastBytes) / $seconds)
                }
                else {
                    $speed = [Int64]0
                }

                if ($total -gt 0) {
                    $percent = [int][Math]::Min(100, [Math]::Floor(($received * 100) / $total))
                    $status = '{0} / {1} ({2:N1}%) at {3}/s' -f `
                        (Format-Bytes $received), (Format-Bytes $total), $percent, (Format-Bytes $speed)
                    Write-Progress -Activity 'Downloading Dell SBE bundle' `
                        -Status $status -PercentComplete $percent
                    Write-Host ("  {0} / {1} ({2:N1}%) at {3}/s" -f `
                        (Format-Bytes $received), (Format-Bytes $total), $percent, (Format-Bytes $speed)) `
                        -ForegroundColor DarkCyan
                }
                else {
                    $status = '{0} received at {1}/s' -f (Format-Bytes $received), (Format-Bytes $speed)
                    Write-Progress -Activity 'Downloading Dell SBE bundle' -Status $status
                    Write-Host ("  {0} received at {1}/s" -f `
                        (Format-Bytes $received), (Format-Bytes $speed)) -ForegroundColor DarkCyan
                }

                $lastReport = $now
                $lastBytes = $received
                $lastTime = $now
            }
        }

        Write-Progress -Activity 'Downloading Dell SBE bundle' -Completed
        if ($total -gt 0 -and $received -ne $total) {
            throw "Download ended early: received $received bytes, expected $total bytes."
        }

        return $received
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
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
        Write-Info "Existing ZIP found; verifying SHA-256 before reuse..."
        $existingHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($existingHash -ieq $ExpectedSha256) {
            $needsDownload = $false
            Write-Ok "Existing SBE ZIP passed SHA-256 validation: $existingHash"
        }
        else {
            Write-Warn "Existing ZIP hash mismatch; downloading a fresh copy."
            Remove-Item -LiteralPath $zipPath -Force
        }
    }

    if ($needsDownload) {
        $completed = $false
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            if (Test-Path -LiteralPath $partialPath) {
                Remove-Item -LiteralPath $partialPath -Force
            }

            try {
                Write-Info "Download attempt $attempt of $MaxRetries from $Url"
                $bytes = Download-WithProgress -SourceUrl $Url -DestinationPath $partialPath
                Write-Info ("Transfer complete: {0}" -f (Format-Bytes $bytes))
                Move-Item -LiteralPath $partialPath -Destination $zipPath -Force
                $completed = $true
                break
            }
            catch {
                Write-Warn "Download attempt $attempt failed: $($_.Exception.Message)"
                if ($attempt -lt $MaxRetries) {
                    Write-Info "Retrying in $RetryDelaySeconds seconds..."
                    Start-Sleep -Seconds $RetryDelaySeconds
                }
            }
        }

        if (-not $completed) {
            throw "Dell SBE download failed after $MaxRetries attempts."
        }

        $downloadedHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($downloadedHash -ine $ExpectedSha256) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            throw "SHA-256 mismatch. Expected $ExpectedSha256 but received $downloadedHash."
        }
        Write-Ok "Downloaded ZIP passed SHA-256 validation: $downloadedHash"
    }

    if (Test-Path -LiteralPath $extractDirectory) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null

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
