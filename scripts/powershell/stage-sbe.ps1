<#
.SYNOPSIS
    Stage a validated SBE bundle to Azure Local nodes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string[]]$NodeIPs,
    [string]$LocalAdminUser = 'Administrator',
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTP','HTTPS')][string]$Transport = 'HTTP',
    [int]$Port,
    [switch]$SkipCertCheck,
    [Parameter(Mandatory=$true)][string]$SbeSourcePath,
    [string]$RemoteSbePath = 'C:\SBE',
    [switch]$Apply,
    [switch]$ReplaceRemoteSbe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Write-Host ('[ZCOFFEE] stage-sbe.ps1 executing: ' + $PSCommandPath) -ForegroundColor Cyan
Write-Host ('[ZCOFFEE] PowerShell: ' + $PSVersionTable.PSVersion) -ForegroundColor Cyan
Write-Host ('[ZCOFFEE] Source: ' + $SbeSourcePath) -ForegroundColor Cyan
Write-Host ('[ZCOFFEE] Nodes: ' + ($NodeIPs -join ', ')) -ForegroundColor Cyan
Write-Host ('[ZCOFFEE] Apply=' + [bool]$Apply + ' ReplaceRemoteSbe=' + [bool]$ReplaceRemoteSbe) -ForegroundColor Cyan

. (Join-Path $PSScriptRoot 'ui-common.ps1')

if (-not $Port) { $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 } }
if ($LocalAdminUser -notmatch '[\\@]') { $authUser = '.\' + $LocalAdminUser } else { $authUser = $LocalAdminUser }

function Get-SbeFiles {
    param([Parameter(Mandatory=$true)][string]$Root)
    if (-not (Test-Path -Path $Root -PathType Container)) {
        throw "SBE source directory not found: $Root"
    }
    $all = @(Get-ChildItem -Path $Root -Recurse -File -ErrorAction Stop)
    $selected = @($all | Where-Object {
        $_.Extension -in @('.xml','.zip','.cab','.msu') -and
        $_.Name -notmatch '^\.'
    })
    if (@($selected | Where-Object { $_.Extension -ieq '.xml' }).Count -eq 0) {
        throw "No XML SBE manifest found under: $Root"
    }
    if (@($selected | Where-Object { $_.Extension -in @('.zip','.cab','.msu') }).Count -eq 0) {
        throw "No ZIP/CAB/MSU SBE payload found under: $Root"
    }
    return @($selected | Sort-Object FullName)
}

function Get-RemoteSummary {
    param([Parameter(Mandatory=$true)][System.Management.Automation.Runspaces.PSSession]$Session,
          [Parameter(Mandatory=$true)][string]$Path)
    $r = Invoke-Command -Session $Session -ScriptBlock {
        param($p)
        $files = @()
        if (Test-Path -Path $p -PathType Container) {
            $files = @(Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue)
        }
        [pscustomobject]@{
            Exists = (Test-Path -Path $p -PathType Container)
            FileCount = $files.Count
            ManifestCount = @($files | Where-Object { $_.Extension -ieq '.xml' }).Count
            PayloadCount = @($files | Where-Object { $_.Extension -in @('.zip','.cab','.msu') }).Count
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        }
    } -ArgumentList $Path
    return @($r | Select-Object -Last 1)
}

$logRoot = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path -Path $logRoot)) { New-Item -Path $logRoot -ItemType Directory -Force | Out-Null }
$sourceFiles = @()
$failures = New-Object System.Collections.ArrayList

try {
    Initialize-Ui -StageName 'stage-sbe' -TotalSteps 3

    Invoke-Step 'Validate local SBE source' {
        $script:sourceFiles = @(Get-SbeFiles -Root $SbeSourcePath)
        Write-Info ('Selected source files: ' + $script:sourceFiles.Count)
        foreach ($f in $script:sourceFiles) { Write-Info ('Source: ' + $f.FullName) }
    }

    Invoke-Step 'Resolve credentials and WinRM connectivity' {
        if ($null -ne $LocalAdminPassword) {
            $script:cred = New-Object System.Management.Automation.PSCredential($authUser,$LocalAdminPassword)
        } else {
            $script:cred = Get-LabNodeCredential -User $authUser
        }
        foreach ($ip in $NodeIPs) {
            if ($Transport -eq 'HTTPS') {
                $so = New-PSSessionOption -SkipCACheck:$SkipCertCheck -SkipCNCheck:$SkipCertCheck
                Test-WSMan -ComputerName $ip -Port $Port -UseSSL -Authentication Negotiate -Credential $script:cred -SessionOption $so -ErrorAction Stop | Out-Null
            } else {
                Test-WSMan -ComputerName $ip -Port $Port -Authentication Negotiate -Credential $script:cred -ErrorAction Stop | Out-Null
            }
            Write-Ok ('WinRM reachable: ' + $ip)
        }
    }

    Invoke-Step 'Stage and verify SBE on every node' {
        foreach ($ip in $NodeIPs) {
            $session = $null
            try {
                Write-Info ($ip + ': opening WinRM session')
                $sessionArgs = @{ ComputerName=$ip; Credential=$script:cred; Port=$Port; ErrorAction='Stop' }
                if ($Transport -eq 'HTTPS') {
                    $sessionArgs.UseSSL = $true
                    $sessionArgs.SessionOption = New-PSSessionOption -SkipCACheck:$SkipCertCheck -SkipCNCheck:$SkipCertCheck
                }
                $session = New-PSSession @sessionArgs
                $before = Get-RemoteSummary -Session $session -Path $RemoteSbePath
                Write-Info ($ip + ': remote PowerShell=' + $before.PowerShellVersion)
                Write-Info ($ip + ': before Exists=' + $before.Exists + ' Files=' + $before.FileCount)

                if ($Apply) {
                    $remoteStage = $RemoteSbePath + '.zcoffee-stage-' + [guid]::NewGuid().ToString('N')
                    Invoke-Command -Session $session -ScriptBlock { param($p) New-Item -Path $p -ItemType Directory -Force | Out-Null } -ArgumentList $remoteStage
                    foreach ($file in $script:sourceFiles) {
                        $source = [string]$file.FullName
                        if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -Path $source -PathType Leaf)) { throw ('Missing source file: ' + $source) }
                        Write-Info ($ip + ': copying ' + $file.Name + ' (' + $file.Length + ' bytes)')
                        Copy-Item -Path $source -Destination $remoteStage -ToSession $session -Force -ErrorAction Stop
                    }
                    Invoke-Command -Session $session -ScriptBlock {
                        param($stage,$dest,$replace)
                        if ($replace -and (Test-Path -Path $dest)) { Remove-Item -Path $dest -Recurse -Force }
                        New-Item -Path $dest -ItemType Directory -Force | Out-Null
                        foreach ($f in @(Get-ChildItem -Path $stage -File -Force)) { Copy-Item -Path $f.FullName -Destination $dest -Force }
                        Remove-Item -Path $stage -Recurse -Force
                    } -ArgumentList $remoteStage,$RemoteSbePath,[bool]$ReplaceRemoteSbe
                    Write-Ok ($ip + ': remote copy completed')
                }

                $after = Get-RemoteSummary -Session $session -Path $RemoteSbePath
                if (-not $after.Exists -or $after.ManifestCount -eq 0 -or $after.PayloadCount -eq 0) {
                    throw ($ip + ': SBE gate failed. ManifestCount=' + $after.ManifestCount + ' PayloadCount=' + $after.PayloadCount)
                }
                Write-Ok ($ip + ': SBE verified. Files=' + $after.FileCount + ' Manifests=' + $after.ManifestCount + ' Payloads=' + $after.PayloadCount)
            }
            catch {
                [void]$failures.Add($ip + ' : ' + $_.Exception.Message)
                Write-Err ($ip + ' failed: ' + $_.Exception.Message)
            }
            finally {
                if ($null -ne $session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
            }
        }
        if ($failures.Count -gt 0) { throw ('SBE staging failed: ' + ($failures -join ' | ')) }
    }
    Complete-Ui -FinalMessage 'SBE staging completed.'
}
catch {
    Write-Err $_.Exception.Message
    Write-Host '===== FULL EXCEPTION =====' -ForegroundColor Red
    $_ | Format-List * -Force
    Write-Host '===== POSITION =====' -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage
    Write-Host '===== SCRIPT STACK =====' -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Complete-Ui -Failed -FinalMessage 'SBE staging failed.'
    throw
}
