<#
.SYNOPSIS
    Canonical spec-driven ZCOFFEE vNext deployment orchestrator.
.DESCRIPTION
    Loads a deployment spec and hardware profile, runs modular read-only preflight,
    optionally stages SBE, records timing, and invokes the proven legacy deployment
    backend (deploy-all.ps1). This script is the single vNext execution entry point.
#>
[CmdletBinding()]
param(
    [string]$SpecFile = (Join-Path $PSScriptRoot 'deployment-spec.yaml'),
    [string]$ProfileFile,
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
    [switch]$SkipAzure,
    [switch]$StageSbe,
    [string]$SbeSourcePath,
    [switch]$UseExistingAzLogin,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vnextRoot = $PSScriptRoot
$scriptRoot = Split-Path -Path $vnextRoot -Parent

. (Join-Path $vnextRoot 'lib\Spec.ps1')
. (Join-Path $vnextRoot 'lib\Timing.ps1')
. (Join-Path $vnextRoot 'lib\Preflight.ps1')

$loaded = Import-ZcoffeeDeploymentSpec -SpecFile $SpecFile -ProfileFile $ProfileFile
$spec = $loaded.Spec
$profile = $loaded.Profile

$validation = Test-ZcoffeeDeploymentSpec -LoadedSpec $loaded
foreach ($w in $validation.Warnings) { Write-Warning $w }
if (-not $validation.IsValid) {
    throw ("Spec validation failed: " + ($validation.Errors -join '; '))
}

if (-not $SubscriptionId -and $spec.azure) { $SubscriptionId = [string]$spec.azure.subscriptionId }
if (-not $TenantId -and $spec.azure) { $TenantId = [string]$spec.azure.tenantId }
if (-not $SubscriptionId -or -not $TenantId) {
    throw 'SubscriptionId and TenantId are required. Pass them explicitly or populate azure.subscriptionId/azure.tenantId in the spec.'
}

$resolvedProfileFile = $ProfileFile
if (-not $resolvedProfileFile -and $loaded.ProfilePath) { $resolvedProfileFile = $loaded.ProfilePath }
if (-not $resolvedProfileFile) { throw 'ProfileFile is required (pass -ProfileFile or set hardwareProfile in the spec).' }

$nodeIps = @(Get-ZcoffeeNodeIps -Spec $spec)
if ($nodeIps.Count -eq 0) { throw 'Spec contains no node hostIp values.' }

$adminUser = 'Administrator'
if ($spec.identity -and $spec.identity.localAdminUser) { $adminUser = [string]$spec.identity.localAdminUser }

$templateFile = Resolve-ZcoffeePathFromSpec -BaseDirectory $loaded.SpecDirectory -PathValue ([string]$spec.deployment.templateFile)
$parameterFile = Resolve-ZcoffeePathFromSpec -BaseDirectory $loaded.SpecDirectory -PathValue ([string]$spec.deployment.parameterFile)
$region = [string]$spec.deployment.region

$telemetryDirName = 'logs'
if ($spec.telemetry -and $spec.telemetry.outputDirectory) { $telemetryDirName = [string]$spec.telemetry.outputDirectory }
$timingDir = Resolve-ZcoffeePathFromSpec -BaseDirectory $loaded.SpecDirectory -PathValue $telemetryDirName
if (-not $timingDir) { $timingDir = Join-Path $vnextRoot 'logs' }

$timing = New-ZcoffeeTimingState -DeploymentId (Get-Date -Format 'yyyyMMdd-HHmmss')
$timingFile = Join-Path $timingDir ("timing-{0}.json" -f $timing.DeploymentId)

function Invoke-ZcoffeePreflightPhase {
    param([string]$Name)
    $stage = Start-ZcoffeeTimedStage -State $timing -Name $Name -Phase 'Infrastructure Preparation'
    try {
        $preflightArgs = @{
            SpecFile         = $loaded.SpecPath
            ProfileFile      = $resolvedProfileFile
            SubscriptionId   = $SubscriptionId
            TenantId         = $TenantId
            UseExistingAzLogin = $UseExistingAzLogin
            SkipArc          = ($SkipArc -or (4 -notin $Stages))
            SkipAzure        = ($SkipAzure -or (4 -notin $Stages) -or $SkipArc)
            SkipSbe          = $StageSbe
        }
        Invoke-ZcoffeePreflight @preflightArgs | Out-Null
        Complete-ZcoffeeTimedStage -Entry $stage -Status 'Succeeded'
    }
    catch {
        Complete-ZcoffeeTimedStage -Entry $stage -Status 'Failed'
        throw
    }
}

try {
    if (-not $SkipPreflight) {
        Invoke-ZcoffeePreflightPhase -Name 'vNext preflight'
    } else {
        $stage = Start-ZcoffeeTimedStage -State $timing -Name 'vNext preflight' -Phase 'Infrastructure Preparation'
        Complete-ZcoffeeTimedStage -Entry $stage -Status 'Skipped'
    }

    if ($StageSbe) {
        $stage = Start-ZcoffeeTimedStage -State $timing -Name 'SBE staging' -Phase 'Infrastructure Preparation'
        try {
            $sbeScript = Join-Path $scriptRoot 'stage-sbe.ps1'
            if (-not (Test-Path -Path $sbeScript -PathType Leaf)) { throw "Proven stage-sbe.ps1 not found: $sbeScript" }

            $effectiveSbeSource = $SbeSourcePath
            if (-not $effectiveSbeSource -and $spec.sbe -and $spec.sbe.sourcePath) { $effectiveSbeSource = [string]$spec.sbe.sourcePath }
            if (-not $effectiveSbeSource) { throw 'SBE source path is required when -StageSbe is used (pass -SbeSourcePath or set sbe.sourcePath in spec).' }

            & $sbeScript -NodeIPs $nodeIps -SbeSourcePath $effectiveSbeSource -Apply -ReplaceRemoteSbe
            if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "stage-sbe.ps1 exited with code $LASTEXITCODE" }
            Complete-ZcoffeeTimedStage -Entry $stage -Status 'Succeeded'
        }
        catch {
            Complete-ZcoffeeTimedStage -Entry $stage -Status 'Failed'
            throw
        }

        if (-not $SkipPreflight) {
            Invoke-ZcoffeePreflightPhase -Name 'vNext preflight (post-SBE)'
        }
    }

    $stage = Start-ZcoffeeTimedStage -State $timing -Name 'Legacy execution backend' -Phase 'Deployment'
    try {
        $legacy = Join-Path $scriptRoot 'deploy-all.ps1'
        if (-not (Test-Path -Path $legacy -PathType Leaf)) { throw "Legacy orchestrator not found: $legacy" }

        $legacyArgs = @{
            SubscriptionId  = $SubscriptionId
            TenantId        = $TenantId
            Region          = $region
            Stages          = $Stages
            NodeIPs         = $nodeIps
            LocalAdminUser  = $adminUser
            Transport       = 'HTTP'
            TemplateFile    = $templateFile
            ParameterFile   = $parameterFile
            AutoApprove     = $AutoApprove
            DryRun          = $DryRun
            UseGui          = $UseGui
            IncludeOsDeploy = $IncludeOsDeploy
        }

        if ($IncludeOsDeploy) {
            if (-not $HttpHost -and $spec.deployment.httpHost) { $HttpHost = [string]$spec.deployment.httpHost }
            if (-not $ISOFile -and $spec.deployment.isoFile) { $ISOFile = [string]$spec.deployment.isoFile }
            if (-not $HttpHost -or -not $ISOFile) {
                throw 'IncludeOsDeploy requires -HttpHost and -ISOFile, or deployment.httpHost/deployment.isoFile in the spec.'
            }
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
Write-Host "Spec: $($loaded.SpecPath)"
Write-Host "Profile: $resolvedProfileFile"
Write-Host 'ZCOFFEE vNext orchestration completed.'
