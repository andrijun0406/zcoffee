#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NodeIP,

    [Parameter(Mandatory = $true)]
    [System.Management.Automation.PSCredential]$Credential,

    [switch]$UseSSL,
    [int]$Port = 5985
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sessionArgs = @{
    ComputerName = $NodeIP
    Credential   = $Credential
    ErrorAction  = 'Stop'
    Port         = $Port
}
if ($UseSSL) { $sessionArgs['UseSSL'] = $true }

$s = New-PSSession @sessionArgs
try {
    $result = Invoke-Command -Session $s -ScriptBlock {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $moduleName = 'AzSHCI.ARCInstaller'
        $moduleRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
        $powershell = Join-Path $PSHOME 'powershell.exe'

        function Get-ArcCapability {
            $mods = @(Get-Module -ListAvailable -Name $moduleName |
                Sort-Object Version -Descending)
            if ($mods.Count -eq 0) { return $null }

            $cmd = Get-Command Invoke-AzStackHciArcInitialization `
                -ErrorAction SilentlyContinue
            if (-not $cmd) {
                Import-Module $mods[0].Path -Force -ErrorAction Stop
                $cmd = Get-Command Invoke-AzStackHciArcInitialization `
                    -ErrorAction SilentlyContinue
            }
            if (-not $cmd) { return $null }

            [pscustomobject]@{
                ModuleVersion                 = $mods[0].Version.ToString()
                ModulePath                    = $mods[0].Path
                SupportsTargetSolutionVersion = ($cmd.Parameters.Keys -contains 'TargetSolutionVersion')
                SupportsArcGatewayID          = ($cmd.Parameters.Keys -contains 'ArcGatewayID')
            }
        }

        $before = Get-ArcCapability
        if ($before -and $before.SupportsTargetSolutionVersion) {
            [pscustomobject]@{
                Node                          = $env:COMPUTERNAME
                Action                        = 'Already supported'
                ModuleVersion                 = $before.ModuleVersion
                ModulePath                    = $before.ModulePath
                SupportsTargetSolutionVersion = $before.SupportsTargetSolutionVersion
                SupportsArcGatewayID          = $before.SupportsArcGatewayID
            }
            return
        }

        $bootstrap = Join-Path $env:TEMP 'zcoffee-install-arcinstaller.ps1'
        @'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$moduleName = 'AzSHCI.ARCInstaller'
$moduleRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'

try {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Force -ErrorAction Stop | Out-Null
} catch {
    # The provider may already be installed; Find/Save-Module gives the real error if not.
}

try {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted `
        -ErrorAction Stop
} catch {
    # Continue; an existing repository policy is sufficient.
}

$latest = Find-Module -Name $moduleName -Repository PSGallery `
    -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
if (-not $latest) { throw "No PSGallery package found for $moduleName." }

New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
Save-Module -Name $moduleName `
    -Repository PSGallery `
    -RequiredVersion $latest.Version `
    -Path $moduleRoot `
    -Force `
    -ErrorAction Stop

Write-Output ("Saved {0} {1}" -f $moduleName, $latest.Version)
'@ | Set-Content -LiteralPath $bootstrap -Encoding UTF8

        $stdoutLog = Join-Path $env:TEMP 'zcoffee-install-arcinstaller.stdout.log'
        $stderrLog = Join-Path $env:TEMP 'zcoffee-install-arcinstaller.stderr.log'
        Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $powershell `
            -ArgumentList @(
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy', 'Bypass',
                '-File', $bootstrap
            ) `
            -Wait -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

        if ($p.ExitCode -ne 0) {
            $outDetail = if (Test-Path $stdoutLog) { Get-Content $stdoutLog -Raw } else { '' }
            $errDetail = if (Test-Path $stderrLog) { Get-Content $stderrLog -Raw } else { '' }
            throw "Clean module-save process failed with exit code $($p.ExitCode). $outDetail $errDetail"
        }

        Remove-Item $bootstrap -Force -ErrorAction SilentlyContinue

        # Load the highest available copy only after the child process exits.
        Remove-Module $moduleName -Force -ErrorAction SilentlyContinue
        $after = Get-ArcCapability
        if (-not $after) {
            throw "$moduleName was not discoverable after Save-Module."
        }
        if (-not $after.SupportsTargetSolutionVersion) {
            throw "Latest installed $moduleName version $($after.ModuleVersion) still does not support TargetSolutionVersion."
        }

        [pscustomobject]@{
            Node                          = $env:COMPUTERNAME
            Action                        = 'Upgraded side-by-side'
            ModuleVersion                 = $after.ModuleVersion
            ModulePath                    = $after.ModulePath
            SupportsTargetSolutionVersion = $after.SupportsTargetSolutionVersion
            SupportsArcGatewayID          = $after.SupportsArcGatewayID
        }
    }
    $result
}
finally {
    Remove-PSSession $s -ErrorAction SilentlyContinue
}
