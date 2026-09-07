[CmdletBinding()]
param(
    [string[]]$NodeIPs = @('10.8.230.232','10.8.230.235'),
    [string]$LocalAdminUser = 'Administrator',
    [SecureString]$LocalAdminPassword,
    [string]$OutputRoot,
    [switch]$SkipPanther
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$uiPath = Join-Path $scriptRoot 'ui-common.ps1'
if (Test-Path -LiteralPath $uiPath) { . $uiPath }

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $scriptRoot ('logs\reimage-artifacts-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$jumpLogRoot = Join-Path $OutputRoot 'jump-host'
New-Item -ItemType Directory -Path $jumpLogRoot -Force | Out-Null

if ($PSBoundParameters.ContainsKey('LocalAdminPassword')) {
    $credentialUser = if ($LocalAdminUser -match '[\\@]') { $LocalAdminUser } else { '.\' + $LocalAdminUser }
    $credential = New-Object System.Management.Automation.PSCredential($credentialUser, $LocalAdminPassword)
} elseif (Get-Command Get-LabNodeCredential -ErrorAction SilentlyContinue) {
    $credential = Get-LabNodeCredential -User $LocalAdminUser
} else {
    $user = if ($LocalAdminUser -match '[\\@]') { $LocalAdminUser } else { '.\' + $LocalAdminUser }
    $credential = Get-Credential -UserName $user -Message 'Enter node local-admin password'
}

$remoteSnapshot = {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    $arc = Join-Path ${env:ProgramFiles} 'AzureConnectedMachineAgent\azcmagent.exe'
    $arcJson = $null
    if (Test-Path -LiteralPath $arc) {
        try { $arcJson = ((& $arc show -j 2>$null | Out-String) | ConvertFrom-Json) } catch { }
    }

    $logs = @(
        'C:\Windows\Temp\bootdisk-select.log',
        'C:\bootdisk-select.log',
        'C:\Windows\Temp\netbootstrap.log',
        'C:\Windows\Temp\netbootstrap-cmd.log',
        'C:\Bootstrap\success.txt'
    )
    if (-not $using:SkipPanther) {
        $logs += 'C:\Windows\Panther\setuperr.log'
        $logs += 'C:\Windows\Panther\setupact.log'
    }

    [pscustomobject]@{
        Node              = $env:COMPUTERNAME
        Timestamp         = (Get-Date).ToString('o')
        Caption           = $os.Caption
        Version           = $os.Version
        Build             = '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR
        DisplayVersion    = $cv.DisplayVersion
        ProductName       = $cv.ProductName
        ArcStatus         = if ($arcJson) { $arcJson.status } else { $null }
        ArcAgentVersion   = if ($arcJson) { $arcJson.agentVersion } else { $null }
        ArcConnectionType = if (Test-Path -LiteralPath $arc) { ((& $arc config get connection.type 2>$null | Out-String).Trim()) } else { $null }
        ExistingLogs      = @($logs | Where-Object { Test-Path -LiteralPath $_ })
        Disks             = @(Get-CimInstance Win32_DiskDrive | Select-Object Index,Model,Size,InterfaceType,SerialNumber)
        Adapters          = @(Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name,Status,LinkSpeed,MacAddress,InterfaceDescription)
    }
}

try {
    Write-Host "Collecting reimage artifacts into $OutputRoot" -ForegroundColor Cyan

    $ipIndex = 0
    foreach ($ip in $NodeIPs) {
        $ipIndex++
        $nodeDir = Join-Path $OutputRoot ('node-{0}-{1}' -f $ipIndex, $ip.Replace('.','-'))
        New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
        $session = $null

        try {
            Write-Host "Connecting to $ip ..." -ForegroundColor Yellow
            $session = New-PSSession -ComputerName $ip -Credential $credential -Authentication Negotiate -Port 5985 -ErrorAction Stop
            $snapshot = Invoke-Command -Session $session -ScriptBlock $remoteSnapshot -ErrorAction Stop
            $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $nodeDir 'node-snapshot.json') -Encoding UTF8

            $remotePaths = @(
                @{ Path = 'C:\Windows\Temp\bootdisk-select.log'; Name = 'bootdisk-select-windows-temp.log' },
                @{ Path = 'C:\bootdisk-select.log'; Name = 'bootdisk-select-root.log' },
                @{ Path = 'C:\Windows\Temp\netbootstrap.log'; Name = 'netbootstrap.log' },
                @{ Path = 'C:\Windows\Temp\netbootstrap-cmd.log'; Name = 'netbootstrap-cmd.log' },
                @{ Path = 'C:\Bootstrap\success.txt'; Name = 'bootstrap-success.txt' }
            )
            if (-not $SkipPanther) {
                $remotePaths += @{ Path = 'C:\Windows\Panther\setuperr.log'; Name = 'setuperr.log' }
                $remotePaths += @{ Path = 'C:\Windows\Panther\setupact.log'; Name = 'setupact.log' }
            }

            foreach ($item in $remotePaths) {
                $exists = Invoke-Command -Session $session -ScriptBlock {
                    param($p)
                    Test-Path -LiteralPath $p
                } -ArgumentList $item.Path -ErrorAction Stop

                if ($exists) {
                    $destination = Join-Path $nodeDir $item.Name
                    Copy-Item -FromSession $session -LiteralPath $item.Path -Destination $destination -Force -ErrorAction Stop
                    Write-Host "  copied $($item.Path)" -ForegroundColor Green
                } else {
                    Write-Host "  absent  $($item.Path)" -ForegroundColor DarkYellow
                }
            }
        }
        catch {
            $errorText = $_ | Out-String
            $errorText | Set-Content -LiteralPath (Join-Path $nodeDir 'collection-error.txt') -Encoding UTF8
            Write-Warning "$ip collection failed: $($_.Exception.Message)"
        }
        finally {
            if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
        }
    }

    $localPatterns = @(
        '01-deploy-os-parallel-*.log',
        'deploy-os-*.log',
        'serve-iso-*.log',
        '02-configure-network-*.log',
        '03-prepare-node-*.log'
    )
    foreach ($pattern in $localPatterns) {
        Get-ChildItem -Path (Join-Path $scriptRoot 'logs') -Filter $pattern -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $jumpLogRoot $_.Name) -Force }
    }

    Write-Host "`nCollection complete: $OutputRoot" -ForegroundColor Green
    Get-ChildItem -Path $OutputRoot -Recurse -File | Select-Object FullName,Length
}
catch {
    Write-Error $_.Exception.Message
    throw
}
