#requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$NodeIPs = @('10.8.230.232', '10.8.230.235'),
    [string]$LocalAdminUser = 'Administrator',
    [SecureString]$LocalAdminPassword,
    [string]$OutputRoot,
    [switch]$SkipPanther,
    [switch]$SkipSetupEvents,
    [switch]$SkipArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$uiPath = Join-Path $scriptRoot 'ui-common.ps1'
if (Test-Path -LiteralPath $uiPath) {
    . $uiPath
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $scriptRoot ('logs\reimage-artifacts-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$jumpLogRoot = Join-Path $OutputRoot 'jump-host'
New-Item -ItemType Directory -Path $jumpLogRoot -Force | Out-Null

if ($PSBoundParameters.ContainsKey('LocalAdminPassword')) {
    $credentialUser = if ($LocalAdminUser -match '[\\@]') { $LocalAdminUser } else { '.\' + $LocalAdminUser }
    $credential = New-Object System.Management.Automation.PSCredential($credentialUser, $LocalAdminPassword)
}
elseif (Get-Command Get-LabNodeCredential -ErrorAction SilentlyContinue) {
    $credential = Get-LabNodeCredential -User $LocalAdminUser
}
else {
    $credentialUser = if ($LocalAdminUser -match '[\\@]') { $LocalAdminUser } else { '.\' + $LocalAdminUser }
    $credential = Get-Credential -UserName $credentialUser -Message 'Enter node local-admin password'
}

function Get-CleanArtifactText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes)
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    else {
        $ansiText = [System.Text.Encoding]::Default.GetString($bytes)
        $nullCount = ([regex]::Matches($ansiText, [char]0)).Count
        if ($nullCount -gt 0) {
            $utf16Text = [System.Text.Encoding]::Unicode.GetString($bytes)
            if ($utf16Text -match '(?i)boot|DELLBOSS|diskpart|Index|Model') {
                $text = $utf16Text
            }
            else {
                $text = $ansiText
            }
        }
        else {
            $text = $ansiText
        }
    }

    return $text.Replace([char]0, '')
}

function Save-CleanLog {
    param(
        [Parameter(Mandatory = $true)][string]$RawPath,
        [Parameter(Mandatory = $true)][string]$CleanPath
    )

    $text = Get-CleanArtifactText -Path $RawPath
    Set-Content -LiteralPath $CleanPath -Value $text -Encoding UTF8
}

function New-BootdiskSummary {
    param(
        [Parameter(Mandatory = $true)][string]$CleanPath,
        [Parameter(Mandatory = $true)][string]$SummaryPath
    )

    $patterns = @(
        '(?i)FINAL_BOSS_INDEX',
        '(?i)SELECTED_BOSS_INDEX',
        '(?i)diskpart.*exit',
        '(?i)Boot disk prepared',
        '(?i)FAILURE',
        '(?i)RESULT'
    )
    $lines = @(Get-Content -LiteralPath $CleanPath -ErrorAction SilentlyContinue)
    $hits = @($lines | Where-Object {
        $line = $_
        ($patterns | Where-Object { $line -match $_ }).Count -gt 0
    })
    if ($hits.Count -eq 0) {
        $hits = @('No boot-disk summary markers found.')
    }
    Set-Content -LiteralPath $SummaryPath -Value $hits -Encoding UTF8
}

function New-NetworkBootstrapSummary {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$SummaryPath
    )

    $patterns = @(
        '(?i)service.?tag',
        '(?i)hostname|computername',
        '(?i)ip(address)?|ipv4',
        '(?i)vlan',
        '(?i)winrm',
        '(?i)link.?speed',
        '(?i)dns|gateway',
        '(?i)success|complete|result'
    )
    $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
    $hits = @($lines | Where-Object {
        $line = $_
        ($patterns | Where-Object { $line -match $_ }).Count -gt 0
    })
    if ($hits.Count -eq 0) {
        $hits = @('No network-bootstrap summary markers found.')
    }
    Set-Content -LiteralPath $SummaryPath -Value $hits -Encoding UTF8
}

$remoteSnapshot = {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    $logPaths = @(
        'C:\Windows\Temp\bootdisk-select.log',
        'C:\bootdisk-select.log',
        'C:\Windows\Temp\netbootstrap.log',
        'C:\Windows\Temp\netbootstrap-cmd.log',
        'C:\Bootstrap\success.txt',
        'C:\Windows\Panther\setupact.log',
        'C:\Windows\Panther\setuperr.log',
        'C:\Windows\Panther\UnattendGC\setupact.log',
        'C:\Windows\Panther\UnattendGC\setuperr.log'
    )

    [pscustomobject]@{
        Node             = $env:COMPUTERNAME
        Timestamp        = (Get-Date).ToString('o')
        Caption          = $os.Caption
        Version          = $os.Version
        Build            = '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR
        DisplayVersion   = $cv.DisplayVersion
        ProductName      = $cv.ProductName
        WindowsBTExists  = Test-Path -LiteralPath 'C:\$WINDOWS.~BT'
        SbePathExists    = Test-Path -LiteralPath 'C:\SBE'
        SbeFileCount     = @(Get-ChildItem -LiteralPath 'C:\SBE' -Recurse -File -ErrorAction SilentlyContinue).Count
        ExistingLogs     = @($logPaths | Where-Object { Test-Path -LiteralPath $_ })
        Disks            = @(Get-CimInstance Win32_DiskDrive | Select-Object Index, Model, Size, InterfaceType, SerialNumber)
        Adapters         = @(Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, Status, LinkSpeed, MacAddress, InterfaceDescription)
    }
}

$remoteEventText = {
    try {
        Get-WinEvent -LogName 'Setup' -MaxEvents 500 -ErrorAction Stop |
            ForEach-Object {
                "[{0}] Id={1} Level={2} Provider={3}`r`n{4}`r`n" -f `
                    $_.TimeCreated, $_.Id, $_.LevelDisplayName, $_.ProviderName, $_.Message
            }
    }
    catch {
        'Get-WinEvent Setup collection failed: ' + $_.Exception.Message
    }
}

try {
    Write-Host "Collecting Stage 1 deployment artifacts into $OutputRoot" -ForegroundColor Cyan

    $ipIndex = 0
    foreach ($ip in $NodeIPs) {
        $ipIndex++
        $nodeDir = Join-Path $OutputRoot ('node-{0}-{1}' -f $ipIndex, $ip.Replace('.', '-'))
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
                $remotePaths += @{ Path = 'C:\Windows\Panther\setupact.log'; Name = 'setupact.log' }
                $remotePaths += @{ Path = 'C:\Windows\Panther\setuperr.log'; Name = 'setuperr.log' }
                $remotePaths += @{ Path = 'C:\Windows\Panther\UnattendGC\setupact.log'; Name = 'unattendgc-setupact.log' }
                $remotePaths += @{ Path = 'C:\Windows\Panther\UnattendGC\setuperr.log'; Name = 'unattendgc-setuperr.log' }
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
                }
                else {
                    Write-Host "  absent  $($item.Path)" -ForegroundColor DarkYellow
                }
            }

            if (-not $SkipSetupEvents) {
                $events = Invoke-Command -Session $session -ScriptBlock $remoteEventText -ErrorAction Stop
                $events | Set-Content -LiteralPath (Join-Path $nodeDir 'setup-events.txt') -Encoding UTF8
                Write-Host '  collected Setup event log' -ForegroundColor Green
            }

            $rawBoot = @(
                (Join-Path $nodeDir 'bootdisk-select-root.log'),
                (Join-Path $nodeDir 'bootdisk-select-windows-temp.log')
            ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($rawBoot) {
                $cleanBoot = Join-Path $nodeDir 'bootdisk-select-clean.log'
                Save-CleanLog -RawPath $rawBoot -CleanPath $cleanBoot
                New-BootdiskSummary -CleanPath $cleanBoot -SummaryPath (Join-Path $nodeDir 'bootdisk-summary.txt')
                Write-Host '  generated boot-disk clean log and summary' -ForegroundColor Green
            }

            $networkLog = Join-Path $nodeDir 'netbootstrap.log'
            if (Test-Path -LiteralPath $networkLog) {
                New-NetworkBootstrapSummary -LogPath $networkLog -SummaryPath (Join-Path $nodeDir 'netbootstrap-summary.txt')
                Write-Host '  generated network-bootstrap summary' -ForegroundColor Green
            }
        }
        catch {
            ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $nodeDir 'collection-error.txt') -Encoding UTF8
            Write-Warning "$ip collection failed: $($_.Exception.Message)"
        }
        finally {
            if ($session) {
                Remove-PSSession $session -ErrorAction SilentlyContinue
            }
        }
    }

    $localPatterns = @(
        '01-deploy-os-parallel-*.log',
        'deploy-os-*.log',
        'serve-iso-*.log',
        'make-golden-with-unattend-*.log',
        'preflight-os-*.log',
        'prepare-hardware-*.log'
    )
    $localLogDir = Join-Path $scriptRoot 'logs'
    foreach ($pattern in $localPatterns) {
        Get-ChildItem -Path $localLogDir -Filter $pattern -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                Copy-Item $_.FullName (Join-Path $jumpLogRoot $_.Name) -Force
            }
    }

    $manifest = [ordered]@{
        CollectedAt       = (Get-Date).ToString('o')
        Collector         = 'collect-reimage-artifacts.ps1'
        Scope             = 'Stage 1 deployment forensics only'
        NodeIPs           = @($NodeIPs)
        ArcMetadata       = $false
        AzureQueries       = $false
        SkipPanther       = [bool]$SkipPanther
        SkipSetupEvents   = [bool]$SkipSetupEvents
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputRoot 'collection-manifest.json') -Encoding UTF8

    $archivePath = $null
    if (-not $SkipArchive) {
        $archivePath = "$OutputRoot.zip"
        $items = @(Get-ChildItem -LiteralPath $OutputRoot -Force)
        if ($items.Count -gt 0) {
            Compress-Archive -Path $items.FullName -DestinationPath $archivePath -Force
        }
    }

    Write-Host "`nCollection complete: $OutputRoot" -ForegroundColor Green
    if ($archivePath) {
        Write-Host "Archive: $archivePath" -ForegroundColor Green
    }
    Get-ChildItem -Path $OutputRoot -Recurse -File | Select-Object FullName, Length
}
catch {
    Write-Error $_.Exception.Message
    throw
}
