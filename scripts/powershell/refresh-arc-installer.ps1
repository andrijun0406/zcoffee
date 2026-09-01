<#
.SYNOPSIS
    Refresh AzsHci.ARCInstaller on an Azure Local node.
.DESCRIPTION
    Use before Stage 4 registration when Invoke-AzStackHciArcInitialization
    lacks TargetSolutionVersion. This changes only the PowerShell module on
    the selected node; it does not disconnect or delete Azure resources.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$NodeIP,
    [Parameter(Mandatory=$true)][System.Management.Automation.PSCredential]$Credential
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$remote = {
    Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    if (Get-Command Install-PackageProvider -ErrorAction SilentlyContinue) {
        try { Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
    Install-Module AzsHci.ARCInstaller -Repository PSGallery -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
    Remove-Module AzsHci.ARCInstaller -Force -ErrorAction SilentlyContinue
    $mods = @(Get-Module -ListAvailable -Name AzsHci.ARCInstaller | Sort-Object Version -Descending)
    if ($mods.Count -eq 0) { throw 'AzsHci.ARCInstaller was not found after installation.' }
    Import-Module $mods[0].Path -Force -ErrorAction Stop
    $cmd = Get-Command Invoke-AzStackHciArcInitialization -ErrorAction Stop
    [pscustomobject]@{
        Node=$env:COMPUTERNAME
        ModuleVersion=[string]$mods[0].Version
        ModulePath=$mods[0].Path
        SupportsTargetSolutionVersion=($cmd.Parameters.Keys -contains 'TargetSolutionVersion')
        SupportsArcGatewayID=($cmd.Parameters.Keys -contains 'ArcGatewayID')
    }
}
Invoke-Command -ComputerName $NodeIP -Credential $Credential -Authentication Negotiate -Port 5985 -ScriptBlock $remote
