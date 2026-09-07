<#
.SYNOPSIS
    Stage and verify the Dell SBE package on Azure Local nodes.

.DESCRIPTION
    Stage 3 validates whether C:\SBE exists, but does not install or copy an SBE package.
    This script is the explicit pre-deployment staging gate. It supports either a local
    jump-host path (preferred) or an HTTPS download URL, validates the package, copies it
    to every node, and verifies the remote contents.

    This script stages the package only. Azure Local deployment / LCM applies the SBE.
    Azure Update Manager is for post-deployment servicing and is not used here.

    Validate is read-only. Apply is required to copy files to nodes.
#>
[CmdletBinding()]
param(
    [string[]]$NodeIPs,
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTP','HTTPS')]
    [string]$Transport = 'HTTP',
    [int]$Port,
    [switch]$ConfigureTrustedHosts,
    [switch]$SkipCertCheck,

    # Local path wins when both sources are provided.
    [string]$SbeSourcePath,
    [string]$SbeDownloadUrl,
    [string]$SbeSha256,
    [string]$ExpectedSbeVersion,
    [string]$RemoteSbePath = 'C:\SBE',

    [switch]$Apply,
    [switch]$ReplaceRemoteSbe,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Write-Host ('[ZCOFFEE] stage-sbe.ps1 starting: ' + $PSCommandPath) -ForegroundColor Cyan
Write-Host ('[ZCOFFEE] PowerShell: ' + $PSVersionTable.PSVersion) -ForegroundColor DarkCyan
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$bound = $PSBoundParameters

if (-not $bound.ContainsKey('NodeIPs')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeIPs = @($cfg.Nodes | ForEach-Object { $_.HostIP }) }
    else { $NodeIPs = @('10.8.230.232','10.8.230.235') }
}
if (-not $NodeIPs -or $NodeIPs.Count -eq 0) { throw 'At least one node IP is required.' }

if (-not $bound.ContainsKey('LocalAdminUser') -or -not $LocalAdminUser) {
    if ($cfg.ContainsKey('LocalAdminUser')) { $LocalAdminUser = $cfg.LocalAdminUser }
    else { $LocalAdminUser = 'Administrator' }
}
if (-not $Port) { $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 } }
if (-not $bound.ContainsKey('SbeSourcePath') -and $cfg.ContainsKey('SbeSourcePath')) { $SbeSourcePath = $cfg.SbeSourcePath }
if (-not $bound.ContainsKey('SbeDownloadUrl') -and $cfg.ContainsKey('SbeDownloadUrl')) { $SbeDownloadUrl = $cfg.SbeDownloadUrl }
if (-not $bound.ContainsKey('SbeSha256') -and $cfg.ContainsKey('SbeSha256')) { $SbeSha256 = $cfg.SbeSha256 }
if (-not $bound.ContainsKey('ExpectedSbeVersion') -and $cfg.ContainsKey('SbeExpectedVersion')) { $ExpectedSbeVersion = $cfg.SbeExpectedVersion }

$authUser = $LocalAdminUser
if ($authUser -notmatch '[\\@]') { $authUser = ".\$authUser" }

function Test-SbeContent {
    param([Parameter(Mandatory=$true)][string]$Path)

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction Stop)
    $xml = @($files | Where-Object { $_.Extension -ieq '.xml' })
    $archives = @($files | Where-Object { $_.Extension -iin @('.zip','.cab','.msu') })
    if ($xml.Count -eq 0) { throw "SBE package '$Path' contains no XML manifest." }
    if ($archives.Count -eq 0) { throw "SBE package '$Path' contains no ZIP/CAB/MSU payload." }

    $versionText = @($files | Where-Object { $_.Extension -iin @('.xml','.nuspec','.txt') } |
        ForEach-Object {
            try { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop } catch { '' }
        }) -join "`n"

    if ($ExpectedSbeVersion) {
        if ($versionText -notmatch [regex]::Escape($ExpectedSbeVersion) -and
            (($files | Select-Object -ExpandProperty FullName) -join "`n") -notmatch [regex]::Escape($ExpectedSbeVersion)) {
            throw "SBE package does not contain expected version '$ExpectedSbeVersion'."
        }
    }

    [pscustomobject]@{
        FileCount      = $files.Count
        ManifestCount  = $xml.Count
        PayloadCount   = $archives.Count
        ExpectedVersion = $ExpectedSbeVersion
        Files          = @($files | ForEach-Object { $_.Name })
    }
}

function Get-LocalSbeStagingRoot {
    param([string]$SourcePath, [string]$DownloadUrl)

    $root = Join-Path ([IO.Path]::GetTempPath()) ('zcoffee-sbe-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $root -ItemType Directory -Force | Out-Null

    $source = $SourcePath
    if ($source) {
        $resolved = (Resolve-Path -LiteralPath $source -ErrorAction Stop).Path
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            $children = @(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop)
            foreach ($child in $children) {
                Copy-Item -LiteralPath $child.FullName -Destination $root -Recurse -Force
            }
        }
        else {
            Copy-Item -LiteralPath $resolved -Destination $root -Force
        }
    }
    elseif ($DownloadUrl) {
        $uri = [Uri]$DownloadUrl
        $name = [IO.Path]::GetFileName($uri.AbsolutePath)
        if (-not $name) { $name = 'sbe-package.zip' }
        $downloaded = Join-Path $root $name
        Write-Info "Downloading SBE package to $downloaded ..."
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $downloaded -UseBasicParsing -ErrorAction Stop
    }
    else {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    $archives = @(Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Extension -ieq '.zip' })
    foreach ($archive in $archives) {
        $extract = Join-Path $archive.DirectoryName ($archive.BaseName + '.expanded')
        if (-not (Test-Path -LiteralPath $extract)) {
            try {
                Expand-Archive -LiteralPath $archive.FullName -DestinationPath $extract -Force -ErrorAction Stop
                Get-ChildItem -LiteralPath $extract -Force | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination $root -Recurse -Force
                }
            } catch {
                Write-Warn "Could not expand $($archive.Name); retaining the archive for remote staging."
            }
        }
    }

    if ($SbeSha256) {
        $hashCandidates = @(Get-ChildItem -LiteralPath $root -Recurse -File |
            Where-Object { $_.Extension -iin @('.zip','.cab','.msu') })
        if ($hashCandidates.Count -ne 1) {
            throw 'SbeSha256 requires exactly one archive payload in the source.'
        }
        $actual = (Get-FileHash -LiteralPath $hashCandidates[0].FullName -Algorithm SHA256).Hash
        if ($actual -ine $SbeSha256) {
            throw "SBE SHA256 mismatch. Expected $SbeSha256, got $actual."
        }
        Write-Ok "SBE SHA256 verified: $actual"
    }

    return $root
}

Write-Host ('[INFO] Nodes: ' + ($NodeIPs -join ', '))
Write-Host ('[INFO] SBE source: ' + $(if ($SbeSourcePath) { $SbeSourcePath } else { '<none>' }))
Write-Host ('[INFO] Apply: ' + [bool]$Apply + '; ReplaceRemoteSbe: ' + [bool]$ReplaceRemoteSbe)
$totalSteps = 3
Initialize-Ui -StageName 'stage-sbe' -TotalSteps $totalSteps -UseGui:$UseGui
$stagingRoot = $null
$sessionList = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList

try {
    Invoke-Step 'Resolve and validate SBE source' {
        $stagingRoot = Get-LocalSbeStagingRoot -SourcePath $SbeSourcePath -DownloadUrl $SbeDownloadUrl
        if ($stagingRoot) {
            $summary = Test-SbeContent -Path $stagingRoot
            Write-Ok "SBE source valid: $($summary.FileCount) files, $($summary.ManifestCount) manifest(s), $($summary.PayloadCount) payload(s)."
        }
        elseif ($Apply) {
            throw 'Apply requires SbeSourcePath or SbeDownloadUrl. No SBE source was supplied.'
        }
        else {
            Write-Info 'No local/download source supplied; Validate will inspect existing remote C:\SBE only.'
        }
    }

    Invoke-Step 'Resolve credentials and WinRM connectivity' {
        if ($bound.ContainsKey('LocalAdminPassword') -and $null -ne $LocalAdminPassword) {
            $script:cred = [System.Management.Automation.PSCredential]::new($authUser, $LocalAdminPassword)
        }
        else {
            $script:cred = Get-LabNodeCredential -User $authUser
        }

        if ($ConfigureTrustedHosts) {
            $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
            $desired = @($current -split ',' | Where-Object { $_ }) + @($NodeIPs)
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value (($desired | Select-Object -Unique) -join ',') -Force
            Write-Ok 'TrustedHosts updated.'
        }

        foreach ($ip in $NodeIPs) {
            try {
                if ($Transport -eq 'HTTPS') {
                    $so = New-PSSessionOption -SkipCACheck:$SkipCertCheck -SkipCNCheck:$SkipCertCheck
                    Test-WSMan -ComputerName $ip -Port $Port -UseSSL -Authentication Negotiate -Credential $script:cred -SessionOption $so -ErrorAction Stop | Out-Null
                }
                else {
                    Test-WSMan -ComputerName $ip -Port $Port -Authentication Negotiate -Credential $script:cred -ErrorAction Stop | Out-Null
                }
                Write-Ok "WinRM reachable: $ip"
            }
            catch { throw "WinRM NOT reachable on $ip - $($_.Exception.Message)" }
        }
    }

    Invoke-Step 'Stage and verify SBE on every node' {
        foreach ($ip in $NodeIPs) {
            $conn = New-PSSession -ComputerName $ip -Credential $script:cred -Port $Port -ErrorAction Stop
            [void]$sessionList.Add($conn)
            try {
                $remoteBefore = Invoke-Command -Session $conn -ScriptBlock {
                    param($path)
                    $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue)
                    [pscustomobject]@{ Exists = (Test-Path -LiteralPath $path); FileCount = $files.Count; Files = @($files | ForEach-Object { $_.Name }) }
                } -ArgumentList $RemoteSbePath

                if ($Apply) {
                    $remoteStage = "$RemoteSbePath.zcoffee-staging"
                    Invoke-Command -Session $conn -ScriptBlock {
                        param($path)
                        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
                        New-Item -Path $path -ItemType Directory -Force | Out-Null
                    } -ArgumentList $remoteStage

                    foreach ($item in @(Get-ChildItem -LiteralPath $stagingRoot -Force)) {
                        Copy-Item -LiteralPath $item.FullName -Destination $remoteStage -ToSession $conn -Recurse -Force -ErrorAction Stop
                    }

                    Invoke-Command -Session $conn -ScriptBlock {
                        param($stage,$dest,$replace)
                        if ($replace -and (Test-Path -LiteralPath $dest)) { Remove-Item -LiteralPath $dest -Recurse -Force }
                        New-Item -Path $dest -ItemType Directory -Force | Out-Null
                        Get-ChildItem -LiteralPath $stage -Force | ForEach-Object {
                            Move-Item -LiteralPath $_.FullName -Destination $dest -Force
                        }
                        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
                    } -ArgumentList $remoteStage,$RemoteSbePath,[bool]$ReplaceRemoteSbe
                    Write-Ok "$ip SBE copied to $RemoteSbePath"
                }

                $remoteAfter = Invoke-Command -Session $conn -ScriptBlock {
                    param($path)
                    $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue)
                    $xml = @($files | Where-Object { $_.Extension -ieq '.xml' })
                    $payload = @($files | Where-Object { $_.Extension -iin @('.zip','.cab','.msu') })
                    [pscustomobject]@{ Exists = (Test-Path -LiteralPath $path); FileCount = $files.Count; ManifestCount = $xml.Count; PayloadCount = $payload.Count; Files = @($files | ForEach-Object { $_.Name }) }
                } -ArgumentList $RemoteSbePath

                if (-not $remoteAfter.Exists -or $remoteAfter.ManifestCount -eq 0 -or $remoteAfter.PayloadCount -eq 0) {
                    throw "$ip SBE gate failed: C:\SBE must contain at least one XML manifest and one ZIP/CAB/MSU payload."
                }
                Write-Ok "$ip SBE verified: $($remoteAfter.FileCount) files"
            }
            catch {
                [void]$failures.Add("$ip : $($_.Exception.Message)")
                Write-Err "$ip SBE staging failed: $($_.Exception.Message)"
            }
            finally {
                if ($conn) { Remove-PSSession $conn -ErrorAction SilentlyContinue }
                [void]$sessionList.Remove($conn)
            }
        }
        if ($failures.Count -gt 0) { throw "SBE staging failed: $($failures -join ' | ')" }
    }

    if ($Apply) { $modeLabel = 'Apply' } else { $modeLabel = 'Validate' }
    Complete-Ui -FinalMessage "SBE stage finished ($modeLabel)."
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'SBE staging failed.'
    throw
}
finally {
    foreach ($s in @($sessionList)) { if ($s) { Remove-PSSession $s -ErrorAction SilentlyContinue } }
    if ($stagingRoot -and (Test-Path -LiteralPath $stagingRoot)) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
