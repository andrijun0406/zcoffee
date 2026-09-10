<#
.SYNOPSIS
    Spec-driven, backward-compatible ZCOFFEE orchestrator.
.DESCRIPTION
    Loads deployment-spec.yaml and a hardware profile, runs read-only preflight,
    optionally stages SBE, records timing, then invokes the proven deploy-all.ps1
    backend. The legacy orchestrator remains the rollback path.
#>
[CmdletBinding()]
param(
    [string]$SpecFile = (Join-Path $PSScriptRoot 'deployment-spec.yaml'),
    [string]$ProfileFile = (Join-Path $PSScriptRoot 'profiles\dell-ax-15g-switchless.yaml'),
    [string]$SubscriptionId,
    [string]$TenantId,
    [int[]]$Stages = @(1,2,3,4,5,6),
    [switch]$IncludeOsDeploy,
    [string]$HttpHost,
    [string]$ISOFile,
    [switch]$DryRun,
    [switch]$AutoApprove,
    [switch]$SkipPreflight,
    [switch]$SkipArc,
    [switch]$StageSbe,
    [string]$SbeSourcePath,
    [switch]$UseExistingAzLogin,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')
. (Join-Path $PSScriptRoot 'zcoffee-spec.ps1')
. (Join-Path $PSScriptRoot 'zcoffee-timing.ps1')

$loaded = & (Join-Path $PSScriptRoot 'zcoffee-spec.ps1') -SpecFile $SpecFile -ProfileFile $ProfileFile
$spec = $loaded.Spec
if (-not $SubscriptionId) { $SubscriptionId = [string]$spec.azure.subscriptionId }
if (-not $TenantId) { $TenantId = [string]$spec.azure.tenantId }
if (-not $SubscriptionId -or -not $TenantId) {
    throw 'SubscriptionId and TenantId are required. Pass them explicitly or populate the non-secret azure section in deployment-spec.yaml.'
}

$timing = New-ZcoffeeTimingState -DeploymentId (Get-Date -Format 'yyyyMMdd-HHmmss')
$logDir = Join-Path $PSScriptRoot ([string]$spec.telemetry.outputDirectory)
$timingFile = Join-Path $logDir ("timing-{0}.json" -f $timing.DeploymentId)

try {
    $stage = Start-ZcoffeeTimedStage -State $timing -Name 'vNext preflight' -Phase 'Infrastructure Preparation'
    try {
        if (-not $SkipPreflight) {
            $preflightArgs = @{
                SpecFile = $SpecFile
                ProfileFile = $ProfileFile
                SubscriptionId = $SubscriptionId
                TenantId = $TenantId
                UseExistingAzLogin = $UseExistingAzLogin
                SkipArc = ($SkipArc -or (4 -notin $Stages))
                SkipAzure = ($SkipArc -or (4 -notin $Stages))
                SkipSbe = $StageSbe
            }
            & (Join-Path $PSScriptRoot 'zcoffee-preflight.ps1') @preflightArgs
        }
        Complete-ZcoffeeTimedStage -Entry $stage -Status 'Succeeded'
    }
    catch {
        Complete-ZcoffeeTimedStage -Entry $stage -Status 'Failed'
        throw
    }

    if ($StageSbe) {
        $stage = Start-ZcoffeeTimedStage -State $timing -Name 'SBE staging' -Phase 'Infrastructure Preparation'
        try {
            $sbeScript = Join-Path $PSScriptRoot 'stage-sbe.ps1'
            if (-not (Test-Path -Path $sbeScript -PathType Leaf)) { throw "stage-sbe.ps1 not found: $sbeScript" }
            if (-not $SbeSourcePath) { $SbeSourcePath = [string]$spec.sbe.sourcePath }
            if (-not $SbeSourcePath) { throw 'SBE source path is required when -StageSbe is used.' }
            & $sbeScript -NodeIPs @($spec.nodes | ForEach-Object { $_.hostIp }) -SbeSourcePath $SbeSourcePath -Apply -ReplaceRemoteSbe
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "stage-sbe.ps1 exited with code $LASTEXITCODE" }
            Complete-ZcoffeeTimedStage -Entry $stage -Status 'Succeeded'
        }
        catch {
            Complete-ZcoffeeTimedStage -Entry $stage -Status 'Failed'
            throw
        }

        if (-not $SkipPreflight) {
            $postSbeArgs = @{
                SpecFile = $SpecFile
                ProfileFile = $ProfileFile
                SubscriptionId = $SubscriptionId
                TenantId = $TenantId
                UseExistingAzLogin = $UseExistingAzLogin
                SkipArc = ($SkipArc -or (4 -notin $Stages))
                SkipAzure = ($SkipArc -or (4 -notin $Stages))
            }
            & (Join-Path $PSScriptRoot 'zcoffee-preflight.ps1') @postSbeArgs
        }
    }

    $stage = Start-ZcoffeeTimedStage -State $timing -Name 'Legacy execution backend' -Phase 'Deployment'
    try {
        $legacy = Join-Path $PSScriptRoot 'deploy-all.ps1'
        if (-not (Test-Path -Path $legacy -PathType Leaf)) { throw "Legacy orchestrator not found: $legacy" }
        $legacyArgs = @{
            SubscriptionId = $SubscriptionId
            TenantId = $TenantId
            Region = $spec.deployment.region
            Stages = $Stages
            NodeIPs = @($spec.nodes | ForEach-Object { $_.hostIp })
            LocalAdminUser = [string]$spec.identity.localAdminUser
            Transport = 'HTTP'
            TemplateFile = (Join-Path $PSScriptRoot $spec.deployment.templateFile)
            ParameterFile = (Join-Path $PSScriptRoot $spec.deployment.parameterFile)
            AutoApprove = $AutoApprove
            DryRun = $DryRun
            UseGui = $UseGui
            IncludeOsDeploy = $IncludeOsDeploy
        }
        if ($IncludeOsDeploy) {
            if (-not $HttpHost) { $HttpHost = [string]$spec.deployment.httpHost }
            if (-not $ISOFile) { $ISOFile = [string]$spec.deployment.isoFile }
            if (-not $HttpHost -or -not $ISOFile) { throw 'IncludeOsDeploy requires -HttpHost and -ISOFile, or values in deployment-spec.yaml.' }
            $legacyArgs.HttpHost = $HttpHost
            $legacyArgs.ISOFile = $ISOFile
        }
        & $legacy @legacyArgs
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Legacy orchestrator exited with code $LASTEXITCODE" }
        Complete-ZcoffeeTimedStage -Entry $stage -Status 'Succeeded'
    }
    catch {
        Complete-ZcoffeeTimedStage -Entry $stage -Status 'Failed'
        throw
    }
}
catch {
    Save-ZcoffeeTimingState -State $timing -Path $timingFile
    throw
}
finally {
    if (-not (Test-Path -Path $timingFile)) { Save-ZcoffeeTimingState -State $timing -Path $timingFile }
}

Write-Host "Timing report: $timingFile"
