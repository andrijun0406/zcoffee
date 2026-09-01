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
    Invoke-Command -Session $s -ScriptBlock {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $moduleName = 'AzSHCI.ARCInstaller'

        $before = @(Get-Module -ListAvailable -Name $moduleName |
            Sort-Object Version -Descending)
        $beforeCommand = $null
        if ($before.Count -gt 0) {
            $beforeCommand = Get-Command Invoke-AzStackHciArcInitialization `
                -Module $moduleName -ErrorAction SilentlyContinue
        }

        if ($beforeCommand -and
            ($beforeCommand.Parameters.Keys -contains 'TargetSolutionVersion')) {
            [pscustomobject]@{
                Node                          = $env:COMPUTERNAME
                Action                        = 'Already supported'
                ModuleVersion                 = $before[0].Version.ToString()
                ModulePath                    = $before[0].Path
                SupportsTargetSolutionVersion = $true
                SupportsArcGatewayID          = ($beforeCommand.Parameters.Keys -contains 'ArcGatewayID')
            }
            return
        }

        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
                -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "NuGet provider setup returned: $($_.Exception.Message)"
        }

        try {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted `
                -ErrorAction Stop
        } catch {
            Write-Warning "Could not set PSGallery trust policy: $($_.Exception.Message)"
        }

        $available = @(Find-Module -Name $moduleName -Repository PSGallery `
            -ErrorAction Stop)
        if ($available.Count -eq 0) {
            throw "No PSGallery module found for $moduleName."
        }

        $latest = $available | Sort-Object Version -Descending | Select-Object -First 1
        Install-Module -Name $moduleName -Repository PSGallery `
            -RequiredVersion $latest.Version -Force -AllowClobber `
            -Scope AllUsers -ErrorAction Stop

        $installed = @(Get-Module -ListAvailable -Name $moduleName |
            Sort-Object Version -Descending)
        if ($installed.Count -eq 0) {
            throw "$moduleName was not found after installation."
        }

        $selected = $installed[0]
        Import-Module $selected.Path -Force -ErrorAction Stop
        $afterCommand = Get-Command Invoke-AzStackHciArcInitialization `
            -Module $moduleName -ErrorAction Stop
        $supportsTarget = ($afterCommand.Parameters.Keys -contains 'TargetSolutionVersion')
        $supportsGateway = ($afterCommand.Parameters.Keys -contains 'ArcGatewayID')

        if (-not $supportsTarget) {
            throw "Installed $moduleName version $($selected.Version) still does not support TargetSolutionVersion."
        }

        [pscustomobject]@{
            Node                          = $env:COMPUTERNAME
            Action                        = 'Upgraded'
            ModuleVersion                 = $selected.Version.ToString()
            ModulePath                    = $selected.Path
            SupportsTargetSolutionVersion = $supportsTarget
            SupportsArcGatewayID          = $supportsGateway
        }
    }
}
finally {
    Remove-PSSession $s -ErrorAction SilentlyContinue
}
