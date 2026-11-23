<#
.SYNOPSIS
    Compatibility shim for the canonical spec-driven ZCOFFEE vNext orchestrator.
.DESCRIPTION
    Forwards all parameters to Invoke-ZcoffeeDeployment.ps1 to avoid overlapping
    orchestration implementations. Prefer Invoke-ZcoffeeDeployment.ps1 for new usage.
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

$entry = Join-Path $PSScriptRoot 'Invoke-ZcoffeeDeployment.ps1'
if (-not (Test-Path -Path $entry -PathType Leaf)) {
    throw "Canonical orchestrator not found: $entry"
}

& $entry @PSBoundParameters
exit $LASTEXITCODE


