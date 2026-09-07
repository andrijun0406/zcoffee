<#
.SYNOPSIS
    Deploy the same unattended ISO to multiple iDRACs concurrently.

.DESCRIPTION
    Starts one concurrent range-capable serve-iso.ps1 process and invokes the existing
    deploy-os.ps1 worker once per iDRAC in an in-process runspace pool. The SecureString
    iDRAC password never appears on a child-process command line.

    The HTTP server remains alive for ServerLifetimeMinutes after the workers finish so
    the nodes can continue reading the ISO during Windows Setup. Do not use -NoWait for
    an unattended installation unless the ISO is hosted elsewhere.
#>
[CmdletBinding()]
param(
    [string]$ISOFile,
    [string]$HttpHost,
    [string]$HttpBind = '0.0.0.0',
    [ValidateRange(1,65535)]
    [int]$HttpPort,
    [string]$iDRACUser,
    [SecureString]$iDRACPassword,
    [string]$RACADMPath = 'racadm',
    [switch]$StartInstallation,
    [switch]$NoCertWarn,
    [int]$ServerLifetimeMinutes = 240,
    [switch]$NoWait,
    [switch]$UseGui,
    [string[]]$iDRACIPs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

# Initialize runtime state before any operation that can fail so early errors are reportable.
$serverProcess = $null
$runspacePool = $null
$jobs = @()
$workerErrors = New-Object System.Collections.Generic.List[string]
$serverStartedAt = Get-Date

Initialize-Ui -StageName '01-deploy-os-parallel' -TotalSteps 4 -UseGui:$UseGui

try {
    Write-Info 'Initializing parallel OS deployment launcher.'
    $cfg = Import-LabConfig
    $b = $PSBoundParameters

$iDRACUser = Resolve-Setting -Name 'iDRACUser' -Bound $b -Current $iDRACUser -ConfigKey 'iDRACUser' -Config $cfg
if (-not $iDRACUser) { $iDRACUser = 'root' }

$HttpPort = Resolve-Setting -Name 'HttpPort' -Bound $b -Current $HttpPort -ConfigKey 'HttpPort' -Config $cfg
if (-not $HttpPort) { $HttpPort = 8080 }

if (-not $b.ContainsKey('iDRACIPs')) {
    if ($cfg.ContainsKey('Nodes')) {
        $iDRACIPs = @($cfg.Nodes | ForEach-Object { $_.iDRAC })
    } else {
        $iDRACIPs = @('10.8.230.84','10.8.230.86')
    }
}
if ($iDRACIPs.Count -lt 2) {
    throw 'Provide at least two iDRAC IPs for parallel deployment.'
}

if (-not $ISOFile) {
    throw '-ISOFile is required. Provide the prepared unattended ISO path.'
}
$ISOFile = (Resolve-Path -LiteralPath $ISOFile -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $ISOFile -PathType Leaf)) {
    throw "ISO file not found: $ISOFile"
}

if (-not $HttpHost) {
    $HttpHost = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            $_.IPAddress -like '10.8.230.*' -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*'
        } |
        Select-Object -First 1 -ExpandProperty IPAddress
}
if (-not $HttpHost) {
    throw 'Unable to determine a reachable 10.8.230.x HTTP host. Supply -HttpHost.'
}

if (-not $b.ContainsKey('iDRACPassword') -or $null -eq $iDRACPassword) {
    $iDRACPassword = Read-Host -Prompt "Enter the iDRAC password for '$iDRACUser'" -AsSecureString
}

$serveScript = Join-Path $PSScriptRoot 'serve-iso.ps1'
$worker = Join-Path $PSScriptRoot 'deploy-os.ps1'
if (-not (Test-Path -LiteralPath $serveScript -PathType Leaf)) { throw "Missing serve-iso.ps1: $serveScript" }
if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) { throw "Missing deploy-os.ps1: $worker" }

# Avoid PowerShell 5.1 Split-Path parameter-set ambiguity.
$isoFullPath = [System.IO.Path]::GetFullPath($ISOFile)
$isoDir = [System.IO.Path]::GetDirectoryName($isoFullPath)
$isoName = [System.IO.Path]::GetFileName($isoFullPath)
if ([string]::IsNullOrWhiteSpace($isoDir)) {
    $isoDir = (Get-Location).Path
}
$prefixHost = if ($HttpBind -and $HttpBind -notin @('0.0.0.0','+')) { $HttpBind } else { '+' }
$prefix = "http://$prefixHost`:$HttpPort/"
$isoUrl = "http://$HttpHost`:$HttpPort/$([Uri]::EscapeDataString($isoName))"

$psExe = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
} else {
    Join-Path $PSHOME 'powershell.exe'
}
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

    Write-Info 'Preflight complete; beginning privileged execution steps.'
    Invoke-Step 'Verify Administrator privileges' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($id)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Administrator privileges are required.'
        }
    }

    Invoke-Step 'Start one concurrent ISO HTTP server' {
        $errFile = Join-Path $env:TEMP "zcoffee-iso-parallel-$PID.err"
        $outFile = Join-Path $env:TEMP "zcoffee-iso-parallel-$PID.out"
        Write-Info "ISO server diagnostics: $errFile"
        # Use only the basic Start-Process parameter set. Windows PowerShell 5.1
        # can reject combinations of redirection/window switches before the server
        # starts. The server writes its own startup/errors to its console window.
        $serverArgs = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$serveScript,
            '-Prefix',$prefix,'-Directory',$isoDir
        )
        Write-Info "Launching ISO server: $psExe $($serverArgs -join ' ')"
        $serverProcess = Start-Process -FilePath $psExe `
            -ArgumentList $serverArgs `
            -WorkingDirectory $isoDir `
            -PassThru

        Start-Sleep -Seconds 3
        if ($serverProcess.HasExited) {
            throw "ISO HTTP server exited unexpectedly with code $($serverProcess.ExitCode)."
        }
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($HttpHost, $HttpPort, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne(15000)) {
                throw "TCP probe timed out"
            }
            $tcp.EndConnect($async)
        }
        catch {
            throw "ISO server is not reachable at $HttpHost`:$HttpPort - $($_.Exception.Message)"
        }
        finally {
            $tcp.Close()
        }

        $request = [System.Net.HttpWebRequest]::Create($isoUrl)
        $request.Method = 'HEAD'
        $request.Timeout = 15000
        $response = $null
        try {
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 400) {
                throw "HTTP probe returned $([int]$response.StatusCode)"
            }
        }
        catch {
            throw "ISO HTTP probe failed at $isoUrl - $($_.Exception.Message)"
        }
        finally {
            if ($response) { $response.Close() }
        }
        Write-Ok "Serving $isoName for $($iDRACIPs.Count) concurrent iDRAC workers at $isoUrl"
    }

    Invoke-Step 'Start concurrent iDRAC OS workers' {
        $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $iDRACIPs.Count)
        $runspacePool.Open()

        foreach ($node in $iDRACIPs) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $runspacePool
            [void]$ps.AddScript({
                param($workerPath, $target, $user, $password, $url, $racadm, $start, $noCert)
                $workerArgs = @{
                    NodeIP        = $target
                    iDRACUser     = $user
                    iDRACPassword = $password
                    ISOUrl        = $url
                    RACADMPath    = $racadm
                }
                # Switch parameters must be omitted when false. Passing an explicit
                # $false value can produce confusing binding errors in Windows
                # PowerShell 5.1 when invoked through a runspace.
                if ($start)   { $workerArgs['StartInstallation'] = $true }
                if ($noCert)  { $workerArgs['NoCertWarn'] = $true }
                & $workerPath @workerArgs 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "deploy-os.ps1 failed for $target (exit code $LASTEXITCODE)"
                }
            }).AddArgument($worker).AddArgument($node).AddArgument($iDRACUser).AddArgument($iDRACPassword).AddArgument($isoUrl).AddArgument($RACADMPath).AddArgument([bool]$StartInstallation).AddArgument([bool]$NoCertWarn)

            $jobs += [pscustomobject]@{
                Node = $node
                PowerShell = $ps
                Handle = $ps.BeginInvoke()
            }
            Write-Info "Started worker for iDRAC $node"
        }

        while (@($jobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) {
            foreach ($job in @($jobs | Where-Object { $_.Handle.IsCompleted -and -not $_.PSObject.Properties['Collected'] })) {
                try {
                    $output = $job.PowerShell.EndInvoke($job.Handle)
                    foreach ($line in @($output)) { Write-Host $line }
                    $job | Add-Member -NotePropertyName Collected -NotePropertyValue $true
                    Write-Ok "Worker completed: $($job.Node)"
                }
                catch {
                    $workerErrors.Add("$($job.Node): $($_.Exception.Message)")
                    $job | Add-Member -NotePropertyName Collected -NotePropertyValue $true
                    Write-Err "Worker failed: $($job.Node) - $($_.Exception.Message)"
                }
            }
            if ((Get-Date) -gt $serverStartedAt.AddMinutes($ServerLifetimeMinutes)) {
                throw "Worker timeout exceeded $ServerLifetimeMinutes minute(s)."
            }
            Start-Sleep -Seconds 2
        }
        foreach ($job in $jobs) {
            if (-not $job.PSObject.Properties['Collected']) {
                try {
                    $output = $job.PowerShell.EndInvoke($job.Handle)
                    foreach ($line in @($output)) { Write-Host $line }
                }
                catch { $workerErrors.Add("$($job.Node): $($_.Exception.Message)") }
            }
        }
        if ($workerErrors.Count -gt 0) {
            throw "One or more OS workers failed: $($workerErrors -join ' | ')"
        }
    }

    Invoke-Step 'Keep ISO server alive for Windows Setup' {
        if (-not $StartInstallation) {
            Write-Warn 'StartInstallation was not supplied; workers mounted media only.'
            return
        }
        if ($NoWait) {
            Write-Warn 'NoWait supplied; stopping the server now may interrupt installation.'
            return
        }
        Write-Info "Keeping the single ISO server alive for up to $ServerLifetimeMinutes minute(s)."
        Write-Info 'Leave this window running until both nodes finish Windows Setup and return WinRM.'
        while ((Get-Date) -lt $serverStartedAt.AddMinutes($ServerLifetimeMinutes)) {
            if ($serverProcess.HasExited) { throw 'ISO server exited during Windows Setup.' }
            Start-Sleep -Seconds 30
        }
        Write-Warn 'Server lifetime reached. Confirm both nodes completed Setup before continuing.'
    }

    Complete-Ui -FinalMessage 'Parallel OS deployment launcher finished.'
}
catch {
    $caught = $_
    Write-Host ''
    Write-Host '===== FULL EXCEPTION =====' -ForegroundColor Red
    $caught | Format-List * -Force | Out-Host
    Write-Host ''
    Write-Host '===== POSITION =====' -ForegroundColor Red
    if ($caught.InvocationInfo) {
        $caught.InvocationInfo.PositionMessage | Out-Host
    }
    Write-Host ''
    Write-Host '===== SCRIPT STACK =====' -ForegroundColor Red
    if ($caught.ScriptStackTrace) {
        $caught.ScriptStackTrace | Out-Host
    }
    Write-Err $caught.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Parallel OS deployment launcher failed.'
    throw
}
finally {
    foreach ($job in @($jobs)) {
        try { $job.PowerShell.Dispose() } catch { }
    }
    if ($runspacePool) { try { $runspacePool.Close(); $runspacePool.Dispose() } catch { } }
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Info 'ISO HTTP server stopped.'
    }
}
