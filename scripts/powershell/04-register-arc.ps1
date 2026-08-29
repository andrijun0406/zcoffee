<#
.SYNOPSIS
    Stage 4 - Register both nodes with Azure Arc (Arc-enabled servers) for Azure Local deployment.

.DESCRIPTION
    Runs AFTER Stage 3 (node readiness green, Secure Boot re-enabled, no pending reboot) and BEFORE
    Stage 5 (cloud deployment). Arc registration installs the Connected Machine agent on each node
    and projects it into Azure so the Stage 5 ARM template can target the arcNodeResourceIds.

    Flow (matches Microsoft/Dell "Register machines with Azure Arc" for Azure Local):
      1. Jump host: confirm Az modules, sign in to Azure (device auth), select the subscription.
      2. Register + verify the required resource providers on the subscription.
      3. Obtain ARM + Graph access tokens and the signed-in account id (passed to each node).
      4. Per node over WinRM: ensure AzsHci.ARCInstaller + Az modules, then run
         Invoke-AzStackHciArcInitialization with the passed tokens (no interactive auth on the node).
      5. Verify each node shows as a Connected Arc machine and print its resource id
         (the value Stage 5 needs for arcNodeResourceIds).

    Validate mode (default): steps 1-3 + per-node module/prereq checks (read-only, no registration).
    Register mode (-Apply):  also performs steps 4-5.

    AD-less (Local Identity): node access uses an explicit .\Administrator credential over WinRM,
    same pattern as Stages 2/3. Azure sign-in is interactive device code by default.

.NOTES
    Secrets (subscription, tenant) are NOT stored in the repo - pass them as parameters or fill the
    private lab-config. Arc registration reboots the node when the agent update phase completes;
    re-run in Register mode is idempotent (already-connected nodes are detected and skipped).
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

    # Node access (WinRM), same as Stages 2/3.
    [string[]]$NodeIPs,
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTPS','HTTP')]
    [string]$Transport = 'HTTP',
    [int]$Port,
    [switch]$ConfigureTrustedHosts,
    [switch]$SkipCertCheck,

    # Perform the actual registration (Register mode requires this).
    [switch]$Apply,
    # Use an existing Az context on the jump host instead of interactive device sign-in.
    [switch]$UseExistingAzLogin,
    # Unattended service-principal / managed-identity auth (zero-touch).
    [string]$ServicePrincipalId,
    [SecureString]$ServicePrincipalSecret,
    [string]$CertificateThumbprint,
    [switch]$UseManagedIdentity,
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

# Resource providers required for Azure Local + Arc.
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

# steps: azure-signin + providers + tokens + creds + winrm + (per node)
$totalSteps = 5 + ($NodeIPs.Count)
Initialize-Ui -StageName '04-register-arc' -TotalSteps $totalSteps -UseGui:$UseGui

# Node-side Arc initialization (runs ON each node via WinRM; no interactive auth).
$remoteArc = {
    param($subId, $rg, $tenant, $region, $cloud, $armToken, $graphToken, $accountId, $doRegister)

    $o = [ordered]@{ Actions=@(); Warnings=@(); AlreadyConnected=$false; ModulesOk=$false }

    # Detect existing Arc connection (idempotent re-runs).
    try {
        $svc = Get-Service himds -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $agent = & "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show 2>$null
            if ($agent -match 'Connected') { $o.AlreadyConnected = $true; $o.Actions += 'azcmagent already Connected' }
        }
    } catch { }

    # Ensure required modules present.
    try {
        foreach ($m in @('Az.Accounts','Az.Resources','AzsHci.ARCInstaller')) {
            if (-not (Get-Module -ListAvailable -Name $m)) {
                if ($doRegister) {
                    Install-Module $m -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
                    $o.Actions += "Installed $m"
                } else {
                    $o.Warnings += "Module missing: $m (install with Register/-Apply)"
                }
            }
        }
        $o.ModulesOk = -not ($o.Warnings | Where-Object { $_ -match 'Module missing' })
    } catch { $o.Warnings += "module install: $($_.Exception.Message)" }

    if ($doRegister -and -not $o.AlreadyConnected) {
        try {
            Invoke-AzStackHciArcInitialization `
                -SubscriptionID $subId `
                -ResourceGroup $rg `
                -TenantID $tenant `
                -Region $region `
                -Cloud $cloud `
                -ArmAccessToken $armToken `
                -GraphAccessToken $graphToken `
                -AccountID $accountId -ErrorAction Stop
            $o.Actions += 'Invoke-AzStackHciArcInitialization completed'
        } catch {
            $o.Warnings += "Arc init: $($_.Exception.Message)"
        }
    }

    [pscustomobject]$o
}

try {
    # 1. Azure sign-in on the jump host
    Invoke-Step 'Sign in to Azure and select subscription' {
        if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
            throw 'Az.Accounts not found on this host. Install-Module Az.Accounts -Scope CurrentUser'
        }
        Import-Module Az.Accounts -ErrorAction Stop
        if (-not $SubscriptionId) { throw 'SubscriptionId is required (pass -SubscriptionId or fill lab-config/private runbook).' }
        if (-not $TenantId)       { throw 'TenantId is required (pass -TenantId).' }

        $script:azctx = Connect-AzForStage -TenantId $TenantId -SubscriptionId $SubscriptionId `
            -ServicePrincipalId $script:ServicePrincipalId -ServicePrincipalSecret $script:ServicePrincipalSecret `
            -CertificateThumbprint $script:CertificateThumbprint -UseManagedIdentity:$script:UseManagedIdentity `
            -UseExistingAzLogin:$script:UseExistingAzLogin
        Write-Ok "Signed in as $($script:azctx.Account.Id); subscription $SubscriptionId; region $Region."
    }

    # 2. Resource providers
    Invoke-Step 'Register and verify required resource providers' {
        Import-Module Az.Resources -ErrorAction SilentlyContinue
        $notReady = @()
        foreach ($p in $requiredProviders) {
            $rp = Get-AzResourceProvider -ProviderNamespace $p -ErrorAction SilentlyContinue |
                  Select-Object -First 1
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

    # 3. Ensure resource group + acquire tokens
    Invoke-Step 'Ensure resource group and acquire access tokens' {
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            if ($script:registerMode) {
                New-AzResourceGroup -Name $ResourceGroupName -Location $Region -ErrorAction Stop | Out-Null
                Write-Ok "Created resource group $ResourceGroupName in $Region"
            } else { Write-Warn "Resource group $ResourceGroupName does not exist (created in Register mode)" }
        } else { Write-Ok "Resource group $ResourceGroupName exists ($($rg.Location))" }

        $script:armToken   = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop).Token
        $script:graphToken = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -ErrorAction Stop).Token
        $script:accountId  = $script:azctx.Account.Id
        Write-Ok 'ARM + Graph tokens acquired (not logged).'
    }

    # 4. Node credentials + WinRM
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

    # 5. Per-node Arc registration / validation
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
                $script:armToken, $script:graphToken, $script:accountId, [bool]$script:registerMode)

            foreach ($a in $r.Actions)  { Write-Ok  $a }
            foreach ($w in $r.Warnings) { Write-Warn $w }

            if (-not $script:registerMode) {
                if ($r.ModulesOk) { Write-Ok "$ip prerequisites OK (modules present)" }
                else { Write-Warn "$ip missing Arc modules (Register mode installs them)" }
            }
        }
    }

    # 6. Post-registration verification (Register mode)
    if ($registerMode) {
        Write-Info 'Verifying Arc-connected machines in Azure...'
        Import-Module Az.ConnectedMachine -ErrorAction SilentlyContinue
        foreach ($ip in $NodeIPs) {
            $name = if ($nodeNameByIp.ContainsKey($ip)) { $nodeNameByIp[$ip] } else { $ip }
            try {
                $m = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction Stop
                Write-Ok "$name : $($m.Status) - $($m.Id)"
            } catch {
                Write-Warn "$name not yet visible in Azure ($ResourceGroupName). It may still be onboarding/rebooting."
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
