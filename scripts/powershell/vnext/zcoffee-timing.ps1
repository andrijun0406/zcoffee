<#
.SYNOPSIS
    Compatibility wrapper for timing helpers.
.DESCRIPTION
    Dot-sources lib/Timing.ps1 to provide timing functions without duplicating logic.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Timing.ps1')

