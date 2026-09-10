<#
.SYNOPSIS
    ZCOFFEE vNext read-only dependency and support preflight.
.DESCRIPTION
    This script lives under scripts\powershell\vnext. Shared legacy helpers
    are resolved from the parent scripts\powershell directory. The spec loader
    is invoked with explicit paths; it is not dot-sourced, preventing prompts
    for mandatory parameters.
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

$vnextRoot = $PSScriptRoot
$scriptRoot = (Resolve-Path (Join-Path $vnextRoot '..')).Path
$uiCommon = Join-Path $scriptRoot 'ui-common.ps1'
$specLoader = Join-Path $vnextRoot 'zcoffee-spec.ps1'

if (-not (Test-Path -Path $uiCommon -PathType Leaf)) {
    throw "Shared helper not found: $uiCommon"
}
if (-not (Test-Path -Path $specLoader -PathType Leaf)) {
    throw "Spec loader not found: $specLoader"
}

. $uiCommon

$resolvedSpec = (Resolve-Path -Path $SpecFile -ErrorAction Stop).Path
$resolvedProfile = (Resolve-Path -Path $ProfileFile -ErrorAction Stop).Path
$loaded = & $specLoader -SpecFile $resolvedSpec -ProfileFile $resolvedProfile
$spec = $loaded.Spec
$profile = $loaded.Profile

if ($null -eq $spec) { throw "Spec loader returned no spec: $resolvedSpec" }
if ($null -eq $profile) { throw "Spec loader returned no profile: $resolvedProfile" }

if ($profile.supportStatus -and ([string]$profile.supportStatus -match 'experimental')) {
    Write-Warning ('Hardware profile is experimental: ' + [string]$profile.supportStatus)
}

$nodes = @($spec.nodes | ForEach-Object { $_.hostIp })
if ($nodes.Count -eq 0) { throw 'Spec contains no nodes.' }

$adminUser = 'Administrator'
if ($spec.identity -and $spec.identity.localAdminUser) {
    $adminUser = [string]$spec.identity.localAdminUser
}
$authUser = if ($adminUser -match '[\\@]') { $adminUser } else { '.\' + $adminUser }
$cred = Get-LabNodeCredential -User $authUser

$errors = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
$results = New-Object System.Collections.ArrayList

function Add-PreflightResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS','WARN','FAIL')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    [void]$script:results.Add([pscustomobject]@{
        Check = $Name
        Status = $Status
        Detail = $Detail
    })
    if ($Status -eq 'FAIL') { [void]$script:errors.Add(('{0}: {1}' -f $Name, $Detail)) }
    if ($Status -eq 'WARN') { [void]$script:warnings.Add(('{0}: {1}' -f $Name, $Detail)) }
}

$expectedBuild = ''
if ($spec.preflight -and $spec.preflight.expectedOsBuild) {
    $expectedBuild = [string]$spec.preflight.expectedOsBuild
}
$managementAdapters = @($profile.expectedAdapters.management)
$storageAdapters = @($profile.expectedAdapters.storage)
$requireSbe = $false
if ($spec.preflight -and $null -ne $spec.preflight.requireSbeFiles) {
    $requireSbe = [bool]$spec.preflight.requireSbeFiles
}

$nodeCheck = {
    param($ExpectedBuild, $ManagementAdapters, $StorageAdapters, $RequireSbe)

    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name })
    $adapterNames = @($adapters | ForEach-Object { $_.Name })
    $expectedAdapters = @($ManagementAdapters) + @($StorageAdapters)
    $missing = @($expectedAdapters | Where-Object { $_ -notin $adapterNames })
    $sbeFiles = @(Get-ChildItem -Path 'C:\SBE' -File -ErrorAction SilentlyContinue)
    $agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
    $arcStatus = ''
    $gatewayMode = ''

    if (Test-Path -Path $agent -PathType Leaf) {
        try {
            $arcJson = ((& $agent show -j 2>$null | Out-String) | ConvertFrom-Json)
            $arcStatus = [string]$arcJson.status
        } catch { $arcStatus = '' }
        $gatewayMode = (& $agent config get connection.type 2>$null | Out-String).Trim()
    }

    [pscustomobject]@{
        Node = $env:COMPUTERNAME
        Build = $build
        BuildOk = ($build -eq $ExpectedBuild)
        MissingAdapters = $missing
        SbeCount = $sbeFiles.Count
        SbeOk = (-not $RequireSbe -or $sbeFiles.Count -gt 0)
        ArcStatus = $arcStatus
        GatewayMode = $gatewayMode
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    }
}

foreach ($ip in $nodes) {
    try {
        $result = Invoke-Command -ComputerName $ip -Credential $cred `
            -Authentication Negotiate -Port 5985 `
            -ScriptBlock $nodeCheck `
            -ArgumentList $expectedBuild, $managementAdapters, $storageAdapters, $requireSbe `
            -ErrorAction Stop

        [void]$results.Add($result)
        if (-not $result.BuildOk) {
            Add-PreflightResult ('OS {0}' -f $ip) 'FAIL' ('Expected {0}, found {1}' -f $expectedBuild, $result.Build)
        }
        if (-not $SkipSbe -and -not $result.SbeOk) {
            Add-PreflightResult ('SBE {0}' -f $ip) 'FAIL' 'C:\SBE is missing or empty'
        }
        if (@($result.MissingAdapters).Count -gt 0) {
            Add-PreflightResult ('Hardware {0}' -f $ip) 'FAIL' ('Missing adapters: {0}' -f ($result.MissingAdapters -join ', '))
        }
        if (-not $SkipArc) {
            if ($result.ArcStatus -ne 'Connected') {
                Add-PreflightResult ('Arc {0}' -f $ip) 'FAIL' ('Status={0}' -f $result.ArcStatus)
            }
            if ($spec.arc -and $spec.arc.requireGatewayMode -and $result.GatewayMode -ne 'gateway') {
                Add-PreflightResult ('ArcGateway {0}' -f $ip) 'FAIL' ('Mode={0}' -f $result.GatewayMode)
            }
        }
    } catch {
        Add-PreflightResult ('WinRM {0}' -f $ip) 'FAIL' $_.Exception.Message
    }
}

if (-not $SkipAzure) {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if ($null -eq $ctx) {
        Add-PreflightResult 'AzureContext' 'FAIL' 'No Az context is available.'
    } else {
        if ($SubscriptionId -and $ctx.Subscription.Id -ne $SubscriptionId) {
            Add-PreflightResult 'AzureContext' 'FAIL' 'Subscription mismatch.'
        }
        if ($TenantId -and $ctx.Tenant.Id -ne $TenantId) {
            Add-PreflightResult 'AzureContext' 'FAIL' 'Tenant mismatch.'
        }
    }

    if (-not $SkipArc) {
        Import-Module Az.ConnectedMachine -ErrorAction Stop
        foreach ($name in @($spec.nodes.name)) {
            try {
                $machine = Get-AzConnectedMachine `
                    -ResourceGroupName $spec.deployment.resourceGroup `
                    -Name $name -ErrorAction Stop
                if ($machine.Status -ne 'Connected') {
                    Add-PreflightResult ('AzureArc {0}' -f $name) 'FAIL' ('Status={0}' -f $machine.Status)
                }
            } catch {
                Add-PreflightResult ('AzureArc {0}' -f $name) 'FAIL' $_.Exception.Message
            }
        }
    }
}

$results | Format-Table -AutoSize
Write-Host ('SUMMARY: {0} failures, {1} warnings' -f $errors.Count, $warnings.Count)
if ($errors.Count -gt 0) { throw ($errors -join ' | ') }
Write-Host 'ZCOFFEE vNext preflight passed.' -ForegroundColor Green
