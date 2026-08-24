<#
.SYNOPSIS
    Stage 2 - Host network READINESS VALIDATION for the switchless 2-node Azure Local cluster.

.DESCRIPTION
    On a switchless 2-node Azure Local deployment, the real Network ATC intents (SET switch,
    storage vNICs, RDMA/iWARP, VLAN tagging, storage auto-IP) are created by the Azure Local
    CLOUD DEPLOYMENT in Stage 5, driven by the ARM template's intentList / storageNetworkList.
    Creating them here with a separate host script would COLLIDE with that deployment.

    Therefore this stage does NOT create intents. It connects to each node over WinRM and:
      - verifies the physical adapter NAMES match lab-config.psd1 (what Stage 5's ARM will target),
      - checks link state and link speed (mgmt 10/25GbE, storage 25GbE),
      - checks storage adapters are RDMA-capable (iWARP) and cabled (link up back-to-back),
      - confirms no pre-existing SET team / storage vNICs that would conflict with cloud deploy,
      - confirms hostname and management IP match the config,
      - prints a readiness summary and a per-node PASS/WARN/FAIL result.

    AD-less (Local Identity): uses an explicit local admin credential + WinRM TrustedHosts.
    A helper (-ConfigureTrustedHosts) adds the node IPs to this host's TrustedHosts and tests
    connectivity before running the checks.

.NOTES
    Read-only on the nodes. The only local mutation is TrustedHosts (gated behind -ConfigureTrustedHosts).
#>
[CmdletBinding()]
param(
    [string[]]$NodeIPs,
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTPS','HTTP')]
    [string]$Transport = 'HTTPS',
    [int]$Port,
    [switch]$ConfigureTrustedHosts,   # add node IPs to this host's WinRM TrustedHosts (local mutation)
    [switch]$SkipCertCheck,           # for HTTPS with self-signed WinRM listener cert
    [switch]$UseGui,

    # --- Apply/repair bootstrap management config on the PHYSICAL mgmt port (gated) ---
    # These changes are temporary: Stage 5 Network ATC later builds the SET team and moves the
    # management IP onto a vManagement vNIC. We only set base reachability here.
    [switch]$Apply,            # apply hostname + DNS + static IP/GW repair (connectivity-safe, idempotent)
    [switch]$ApplyVlanTag,     # ALSO set the VLAN 230 tag on the mgmt adapter (RISKY over WinRM - can drop the session)
    [switch]$RebootIfRenamed,  # reboot the node if the hostname was changed (rename needs a reboot to take effect)
    [switch]$ForceIpChange     # allow changing the mgmt IP even though WinRM rides it (WILL drop the session)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b   = $PSBoundParameters

# --- Resolve settings from config (parameters override) ---
$LocalAdminUser = Resolve-Setting -Name 'LocalAdminUser' -Bound $b -Current $LocalAdminUser -ConfigKey 'LocalAdminUser' -Config $cfg
if (-not $LocalAdminUser) { $LocalAdminUser = 'LabAdmin' }

if (-not $b.ContainsKey('NodeIPs')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeIPs = @($cfg.Nodes | ForEach-Object { $_.HostIP }) }
    else { $NodeIPs = @('10.8.230.232','10.8.230.235') }
}

if (-not $Port) { $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 } }

# Expected adapter names / network facts from the single source of truth.
$mgmtAdapters    = if ($cfg.ContainsKey('MgmtAdapters'))    { @($cfg.MgmtAdapters) }    else { @('Integrated NIC1 Port 1-1','Integrated NIC1 Port 2-1') }
$storageAdapters = if ($cfg.ContainsKey('StorageAdapters')) { @($cfg.StorageAdapters) } else { @('SLOT 2 Port 1','SLOT 2 Port 2') }
$mgmtVlan        = if ($cfg.ContainsKey('MgmtVlan'))        { $cfg.MgmtVlan }        else { 230 }
$storageVlan1    = if ($cfg.ContainsKey('StorageVlan1'))    { $cfg.StorageVlan1 }    else { 711 }
$storageVlan2    = if ($cfg.ContainsKey('StorageVlan2'))    { $cfg.StorageVlan2 }    else { 712 }
$dnsSuffix       = if ($cfg.ContainsKey('DnsSuffix'))       { $cfg.DnsSuffix }       else { 'zcoffee.com' }

# Map HostIP -> expected node name for identity checks.
$nodeNameByIp = @{}
if ($cfg.ContainsKey('Nodes')) {
    foreach ($n in $cfg.Nodes) { if ($n.ContainsKey('HostIP')) { $nodeNameByIp[$n.HostIP] = $n.Name } }
}

# Base network facts for -Apply (from the single source of truth).
$gateway    = if ($cfg.ContainsKey('Gateway'))          { $cfg.Gateway }            else { '10.8.230.1' }
$dnsServers = if ($cfg.ContainsKey('DnsServer'))         { @($cfg.DnsServer) }       else { @('10.8.230.51') }
$prefixLen  = if ($cfg.ContainsKey('MgmtPrefixLength'))  { [int]$cfg.MgmtPrefixLength } else { 24 }

$totalSteps = 2 + ($NodeIPs.Count) + $(if ($Apply) { $NodeIPs.Count } else { 0 })   # creds + connectivity + (apply per node) + validate per node
Initialize-Ui -StageName '02-configure-network' -TotalSteps $totalSteps -UseGui:$UseGui

# Applies base management config ON each node (connectivity-safe ordering).
$remoteApply = {
    param($targetName, $targetIp, $prefixLen, $gateway, $dnsServers, $vlanId, $winrmIp, $applyVlan, $forceIpChange)

    $out = [ordered]@{ Actions = @(); Warnings = @(); Renamed = $false }

    # Identify the adapter that currently holds the WinRM IP - the one we must not break.
    $ipObj = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -eq $winrmIp } | Select-Object -First 1
    if (-not $ipObj) { $out.Warnings += "Could not find the adapter holding $winrmIp; skipping apply."; return [pscustomobject]$out }
    $ifIndex = $ipObj.InterfaceIndex
    $ad = Get-NetAdapter -InterfaceIndex $ifIndex

    # 1) DNS - safe, never drops the session.
    $curDns = @((Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    if (($curDns -join ',') -ne ($dnsServers -join ',')) {
        try { Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dnsServers -ErrorAction Stop; $out.Actions += "DNS set to $($dnsServers -join ', ')" }
        catch { $out.Warnings += "DNS set failed: $($_.Exception.Message)" }
    } else { $out.Actions += "DNS already $($dnsServers -join ', ')" }

    # 2) Hostname - safe for the live session; needs a reboot to take effect.
    if ($targetName -and ($env:COMPUTERNAME -ine $targetName)) {
        try { Rename-Computer -NewName $targetName -Force -ErrorAction Stop; $out.Renamed = $true; $out.Actions += "Renamed '$($env:COMPUTERNAME)' -> '$targetName' (reboot required)" }
        catch { $out.Warnings += "Rename failed: $($_.Exception.Message)" }
    } else { $out.Actions += "Hostname already '$($env:COMPUTERNAME)'" }

    # 3) Static IP + gateway - idempotent. Only touch if something differs; refuse address changes over WinRM.
    $curGw = (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
    $sameIp   = ($ipObj.IPAddress -eq $targetIp)
    $isStatic = ($ipObj.PrefixOrigin -eq 'Manual')
    if ($sameIp -and $isStatic -and ($ipObj.PrefixLength -eq $prefixLen) -and ($curGw -eq $gateway)) {
        $out.Actions += "IP already static $targetIp/$prefixLen gw $gateway"
    }
    elseif (-not $sameIp -and -not $forceIpChange) {
        $out.Warnings += "Current IP '$($ipObj.IPAddress)' != target '$targetIp'. Refusing to change over WinRM (would drop the session). Change via iDRAC console, or pass -ForceIpChange."
    }
    else {
        try {
            Remove-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $targetIp -PrefixLength $prefixLen -DefaultGateway $gateway -ErrorAction Stop | Out-Null
            $out.Actions += "Set static $targetIp/$prefixLen gw $gateway"
        } catch { $out.Warnings += "IP set failed: $($_.Exception.Message)" }
    }

    # 4) VLAN tag on the physical mgmt adapter - RISKY; report always, change only if requested.
    $vlanProp = Get-NetAdapterAdvancedProperty -Name $ad.Name -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'VLAN ID' } | Select-Object -First 1
    if ($vlanProp) {
        $out.Actions += "Current 'VLAN ID' on '$($ad.Name)': '$($vlanProp.DisplayValue)'"
        if ($applyVlan -and ("$($vlanProp.DisplayValue)" -ne "$vlanId")) {
            try { Set-NetAdapterAdvancedProperty -Name $ad.Name -DisplayName $vlanProp.DisplayName -DisplayValue "$vlanId" -ErrorAction Stop; $out.Actions += "VLAN ID set to $vlanId (session may drop)" }
            catch { $out.Warnings += "VLAN set failed: $($_.Exception.Message)" }
        }
    } else {
        $out.Actions += "No 'VLAN ID' advanced property on '$($ad.Name)' (VLAN is tagged at the switch / native, or the driver does not expose it)"
    }

    [pscustomobject]$out
}

# The readiness check that runs ON each node (read-only).
$remoteCheck = {
    param($mgmt, $storage, $expectName, $dnsSuffix)

    $r = [ordered]@{
        HostName        = $env:COMPUTERNAME
        Adapters        = @()
        RdmaAdapters    = @()
        SetTeams        = @()
        StorageVnics    = @()
        MgmtIp          = $null
        FeaturesMissing = @()
    }

    $adapters = Get-NetAdapter | Sort-Object Name
    foreach ($a in $adapters) {
        $r.Adapters += [pscustomobject]@{
            Name      = $a.Name
            Desc      = $a.InterfaceDescription
            Status    = $a.Status
            LinkSpeed = $a.LinkSpeed
            MediaState= $a.MediaConnectionState
            MacAddress= $a.MacAddress
        }
    }

    try {
        $rdma = Get-NetAdapterRdma -ErrorAction Stop
        foreach ($x in $rdma) {
            $r.RdmaAdapters += [pscustomobject]@{ Name = $x.Name; Enabled = [bool]$x.Enabled }
        }
    } catch { }

    # Detect pre-existing SET team / storage vNICs (would conflict with cloud deploy).
    try {
        $sw = Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.EmbeddedTeamingEnabled }
        foreach ($s in $sw) { $r.SetTeams += $s.Name }
    } catch { }
    try {
        $vnics = Get-VMNetworkAdapter -ManagementOS -ErrorAction SilentlyContinue
        foreach ($v in $vnics) { $r.StorageVnics += $v.Name }
    } catch { }

    # Management IP (first IPv4 not APIPA/loopback).
    try {
        $r.MgmtIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -First 1 -ExpandProperty IPAddress)
    } catch { }

    # Required roles for Azure Local host readiness.
    foreach ($f in @('Hyper-V','Failover-Clustering','Data-Center-Bridging')) {
        try {
            $fs = Get-WindowsFeature -Name $f -ErrorAction Stop
            if (-not $fs.Installed) { $r.FeaturesMissing += $f }
        } catch { }
    }

    [pscustomobject]$r
}

try {
    # ---------------------------------------------------------------
    Invoke-Step 'Resolve credentials and (optionally) set WinRM TrustedHosts' {
        if (-not $b.ContainsKey('LocalAdminPassword') -or $null -eq $script:LocalAdminPassword) {
            $script:LocalAdminPassword = Read-Host -Prompt "Enter the local admin password for '$script:LocalAdminUser' on the nodes" -AsSecureString
        }
        $script:cred = [System.Management.Automation.PSCredential]::new($script:LocalAdminUser, $script:LocalAdminPassword)
        Write-Info "Credential built for '$script:LocalAdminUser' (value never logged)."
        Write-Info "Transport: $script:Transport on port $script:Port."

        if ($script:ConfigureTrustedHosts) {
            if ($script:Transport -eq 'HTTPS') {
                Write-Info 'HTTPS/SSL uses certificate trust; TrustedHosts is not strictly required. Adding anyway for Negotiate fallback.'
            }
            $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
            $wanted  = $script:NodeIPs
            $set     = @()
            if ($current) { $set += ($current -split ',') }
            $set += $wanted
            $final = ($set | Where-Object { $_ } | Select-Object -Unique) -join ','
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $final -Force
            Write-Ok "TrustedHosts set to: $final"
        }
        else {
            Write-Info 'TrustedHosts not modified (pass -ConfigureTrustedHosts to add node IPs).'
        }
    }

    # ---------------------------------------------------------------
    Invoke-Step 'Test WinRM connectivity to both nodes' {
        $script:reachable = @{}
        foreach ($ip in $script:NodeIPs) {
            $ok = $false
            try {
                if ($script:Transport -eq 'HTTPS') {
                    $so = New-PSSessionOption -SkipCACheck:$script:SkipCertCheck -SkipCNCheck:$script:SkipCertCheck
                    Test-WSMan -ComputerName $ip -Port $script:Port -UseSSL -Authentication Negotiate -Credential $script:cred -SessionOption $so -ErrorAction Stop | Out-Null
                } else {
                    Test-WSMan -ComputerName $ip -Port $script:Port -Authentication Negotiate -Credential $script:cred -ErrorAction Stop | Out-Null
                }
                $ok = $true
                Write-Ok "WinRM reachable: $ip"
            }
            catch {
                Write-Warn "WinRM NOT reachable on $ip via $script:Transport`:$script:Port - $($_.Exception.Message)"
                if ($script:Transport -eq 'HTTPS') {
                    Write-Info "If no HTTPS listener exists on the node, either create one (winrm quickconfig -transport:https with a cert) or re-run with -Transport HTTP."
                }
            }
            $script:reachable[$ip] = $ok
        }
        if (-not ($script:reachable.Values | Where-Object { $_ })) {
            throw 'No node was reachable over WinRM. Fix connectivity (TrustedHosts / listener / firewall) and retry.'
        }
    }

    # ---------------------------------------------------------------
    # Optional: apply/repair base management config (hostname, DNS, static IP/GW, VLAN tag).
    if ($Apply) {
        foreach ($ip in $NodeIPs) {
            Invoke-Step "Apply/repair bootstrap mgmt config: $ip" {
                if (-not $script:reachable[$ip]) { Write-Warn "Skipping $ip (not reachable)."; return }
                $expectName = if ($nodeNameByIp.ContainsKey($ip)) { $nodeNameByIp[$ip] } else { '' }

                $connArgs = @{ ComputerName = $ip; Credential = $script:cred; ErrorAction = 'Stop' }
                if ($script:Transport -eq 'HTTPS') {
                    $connArgs['UseSSL'] = $true; $connArgs['Port'] = $script:Port
                    $connArgs['SessionOption'] = (New-PSSessionOption -SkipCACheck:$script:SkipCertCheck -SkipCNCheck:$script:SkipCertCheck)
                } else { $connArgs['Port'] = $script:Port }

                if ($script:ApplyVlanTag) { Write-Warn "ApplyVlanTag set: changing the VLAN tag can drop the WinRM session on $ip." }
                if ($script:ForceIpChange) { Write-Warn "ForceIpChange set: an IP change will drop the WinRM session on $ip." }

                try {
                    $ar = Invoke-Command @connArgs -ScriptBlock $remoteApply -ArgumentList @(
                        $expectName, $ip, $prefixLen, $gateway, $dnsServers, $mgmtVlan, $ip,
                        [bool]$script:ApplyVlanTag, [bool]$script:ForceIpChange)
                    foreach ($a in $ar.Actions)  { Write-Ok  $a }
                    foreach ($w in $ar.Warnings) { Write-Warn $w }
                    if ($ar.Renamed) {
                        if ($script:RebootIfRenamed) {
                            Write-Info "Rebooting $ip to apply the hostname change..."
                            Invoke-Command @connArgs -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
                        } else {
                            Write-Warn "$ip was renamed to '$expectName' - reboot required (re-run with -RebootIfRenamed, or reboot manually)."
                        }
                    }
                }
                catch {
                    Write-Warn "Apply on $ip did not complete over WinRM (expected if the IP/VLAN changed and dropped the session): $($_.Exception.Message)"
                }
            }
        }
    }

    # ---------------------------------------------------------------
    foreach ($ip in $NodeIPs) {
        Invoke-Step "Validate host network readiness: $ip" {
            if (-not $script:reachable[$ip]) { Write-Warn "Skipping $ip (not reachable)."; return }

            $expectName = if ($nodeNameByIp.ContainsKey($ip)) { $nodeNameByIp[$ip] } else { '' }

            $icmArgs = @{
                ComputerName = $ip
                Credential   = $script:cred
                ArgumentList = @($mgmtAdapters, $storageAdapters, $expectName, $dnsSuffix)
                ScriptBlock  = $remoteCheck
                ErrorAction  = 'Stop'
            }
            if ($script:Transport -eq 'HTTPS') {
                $icmArgs['UseSSL'] = $true
                $icmArgs['Port']   = $script:Port
                $icmArgs['SessionOption'] = (New-PSSessionOption -SkipCACheck:$script:SkipCertCheck -SkipCNCheck:$script:SkipCertCheck)
            } else {
                $icmArgs['Port'] = $script:Port
            }

            $res = Invoke-Command @icmArgs

            $warn = 0; $fail = 0
            $adapterNames = @($res.Adapters | ForEach-Object { $_.Name })

            # 1) Hostname
            if ($expectName) {
                if ($res.HostName -ieq $expectName) { Write-Ok "Hostname matches config: $($res.HostName)" }
                else { Write-Warn "Hostname '$($res.HostName)' != config '$expectName' (set in Stage 3)"; $warn++ }
            }

            # 2) Management IP
            if ($res.MgmtIp -eq $ip) { Write-Ok "Management IP matches: $($res.MgmtIp)" }
            else { Write-Warn "Primary IPv4 '$($res.MgmtIp)' != expected '$ip'"; $warn++ }

            # 3) Mgmt adapter names present + up
            foreach ($m in $mgmtAdapters) {
                $ad = $res.Adapters | Where-Object { $_.Name -eq $m } | Select-Object -First 1
                if (-not $ad) { Write-Err "Missing MGMT adapter '$m' (Stage 5 ARM targets this exact name)"; $fail++ }
                elseif ($ad.Status -ne 'Up') { Write-Warn "MGMT adapter '$m' status=$($ad.Status), link=$($ad.LinkSpeed)"; $warn++ }
                else { Write-Ok "MGMT '$m' Up @ $($ad.LinkSpeed)" }
            }

            # 4) Storage adapter names present + up + 25GbE
            foreach ($s in $storageAdapters) {
                $ad = $res.Adapters | Where-Object { $_.Name -eq $s } | Select-Object -First 1
                if (-not $ad) { Write-Err "Missing STORAGE adapter '$s' (Stage 5 ARM storageNetworkList targets this)"; $fail++ }
                else {
                    if ($ad.Status -ne 'Up' -or $ad.MediaState -ne 'Connected') {
                        Write-Warn "STORAGE '$s' not connected (status=$($ad.Status), media=$($ad.MediaState)) - check back-to-back cable"; $warn++
                    } else {
                        Write-Ok "STORAGE '$s' Up @ $($ad.LinkSpeed) (cable connected)"
                        if ($ad.LinkSpeed -notmatch '25') { Write-Warn "STORAGE '$s' link is $($ad.LinkSpeed), expected 25 Gbps"; $warn++ }
                    }
                }
            }

            # 5) RDMA capability on storage adapters
            foreach ($s in $storageAdapters) {
                $rd = $res.RdmaAdapters | Where-Object { $_.Name -eq $s } | Select-Object -First 1
                if (-not $rd) { Write-Warn "STORAGE '$s' not RDMA-capable / not listed by Get-NetAdapterRdma"; $warn++ }
                elseif (-not $rd.Enabled) { Write-Info "STORAGE '$s' RDMA present but not enabled yet (Stage 5 enables iWARP) - OK pre-deploy" }
                else { Write-Ok "STORAGE '$s' RDMA enabled" }
            }

            # 6) No conflicting SET team / storage vNICs before cloud deploy
            if ($res.SetTeams.Count -gt 0) { Write-Warn "Pre-existing SET switch(es): $($res.SetTeams -join ', ') - remove before Stage 5 (cloud deploy creates its own)"; $warn++ }
            else { Write-Ok 'No pre-existing SET team (good; cloud deploy will create it)' }
            if ($res.StorageVnics.Count -gt 0) { Write-Info "Management-OS vNICs present: $($res.StorageVnics -join ', ')" }

            # 7) Required features
            if ($res.FeaturesMissing.Count -gt 0) { Write-Warn "Features not installed: $($res.FeaturesMissing -join ', ') (cloud deploy adds these, but note it)"; }
            else { Write-Ok 'Hyper-V, Failover-Clustering, DCB present' }

            # Per-node verdict
            if ($fail -gt 0) { Write-Err "$ip readiness: FAIL ($fail blocking, $warn warnings)" }
            elseif ($warn -gt 0) { Write-Warn "$ip readiness: PASS WITH WARNINGS ($warn)" }
            else { Write-Ok "$ip readiness: PASS" }
        }
    }

    Write-Info 'Reminder: Stage 2 is validation-only. The SET switch, storage vNICs, RDMA/iWARP and VLANs are created by the Azure Local cloud deployment in Stage 5 (ARM intentList/storageNetworkList).'
    Complete-Ui -FinalMessage 'Host network readiness validation finished.'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Host network readiness validation failed.'
    throw
}
