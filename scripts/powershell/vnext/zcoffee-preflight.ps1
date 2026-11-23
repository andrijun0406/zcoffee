<#
.SYNOPSIS
    Compatibility wrapper for ZCOFFEE vNext preflight.
.DESCRIPTION
    Delegates to lib/Preflight.ps1 (Invoke-ZcoffeePreflight) to avoid duplicated logic.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SpecFile,

    [Parameter(Mandatory = $true)]
    [string]$ProfileFile,

    [string]$SubscriptionId,
    [string]$TenantId,
    [switch]$UseExistingAzLogin,
    [switch]$SkipArc,
    [switch]$SkipAzure,
    [switch]$SkipSbe,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Preflight.ps1')

$forward = @{}
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -eq 'UseGui') { continue } # not used by modular preflight; kept for compatibility
    $forward[$k] = $PSBoundParameters[$k]
}

Invoke-ZcoffeePreflight @forward | Out-Null
Write-Host 'ZCOFFEE vNext preflight wrapper completed.' -ForegroundColor Green

