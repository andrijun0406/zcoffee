<#
.SYNOPSIS
    Stage 3 - Node PREPARATION and READINESS validation for the switchless 2-node Azure Local cluster.

.DESCRIPTION
    Runs AFTER Stage 2 (base networking green) and BEFORE Stage 4 (Arc registration). This is the
    "is each node truly deploy-ready" gate. Like Stage 2 it is validation-first over WinRM using an
    explicit local admin credential (AD-less / Local Identity), qualified as .\<user> so IP-based
    Negotiate/NTLM auth works.

    Read-only checks per node:
      - Time synchronization (w32time service + source) - clock skew breaks Arc/Azure auth
      - Required roles: Hyper-V, Failover-Clustering, Data-Center-Bridging
      - Security baseline: TPM 2.0 present/ready, Secure Boot state, BitLocker readiness
      - Dell SBE staged in C:\SBE (applied by cloud deploy / LCM in Stage 5)
      - Pending reboot state
      - Local administrator account present
      - Azure/Internet egress to the endpoints Arc + cloud deploy need (HTTPS 443)
      - Azure Local Environment Checker (AzStackHci.EnvironmentChecker) - the authoritative
        pre-deployment gate (connectivity + hardware + readiness). Read-only.

    Optional -Apply performs only SAFE, idempotent repairs:
      - Enable + start w32time and resync
      - Install a missing Windows feature (Hyper-V / Failover-Clustering / DCB)  [may require reboot]
      - Install the AzStackHci.EnvironmentChecker module if absent

.NOTES
    The SET switch, storage vNICs, RDMA/iWARP and VLANs are created by the Azure Local CLOUD
    DEPLOYMENT in Stage 5 - NOT here. AD-specific Environment Checker results do not apply to
    this Local Identity build and can be treated as informational.
#>
[CmdletBinding()]
param(
    [string[]]$NodeIPs,
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTPS','HTTP')]
    [string]$Transport = 'HTTPS',
    [int]$Port,
    [switch]$ConfigureTrustedHosts,
    [switch]$SkipCertCheck,
    [switch]$UseGui,

    # Safe, idempotent repairs only (time sync, missing features, checker module install).
    [switch]$Apply,
    # Run the Azure Local Environment Checker (read-only). On by default; -SkipEnvChecker to skip.
    [switch]$SkipEnvChecker,
    # Only run connectivity validation (fast pre-Arc gate), not full deployment readiness.
    [switch]$ConnectivityOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b   = $PSBoundParameters

# --- Resolve settings from config (parameters override) ---
$LocalAdminUser = Resolve-Setting -Name 'LocalAdminUser' -Bound $b -Current $LocalAdminUser -ConfigKey 'LocalAdminUser' -Config $cfg
if (-not $LocalAdminUser) { $LocalAdminUser = 'Administrator' }

if (-not $b.ContainsKey('NodeIPs')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeIPs = @($cfg.Nodes | ForEach-Object { $_.HostIP }) }
    else { $NodeIPs = @('10.8.230.232','10.8.230.235') }
}

if (-not $Port) { $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 } }

# Qualify a local account as .\user so IP-based WinRM (Negotiate/NTLM) authenticates.
$authUser = $LocalAdminUser
if ($authUser -notmatch '[\\@]') { $authUser = ".\$authUser" }

$dnsSuffix = if ($cfg.ContainsKey('DnsSuffix')) { $cfg.DnsSuffix } else { 'zcoffee.com' }
$nodeNameByIp = @{}
if ($cfg.ContainsKey('Nodes')) {
    foreach ($n in $cfg.Nodes) { if ($n.ContainsKey('HostIP')) { $nodeNameByIp[$n.HostIP] = $n.Name } }
}

# Azure endpoints Arc onboarding + cloud deploy need outbound HTTPS to.
$azureEndpoints = @(
    'login.microsoftonline.com',
    'management.azure.com',
    'gbl.his.arc.azure.com',
    'agentserviceapi.guestconfiguration.azure.com'
)

$totalSteps = 2 + ($NodeIPs.Count)   # creds + connectivity + validate per node
Initialize-Ui -StageName '03-prepare-node' -TotalSteps $totalSteps -UseGui:$UseGui

# Safe repairs that run ON each node when -Apply is set.
$remoteApply = {
    param($endpoints, $doEnvChecker)
    $out = [ordered]@{ Actions = @(); Warnings = @() }

    # Time sync
    try {
        Set-Service w32time -StartupType Automatic -ErrorAction Stop
        Start-Service w32time -ErrorAction SilentlyContinue
        w32tm /resync /force *> $null
        $out.Actions += 'w32time set Automatic, started, resynced'
    } catch { $out.Warnings += "w32time: $($_.Exception.Message)" }

    # Required features
    foreach ($f in @('Hyper-V','Failover-Clustering','Data-Center-Bridging')) {
        try {
            $fs = Get-WindowsFeature -Name $f -ErrorAction Stop
            if (-not $fs.Installed) {
                Install-WindowsFeature -Name $f -IncludeManagementTools -ErrorAction Stop | Out-Null
                $out.Actions += "Installed feature $f (reboot may be required)"
            }
        } catch { $out.Warnings += "feature ${f}: $($_.Exception.Message)" }
    }

    # Environment Checker module
    if ($doEnvChecker) {
        try {
            if (-not (Get-Module -ListAvailable -Name AzStackHci.EnvironmentChecker)) {
                Install-Module AzStackHci.EnvironmentChecker -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
                $out.Actions += 'Installed AzStackHci.EnvironmentChecker'
            }
        } catch { $out.Warnings += "env-checker install: $($_.Exception.Message)" }
    }

    [pscustomobject]$out
}

# Read-only readiness check that runs ON each node.
$remoteCheck = {
    param($endpoints, $doEnvChecker, $connectivityOnly)

    $r = [ordered]@{
        HostName        = $env:COMPUTERNAME
        TimeService     = $null
        TimeSource      = $null
        FeaturesMissing = @()
        Tpm             = $null
        SecureBoot      = $null
        BitLockerReady  = $null
        SbeStaged       = $false
        PendingReboot   = $false
        Egress          = @()
        EnvChecker      = $null
        EnvCheckerRan   = $false
    }

    # Time
    try {
        $svc = Get-Service w32time -ErrorAction Stop
        $r.TimeService = $svc.Status.ToString()
        $src = (w32tm /query /source) 2>$null
        $r.TimeSource = ($src | Select-Object -First 1)
    } catch { }

    # Features
    foreach ($f in @('Hyper-V','Failover-Clustering','Data-Center-Bridging')) {
        try { $fs = Get-WindowsFeature -Name $f -ErrorAction Stop; if (-not $fs.Installed) { $r.FeaturesMissing += $f } } catch { }
    }

    # TPM
    try {
        $t = Get-Tpm -ErrorAction Stop
        $r.Tpm = [pscustomobject]@{ Present = [bool]$t.TpmPresent; Ready = [bool]$t.TpmReady; Enabled = [bool]$t.TpmEnabled }
    } catch { }

    # Secure Boot
    try { $r.SecureBoot = [bool](Confirm-SecureBootUEFI) } catch { $r.SecureBoot = $null }

    # BitLocker feature readiness (not necessarily encrypted yet)
    try {
        $bl = Get-WindowsFeature -Name BitLocker -ErrorAction SilentlyContinue
        $r.BitLockerReady = if ($bl) { [bool]$bl.Installed } else { $null }
    } catch { }

    # Dell SBE staged
    try { $r.SbeStaged = (Test-Path 'C:\SBE') -and @(Get-ChildItem 'C:\SBE' -ErrorAction SilentlyContinue).Count -gt 0 } catch { }

    # Pending reboot
    try {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )
        foreach ($k in $keys) { if (Test-Path $k) { $r.PendingReboot = $true } }
        $pfr = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($pfr) { $r.PendingReboot = $true }
    } catch { }

    # Azure/Internet egress (HTTPS 443)
    foreach ($ep in $endpoints) {
        $ok = $false
        try { $ok = (Test-NetConnection -ComputerName $ep -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) } catch { }
        $r.Egress += [pscustomobject]@{ Endpoint = $ep; Reachable = [bool]$ok }
    }

    # Environment Checker (read-only)
    if ($doEnvChecker) {
        try {
            Import-Module AzStackHci.EnvironmentChecker -ErrorAction Stop
            $r.EnvCheckerRan = $true
            if ($connectivityOnly) {
                $res = Invoke-AzStackHciConnectivityValidation -PassThru -ErrorAction SilentlyContinue
            } else {
                $res = Invoke-AzStackHciConnectivityValidation -PassThru -ErrorAction SilentlyContinue
            }
            if ($res) {
                $r.EnvChecker = @($res | ForEach-Object {
                    [pscustomobject]@{ Name = $_.Name; Status = "$($_.Status)" }
                })
            }
        } catch {
            $r.EnvChecker = @([pscustomobject]@{ Name = 'ModuleLoad'; Status = "NotAvailable: $($_.Exception.Message)" })
        }
    }

    [pscustomobject]$r
}

try {
    Invoke-Step 'Resolve credentials and (optionally) set WinRM TrustedHosts' {
        if (-not $b.ContainsKey('LocalAdminPassword') -or $null -eq $script:LocalAdminPassword) {
            $script:LocalAdminPassword = Read-Host -Prompt "Enter the local admin password for '$script:authUser' on the nodes" -AsSecureString
        }
        $script:cred = [System.Management.Automation.PSCredential]::new($script:authUser, $script:LocalAdminPassword)
        Write-Info "Credential built for '$script:authUser' (value never logged)."
        Write-Info "Transport: $script:Transport on port $script:Port."

        if ($script:ConfigureTrustedHosts) {
            $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
            if ($current -eq '*') {
                Write-Ok "TrustedHosts already '*' (trust all) - leaving unchanged; nodes are covered."
            }
            else {
                $set = @()
                if ($current) { $set += ($current -split ',') }
                $set += $script:NodeIPs
                $final = ($set | Where-Object { $_ } | Select-Object -Unique) -join ','
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $final -Force
                Write-Ok "TrustedHosts set to: $final"
            }
        }
        else { Write-Info 'TrustedHosts not modified (pass -ConfigureTrustedHosts if needed).' }
    }

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
            catch { Write-Warn "WinRM NOT reachable on $ip via $script:Transport`:$script:Port - $($_.Exception.Message)" }
            $script:reachable[$ip] = $ok
        }
        if (-not ($script:reachable.Values | Where-Object { $_ })) {
            throw 'No node was reachable over WinRM. Fix connectivity and retry.'
        }
    }

    foreach ($ip in $NodeIPs) {
        Invoke-Step "Validate node readiness: $ip" {
            if (-not $script:reachable[$ip]) { Write-Warn "Skipping $ip (not reachable)."; return }

            $connArgs = @{ ComputerName = $ip; Credential = $script:cred; ErrorAction = 'Stop' }
            if ($script:Transport -eq 'HTTPS') {
                $connArgs['UseSSL'] = $true; $connArgs['Port'] = $script:Port
                $connArgs['SessionOption'] = (New-PSSessionOption -SkipCACheck:$script:SkipCertCheck -SkipCNCheck:$script:SkipCertCheck)
            } else { $connArgs['Port'] = $script:Port }

            # Optional safe repairs first
            if ($script:Apply) {
                Write-Info "Applying safe repairs on $ip (time sync, missing features, checker module)..."
                try {
                    $ar = Invoke-Command @connArgs -ScriptBlock $remoteApply -ArgumentList @($script:azureEndpoints, (-not $script:SkipEnvChecker))
                    foreach ($a in $ar.Actions)  { Write-Ok  $a }
                    foreach ($w in $ar.Warnings) { Write-Warn $w }
                } catch { Write-Warn "Apply on ${ip}: $($_.Exception.Message)" }
            }

            $res = Invoke-Command @connArgs -ScriptBlock $remoteCheck -ArgumentList @(
                $script:azureEndpoints, (-not $script:SkipEnvChecker), [bool]$script:ConnectivityOnly)

            $warn = 0; $fail = 0
            $expectName = if ($nodeNameByIp.ContainsKey($ip)) { $nodeNameByIp[$ip] } else { '' }

            if ($expectName -and ($res.HostName -ieq $expectName)) { Write-Ok "Hostname: $($res.HostName)" }
            elseif ($expectName) { Write-Warn "Hostname '$($res.HostName)' != config '$expectName'"; $warn++ }

            # Time
            if ($res.TimeService -eq 'Running') { Write-Ok "Time service running (source: $($res.TimeSource))" }
            else { Write-Warn "w32time status=$($res.TimeService) (enable with -Apply)"; $warn++ }

            # Features
            if ($res.FeaturesMissing.Count -eq 0) { Write-Ok 'Hyper-V, Failover-Clustering, DCB present' }
            else { Write-Warn "Features missing: $($res.FeaturesMissing -join ', ') (install with -Apply)"; $warn++ }

            # TPM
            if ($res.Tpm -and $res.Tpm.Present -and $res.Tpm.Ready) { Write-Ok 'TPM 2.0 present and ready' }
            else { Write-Warn "TPM not ready: $($res.Tpm | ConvertTo-Json -Compress)"; $warn++ }

            # Secure Boot
            if ($res.SecureBoot -eq $true) { Write-Ok 'Secure Boot enabled' }
            elseif ($res.SecureBoot -eq $false) { Write-Warn 'Secure Boot DISABLED - re-enable before Stage 5 (Azure Local requires it)'; $warn++ }
            else { Write-Warn 'Secure Boot state unknown'; $warn++ }

            # BitLocker readiness
            if ($res.BitLockerReady -eq $true) { Write-Ok 'BitLocker feature present' }
            else { Write-Info 'BitLocker feature not installed yet (cloud deploy enables per security profile)' }

            # SBE
            if ($res.SbeStaged) { Write-Ok 'Dell SBE staged in C:\SBE' }
            else { Write-Warn 'C:\SBE empty/absent - confirm the golden image staged the SBE (needed for Stage 5 LCM)'; $warn++ }

            # Pending reboot
            if ($res.PendingReboot) { Write-Warn 'Pending reboot detected - reboot before Stage 4/5'; $warn++ }
            else { Write-Ok 'No pending reboot' }

            # Egress
            $bad = @($res.Egress | Where-Object { -not $_.Reachable })
            if ($bad.Count -eq 0) { Write-Ok "Azure egress OK: $(@($res.Egress).Count) endpoints reachable on 443" }
            else { Write-Err "Azure egress FAILED: $($bad.Endpoint -join ', ') - Arc/deploy needs these (raise with DC/firewall)"; $fail++ }

            # Environment Checker
            if ($res.EnvCheckerRan -and $res.EnvChecker) {
                $failed = @($res.EnvChecker | Where-Object { $_.Status -match 'Fail|Error' })
                if ($failed.Count -eq 0) { Write-Ok "Environment Checker: all connectivity checks passed" }
                else {
                    Write-Warn "Environment Checker flagged: $((@($failed | ForEach-Object { $_.Name }) | Select-Object -Unique) -join ', ')"
                    $warn++
                }
            }
            elseif (-not $script:SkipEnvChecker) {
                Write-Warn 'Environment Checker not available on node (install with -Apply, or -SkipEnvChecker)'; $warn++
            }

            # Verdict
            if ($fail -gt 0)    { Write-Err  "$ip readiness: FAIL ($fail blocking, $warn warnings)" }
            elseif ($warn -gt 0){ Write-Warn "$ip readiness: PASS WITH WARNINGS ($warn)" }
            else                { Write-Ok   "$ip readiness: PASS" }
        }
    }

    Write-Info 'Stage 3 is validation-first. Run the Environment Checker green before Stage 4 (Arc) and Stage 5 (cloud deploy).'
    Complete-Ui -FinalMessage 'Node preparation / readiness validation finished.'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Node preparation / readiness validation failed.'
    throw
}
