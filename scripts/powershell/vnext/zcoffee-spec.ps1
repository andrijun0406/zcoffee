<#
.SYNOPSIS
    Load the ZCOFFEE vNext YAML deployment spec and hardware profile.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SpecFile,
    [string]$ProfileFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-ZcoffeeYaml {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml is required. Install-Module powershell-yaml -Scope CurrentUser"
    }
    Import-Module powershell-yaml -ErrorAction Stop
    if (-not (Test-Path -Path $Path -PathType Leaf)) { throw "YAML file not found: $Path" }
    ConvertFrom-Yaml -Yaml (Get-Content -Path $Path -Raw)
}

$spec = Import-ZcoffeeYaml -Path (Resolve-Path -Path $SpecFile).Path
$profile = $null
if ($ProfileFile) { $profile = Import-ZcoffeeYaml -Path (Resolve-Path -Path $ProfileFile).Path }
[pscustomobject]@{ Spec = $spec; Profile = $profile; SpecPath = (Resolve-Path -Path $SpecFile).Path; ProfilePath = if ($ProfileFile) { (Resolve-Path -Path $ProfileFile).Path } else { $null } }
