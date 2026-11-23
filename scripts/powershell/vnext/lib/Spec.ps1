<#
.SYNOPSIS
    ZCOFFEE vNext spec/profile loading and validation helpers.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-ZcoffeeYamlFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml is required. Install with: Install-Module powershell-yaml -Scope CurrentUser"
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $resolved = (Resolve-Path -Path $Path -ErrorAction Stop).Path
    if (-not (Test-Path -Path $resolved -PathType Leaf)) {
        throw "YAML file not found: $resolved"
    }

    $raw = Get-Content -Path $resolved -Raw -ErrorAction Stop
    $obj = ConvertFrom-Yaml -Yaml $raw
    [pscustomobject]@{
        Path = $resolved
        Data = $obj
    }
}

function Resolve-ZcoffeePathFromSpec {
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [string]$PathValue
    )
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $PathValue))
}

function Import-ZcoffeeDeploymentSpec {
    param(
        [Parameter(Mandatory)][string]$SpecFile,
        [string]$ProfileFile
    )

    $specDoc = Import-ZcoffeeYamlFile -Path $SpecFile
    $spec = $specDoc.Data
    $specDir = Split-Path -Path $specDoc.Path -Parent

    $profilePath = $ProfileFile
    if (-not $profilePath -and $spec.hardwareProfile) {
        $profilePath = [string]$spec.hardwareProfile
    }
    $resolvedProfilePath = if ($profilePath) { Resolve-ZcoffeePathFromSpec -BaseDirectory $specDir -PathValue $profilePath } else { $null }

    $profile = $null
    if ($resolvedProfilePath) {
        $profileDoc = Import-ZcoffeeYamlFile -Path $resolvedProfilePath
        $profile = $profileDoc.Data
        $resolvedProfilePath = $profileDoc.Path
    }

    [pscustomobject]@{
        Spec            = $spec
        Profile         = $profile
        SpecPath        = $specDoc.Path
        SpecDirectory   = $specDir
        ProfilePath     = $resolvedProfilePath
    }
}

function Test-ZcoffeeDeploymentSpec {
    param([Parameter(Mandatory)]$LoadedSpec)

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $spec = $LoadedSpec.Spec
    $profile = $LoadedSpec.Profile

    if ($null -eq $spec) { $errors.Add('Spec is empty.') }
    if ($null -eq $spec.nodes -or @($spec.nodes).Count -eq 0) { $errors.Add('Spec must define at least one node in nodes[].') }
    if ($null -eq $spec.deployment) { $errors.Add('Spec must define deployment settings.') }
    if ($null -eq $spec.identity -or [string]::IsNullOrWhiteSpace([string]$spec.identity.localAdminUser)) {
        $warnings.Add('identity.localAdminUser is not set; defaulting to Administrator.')
    }

    if ($spec.deployment) {
        foreach ($k in @('region','resourceGroup','templateFile','parameterFile')) {
            if ([string]::IsNullOrWhiteSpace([string]$spec.deployment.$k)) {
                $errors.Add("deployment.$k is required.")
            }
        }
        foreach ($f in @('templateFile','parameterFile')) {
            $p = [string]$spec.deployment.$f
            if (-not [string]::IsNullOrWhiteSpace($p)) {
                $resolved = Resolve-ZcoffeePathFromSpec -BaseDirectory $LoadedSpec.SpecDirectory -PathValue $p
                if (-not (Test-Path -Path $resolved -PathType Leaf)) {
                    $errors.Add("deployment.$f not found: $resolved")
                }
            }
        }
    }

    if ($null -eq $profile) {
        $warnings.Add('No hardware profile loaded (spec.hardwareProfile missing or not resolved).')
    } elseif ($profile.supportStatus -and ([string]$profile.supportStatus -match 'experimental')) {
        $warnings.Add("Hardware profile supportStatus is experimental: $([string]$profile.supportStatus)")
    }

    [pscustomobject]@{
        IsValid  = ($errors.Count -eq 0)
        Errors   = @($errors)
        Warnings = @($warnings)
    }
}

function Get-ZcoffeeNodeIps {
    param([Parameter(Mandatory)]$Spec)
    @($Spec.nodes | ForEach-Object { [string]$_.hostIp } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ZcoffeeNodeNames {
    param([Parameter(Mandatory)]$Spec)
    @($Spec.nodes | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
