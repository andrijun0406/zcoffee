<#
.SYNOPSIS
    Non-destructive validation and test helper for ZCOFFEE vNext spec-driven automation.
.DESCRIPTION
    Performs safe checks: spec/profile loading and validation, resolved path preview,
    timing/report path preview, and optional read-only preflight. Does not deploy or
    modify Azure/node state unless you explicitly run preflight in an environment where
    its read-only checks can execute.
#>
[CmdletBinding()]
param(
    [string]$SpecFile = (Join-Path $PSScriptRoot 'deployment-spec.yaml'),
    [string]$ProfileFile,
    [string]$SubscriptionId,
    [string]$TenantId,
    [int[]]$Stages = @(1,2,3,4,5,6),
    [switch]$RunPreflight,
    [switch]$SkipArc,
    [switch]$SkipAzure,
    [switch]$SkipSbe,
    [switch]$UseExistingAzLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Spec.ps1')
. (Join-Path $PSScriptRoot 'lib\Timing.ps1')

$loaded = Import-ZcoffeeDeploymentSpec -SpecFile $SpecFile -ProfileFile $ProfileFile
$spec = $loaded.Spec
$profile = $loaded.Profile

Write-Host "Spec:    $($loaded.SpecPath)"
Write-Host "Profile: $($loaded.ProfilePath)"

$validation = Test-ZcoffeeDeploymentSpec -LoadedSpec $loaded
foreach ($w in $validation.Warnings) { Write-Warning $w }
if (-not $validation.IsValid) {
    foreach ($e in $validation.Errors) { Write-Error $e }
    throw 'Spec validation failed.'
}
Write-Host 'Spec validation: PASS' -ForegroundColor Green

if (-not $SubscriptionId -and $spec.azure) { $SubscriptionId = [string]$spec.azure.subscriptionId }
if (-not $TenantId -and $spec.azure) { $TenantId = [string]$spec.azure.tenantId }
$resolvedProfileFile = $ProfileFile
if (-not $resolvedProfileFile -and $loaded.ProfilePath) { $resolvedProfileFile = $loaded.ProfilePath }

$nodeIps = @(Get-ZcoffeeNodeIps -Spec $spec)
$nodeNames = @(Get-ZcoffeeNodeNames -Spec $spec)
$templateFile = Resolve-ZcoffeePathFromSpec -BaseDirectory $loaded.SpecDirectory -PathValue ([string]$spec.deployment.templateFile)
$parameterFile = Resolve-ZcoffeePathFromSpec -BaseDirectory $loaded.SpecDirectory -PathValue ([string]$spec.deployment.parameterFile)
$legacyBackend = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\deploy-all.ps1'))
$stageSbeScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\stage-sbe.ps1'))
$timingDirName = 'logs'
if ($spec.telemetry -and $spec.telemetry.outputDirectory) { $timingDirName = [string]$spec.telemetry.outputDirectory }
$timingDir = Resolve-ZcoffeePathFromSpec -BaseDirectory $loaded.SpecDirectory -PathValue $timingDirName
if (-not $timingDir) { $timingDir = Join-Path $PSScriptRoot 'logs' }

$preview = [pscustomobject]@{
    SubscriptionId   = $SubscriptionId
    TenantId         = $TenantId
    Stages           = ($Stages -join ',')
    Region           = [string]$spec.deployment.region
    ResourceGroup    = [string]$spec.deployment.resourceGroup
    NodeNames        = ($nodeNames -join ',')
    NodeIPs          = ($nodeIps -join ',')
    LocalAdminUser   = if ($spec.identity -and $spec.identity.localAdminUser) { [string]$spec.identity.localAdminUser } else { 'Administrator' }
    TemplateFile     = $templateFile
    ParameterFile    = $parameterFile
    LegacyBackend    = $legacyBackend
    StageSbeScript   = $stageSbeScript
    TimingDirectory  = $timingDir
}

$preview | Format-List

if (-not (Test-Path -Path $legacyBackend -PathType Leaf)) { throw "Legacy backend not found: $legacyBackend" }
if (-not (Test-Path -Path $stageSbeScript -PathType Leaf)) { throw "stage-sbe.ps1 not found: $stageSbeScript" }
Write-Host 'Backend script paths: PASS' -ForegroundColor Green

if ($RunPreflight) {
    . (Join-Path $PSScriptRoot 'lib\Preflight.ps1')
    $pf = @{
        SpecFile    = $loaded.SpecPath
        ProfileFile = $resolvedProfileFile
        SubscriptionId = $SubscriptionId
        TenantId    = $TenantId
        UseExistingAzLogin = $UseExistingAzLogin
        SkipArc     = $SkipArc
        SkipAzure   = $SkipAzure
        SkipSbe     = $SkipSbe
    }
    Invoke-ZcoffeePreflight @pf | Out-Null
    Write-Host 'Preflight: PASS' -ForegroundColor Green
} else {
    Write-Host 'Preflight: skipped (use -RunPreflight to execute read-only checks).'
}

Write-Host 'ZCOFFEE vNext test helper completed.' -ForegroundColor Green
