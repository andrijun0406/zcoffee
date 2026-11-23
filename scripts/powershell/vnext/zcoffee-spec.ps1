<#
.SYNOPSIS
    Compatibility wrapper for spec/profile loading.
.DESCRIPTION
    Delegates to lib/Spec.ps1 to avoid duplicated YAML loading logic.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SpecFile,
    [string]$ProfileFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Spec.ps1')

$loaded = Import-ZcoffeeDeploymentSpec -SpecFile $SpecFile -ProfileFile $ProfileFile
[pscustomobject]@{
    Spec        = $loaded.Spec
    Profile     = $loaded.Profile
    SpecPath    = $loaded.SpecPath
    ProfilePath = $loaded.ProfilePath
    SpecDirectory = $loaded.SpecDirectory
}

