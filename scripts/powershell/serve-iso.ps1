<#
.SYNOPSIS
Native PowerShell HTTP file server for the Golden Image / Autounattend ISOs.
No Python required. Uses System.Net.HttpListener (HTTP.sys).

Concurrency: a runspace pool serves multiple requests in parallel, so the
iDRAC boot-time streaming pattern (many concurrent HTTP Range reads) is
satisfied. The previous single-threaded loop could mount an ISO (light reads)
but failed to BOOT one ("no compatible bootloader") because boot-time range
requests queued behind each other and timed out.

Features:
- GET, HEAD, and Range (206 Partial Content) with correct Content-Range.
- HTTP/1.1 keep-alive.
- Client-disconnect tolerant (aborted reads never crash the server).
- Path-traversal protection.

Launched by 01-deploy-os.ps1 as a background process. Run elevated so the
'+' URL prefix registers without a manual netsh urlacl reservation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Prefix,        # e.g. http://+:8080/
    [Parameter(Mandatory)][string]$Directory,
    [int]$MaxThreads = 24,
    [int]$BufferBytes = 1048576                    # 1 MB stream chunk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Directory -PathType Container)) {
    Write-Error "Directory not found: $Directory"; exit 1
}

$root = [System.IO.Path]::GetFullPath($Directory)

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)
# Allow many queued/parallel connections.
try { $listener.TimeoutManager.IdleConnection = [TimeSpan]::FromMinutes(5) } catch { }

try {
    $listener.Start()
}
catch {
    Write-Error "Failed to start HttpListener on $Prefix. $($_.Exception.Message)"
    Write-Error "If access is denied, run once: netsh http add urlacl url=$Prefix user=Everyone"
    exit 1
}

Write-Output "Listening on $Prefix serving $Directory (max $MaxThreads parallel requests)"

# ---- Per-request handler (runs inside a pool runspace) --------------------
$handler = {
    param($ctx, $root, $bufferBytes)

    $req = $ctx.Request
    $res = $ctx.Response

    function Close-Quiet($response) {
        try { $response.OutputStream.Close() } catch { }
        try { $response.Close() } catch { }
    }

    try {
        $res.ProtocolVersion = [Version]'1.1'
        $res.KeepAlive = $true

        # Resolve requested path safely.
        $rel  = [Uri]::UnescapeDataString($req.Url.AbsolutePath.TrimStart('/'))
        $path = [System.IO.Path]::GetFullPath((Join-Path $root $rel))

        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $res.StatusCode = 404
            Close-Quiet $res
            return
        }

        $fi    = Get-Item -LiteralPath $path
        $total = [int64]$fi.Length

        $res.Headers['Accept-Ranges'] = 'bytes'
        $res.ContentType = 'application/octet-stream'

        $start = [int64]0
        $end   = [int64]($total - 1)

        $range = $req.Headers['Range']
        if ($range -and ($range -match 'bytes=(\d*)-(\d*)')) {
            $mStart = $matches[1]
            $mEnd   = $matches[2]
            if ($mStart -ne '') { $start = [int64]$mStart }
            if ($mEnd   -ne '') { $end   = [int64]$mEnd }

            # Suffix range: bytes=-N  (last N bytes)
            if ($mStart -eq '' -and $mEnd -ne '') {
                $start = [int64]([Math]::Max([int64]0, $total - [int64]$mEnd))
                $end   = $total - 1
            }
            if ($end -gt ($total - 1)) { $end = $total - 1 }

            if ($start -gt $end -or $start -lt 0) {
                $res.StatusCode = 416
                $res.Headers['Content-Range'] = "bytes */$total"
                Close-Quiet $res
                return
            }

            $res.StatusCode = 206
            $res.Headers['Content-Range'] = "bytes $start-$end/$total"
        }
        else {
            $res.StatusCode = 200
        }

        $length = $end - $start + 1
        $res.ContentLength64 = $length

        if ($req.HttpMethod -eq 'HEAD') {
            Close-Quiet $res
            return
        }

        $fs = [System.IO.File]::Open(
            $path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read)
        try {
            [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buffer    = New-Object byte[] $bufferBytes
            $remaining = $length
            $out       = $res.OutputStream
            while ($remaining -gt 0) {
                $toRead = [int][Math]::Min([int64]$buffer.Length, $remaining)
                $read   = $fs.Read($buffer, 0, $toRead)
                if ($read -le 0) { break }
                $out.Write($buffer, 0, $read)
                $remaining -= $read
            }
            try { $out.Flush() } catch { }
        }
        finally {
            $fs.Dispose()
        }

        Close-Quiet $res
    }
    catch [System.Net.HttpListenerException] {
        # Client aborted (normal during boot re-reads) - ignore.
        Close-Quiet $res
    }
    catch [System.IO.IOException] {
        # Broken pipe / connection reset - ignore.
        Close-Quiet $res
    }
    catch {
        try { $res.StatusCode = 500 } catch { }
        Close-Quiet $res
    }
}

# ---- Runspace pool + accept loop ------------------------------------------
$pool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads)
$pool.Open()

$inflight = New-Object System.Collections.ArrayList

try {
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }

        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($handler).
            AddArgument($ctx).
            AddArgument($root).
            AddArgument($BufferBytes)

        $async = $ps.BeginInvoke()
        [void]$inflight.Add([pscustomobject]@{ PS = $ps; Async = $async })

        # Reap finished handlers so instances don't accumulate.
        if ($inflight.Count -ge 32) {
            for ($i = $inflight.Count - 1; $i -ge 0; $i--) {
                $item = $inflight[$i]
                if ($item.Async.IsCompleted) {
                    try { $item.PS.EndInvoke($item.Async) } catch { }
                    $item.PS.Dispose()
                    $inflight.RemoveAt($i)
                }
            }
        }
    }
}
finally {
    foreach ($item in $inflight) {
        try { $item.PS.EndInvoke($item.Async) } catch { }
        try { $item.PS.Dispose() } catch { }
    }
    try { $pool.Close() } catch { }
    try { $pool.Dispose() } catch { }
    try { $listener.Stop() } catch { }
}
