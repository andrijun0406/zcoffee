<#
.SYNOPSIS
    Stage 4 - Register both nodes with Azure Arc (Arc-enabled servers) for Azure Local deployment.

.DESCRIPTION
    Runs AFTER Stage 3 and BEFORE Stage 5. Installs the Connected Machine agent on each node and
    projects it into Azure so the Stage 5 ARM template can target the arcNodeResourceIds.

    Auth model:
      - Jump host signs into Azure as a USER (interactive/device) or as the SERVICE PRINCIPAL
        (secret or certificate) via Connect-AzForStage.
      - Node onboarding uses one of:
          * -SpnCredential            (SP + SECRET only)
          * -ArmAccessToken+-AccountID (user token, or SP token for a CERT SP)
      - -GraphAccessToken is NOT used (removed from current AzsHci.ARCInstaller builds).

    Certificate SP note: a cert-based SP has no secret, so SpnCredential is unavailable and the
    node onboards with the SP's ARM token + the SP OBJECT ID as AccountID. Because resolving the
    SP object id from inside an SP context may require directory-read the SP lacks, pass -AccountId
    explicitly (Stage 0 prints it) to make this deterministic.

    Stale-state note: a node whose prior onboarding succeeded locally but whose Azure resource was
    later deleted will still report Connected via azcmagent. -ForceReregister clears that local
    state (azcmagent disconnect --force-local-only) before re-onboarding.

.NOTES
    Arc-init failure is FATAL (throws), not a swallowed warning. Args are built from the cmdlet's
    ACTUAL parameters on the node so this survives installer version changes. Status detection uses
    azcmagent JSON output (deterministic) rather than text/regex parsing.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Validate','Register')]
    [string]$Mode = 'Validate',

    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName,
    [string]$Region,
    [string]$Cloud = 'AzureCloud',

    [string[]]$NodeIPs,
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTPS','HTTP')]
    [string]$Transport = 'HTTP',
    [int]$Port,
    [switch]$ConfigureTrustedHosts,
    [switch]$SkipCertCheck,

    [switch]$Apply,
    [switch]$UseExistingAzLogin,
    [string]$ServicePrincipalId,
    [SecureString]$ServicePrincipalSecret,
    [string]$CertificateThumbprint,
    [switch]$UseManagedIdentity,
    # Explicit AccountID (object id of the signed-in identity). Recommended for CERT service
    # principals where directory-read to resolve the SP object id may be unavailable.
    [string]$AccountId,
    # Force re-onboarding even if the local agent reports Connected (clears stale local state from
    # a prior onboard whose Azure resource was later deleted).
    [switch]$ForceReregister,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b   = $PSBoundParameters

$SubscriptionId    = Resolve-Setting -Name 'SubscriptionId'    -Bound $b -Current $SubscriptionId    -ConfigKey 'SubscriptionId' -Config $cfg
$TenantId          = Resolve-Setting -Name 'TenantId'          -Bound $b -Current $TenantId          -ConfigKey 'TenantId'       -Config $cfg
$ResourceGroupName = Resolve-Setting -Name 'ResourceGroupName' -Bound $b -Current $ResourceGroupName -ConfigKey 'ResourceGroup'  -Config $cfg
if (-not $ResourceGroupName) { $ResourceGroupName = 'azljkt01rg' }
$Region            = Resolve-Setting -Name 'Region' -Bound $b -Current $Region -ConfigKey 'Region' -Config $cfg
if (-not $Region) { $Region = 'southeastasia' }
$LocalAdminUser    = Resolve-Setting -Name 'LocalAdminUser' -Bound $b -Current $LocalAdminUser -ConfigKey 'LocalAdminUser' -Config $cfg
if (-not $LocalAdminUser) { $LocalAdminUser = 'Administrator' }

if (-not $b.ContainsKey('NodeIPs')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeIPs = @($cfg.Nodes | ForEach-Object { $_.HostIP }) }
    else { $NodeIPs = @('10.8.230.232','10.8.230.235') }
}
$nodeNameByIp = @{}
if ($cfg.ContainsKey('Nodes')) {
    foreach ($n in $cfg.Nodes) { if ($n.ContainsKey('HostIP')) { $nodeNameByIp[$n.HostIP] = $n.Name } }
}

if (-not $Port) { $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 } }
$authUser = $LocalAdminUser
if ($authUser -notmatch '[\\@]') { $authUser = ".\$authUser" }

$requiredProviders = @(
    'Microsoft.HybridCompute',
    'Microsoft.GuestConfiguration',
    'Microsoft.HybridConnectivity',
    'Microsoft.AzureStackHCI',
    'Microsoft.Kubernetes',
    'Microsoft.KubernetesConfiguration',
    'Microsoft.ExtendedLocation',
    'Microsoft.ResourceConnector',
    'Microsoft.Attestation'
)

$registerMode = ($Mode -eq 'Register')
if ($registerMode -and -not $Apply) { throw 'Register mode requires -Apply (safety gate).' }

$totalSteps = 5 + ($NodeIPs.Count)
Initialize-Ui -StageName '04-register-arc' -TotalSteps $totalSteps -UseGui:$UseGui

$remoteArc = {
    param($subId, $rg, $tenant, $region, $cloud, $armToken, $accountId, $doRegister, $spAppId, $spSecret, $forceReregister)

    $o = [ordered]@{ Actions=@(); Warnings=@(); Errors=@(); AlreadyConnected=$false; ModulesOk=$false; Registered=$false }
    $agentExe = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"

    # Deterministic status via JSON (avoids fragile text/regex parsing of 'Disconnected').
    $localStatus = 'Unknown'
    try {
        if (Test-Path $agentExe) {
            $j = & $agentExe show -j 2>$null | Out-String
            if ($j) { try { $localStatus = [string](ConvertFrom-Json $j).status } catch { $localStatus = 'Unknown' } }
            if ($forceReregister -and $localStatus -ne 'Unknown') {
                & $agentExe disconnect --force-local-only 2>$null | Out-Null
                $o.Actions += "Force re-register: cleared local agent state (was $localStatus)"
                $localStatus = 'Disconnected'
            }
            if ($localStatus -eq 'Connected') { $o.AlreadyConnected = $true; $o.Actions += 'azcmagent status: Connected' }
            else { $o.Actions += "azcmagent status: $localStatus" }
        }
    } catch { }

    try {
        foreach ($m in @('Az.Accounts','Az.Resources','AzsHci.ARCInstaller')) {
            if (-not (Get-Module -ListAvailable -Name $m)) {
                if ($doRegister) {
                    try { Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch { }
                    Install-Module $m -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
                    $o.Actions += "Installed $m"
                } else {
                    $o.Warnings += "Module missing: $m (install with Register/-Apply)"
                }
            }
        }
        $o.ModulesOk = -not ($o.Warnings | Where-Object { $_ -match 'Module missing' })
    } catch { $o.Errors += "module install: $($_.Exception.Message)" }

    if ($doRegister -and -not $o.AlreadyConnected -and $o.Errors.Count -eq 0) {
        try {
            Import-Module AzsHci.ARCInstaller -ErrorAction Stop
            $cmd = Get-Command Invoke-AzStackHciArcInitialization -ErrorAction Stop
            $valid = $cmd.Parameters.Keys

            $arc = @{
                SubscriptionID = $subId
                ResourceGroup  = $rg
                TenantID       = $tenant
                Region         = $region
                Cloud          = $cloud
            }
            if ($spAppId -and $spSecret -and ($valid -contains 'SpnCredential')) {
                $spSec = ConvertTo-SecureString $spSecret -AsPlainText -Force
                $arc['SpnCredential'] = [System.Management.Automation.PSCredential]::new($spAppId, $spSec)
                $o.Actions += 'Arc auth: service principal (SpnCredential)'
            } else {
                $arc['ArmAccessToken'] = $armToken
                $arc['AccountID']      = $accountId
                $o.Actions += "Arc auth: ArmAccessToken + AccountID ($accountId)"
            }
            foreach ($k in @($arc.Keys)) { if ($valid -notcontains $k) { $arc.Remove($k) } }
            $o.Actions += "Arc init params: $((@($arc.Keys | Sort-Object)) -join ', ')"

            $null = Invoke-AzStackHciArcInitialization @arc -ErrorAction Stop *>&1
            $o.Registered = $true
            $o.Actions += 'Invoke-AzStackHciArcInitialization completed'
        } catch {
            $o.Errors += "Arc init FAILED: $($_.Exception.Message)"
        }
    }

    [pscustomobject]$o
}

try {
    Invoke-Step 'Sign in to Azure and select subscription' {
        if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
            throw 'Az.Accounts not found on this host. Install-Module Az.Accounts -Scope CurrentUser'
        }
        Import-Module Az.Accounts -ErrorAction Stop
        if (-not $SubscriptionId) { throw 'SubscriptionId is required.' }
        if (-not $TenantId)       { throw 'TenantId is required.' }

        $script:azctx = Connect-AzForStage -TenantId $TenantId -SubscriptionId $SubscriptionId `
            -ServicePrincipalId $script:ServicePrincipalId -ServicePrincipalSecret $script:ServicePrincipalSecret `
            -CertificateThumbprint $script:CertificateThumbprint -UseManagedIdentity:$script:UseManagedIdentity `
            -UseExistingAzLogin:$script:UseExistingAzLogin
        Write-Ok "Signed in as $($script:azctx.Account.Id); subscription $SubscriptionId; region $Region."
    }

    Invoke-Step 'Register and verify required resource providers' {
        Import-Module Az.Resources -ErrorAction SilentlyContinue
        $notReady = @()
        foreach ($p in $requiredProviders) {
            $rp = Get-AzResourceProvider -ProviderNamespace $p -ErrorAction SilentlyContinue | Select-Object -First 1
            $state = if ($rp) { $rp.RegistrationState } else { 'NotFound' }
            if ($state -ne 'Registered') {
                if ($script:registerMode) {
                    Register-AzResourceProvider -ProviderNamespace $p -ErrorAction SilentlyContinue | Out-Null
                    Write-Info "Registering $p ..."
                    $notReady += $p
                } else {
                    Write-Warn "$p = $state (will register in Register mode)"
                    $notReady += $p
                }
            } else { Write-Ok "$p registered" }
        }
        if ($script:registerMode -and $notReady.Count -gt 0) {
            Write-Info 'Waiting for provider registration to complete (up to 10 min)...'
            $deadline = (Get-Date).AddMinutes(10)
            do {
                Start-Sleep -Seconds 20
                $still = @()
                foreach ($p in $notReady) {
                    $rp = Get-AzResourceProvider -ProviderNamespace $p -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not $rp -or $rp.RegistrationState -ne 'Registered') { $still += $p }
                }
                $notReady = $still
            } while ($notReady.Count -gt 0 -and (Get-Date) -lt $deadline)
            if ($notReady.Count -gt 0) { Write-Warn "Still not registered: $($notReady -join ', ')" }
            else { Write-Ok 'All required providers registered' }
        }
    }

    Invoke-Step 'Ensure resource group and acquire access token' {
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            if ($script:registerMode) {
                New-AzResourceGroup -Name $ResourceGroupName -Location $Region -ErrorAction Stop | Out-Null
                Write-Ok "Created resource group $ResourceGroupName in $Region"
            } else { Write-Warn "Resource group $ResourceGroupName does not exist (created in Register mode)" }
        } else { Write-Ok "Resource group $ResourceGroupName exists ($($rg.Location))" }

        $tok = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop).Token
        if ($tok -is [System.Security.SecureString]) {
            $bt = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok)
            try { $tok = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bt) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bt) }
        }
        $script:armToken = $tok

        $acctId = $null
        if ($script:AccountId) {
            $acctId = $script:AccountId
            Write-Info 'Using explicit -AccountId (recommended for certificate SPs).'
        }
        if (-not $acctId -and $script:ServicePrincipalId) {
            try { $acctId = (Get-AzADServicePrincipal -ApplicationId $script:ServicePrincipalId -ErrorAction SilentlyContinue).Id } catch { }
        }
        if (-not $acctId) {
            try { $u = Get-AzADUser -SignedIn -ErrorAction SilentlyContinue; if ($u) { $acctId = $u.Id } } catch { }
        }
        if (-not $acctId) { $acctId = $script:azctx.Account.Id }
        $script:accountId = $acctId
        Write-Info "AccountID resolved to: $acctId"

        $script:spAppIdForNode = $null
        $script:spSecretForNode = $null
        if ($script:ServicePrincipalId -and $script:ServicePrincipalSecret) {
            $script:spAppIdForNode = $script:ServicePrincipalId
            $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:ServicePrincipalSecret)
            try { $script:spSecretForNode = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2) }
            Write-Info 'SP secret supplied - nodes will onboard via SpnCredential.'
        } elseif ($script:ServicePrincipalId) {
            Write-Info 'Certificate SP - nodes will onboard via SP ARM token + AccountID.'
        }
        Write-Ok 'ARM token + account id acquired (not logged).'
    }

    Invoke-Step 'Resolve node credentials and WinRM connectivity' {
        if (-not $b.ContainsKey('LocalAdminPassword') -or $null -eq $script:LocalAdminPassword) {
            $script:LocalAdminPassword = Read-Host -Prompt "Enter the local admin password for '$script:authUser' on the nodes" -AsSecureString
        }
        $script:cred = [System.Management.Automation.PSCredential]::new($script:authUser, $script:LocalAdminPassword)

        if ($script:ConfigureTrustedHosts) {
            $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
            if ($current -eq '*') { Write-Ok "TrustedHosts already '*'." }
            else {
                $set = @(); if ($current) { $set += ($current -split ',') }; $set += $script:NodeIPs
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value (($set | Where-Object { $_ } | Select-Object -Unique) -join ',') -Force
                Write-Ok 'TrustedHosts updated.'
            }
        }

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
                $ok = $true; Write-Ok "WinRM reachable: $ip"
            } catch { Write-Warn "WinRM NOT reachable on $ip - $($_.Exception.Message)" }
            $script:reachable[$ip] = $ok
        }
        if (-not ($script:reachable.Values | Where-Object { $_ })) { throw 'No node reachable over WinRM.' }
    }

    $script:arcFailures = @()
    foreach ($ip in $NodeIPs) {
        Invoke-Step "Arc $($Mode.ToLower()): $ip" {
            if (-not $script:reachable[$ip]) { Write-Warn "Skipping $ip (not reachable)."; return }

            $connArgs = @{ ComputerName = $ip; Credential = $script:cred; ErrorAction = 'Stop' }
            if ($script:Transport -eq 'HTTPS') {
                $connArgs['UseSSL'] = $true; $connArgs['Port'] = $script:Port
                $connArgs['SessionOption'] = (New-PSSessionOption -SkipCACheck:$script:SkipCertCheck -SkipCNCheck:$script:SkipCertCheck)
            } else { $connArgs['Port'] = $script:Port }

            $r = Invoke-Command @connArgs -ScriptBlock $remoteArc -ArgumentList @(
                $script:SubscriptionId, $script:ResourceGroupName, $script:TenantId, $script:Region, $script:Cloud,
                $script:armToken, $script:accountId, [bool]$script:registerMode,
                $script:spAppIdForNode, $script:spSecretForNode, [bool]$script:ForceReregister)

            $r = @($r) | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties.Name -contains 'Actions' } | Select-Object -Last 1
            if (-not $r) { throw "No Arc result object returned from $ip (scriptblock output was unexpected)." }

            foreach ($a in $r.Actions)  { Write-Ok  $a }
            foreach ($w in $r.Warnings) { Write-Warn $w }
            foreach ($e in $r.Errors)   { Write-Err  $e; $script:arcFailures += "$ip : $e" }

            if (-not $script:registerMode) {
                if ($r.ModulesOk) { Write-Ok "$ip prerequisites OK (modules present)" }
                else { Write-Warn "$ip missing Arc modules (Register mode installs them)" }
            } else {
                if ($r.AlreadyConnected) { Write-Ok "$ip already Arc-connected (skipped; use -ForceReregister to re-onboard)" }
                elseif ($r.Registered)   { Write-Ok "$ip Arc initialization succeeded" }
                elseif ($r.Errors.Count -eq 0) { Write-Warn "$ip did not register and reported no error (investigate)" }
            }
        }
    }

    if ($registerMode -and $script:arcFailures.Count -gt 0) {
        throw "Arc registration failed on: $($script:arcFailures -join ' | ')"
    }

    if ($registerMode) {
        Write-Info 'Verifying Arc-connected machines in Azure (may take a few minutes to appear)...'
        Import-Module Az.ConnectedMachine -ErrorAction SilentlyContinue
        foreach ($ip in $NodeIPs) {
            $name = if ($nodeNameByIp.ContainsKey($ip)) { $nodeNameByIp[$ip] } else { $ip }
            try {
                $m = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction Stop
                Write-Ok "$name : $($m.Status) - $($m.Id)"
            } catch {
                Write-Warn "$name not yet visible in Azure ($ResourceGroupName). It may still be onboarding/rebooting - re-check with Get-AzConnectedMachine."
            }
        }
        Write-Info 'Collect the resource ids above into arcNodeResourceIds for the Stage 5 ARM parameters.'
    }

    Write-Info 'Arc registration prerequisite for Stage 5: both nodes must show Status=Connected before cloud deployment.'
    Complete-Ui -FinalMessage "Arc stage finished ($Mode)."
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Arc stage failed.'
    throw
}
