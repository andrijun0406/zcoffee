<#
.SYNOPSIS
    Run Stage 2 network validation followed by Stage 3 node-readiness validation.

.DESCRIPTION
    This is a validation wrapper, not a replacement for the underlying stages. It runs
    Stage 2 first and stops before Stage 3 if Stage 2 fails. Read-only behavior is the
    default; use -Apply only when the safe repair actions in the underlying stages are
    intentionally required.
#>
[CmdletBinding()]
param(
    [string[]]$NodeIPs,
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTPS','HTTP')]
    [string]$Transport = 'HTTP',
    [int]$Port,
    [switch]$ConfigureTrustedHosts,
    [switch]$SkipCertCheck,
    [switch]$Apply,
    [switch]$ApplyVlanTag,
    [switch]$RebootIfRenamed,
    [switch]$ForceIpChange,
    [switch]$SkipEnvChecker,
    [switch]$ConnectivityOnly,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b = $PSBoundParameters

$LocalAdminUser = Resolve-Setting -Name 'LocalAdminUser' -Bound $b -Current $LocalAdminUser -ConfigKey 'LocalAdminUser' -Config $cfg
if (-not $LocalAdminUser) { $LocalAdminUser = 'Administrator' }

if (-not $b.ContainsKey('NodeIPs')) {
    if ($cfg.ContainsKey('Nodes')) {
        $NodeIPs = @($cfg.Nodes | ForEach-Object { $_.HostIP })
    } else {
        $NodeIPs = @('10.8.230.232','10.8.230.235')
    }
}
if (-not $NodeIPs -or $NodeIPs.Count -eq 0) { throw 'At least one node IP is required.' }
if (-not $Port) { $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 } }

if (-not $b.ContainsKey('LocalAdminPassword') -or $null -eq $LocalAdminPassword) {
    $authUser = $LocalAdminUser
    if ($authUser -notmatch '[\\@]') { $authUser = ".\$authUser" }
    $cred = Get-LabNodeCredential -User $authUser
    $LocalAdminPassword = $cred.Password
}

$stage2 = Join-Path $PSScriptRoot '02-configure-network.ps1'
$stage3 = Join-Path $PSScriptRoot '03-prepare-node.ps1'
if (-not (Test-Path -LiteralPath $stage2 -PathType Leaf)) { throw "Missing Stage 2 script: $stage2" }
if (-not (Test-Path -LiteralPath $stage3 -PathType Leaf)) { throw "Missing Stage 3 script: $stage3" }

Initialize-Ui -StageName '02-03-validate-nodes' -TotalSteps 2 -UseGui:$UseGui

try {
    Invoke-Step 'Stage 2 - validate host network' {
        $args2 = @{
            NodeIPs = $NodeIPs
            LocalAdminUser = $LocalAdminUser
            LocalAdminPassword = $LocalAdminPassword
            Transport = $Transport
            Port = $Port
        }
        if ($ConfigureTrustedHosts) { $args2.ConfigureTrustedHosts = $true }
        if ($SkipCertCheck) { $args2.SkipCertCheck = $true }
        if ($Apply) { $args2.Apply = $true }
        if ($ApplyVlanTag) { $args2.ApplyVlanTag = $true }
        if ($RebootIfRenamed) { $args2.RebootIfRenamed = $true }
        if ($ForceIpChange) { $args2.ForceIpChange = $true }
        if ($UseGui) { $args2.UseGui = $true }

        & $stage2 @args2
        if (-not $?) { throw 'Stage 2 returned a failure status.' }
    }

    Invoke-Step 'Stage 3 - validate node readiness' {
        $args3 = @{
            NodeIPs = $NodeIPs
            LocalAdminUser = $LocalAdminUser
            LocalAdminPassword = $LocalAdminPassword
            Transport = $Transport
            Port = $Port
        }
        if ($ConfigureTrustedHosts) { $args3.ConfigureTrustedHosts = $true }
        if ($SkipCertCheck) { $args3.SkipCertCheck = $true }
        if ($Apply) { $args3.Apply = $true }
        if ($SkipEnvChecker) { $args3.SkipEnvChecker = $true }
        if ($ConnectivityOnly) { $args3.ConnectivityOnly = $true }
        if ($UseGui) { $args3.UseGui = $true }

        & $stage3 @args3
        if (-not $?) { throw 'Stage 3 returned a failure status.' }
    }

    Complete-Ui -FinalMessage 'Combined Stage 2+3 validation finished.'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Combined Stage 2+3 validation failed.'
    throw
}
