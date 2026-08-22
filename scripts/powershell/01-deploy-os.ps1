[CmdletBinding()]
param(
    [string]$iDRACUser,
    [SecureString]$iDRACPassword,
    [string]$ISOFile,
    [string]$ExpectedISOHash,
    [ValidateRange(1,65535)]
    [int]$HttpPort,
    [string]$HttpHost,
    [string]$HttpBind = '0.0.0.0',
    [string]$RACADMPath = 'racadm',
    [switch]$StartInstallation,
    [switch]$NoCertWarn,
    [int]$ServerLifetimeMinutes = 240,
    [switch]$NoWait,
    [switch]$UseGui,
    [string[]]$iDRACIPs,
    # Supply when the ISO is already hosted at a DC-reachable URL (e.g. jump host / file server).
    # Bypasses the local Python HTTP server and the HttpHost check (needed on client VPNs like Sangfor).
    [string]$ISOUrl,
    # --- Hardware preparation (optional, runs before OS deploy) ---
    [switch]$FirmwareCheckOnly,   # non-destructive: report installed vs catalog firmware
    [switch]$UpdateFirmware,      # apply firmware from catalog (reboots nodes)
    [string]$CatalogUrl,          # HTTPS catalog host (default from config; e.g. downloads.dell.com or a DRM repo)
    [switch]$UpdateBios,          # apply a SINGLE BIOS DUP only (targeted; refreshes Secure Boot cert store)
    [string]$BiosDupFile,         # BIOS DUP file name for -UpdateBios
    [string]$BiosRepoUrl,         # HTTP/HTTPS repo path hosting the BIOS DUP
    [string]$BiosRepoProtocol = 'HTTPS',
    [switch]$UpdateIdrac,         # apply a SINGLE iDRAC DUP only (targeted; iDRAC self-reboots)
    [string]$IdracDupFile,        # iDRAC DUP file name for -UpdateIdrac
    [string]$IdracRepoUrl,        # HTTP/HTTPS repo path hosting the iDRAC DUP
    [string]$IdracRepoProtocol = 'HTTPS',
    [switch]$RecreateBossVd,      # DESTRUCTIVE: delete + recreate the BOSS RAID-1 boot VD
    [switch]$ForceHardwarePrep,   # skip the interactive destructive confirmation for BOSS
    [switch]$DisableSecureBoot,   # TEMP install workaround: set Secure Boot Disabled (BIOS job + reboot)
    [switch]$EnableSecureBoot,    # hardening: set Secure Boot Enabled (required for the cluster)
    # Target a single node by iDRAC IP, node name, or host IP (default: all nodes from config).
    [string]$OnlyNode,
    # --- Multi-node boot pacing (VPN-friendly) ---
    # By default, when installing more than one node the boot is SEQUENTIAL: each node is
    # booted and given time to finish streaming its boot image before the next node starts,
    # so two iDRACs don't saturate the VPN reading the ISO at the same time.
    [switch]$ParallelNodes,          # opt back into old behavior: boot all nodes at once
    [int]$NodeBootGapSeconds = 0     # 0 = prompt between nodes; >0 = wait this many seconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b = $PSBoundParameters
$iDRACUser = Resolve-Setting -Name 'iDRACUser' -Bound $b -Current $iDRACUser -ConfigKey 'iDRACUser' -Config $cfg
if (-not $iDRACUser) { $iDRACUser = 'root' }
$HttpPort  = Resolve-Setting -Name 'HttpPort'  -Bound $b -Current $HttpPort  -ConfigKey 'HttpPort'  -Config $cfg
if (-not $HttpPort) { $HttpPort = 8080 }
$CatalogUrl = Resolve-Setting -Name 'CatalogUrl' -Bound $b -Current $CatalogUrl -ConfigKey 'FirmwareCatalogUrl' -Config $cfg
if (-not $CatalogUrl) { $CatalogUrl = 'downloads.dell.com/Catalog' }
$doHwPrep = ($FirmwareCheckOnly -or $UpdateFirmware -or $UpdateBios -or $UpdateIdrac -or $RecreateBossVd -or $DisableSecureBoot -or $EnableSecureBoot)
# ISO is only needed when installing, or on a plain (non-hardware-prep) run used to test mounting.
# A hardware-prep-only run (e.g. -FirmwareCheckOnly) without -StartInstallation never touches the ISO.
$isoNeeded = ($StartInstallation -or (-not $doHwPrep))
if (-not $b.ContainsKey('iDRACIPs')) {
    if ($cfg.ContainsKey('Nodes')) { $iDRACIPs = @($cfg.Nodes | ForEach-Object { $_.iDRAC }) }
    else { $iDRACIPs = @('10.8.230.84','10.8.230.86') }
}

if ($OnlyNode) {
    $match = $null
    if ($cfg.ContainsKey('Nodes')) {
        $match = $cfg.Nodes | Where-Object {
            $_.iDRAC -eq $OnlyNode -or $_.Name -eq $OnlyNode -or
            ($_.ContainsKey('HostIP') -and $_.HostIP -eq $OnlyNode)
        } | Select-Object -First 1
    }
    if ($match) { $iDRACIPs = @($match.iDRAC) }
    elseif ($iDRACIPs -contains $OnlyNode) { $iDRACIPs = @($OnlyNode) }
    else { throw "-OnlyNode '$OnlyNode' did not match any node (by iDRAC IP, name, or host IP) in config." }
}

function Get-ManagementHostAddress {
    $address = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -like '10.8.230.*' -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*'
        } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $address) { throw 'Unable to determine a management IP on 10.8.230.0/24. Provide -HttpHost.' }
    return $address
}

$totalSteps = 3   # admin, preflight, credentials
if ($doHwPrep) { $totalSteps++ }
if ($isoNeeded) { $totalSteps += 3 }   # ISO server prep, start server, mount
Initialize-Ui -StageName '01-deploy-os' -TotalSteps $totalSteps -UseGui:$UseGui
$serverProcess = $null

try {
    Invoke-Step 'Verify Administrator privileges' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($id)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Administrator privileges are required.'
        }
    }

    Invoke-Step 'Resolve ISO, host address, and RACADM (preflight)' {
        $preflight = Join-Path $PSScriptRoot 'preflight-os.ps1'
        if (-not (Test-Path $preflight -PathType Leaf)) { throw "Missing preflight script: $preflight" }

        if ($script:isoNeeded) {
            if (-not $script:ISOFile) {
                $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
                $script:ISOFile = Join-Path $repoRoot `
                    'isos\AzureLocal24H2.26100.32230.LCM.12.2604.1.3008_DellSBE.5.0.2606.1510_15G-Intel_A01.en-us.iso'
                Write-Info "Using default ISO path: $script:ISOFile"
            }
            if (-not $script:ISOUrl -and -not $script:HttpHost) {
                $script:HttpHost = Get-ManagementHostAddress
                Write-Info "Auto-selected HTTP host: $script:HttpHost"
            }
        }

        Write-Info "iDRAC targets from config: $($script:iDRACIPs -join ', ')"
        if (-not $script:isoNeeded) {
            Write-Info 'Hardware-prep-only run; ISO checks are skipped.'
            & $preflight -SkipIso -RACADMPath $script:RACADMPath -iDRACIPs $script:iDRACIPs
        }
        elseif ($script:ISOUrl) {
            Write-Info "ISO provided via URL; local HTTP server will be skipped."
            & $preflight -ISOUrl $script:ISOUrl -RACADMPath $script:RACADMPath -iDRACIPs $script:iDRACIPs
        }
        else {
            & $preflight `
                -ISOFile $script:ISOFile `
                -ExpectedISOHash $script:ExpectedISOHash `
                -HttpHost $script:HttpHost `
                -HttpPort $script:HttpPort `
                -RACADMPath $script:RACADMPath `
                -iDRACIPs $script:iDRACIPs
        }
    }

    Invoke-Step 'Prompt for iDRAC credentials if needed' {
        if (-not $b.ContainsKey('iDRACPassword') -or $null -eq $script:iDRACPassword) {
            $script:iDRACPassword = Read-Host -Prompt "Enter the iDRAC password for '$script:iDRACUser'" -AsSecureString
        }
        Write-Info 'iDRAC credential is available (value is never logged).'
    }

    if ($doHwPrep) {
        Invoke-Step 'Prepare node hardware (firmware / BOSS boot VD)' {
            $hw = Join-Path $PSScriptRoot 'prepare-hardware.ps1'
            if (-not (Test-Path $hw -PathType Leaf)) { throw "Missing hardware-prep worker: $hw" }
            if ($script:RecreateBossVd) {
                Write-Warn 'BOSS recreation is DESTRUCTIVE: existing boot VD is deleted and rebuilt on each node. No prompt (the -RecreateBossVd flag is the confirmation).'
            }
            $nodeMeta = @{}
            if ($cfg.ContainsKey('Nodes')) {
                foreach ($n in $cfg.Nodes) { $nodeMeta[$n.iDRAC] = $n }
            }
            foreach ($node in $script:iDRACIPs) {
                $meta = $nodeMeta[$node]
                $nodeName = if ($meta) { $meta.Name } else { '' }
                $svcTag   = if ($meta -and $meta.ContainsKey('ServiceTag')) { $meta.ServiceTag } else { '' }
                Write-Info "Hardware prep on $node ($nodeName)"
                & $hw -NodeIP $node -iDRACUser $script:iDRACUser -iDRACPassword $script:iDRACPassword `
                    -RACADMPath $script:RACADMPath -NoCertWarn:$script:NoCertWarn `
                    -FirmwareCheckOnly:$script:FirmwareCheckOnly -UpdateFirmware:$script:UpdateFirmware `
                    -CatalogUrl $script:CatalogUrl `
                    -UpdateBios:$script:UpdateBios -BiosDupFile $script:BiosDupFile -BiosRepoUrl $script:BiosRepoUrl -BiosRepoProtocol $script:BiosRepoProtocol `
                    -UpdateIdrac:$script:UpdateIdrac -IdracDupFile $script:IdracDupFile -IdracRepoUrl $script:IdracRepoUrl -IdracRepoProtocol $script:IdracRepoProtocol `
                    -RecreateBossVd:$script:RecreateBossVd -Force:$script:ForceHardwarePrep `
                    -DisableSecureBoot:$script:DisableSecureBoot -EnableSecureBoot:$script:EnableSecureBoot `
                    -NodeName $nodeName -ServiceTag $svcTag
                Write-Ok "Hardware prep complete: $node"
            }
        }
    }

    if ($isoNeeded) {
    Invoke-Step 'Prepare native PowerShell ISO server (no Python needed)' {
        if ($script:ISOUrl) { Write-Info 'ISOUrl supplied; skipping local HTTP server.'; return }
        $script:serveScript = Join-Path $PSScriptRoot 'serve-iso.ps1'
        if (-not (Test-Path $script:serveScript -PathType Leaf)) {
            throw "Missing serve-iso.ps1: $script:serveScript"
        }
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $script:psExe = Join-Path $PSHOME 'pwsh.exe'
        } else {
            $script:psExe = Join-Path $PSHOME 'powershell.exe'
        }
        if (-not (Test-Path $script:psExe)) { $script:psExe = 'powershell.exe' }
        Write-Info "PowerShell host: $script:psExe"
    }

    Invoke-Step 'Start ISO HTTP server and confirm reachability' {
        if ($script:ISOUrl) {
            Write-Info "Using provided ISO URL: $script:ISOUrl"
            Write-Warn 'Confirm both iDRAC interfaces can reach this URL from inside the datacenter.'
            $script:isoUrlEffective = $script:ISOUrl
            return
        }
        $script:ISOFile = (Resolve-Path $script:ISOFile).Path
        $isoName = Split-Path $script:ISOFile -Leaf
        $isoDir = Split-Path $script:ISOFile -Parent
        if ($script:HttpHost -in @('127.0.0.1','localhost','0.0.0.0')) { throw 'HttpHost must be a reachable management IP that the iDRAC can reach.' }

        $prefixHost = if ($script:HttpBind -and $script:HttpBind -notin @('0.0.0.0','+','')) { $script:HttpBind } else { '+' }
        $prefix = "http://$prefixHost`:$script:HttpPort/"
        Write-Info "Serving '$isoDir' at $prefix (advertising http://$script:HttpHost`:$script:HttpPort)"

        $errFile = Join-Path $env:TEMP "isoserver-$PID.err"
        $outFile = Join-Path $env:TEMP "isoserver-$PID.out"
        $script:serverProcess = Start-Process -FilePath $script:psExe `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $script:serveScript, '-Prefix', $prefix, '-Directory', $isoDir) `
            -PassThru -WindowStyle Minimized `
            -RedirectStandardError $errFile -RedirectStandardOutput $outFile
        $serverProcess = $script:serverProcess
        Start-Sleep -Seconds 3
        if ($serverProcess.HasExited) {
            $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
            if ($err -match 'Access is denied|denied') {
                throw "ISO server could not register $prefix. Run PowerShell as Administrator, or reserve the URL once: netsh http add urlacl url=$prefix user=Everyone. Detail: $err"
            }
            throw "ISO HTTP server exited unexpectedly. Server error: $err"
        }

        $ProgressPreference = 'SilentlyContinue'
        if (-not (Test-NetConnection -ComputerName $script:HttpHost -Port $script:HttpPort `
            -InformationLevel Quiet -WarningAction SilentlyContinue)) {
            throw "ISO server not reachable at $script:HttpHost`:$script:HttpPort"
        }
        $encoded = [Uri]::EscapeDataString($isoName)
        $script:isoUrlEffective = "http://$script:HttpHost`:$script:HttpPort/$encoded"
        $null = Invoke-WebRequest -Uri $script:isoUrlEffective -Method Head -TimeoutSec 15 -UseBasicParsing
        Write-Ok "ISO URL live: $script:isoUrlEffective"
        Write-Warn 'Confirm both iDRAC interfaces can reach this URL on the chosen port.'
        Write-Info 'Single-RFS mount: the answer file is expected to be slipstreamed into the golden ISO (see make-golden-with-unattend.ps1). A second RFS image is NOT mounted, as it breaks golden-ISO boot on this firmware.'
    }

    Invoke-Step 'Mount ISO on each node via RACADM worker' {
        $worker = Join-Path $PSScriptRoot 'deploy-os.ps1'
        if (-not (Test-Path $worker -PathType Leaf)) { throw "Missing worker: $worker" }
        $nodeList = @($script:iDRACIPs)
        # Sequential by default when installing >1 node (VPN-friendly). -ParallelNodes opts out.
        $sequential = ($script:StartInstallation -and -not $script:ParallelNodes -and $nodeList.Count -gt 1)
        if ($sequential) {
            Write-Info "Sequential boot: one node streams the ISO at a time to avoid saturating the VPN."
        }
        for ($ni = 0; $ni -lt $nodeList.Count; $ni++) {
            $node = $nodeList[$ni]
            Write-Info "Node iDRAC: $node"
            & $worker -NodeIP $node -iDRACUser $script:iDRACUser -iDRACPassword $script:iDRACPassword `
                -ISOUrl $script:isoUrlEffective -RACADMPath $script:RACADMPath `
                -StartInstallation:$script:StartInstallation -NoCertWarn:$script:NoCertWarn
            Write-Ok "Node processed: $node"

            # Pace the next node so its boot-image read doesn't overlap this one over the VPN.
            if ($sequential -and ($ni -lt $nodeList.Count - 1)) {
                $next = $nodeList[$ni + 1]
                if ($script:NodeBootGapSeconds -gt 0) {
                    Write-Info "Waiting $($script:NodeBootGapSeconds)s for $node to finish its boot-image read before starting $next ..."
                    $left = [int]$script:NodeBootGapSeconds
                    while ($left -gt 0) {
                        if ($serverProcess.HasExited) { throw 'ISO server exited during sequential wait.' }
                        $chunk = [Math]::Min(30, $left)
                        Start-Sleep -Seconds $chunk
                        $left -= $chunk
                    }
                }
                else {
                    Write-Warn "Let $node reach Windows Setup (past the boot-image copy), then press Enter to boot $next."
                    [void](Read-Host 'Press Enter to continue to the next node')
                }
            }
        }
    }

    }  # end if ($isoNeeded) ISO server+mount

    if (-not $isoNeeded) {
        Write-Info 'Hardware-prep-only run complete; no ISO was mounted, nothing to detach.'
    }
    elseif ($script:ISOUrl) {
        Write-Info 'External ISO URL in use; no local server to keep alive.'
    }
    elseif ($StartInstallation -and -not $NoWait) {
        Write-Info "Installation started. Keeping ISO server alive up to $ServerLifetimeMinutes minutes."
        Write-Info 'Leave this window open until both nodes finish installing.'
        for ($m = 1; $m -le $ServerLifetimeMinutes; $m++) {
            if ($serverProcess.HasExited) { throw 'ISO server exited during installation.' }
            Start-Sleep -Seconds 60
            if (($m % 10) -eq 0) { Write-Info "ISO server elapsed: $m minute(s)" }
        }
    }
    elseif ($StartInstallation -and $NoWait) {
        Write-Warn 'NoWait selected; ISO server stops now. Nodes may fail to read the image mid-install.'
    }
    else {
        Write-Info 'ISO mounted but installation not started. Detaching remote media so re-runs stay clean.'
        $worker = Join-Path $PSScriptRoot 'deploy-os.ps1'
        foreach ($node in $script:iDRACIPs) {
            try {
                & $worker -NodeIP $node -iDRACUser $script:iDRACUser -iDRACPassword $script:iDRACPassword `
                    -RACADMPath $script:RACADMPath -NoCertWarn:$script:NoCertWarn -DetachOnly
                Write-Ok "Remote media detached: $node"
            }
            catch {
                Write-Warn "Could not detach remote media on $node : $($_.Exception.Message)"
            }
        }
        Write-Info 'Re-run with -StartInstallation to set one-time VCD-DVD boot and power-cycle the nodes.'
    }

    Complete-Ui -FinalMessage 'OS deployment stage finished.'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'OS deployment stage failed.'
    throw
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Info 'Temporary ISO server stopped.'
    }
}
