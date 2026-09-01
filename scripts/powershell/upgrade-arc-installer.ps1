#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NodeIP,

    [Parameter(Mandatory = $true)]
    [System.Management.Automation.PSCredential]$Credential,

    [string]$SourceNodeIP = '10.8.230.232',
    [ValidateSet('HTTP','HTTPS')]
    [string]$Transport = 'HTTP',
    [int]$Port,
    [switch]$SkipSourceCopy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Port) {
    $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 }
}

function New-NodeSession {
    param([string]$ComputerName)

    $args = @{
        ComputerName = $ComputerName
        Credential   = $Credential
        Port         = $Port
        ErrorAction  = 'Stop'
    }
    if ($Transport -eq 'HTTPS') { $args['UseSSL'] = $true }
    New-PSSession @args
}

$inspect = {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $moduleName = 'AzSHCI.ARCInstaller'
    $mods = @(Get-Module -ListAvailable -Name $moduleName |
        Sort-Object Version -Descending)

    if ($mods.Count -eq 0) {
        return [pscustomobject]@{
            Node                          = $env:COMPUTERNAME
            ModuleVersion                 = $null
            ModulePath                    = $null
            ModuleBase                    = $null
            SupportsTargetSolutionVersion = $false
            SupportsArcGatewayID          = $false
        }
    }

    $best = $mods[0]
    Remove-Module $moduleName -Force -ErrorAction SilentlyContinue
    Import-Module $best.Path -Force -ErrorAction Stop
    $cmd = Get-Command Invoke-AzStackHciArcInitialization -ErrorAction Stop

    [pscustomobject]@{
        Node                          = $env:COMPUTERNAME
        ModuleVersion                 = $best.Version.ToString()
        ModulePath                    = $best.Path
        ModuleBase                    = $best.ModuleBase
        SupportsTargetSolutionVersion = ($cmd.Parameters.Keys -contains 'TargetSolutionVersion')
        SupportsArcGatewayID          = ($cmd.Parameters.Keys -contains 'ArcGatewayID')
    }
}

$verify = {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $moduleName = 'AzSHCI.ARCInstaller'
    $mods = @(Get-Module -ListAvailable -Name $moduleName |
        Sort-Object Version -Descending)
    if ($mods.Count -eq 0) {
        throw "$moduleName is not installed."
    }
    $best = $mods[0]
    Remove-Module $moduleName -Force -ErrorAction SilentlyContinue
    Import-Module $best.Path -Force -ErrorAction Stop
    $cmd = Get-Command Invoke-AzStackHciArcInitialization -ErrorAction Stop
    [pscustomobject]@{
        Node                          = $env:COMPUTERNAME
        ModuleVersion                 = $best.Version.ToString()
        ModulePath                    = $best.Path
        SupportsTargetSolutionVersion = ($cmd.Parameters.Keys -contains 'TargetSolutionVersion')
        SupportsArcGatewayID          = ($cmd.Parameters.Keys -contains 'ArcGatewayID')
    }
}

$source = $null
$target = $null
$archiveLocal = Join-Path $env:TEMP ('zcoffee-arcinstaller-{0}.zip' -f ([guid]::NewGuid().ToString('N')))
$archiveRemoteName = 'zcoffee-arcinstaller.zip'

try {
    Write-Host "Inspecting target node $NodeIP..." -ForegroundColor Cyan
    $target = New-NodeSession -ComputerName $NodeIP
    $targetBefore = Invoke-Command -Session $target -ScriptBlock $inspect
    $targetBefore | Format-List

    if ($targetBefore.SupportsTargetSolutionVersion -and
        $targetBefore.SupportsArcGatewayID) {
        Write-Host 'Target already supports Arc Gateway and TargetSolutionVersion.' -ForegroundColor Green
        return $targetBefore
    }

    if ($SkipSourceCopy) {
        throw 'Target lacks TargetSolutionVersion support and -SkipSourceCopy was specified.'
    }

    if ($SourceNodeIP -eq $NodeIP) {
        throw 'SourceNodeIP must be different from NodeIP.'
    }

    Write-Host "Inspecting known-good source node $SourceNodeIP..." -ForegroundColor Cyan
    $source = New-NodeSession -ComputerName $SourceNodeIP
    $sourceInfo = Invoke-Command -Session $source -ScriptBlock $inspect
    $sourceInfo | Format-List

    if (-not $sourceInfo.ModuleBase) {
        throw "No $($sourceInfo.ModuleVersion) module found on source node $SourceNodeIP."
    }
    if (-not $sourceInfo.SupportsTargetSolutionVersion) {
        throw "Source node $SourceNodeIP does not support TargetSolutionVersion; refusing to copy an unsuitable module."
    }
    if (-not $sourceInfo.SupportsArcGatewayID) {
        throw "Source node $SourceNodeIP does not support ArcGatewayID; refusing to copy an unsuitable module."
    }

    $remoteArchive = Join-Path $env:TEMP $archiveRemoteName
    Invoke-Command -Session $source -ScriptBlock {
        param($moduleBase, $archivePath)
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force
        }
        Compress-Archive -Path (Join-Path $moduleBase '*') `
            -DestinationPath $archivePath -Force -ErrorAction Stop
    } -ArgumentList $sourceInfo.ModuleBase, $remoteArchive | Out-Null

    Write-Host 'Copying the known-good module to the jump host...' -ForegroundColor Yellow
    Copy-Item -FromSession $source -LiteralPath $remoteArchive `
        -Destination $archiveLocal -Force -ErrorAction Stop

    $targetModuleRoot = Split-Path $targetBefore.ModuleBase -Parent
    $targetArchive = Join-Path $env:TEMP $archiveRemoteName
    Write-Host "Copying module to $NodeIP..." -ForegroundColor Yellow
    Copy-Item -ToSession $target -LiteralPath $archiveLocal `
        -Destination $targetArchive -Force -ErrorAction Stop

    Invoke-Command -Session $target -ScriptBlock {
        param($archivePath, $moduleBase)
        $parent = Split-Path $moduleBase -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        if (Test-Path -LiteralPath $moduleBase) {
            Remove-Item -LiteralPath $moduleBase -Recurse -Force
        }
        New-Item -ItemType Directory -Path $moduleBase -Force | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $moduleBase -Force
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    } -ArgumentList $targetBefore.ModuleBase, $targetBefore.ModuleBase | Out-Null

    Write-Host 'Verifying module capability in a fresh remote PowerShell process...' -ForegroundColor Cyan
    $after = Invoke-Command -Session $target -ScriptBlock {
        $script = @'
$ErrorActionPreference = 'Stop'
$moduleName = 'AzSHCI.ARCInstaller'
$mods = @(Get-Module -ListAvailable -Name $moduleName | Sort-Object Version -Descending)
if ($mods.Count -eq 0) { throw "No $moduleName module found." }
Import-Module $mods[0].Path -Force -ErrorAction Stop
$cmd = Get-Command Invoke-AzStackHciArcInitialization -ErrorAction Stop
[pscustomobject]@{
    Node = $env:COMPUTERNAME
    ModuleVersion = $mods[0].Version.ToString()
    ModulePath = $mods[0].Path
    SupportsTargetSolutionVersion = ($cmd.Parameters.Keys -contains 'TargetSolutionVersion')
    SupportsArcGatewayID = ($cmd.Parameters.Keys -contains 'ArcGatewayID')
}
'@
        $path = Join-Path $env:TEMP 'zcoffee-verify-arcinstaller.ps1'
        Set-Content -LiteralPath $path -Value $script -Encoding UTF8
        try {
            & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive `
                -ExecutionPolicy Bypass -File $path
            if ($LASTEXITCODE -ne 0) { throw "Verification process exited with $LASTEXITCODE." }
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    $after | Format-List

    if (-not $after.SupportsTargetSolutionVersion) {
        throw 'Module copy completed, but TargetSolutionVersion is still unavailable.'
    }
    if (-not $after.SupportsArcGatewayID) {
        throw 'Module copy completed, but ArcGatewayID is unavailable.'
    }

    Write-Host 'Arc installer upgrade completed successfully.' -ForegroundColor Green
    $after
}
finally {
    if ($source) {
        Invoke-Command -Session $source -ScriptBlock {
            Remove-Item -LiteralPath (Join-Path $env:TEMP 'zcoffee-arcinstaller.zip') `
                -Force -ErrorAction SilentlyContinue
        } -ErrorAction SilentlyContinue | Out-Null
        Remove-PSSession $source -ErrorAction SilentlyContinue
    }
    if ($target) {
        Remove-PSSession $target -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $archiveLocal -Force -ErrorAction SilentlyContinue
}
