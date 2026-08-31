<#
.SYNOPSIS
    Zero-touch orchestrator for the zcoffee Azure Local build. Chains Stage 0 -> 6 with one
    up-front credential, inter-stage reboot synchronization, safety gates, and unattended
    service-principal auth for the Azure stages.

.DESCRIPTION
    Preserves the existing framework: this does NOT reimplement any stage. It calls the proven
    stage scripts via bootstrap-cluster.ps1 in sequence, and adds the glue that makes an
    end-to-end run possible:

      * Stage 0 auto-bootstrap: if no SP credential file is found, it runs
        00-create-service-principal.ps1 (interactive, MFA-capable) once, then continues
        unattended with the created SP.
      * Wait-NodeReady: after every reboot-causing stage (OS install, Arc onboarding) it polls
        WinRM on each node until reachable (or times out) before advancing.
      * Gates: a stage must succeed before the next runs; Arc requires both nodes Connected;
        the two irreversible actions (Arc Register, Stage 5 Deploy) require confirmation unless
        -AutoApprove is set.
      * -DryRun runs Stages 4 and 5 in validate-only mode (no onboarding, no resources created).

    Auth precedence for the Azure stages is handled by Connect-AzForStage in ui-common.ps1:
      SP secret -> SP certificate -> managed identity -> existing login -> device code.
    This orchestrator loads the SP identity from the Stage 0 credential file and passes it in.

.NOTES
    Never commit config\sp-credentials.local.json. The secret is DPAPI-protected (same-user/
    same-machine) unless Stage 0 was run with -PlainSecretFile or -UseCertificate.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$Region = 'southeastasia',
    [switch]$UseArcGateway,
    [string]$ArcGatewayID,
    [string]$ArcGatewayName,
    [int]$ArcGatewayTimeoutMin = 120,

    # Which stages to run (numbers). Default is the full node->cluster path. Stage 0 (SP) runs
    # automatically only if credentials are missing; it is not part of this list.
    [int[]]$Stages = @(1,2,3,4,5,6),

    # Node OS deploy (Stage 1) reimages the nodes - destructive. Off by default so a normal
    # orchestration run does not wipe installed nodes. Include 1 in -Stages AND pass this to run it.
    [switch]$IncludeOsDeploy,

    # SP credential file written by Stage 0.
    [string]$SpCredentialFile = (Join-Path $PSScriptRoot 'config\sp-credentials.local.json'),
    # Auto-run Stage 0 to create the SP if the credential file is absent.
    [switch]$AutoCreateSp = $true,

    # Node connectivity.
    [string[]]$NodeIPs,
    [string]$LocalAdminUser = 'Administrator',
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTP','HTTPS')]
    [string]$Transport = 'HTTP',

    # Stage 1 inputs (only used when -IncludeOsDeploy).
    [string]$HttpHost,
    [string]$ISOFile,
    [string]$RACADMPath = 'racadm',
    [SecureString]$iDRACPassword,

    # Stage 5 inputs.
    [string]$TemplateFile,
    [string]$ParameterFile,

    # Validate-only for Stages 4 and 5 (no onboarding, no deployment).
    [switch]$DryRun,
    # Skip the confirmation prompts at the two irreversible points.
    [switch]$AutoApprove,

    # Wait-NodeReady tuning.
    [int]$NodeReadyTimeoutMin = 30,
    [int]$NodeReadyPollSec = 20,

    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')


function Show-ZcoffeeBanner {
    $banner = @(
        ''
        ' ( ('
        ' ) ) Z C O F F E E'
        ' ........ -------------------------------------------'
        ' | |] Zero-touCh Orchestration For Fabric & Edge'
        ' \ / From Bare Metal to Azure Local'
        ' `----'' Brewing clusters, zero touch.'
        ''
    )

    foreach ($line in $banner) {
        Write-Host $line -ForegroundColor Cyan
    }
}

Show-ZcoffeeBanner

$cfg = Import-LabConfig
$b   = $PSBoundParameters

# --- Resolve settings from the single source of truth (parameters override) ---
if (-not $SubscriptionId -and $cfg.ContainsKey('SubscriptionId')) { $SubscriptionId = $cfg.SubscriptionId }
if (-not $TenantId       -and $cfg.ContainsKey('TenantId'))       { $TenantId       = $cfg.TenantId }
if (-not $b.ContainsKey('UseArcGateway') -and $cfg.ContainsKey('UseArcGateway')) { $UseArcGateway = [bool]$cfg.UseArcGateway }
if (-not $ArcGatewayID -and $cfg.ContainsKey('ArcGatewayID')) { $ArcGatewayID = [string]$cfg.ArcGatewayID }
if (-not $ArcGatewayName -and $cfg.ContainsKey('ArcGatewayName')) { $ArcGatewayName = [string]$cfg.ArcGatewayName }
if (-not $b.ContainsKey('NodeIPs')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeIPs = @($cfg.Nodes | ForEach-Object { $_.HostIP }) }
    else { $NodeIPs = @('10.8.230.232','10.8.230.235') }
}
$winrmPort = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 }
$dispatcher = Join-Path $PSScriptRoot 'bootstrap-cluster.ps1'
if (-not (Test-Path $dispatcher)) { throw "Dispatcher not found: $dispatcher" }
$arcGatewayStateFile = Join-Path $PSScriptRoot 'config\arc-gateway.local.json'

$stageName = @{
    1 = '01-deploy-os'; 2 = '02-configure-network'; 3 = '03-prepare-node'
    4 = '04-register-arc'; 5 = '05-deploy-azure-local'; 6 = '06-validate-cluster'
}

# ------------------------------------------------------------------ helpers ---
function Wait-NodeReady {
    param([string[]]$Ips, [int]$TimeoutMin, [int]$PollSec, [int]$Port)
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $pending  = [System.Collections.ArrayList]::new($Ips)
    Write-Info "Waiting for WinRM on: $($Ips -join ', ') (timeout ${TimeoutMin}m)"
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        foreach ($ip in @($pending)) {
            $ok = $false
            try { $ok = Test-NetConnection -ComputerName $ip -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue } catch { }
            if ($ok) { Write-Ok "Node reachable: ${ip}:$Port"; [void]$pending.Remove($ip) }
        }
        if ($pending.Count -gt 0) { Start-Sleep -Seconds $PollSec }
    }
    if ($pending.Count -gt 0) { throw "Timed out waiting for: $($pending -join ', ')" }
}

function Confirm-Gate {
    param([string]$Action)
    if ($AutoApprove) { Write-Warn "AutoApprove: proceeding with '$Action' without prompting."; return $true }
    $ans = Read-Host "CONFIRM irreversible action '$Action' - type YES to proceed"
    return ($ans -ceq 'YES')
}

function Invoke-Stage {
    param([string]$Name, [hashtable]$Extra)

    # Bootstrap accepts canonical stage IDs only. Normalize display labels such
    # as "Stage 04-register-arc" before binding its ValidateSet parameter.
    $displayName = if ($null -eq $Name) { '' } else { [string]$Name }
    $canonicalName = [regex]::Replace($displayName, '^Stage\s+', '')
    if (-not ($stageName.Values -contains $canonicalName)) {
        throw "Invalid stage name '$Name'. Expected one of: $($stageName.Values -join ', ')"
    }

    $stageArgs = @{ Stage = $canonicalName }
    if ($null -ne $Extra) {
        foreach ($k in $Extra.Keys) { $stageArgs[$k] = $Extra[$k] }
    }
    Write-Info "--> dispatching $canonicalName"
    & $dispatcher @stageArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "$canonicalName exited with code $LASTEXITCODE" }
}

function Get-PersistedArcGatewayId {
    if ($script:ArcGatewayID) { return [string]$script:ArcGatewayID }
    if (Test-Path $script:arcGatewayStateFile -PathType Leaf) {
        try {
            $state = Get-Content $script:arcGatewayStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($state.resourceId) { return [string]$state.resourceId }
        } catch {
            Write-Warn "Could not read Arc Gateway state file: $($_.Exception.Message)"
        }
    }
    return $null
}

# --- shared node auth forwarded to stages 2/3/4/5 ---
$nodeAuth = @{ ConfigureTrustedHosts = $true; Transport = $Transport; LocalAdminUser = $LocalAdminUser }
if ($LocalAdminPassword) {
    $nodeAuth['LocalAdminPassword'] = $LocalAdminPassword
} else {
    # Stage 0 and the node stages run under this same Windows identity. The helper
    # returns a PSCredential; only the SecureString password is forwarded.
    $nodeCredential = Get-LabNodeCredential -User $LocalAdminUser
    $nodeAuth['LocalAdminPassword'] = $nodeCredential.Password
}

Initialize-Ui -StageName 'deploy-all (orchestrator)' -TotalSteps (2 + $Stages.Count) -UseGui:$UseGui

try {
    # -------------------------------------------------- Stage 0: ensure SP ---
    Invoke-Step 'Ensure service principal (auto Stage 0 if missing)' {
        if (Test-Path $script:SpCredentialFile) {
            Write-Ok "SP credential file present: $script:SpCredentialFile"
        }
        elseif ($script:AutoCreateSp) {
            Write-Warn 'No SP credential file found - running Stage 0 (interactive, MFA-capable) once.'
            $sp0 = Join-Path $PSScriptRoot '00-create-service-principal.ps1'
            if (-not (Test-Path $sp0)) { throw "Stage 0 script missing: $sp0" }
            & $sp0 -SubscriptionId $script:SubscriptionId -TenantId $script:TenantId -OutFile $script:SpCredentialFile
            if (-not (Test-Path $script:SpCredentialFile)) { throw 'Stage 0 did not produce a credential file.' }
        }
        else {
            throw "No SP credential file and -AutoCreateSp:`$false. Run 00-create-service-principal.ps1 first."
        }
    }

    # -------------------------------------------------- load SP identity ---
    Invoke-Step 'Load SP identity for unattended Azure auth' {
        $rec = Get-Content $script:SpCredentialFile -Raw | ConvertFrom-Json
        $script:spAppId  = $rec.appId
        $script:spTenant = $rec.tenantId
        if (-not $script:SubscriptionId) { $script:SubscriptionId = $rec.subscriptionId }
        $script:spAuth = @{ ServicePrincipalId = $rec.appId; TenantId = $rec.tenantId; SubscriptionId = $script:SubscriptionId }

        if ($rec.authType -eq 'certificate') {
            $script:spAuth['CertificateThumbprint'] = $rec.certThumbprint
            Write-Ok "SP (certificate) AppId $($rec.appId), thumbprint $($rec.certThumbprint)"
        }
        elseif ($rec.PSObject.Properties.Name -contains 'secretProtected' -and $rec.secretProtected) {
            $script:spAuth['ServicePrincipalSecret'] = ($rec.secretProtected | ConvertTo-SecureString)
            Write-Ok "SP (DPAPI secret) AppId $($rec.appId)"
        }
        elseif ($rec.PSObject.Properties.Name -contains 'secret' -and $rec.secret) {
            $script:spAuth['ServicePrincipalSecret'] = (ConvertTo-SecureString $rec.secret -AsPlainText -Force)
            Write-Warn "SP (plaintext secret) AppId $($rec.appId) - move this to a vault."
        }
        else {
            throw 'SP credential file has no usable secret/certificate. Re-run Stage 0 with -ResetSecret or -UseCertificate.'
        }
    }

    # -------------------------------------------------- run the stages ---
    foreach ($s in $Stages) {
        $name = $stageName[$s]
        if (-not $name) { Write-Warn "Unknown stage number $s - skipping."; continue }

        Invoke-Step "Stage $name" {
            switch ($s) {
                1 {
                    if (-not $script:IncludeOsDeploy) {
                        Write-Warn 'Stage 1 (OS deploy) is destructive; -IncludeOsDeploy not set. Skipping reimage.'
                        return
                    }
                    if (-not (Confirm-Gate 'Stage 1 - reimage BOTH nodes (wipes current OS)')) { throw 'Stage 1 declined by operator.' }
                    $ex = @{ HttpHost = $script:HttpHost; ISOFile = $script:ISOFile; RACADMPath = $script:RACADMPath; StartInstallation = $true; NoCertWarn = $true }
                    if ($script:iDRACPassword) { $ex['iDRACPassword'] = $script:iDRACPassword }
                    Invoke-Stage -Name $name -Extra $ex
                    Wait-NodeReady -Ips $script:NodeIPs -TimeoutMin $script:NodeReadyTimeoutMin -PollSec $script:NodeReadyPollSec -Port $script:winrmPort
                }
                2 { Invoke-Stage -Name $name -Extra $script:nodeAuth }
                3 { Invoke-Stage -Name $name -Extra ($script:nodeAuth + @{ ConnectivityOnly = $true }) }
                4 {
                    $mode = if ($script:DryRun) { 'Validate' } else { 'Register' }
                    if ($mode -eq 'Register' -and -not (Confirm-Gate 'Stage 4 - Arc REGISTER (onboards + reboots both nodes)')) {
                        throw 'Stage 4 Register declined by operator.'
                    }
                    $ex = $script:nodeAuth + $script:spAuth + @{
                        ArcMode = $mode
                        Region = $script:Region
                        UseArcGateway = $script:UseArcGateway
                        ArcGatewayID = $script:ArcGatewayID
                        ArcGatewayName = $script:ArcGatewayName
                        ArcGatewayTimeoutMin = $script:ArcGatewayTimeoutMin
                    }
                    if ($mode -eq 'Register') { $ex['Apply'] = $true }
                    Invoke-Stage -Name $name -Extra $ex
                    if ($mode -eq 'Register') {
                        Write-Info 'Arc onboarding reboots nodes; waiting for them to return.'
                        Wait-NodeReady -Ips $script:NodeIPs -TimeoutMin $script:NodeReadyTimeoutMin -PollSec $script:NodeReadyPollSec -Port $script:winrmPort
                    }
                }
                5 {
                    if (-not $script:TemplateFile -or -not $script:ParameterFile) {
                        throw 'Stage 5 needs -TemplateFile and -ParameterFile.'
                    }
                    $gatewayIdForStage5 = Get-PersistedArcGatewayId
                    $ex = $script:nodeAuth + $script:spAuth + @{
                        Region = $script:Region
                        TemplateFile = $script:TemplateFile
                        ParameterFile = $script:ParameterFile
                        UseArcGateway = $script:UseArcGateway
                        ArcGatewayName = $script:ArcGatewayName
                    }
                    if ($gatewayIdForStage5) { $ex['ArcGatewayID'] = $gatewayIdForStage5 }
                    if ($script:DryRun) {
                        $ex['DeploymentMode'] = 'Validate'
                    } else {
                        if (-not (Confirm-Gate 'Stage 5 - DEPLOY Azure Local cluster (irreversible)')) { throw 'Stage 5 Deploy declined by operator.' }
                        $ex['DeploymentMode'] = 'Deploy'; $ex['EnableDeployment'] = $true
                    }
                    Invoke-Stage -Name $name -Extra $ex
                }
                6 { Invoke-Stage -Name $name -Extra @{} }
            }
            Write-Ok "Stage $name complete"
        }
    }

    Complete-Ui -FinalMessage 'Orchestration finished.'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Orchestration failed.'
    throw
}
