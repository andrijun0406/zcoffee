<#
.SYNOPSIS
Minimal native PowerShell HTTP file server for the Golden Image ISO.
No Python required. Uses System.Net.HttpListener (HTTP.sys) and supports
GET, HEAD, and Range (206) requests so iDRAC remoteimage can pull the ISO.

Launched by 01-deploy-os.ps1 as a background process. Run elevated so the
'+' URL prefix can be registered without a manual netsh urlacl reservation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Prefix,      # e.g. http://+:8080/
    [Parameter(Mandatory)][string]$Directory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Directory -PathType Container)) {
    Write-Error "Directory not found: $Directory"; exit 1
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)

try {
    $listener.Start()
}
catch {
    Write-Error "Failed to start HttpListener on $Prefix. $($_.Exception.Message)"
    exit 1
}

Write-Output "Listening on $Prefix serving $Directory"

while ($listener.IsListening) {
    try { $ctx = $listener.GetContext() } catch { break }

    $req = $ctx.Request
    $res = $ctx.Response

    try {
        $rel = [Uri]::UnescapeDataString($req.Url.AbsolutePath.TrimStart('/'))
        $path = Join-Path $Directory $rel

        # Prevent path traversal outside the served directory.
        $full = [System.IO.Path]::GetFullPath($path)
        $root = [System.IO.Path]::GetFullPath($Directory)
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path $full -PathType Leaf)) {
            $res.StatusCode = 404; $res.Close(); continue
        }

        $fi = Get-Item -LiteralPath $full
        $total = $fi.Length
        $res.Headers['Accept-Ranges'] = 'bytes'
        $res.ContentType = 'application/octet-stream'

        $start = [int64]0
        $end   = [int64]($total - 1)
        $range = $req.Headers['Range']
        if ($range -and $range -match 'bytes=(\d*)-(\d*)') {
            if ($matches[1] -ne '') { $start = [int64]$matches[1] }
            if ($matches[2] -ne '') { $end   = [int64]$matches[2] }
            if ($end -gt ($total - 1)) { $end = $total - 1 }
            $res.StatusCode = 206
            $res.Headers['Content-Range'] = "bytes $start-$end/$total"
        }
        else {
            $res.StatusCode = 200
        }

        $length = $end - $start + 1
        $res.ContentLength64 = $length

        if ($req.HttpMethod -eq 'HEAD') { $res.Close(); continue }

        $fs = [System.IO.File]::OpenRead($full)
        try {
            [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] 1048576
            $remaining = $length
            while ($remaining -gt 0) {
                $toRead = [Math]::Min([int64]$buffer.Length, $remaining)
                $read = $fs.Read($buffer, 0, [int]$toRead)
                if ($read -le 0) { break }
                $res.OutputStream.Write($buffer, 0, $read)
                $remaining -= $read
            }
        }
        finally { $fs.Dispose() }

        $res.OutputStream.Flush()
        $res.Close()
    }
    catch {
        try { $res.StatusCode = 500; $res.Close() } catch { }
    }
}
