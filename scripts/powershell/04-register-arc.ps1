﻿<#
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

.NOTES
    Arc-init failure is FATAL (throws), not a swallowed warning. Args are built from the cmdlet's
    ACTUAL parameters on the node so this survives installer version changes.
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
    # Explicit AccountID (object id of the signed-in identity). Recommended for CERT service
    # principals where directory-read to resolve the SP object id may be unavailable.
    [string]$AccountId,

    # Arc Gateway. In Register mode, an enabled gateway is created/reused idempotently.
    [switch]$UseArcGateway,
    [string]$ArcGatewayID,
    [string]$ArcGatewayName,
    [int]$ArcGatewayTimeoutMin = 120,
    [string]$TargetSolutionVersion,
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
$UseArcGateway     = [bool](Resolve-Setting -Name 'UseArcGateway' -Bound $b -Current ([bool]$UseArcGateway) -ConfigKey 'UseArcGateway' -Config $cfg)
$ArcGatewayName    = Resolve-Setting -Name 'ArcGatewayName' -Bound $b -Current $ArcGatewayName -ConfigKey 'ArcGatewayName' -Config $cfg
$ArcGatewayID      = Resolve-Setting -Name 'ArcGatewayID' -Bound $b -Current $ArcGatewayID -ConfigKey 'ArcGatewayID' -Config $cfg
$TargetSolutionVersion = Resolve-Setting -Name 'TargetSolutionVersion' -Bound $b -Current $TargetSolutionVersion -ConfigKey 'TargetSolutionVersion' -Config $cfg

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

$totalSteps = 6 + ($NodeIPs.Count)
Initialize-Ui -StageName '04-register-arc' -TotalSteps $totalSteps -UseGui:$UseGui

# Node-side Arc initialization (runs ON each node via WinRM).
$remoteArc = {
    param($subId, $rg, $tenant, $region, $cloud, $armToken, $accountId, $doRegister, $spAppId, $spSecret, $arcGatewayId, $targetSolutionVersion)

    $o = [ordered]@{
        Actions=@(); Warnings=@(); Errors=@(); AlreadyConnected=$false; ModulesOk=$false; Registered=$false
        GatewayId=$arcGatewayId; ArcStatus=$null; GatewayMode=$null; PartnerConfigured=$false
        PartnerSolutionVersion=$null; ReadyForAzureLocal=$false
    }
    $agentExe = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"

    try {
        if (Test-Path $agentExe) {
            $agentJson = (& $agentExe show -j 2>$null | Out-String) | ConvertFrom-Json
            $o.ArcStatus = [string]$agentJson.status
            if ($o.ArcStatus -eq 'Connected') {
                $o.AlreadyConnected = $true
                $o.Actions += 'azcmagent status is Connected'
            }
            $modeText = (& $agentExe config get connection.type 2>&1 | Out-String).Trim()
            $o.GatewayMode = $modeText
            if ($modeText) { $o.Actions += "Arc connection.type: $modeText" }

            $partnerText = (& $agentExe partnerconfig get SolutionVersion --partner AzureLocal 2>&1 | Out-String).Trim()
            if ($partnerText -match '(?m)^\s*\d+\.\d+\.\d+\s*$') {
                $o.PartnerConfigured = $true
                $o.PartnerSolutionVersion = (($partnerText -split '\r?\n' | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+\s*$' } | Select-Object -First 1).Trim())
                $o.Actions += "AzureLocal partner SolutionVersion: $($o.PartnerSolutionVersion)"
            } else {
                $o.Warnings += 'AzureLocal partner metadata is missing or unavailable.'
            }
        }
    } catch { $o.Warnings += 'Unable to read azcmagent JSON status.' }

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
            function Get-ArcInitializationCommand {
                Remove-Module AzsHci.ARCInstaller -Force -ErrorAction SilentlyContinue
                $available = @(Get-Module -ListAvailable -Name AzsHci.ARCInstaller |
                    Sort-Object Version -Descending)
                if ($available.Count -eq 0) {
                    throw 'AzsHci.ARCInstaller is not installed on this node.'
                }
                Import-Module $available[0].Path -Force -ErrorAction Stop
                Get-Command Invoke-AzStackHciArcInitialization -ErrorAction Stop
            }

            $cmd = Get-ArcInitializationCommand
            $valid = @($cmd.Parameters.Keys)

            # TargetSolutionVersion is optional in the Microsoft registration contract.
            # Older Dell/Azure Local installer modules may not expose it; do not fail
            # registration or attempt an unbounded PSGallery upgrade in that case.
            if ($targetSolutionVersion -and ($valid -notcontains 'TargetSolutionVersion')) {
                $o.Warnings += 'Installed AzsHci.ARCInstaller does not support TargetSolutionVersion; omitting it and validating partner metadata after registration.'
            }

            $arc = @{
                SubscriptionID = $subId
                ResourceGroup  = $rg
                TenantID       = $tenant
                Region         = $region
                Cloud          = $cloud
            }
            if ($arcGatewayId) {
                if ($valid -notcontains 'ArcGatewayID') { throw 'Installed AzsHci.ARCInstaller does not support ArcGatewayID.' }
                $arc['ArcGatewayID'] = $arcGatewayId
                $o.Actions += "Arc Gateway ID supplied: $arcGatewayId"
            }
            if ($targetSolutionVersion -and ($valid -contains 'TargetSolutionVersion')) {
                $arc['TargetSolutionVersion'] = $targetSolutionVersion
                $o.Actions += "Target solution version supplied: $targetSolutionVersion"
            } elseif ($targetSolutionVersion) {
                $o.Actions += 'Target solution version omitted because the installed initializer does not expose that parameter.'
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

            # Refresh all readiness signals after initialization. A pre-registration
            # probe is expected to show no AzureLocal partner; the post-init probe is
            # the authoritative result used by the Stage 5 gate.
            try {
                $agentJson = (& $agentExe show -j 2>$null | Out-String) | ConvertFrom-Json
                $o.ArcStatus = [string]$agentJson.status
                $o.GatewayMode = (& $agentExe config get connection.type 2>&1 | Out-String).Trim()
                $partnerText = (& $agentExe partnerconfig get SolutionVersion --partner AzureLocal 2>&1 | Out-String).Trim()
                if ($partnerText -match '(?m)^\s*\d+\.\d+\.\d+\s*$') {
                    $o.PartnerConfigured = $true
                    $o.PartnerSolutionVersion = (($partnerText -split '\r?\n' | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+\s*$' } | Select-Object -First 1).Trim())
                } else {
                    $o.Warnings = @($o.Warnings | Where-Object { $_ -ne 'AzureLocal partner metadata is missing or unavailable.' })
                }
            } catch { $o.Errors += "Post-registration readiness probe failed: $($_.Exception.Message)" }
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

        # AccountID resolution: explicit param > SP object-id lookup > signed-in user > context.
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

        # SpnCredential path only when an SP SECRET is available (not for cert SPs).
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

    Invoke-Step 'Create or reuse Arc Gateway' {
        $script:ArcGatewayID = $null
        if (-not $script:UseArcGateway) {
            Write-Info 'Arc Gateway disabled.'
            return
        }

        $gatewayType = 'Microsoft.HybridCompute/gateways'
        $statePath = Join-Path $PSScriptRoot 'config\arc-gateway.local.json'
        $canonicalGatewayId = if ($script:ArcGatewayName) {
            "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/$gatewayType/$($script:ArcGatewayName)"
        } else { $null }
        $state = $null
        if (Test-Path $statePath -PathType Leaf) {
            try { $state = Get-Content $statePath -Raw | ConvertFrom-Json } catch { Write-Warn "Ignoring unreadable Arc Gateway state: $statePath" }
        }

        $candidateId = $script:ArcGatewayID
        $stateIdProperty = if ($state) { $state.PSObject.Properties['resourceId'] } else { $null }
        if (-not $candidateId -and $stateIdProperty) { $candidateId = [string]$stateIdProperty.Value }
        $gateway = $null
        $gatewayId = $null

        if ($candidateId) {
            $gateway = Get-AzResource -ResourceId $candidateId -ErrorAction SilentlyContinue
            if ($gateway) {
                $typeProperty = $gateway.PSObject.Properties['ResourceType']
                $resourceType = if ($typeProperty) { [string]$typeProperty.Value } else { $gatewayType }
                if ($resourceType -ne $gatewayType) { throw "Resource is not an Arc Gateway: $candidateId" }
                $gatewayId = [string]$candidateId
                if ($gatewayId -notmatch "^/subscriptions/$([regex]::Escape($SubscriptionId))/") {
                    throw 'Arc Gateway must be in the Azure Local deployment subscription.'
                }
                Write-Ok "Reusing Arc Gateway from ID: $gatewayId"
            } else { Write-Warn "Configured/state Arc Gateway was not found: $candidateId" }
        }

        if (-not $gateway -and $script:ArcGatewayName) {
            $gateway = Get-AzResource -ResourceGroupName $ResourceGroupName `
                -ResourceType $gatewayType -Name $script:ArcGatewayName `
                -ErrorAction SilentlyContinue
            if ($gateway) {
                $gatewayId = $canonicalGatewayId
                Write-Ok "Reusing Arc Gateway by name: $gatewayId"
            }
        }

        if (-not $gateway -and -not $script:registerMode) {
            Write-Warn 'No Arc Gateway found. Validate mode is read-only; Register mode will create it.'
            return
        }
        if (-not $gateway -and -not $script:ArcGatewayName) {
            throw 'UseArcGateway is enabled but ArcGatewayName is empty and no valid ArcGatewayID/state was found.'
        }

        if (-not $gateway) {
            if (-not (Get-Command New-AzArcgateway -ErrorAction SilentlyContinue)) {
                try {
                    Install-Module Az.ArcGateway -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
                    Import-Module Az.ArcGateway -ErrorAction Stop
                } catch { throw "Az.ArcGateway/New-AzArcgateway is required to auto-create the gateway: $($_.Exception.Message)" }
            }
            if (-not (Get-Command New-AzArcgateway -ErrorAction SilentlyContinue)) {
                throw 'New-AzArcgateway is unavailable after installing Az.ArcGateway.'
            }

            Write-Info "Creating Arc Gateway $($script:ArcGatewayName) (Azure may take 10 minutes or longer)..."
            $creationReportedError = $false
            try {
                # Az.ArcGateway versions differ: some expose Subscription, others
                # SubscriptionId, and AllowedFeatures is optional in the installed module.
                $gatewayCommand = Get-Command New-AzArcgateway -ErrorAction Stop
                $gatewayParameters = @($gatewayCommand.Parameters.Keys)
                $createArgs = @{
                    Name              = $script:ArcGatewayName
                    ResourceGroupName = $ResourceGroupName
                    Location          = $Region
                    GatewayType       = 'Public'
                    ErrorAction       = 'Stop'
                }
                if ($gatewayParameters -contains 'Subscription') {
                    $createArgs['Subscription'] = $SubscriptionId
                } elseif ($gatewayParameters -contains 'SubscriptionId') {
                    $createArgs['SubscriptionId'] = $SubscriptionId
                } else {
                    throw 'New-AzArcGateway exposes neither Subscription nor SubscriptionId.'
                }
                if ($gatewayParameters -contains 'AllowedFeatures') {
                    $createArgs['AllowedFeatures'] = '*'
                    Write-Info 'Using cmdlet AllowedFeatures=*.'
                } else {
                    Write-Warn 'Installed New-AzArcGateway has no AllowedFeatures parameter; using module default.'
                }
                $null = New-AzArcgateway @createArgs
            } catch {
                # A service-side timeout can still leave the resource created. Re-query before failing.
                $creationReportedError = $true
                $gateway = Get-AzResource -ResourceGroupName $ResourceGroupName `
                    -ResourceType $gatewayType -Name $script:ArcGatewayName `
                    -ErrorAction SilentlyContinue
                if (-not $gateway) { throw "Arc Gateway creation failed and no resource was found: $($_.Exception.Message)" }
                Write-Warn "Arc Gateway creation reported an error, but the resource exists; waiting for its final state."
            }

            # New-AzArcGateway may return a response object without ResourceId/Id.
            # The ARM resource ID is deterministic from the validated scope and name.
            $gatewayId = $canonicalGatewayId
            if (-not $gatewayId) { throw 'Arc Gateway was created/found but no canonical resource ID could be formed.' }

            $deadline = (Get-Date).AddMinutes($script:ArcGatewayTimeoutMin)
            do {
                $current = Get-AzResource -ResourceGroupName $ResourceGroupName `
                    -ResourceType $gatewayType -Name $script:ArcGatewayName `
                    -ExpandProperties -ErrorAction SilentlyContinue
                if ($current) {
                    $gateway = $current
                    $stateProperty = $current.PSObject.Properties['ProvisioningState']
                    $stateNow = if ($stateProperty) { [string]$stateProperty.Value } else { $null }
                    $propertiesProperty = $current.PSObject.Properties['Properties']
                    $properties = if ($propertiesProperty) { $propertiesProperty.Value } else { $null }
                    if (-not $stateNow -and $properties) {
                        $nestedStateProperty = $properties.PSObject.Properties['provisioningState']
                        if ($nestedStateProperty) { $stateNow = [string]$nestedStateProperty.Value }
                    }
                    if ($stateNow -eq 'Succeeded') { break }
                    if ($stateNow -in @('Failed','Canceled','Cancelled')) { throw "Arc Gateway provisioning failed with state '$stateNow'." }
                }
                if ((Get-Date) -ge $deadline) { throw "Timed out waiting for Arc Gateway provisioning after $($script:ArcGatewayTimeoutMin) minutes." }
                Start-Sleep -Seconds 20
            } while ($true)
            Write-Ok "Arc Gateway ready: $gatewayId"
        }

        if (-not $gatewayId) { $gatewayId = $canonicalGatewayId }
        if (-not $gatewayId) { throw 'Arc Gateway was found but no resource ID was returned.' }
        $script:ArcGatewayID = $gatewayId
        $stateDir = Split-Path $statePath -Parent
        if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        [ordered]@{
            resourceId = $script:ArcGatewayID
            name = $script:ArcGatewayName
            resourceGroup = $ResourceGroupName
            subscriptionId = $SubscriptionId
            location = $Region
            updatedUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
        Write-Ok "Persisted Arc Gateway ID to $statePath"
    }

    Invoke-Step 'Resolve node credentials and WinRM connectivity' {
        if ($b.ContainsKey('LocalAdminPassword') -and $null -ne $script:LocalAdminPassword) {
            $script:cred = [System.Management.Automation.PSCredential]::new($script:authUser, $script:LocalAdminPassword)
        } else {
            # No password passed: use the DPAPI node-credential store (Stage 0 captured it once).
            $script:cred = Get-LabNodeCredential -User $script:authUser
        }

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
                $script:spAppIdForNode, $script:spSecretForNode, $script:ArcGatewayID, $script:TargetSolutionVersion)

            $r = @($r) | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties.Name -contains 'Actions' } | Select-Object -Last 1
            if (-not $r) { throw "No Arc result object returned from $ip (scriptblock output was unexpected)." }

            $partnerMatches = $true
            if ($script:TargetSolutionVersion) {
                $partnerMatches = $r.PartnerConfigured -and ($r.PartnerSolutionVersion -eq $script:TargetSolutionVersion)
            }
            $gatewayMatches = $true
            if ($script:UseArcGateway) {
                $gatewayMatches = ($r.GatewayMode -match '(?i)^gateway$')
            }
            $r.ReadyForAzureLocal = ($r.ArcStatus -eq 'Connected') -and $gatewayMatches -and $partnerMatches

            if ($script:registerMode -and $script:ArcGatewayID -and $r.AlreadyConnected) {
                # Use the Hybrid Compute settings REST endpoint. Some Az.ArcGateway
                # versions generate an invalid singular machine resource path.
                $machineName = if ($nodeNameByIp.ContainsKey($ip)) { $nodeNameByIp[$ip] } else { $ip }
                $escapedMachineName = [System.Uri]::EscapeDataString([string]$machineName)
                $associationPath = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.HybridCompute/machines/$escapedMachineName/providers/Microsoft.HybridCompute/settings/default?api-version=2024-07-31-preview"
                $associationPayload = @{ properties = @{ gatewayProperties = @{ gatewayResourceId = $script:ArcGatewayID } } } | ConvertTo-Json -Depth 6 -Compress
                $associationResponse = Invoke-AzRestMethod -Method PUT -Path $associationPath -Payload $associationPayload -ErrorAction Stop
                $associationStatus = 0
                if ($associationResponse.PSObject.Properties.Name -contains 'StatusCode') { $associationStatus = [int]$associationResponse.StatusCode }
                if ($associationStatus -and ($associationStatus -lt 200 -or $associationStatus -ge 300)) { throw "$ip Arc Gateway association returned HTTP $associationStatus." }
                Write-Ok "$ip existing Arc machine associated with gateway via REST"

                # Existing agents older than 1.51 need the local connection mode
                # explicitly set. This is idempotent on newer agent versions too.
                $gatewayMode = Invoke-Command @connArgs -ScriptBlock {
                    $agentPath = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
                    if (-not (Test-Path $agentPath)) { throw 'azcmagent.exe not found on node.' }
                    & $agentPath config set connection.type gateway 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "azcmagent config set connection.type gateway failed (exit $LASTEXITCODE)." }
                    $mode = (& $agentPath config get connection.type 2>$null | Out-String).Trim()
                    [pscustomobject]@{ Mode = $mode }
                }
                if (-not $gatewayMode -or $gatewayMode.Mode -notmatch '(?i)gateway') {
                    throw "$ip did not report connection.type=gateway after association."
                }
                Write-Ok "$ip local Arc agent is using gateway mode"
                $r.GatewayMode = $gatewayMode.Mode
                $r.ReadyForAzureLocal = ($r.ArcStatus -eq 'Connected') -and
                    ($r.GatewayMode -match '(?i)^gateway$') -and $partnerMatches
            }

            foreach ($a in $r.Actions)  { Write-Ok  $a }
            foreach ($w in $r.Warnings) { Write-Warn $w }
            foreach ($e in $r.Errors)   { Write-Err  $e; $script:arcFailures += "$ip : $e" }

            if (-not $script:registerMode) {
                if ($r.ModulesOk) { Write-Ok "$ip prerequisites OK (modules present)" }
                else { Write-Warn "$ip missing Arc modules (Register mode installs them)" }
                if ($script:TargetSolutionVersion -and -not $r.ReadyForAzureLocal) {
                    Write-Warn "$ip is not Azure Local ready: ArcStatus=$($r.ArcStatus); GatewayMode=$($r.GatewayMode); Partner=$($r.PartnerSolutionVersion)"
                }
            } else {
                if ($r.AlreadyConnected) { Write-Ok "$ip already Arc-connected (gateway association checked/updated)" }
                elseif ($r.Registered)   { Write-Ok "$ip Arc initialization succeeded" }
                elseif ($r.Errors.Count -eq 0) { Write-Warn "$ip did not register and reported no error (investigate)" }
                if (-not $r.ReadyForAzureLocal) {
                    $script:arcFailures += "$ip : composite Azure Local readiness failed (ArcStatus=$($r.ArcStatus); GatewayMode=$($r.GatewayMode); Partner=$($r.PartnerSolutionVersion); expected TargetSolutionVersion=$script:TargetSolutionVersion)"
                    Write-Err "$ip is not Azure Local ready; do not proceed to Stage 5."
                } else { Write-Ok "$ip Azure Local Arc prerequisites verified" }
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
                if ($m.Status -ne 'Connected') {
                    $script:arcFailures += "$name : Azure Arc status is $($m.Status), expected Connected"
                    Write-Err "$name : Azure Arc status is $($m.Status), expected Connected"
                } else {
                    Write-Ok "$name : $($m.Status) - $($m.Id)"
                }
            } catch {
                Write-Warn "$name not yet visible in Azure ($ResourceGroupName). It may still be onboarding/rebooting - re-check with Get-AzConnectedMachine."
            }
        }
        if ($script:arcFailures.Count -gt 0) {
            throw "Arc verification failed: $($script:arcFailures -join ' | ')"
        }
        Write-Info 'Collect the resource ids above into arcNodeResourceIds for the Stage 5 ARM parameters.'
    }

    Write-Info 'Arc registration prerequisite for Stage 5: every node must be Connected, use gateway mode when enabled, and expose the expected AzureLocal partner SolutionVersion.'
    Complete-Ui -FinalMessage "Arc stage finished ($Mode)."
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Arc stage failed.'
    throw
}
