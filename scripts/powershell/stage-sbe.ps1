<#
.SYNOPSIS
    Stage and verify a Dell SBE bundle on Azure Local nodes.
.DESCRIPTION
    Local SBE source is preferred; an HTTPS ZIP URL is supported as a fallback.
    The outer bundle is extracted once when needed. The inner SBE payload archive is
    preserved and is not expanded. Apply copies only the bundle manifests and payload
    archives into C:\SBE on each node. Validate inspects existing remote C:\SBE.
#>
[CmdletBinding()]
param(
    [string[]]$NodeIPs,
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTP','HTTPS')][string]$Transport = 'HTTP',
    [int]$Port,
    [switch]$ConfigureTrustedHosts,
    [switch]$SkipCertCheck,
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
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$bound = $PSBoundParameters
if (-not $bound.ContainsKey('NodeIPs')) {
    if ($cfg.ContainsKey('Nodes')) { $NodeIPs = @($cfg.Nodes | ForEach-Object { $_.HostIP }) }
    else { $NodeIPs = @('10.8.230.232','10.8.230.235') }
}
if (-not $NodeIPs -or $NodeIPs.Count -eq 0) { throw 'At least one node IP is required.' }
if (-not $bound.ContainsKey('LocalAdminUser') -or [string]::IsNullOrWhiteSpace($LocalAdminUser)) {
    if ($cfg.ContainsKey('LocalAdminUser')) { $LocalAdminUser = [string]$cfg.LocalAdminUser }
    else { $LocalAdminUser = 'Administrator' }
}
if (-not $Port) { $Port = if ($Transport -eq 'HTTPS') { 5986 } else { 5985 } }
if (-not $bound.ContainsKey('SbeSourcePath') -and $cfg.ContainsKey('SbeSourcePath')) { $SbeSourcePath = [string]$cfg.SbeSourcePath }
if (-not $bound.ContainsKey('SbeDownloadUrl') -and $cfg.ContainsKey('SbeDownloadUrl')) { $SbeDownloadUrl = [string]$cfg.SbeDownloadUrl }
if (-not $bound.ContainsKey('SbeSha256') -and $cfg.ContainsKey('SbeSha256')) { $SbeSha256 = [string]$cfg.SbeSha256 }
if (-not $bound.ContainsKey('ExpectedSbeVersion') -and $cfg.ContainsKey('SbeExpectedVersion')) { $ExpectedSbeVersion = [string]$cfg.SbeExpectedVersion }

$authUser = $LocalAdminUser
if ($authUser -notmatch '[\\@]') { $authUser = '.\' + $authUser }

function New-StagingRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('zcoffee-sbe-' + [guid]::NewGuid().ToString('N'))
    New-Item -LiteralPath $root -ItemType Directory -Force | Out-Null
    return $root
}

function Get-PackageFiles {
    param([Parameter(Mandatory=$true)][string]$Root)
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop |
        Where-Object { $_.FullName -notmatch '\.expanded([\\]|$)' -and $_.Extension -iin @('.xml','.zip','.cab','.msu') })
    return @($files | Sort-Object FullName)
}

function Resolve-SbePackage {
    param([string]$SourcePath, [string]$DownloadUrl)
    $work = New-StagingRoot
    $inputPath = $null
    try {
        if ($SourcePath) {
            $inputPath = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
            Write-Info "Using local SBE source: $inputPath"
        }
        elseif ($DownloadUrl) {
            $uri = [Uri]$DownloadUrl
            $name = [IO.Path]::GetFileName($uri.AbsolutePath)
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'sbe-bundle.zip' }
            $inputPath = Join-Path $work $name
            Write-Info "Downloading SBE bundle to $inputPath"
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $inputPath -UseBasicParsing -ErrorAction Stop
            if ($SbeSha256) {
                $actual = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
                if ($actual -ine $SbeSha256) { throw "SBE download SHA-256 mismatch. Expected $SbeSha256, got $actual." }
                Write-Ok "SBE download SHA-256 verified: $actual"
            }
        }
        else {
            return $null
        }

        $packageRoot = Join-Path $work 'package'
        New-Item -LiteralPath $packageRoot -ItemType Directory -Force | Out-Null
        if (Test-Path -LiteralPath $inputPath -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $inputPath -Recurse -File -ErrorAction Stop)) {
                if ($f.Extension -iin @('.xml','.zip','.cab','.msu')) {
                    Copy-Item -LiteralPath ([string]$f.FullName) -Destination (Join-Path $packageRoot $f.Name) -Force
                }
            }
        }
        elseif ([IO.Path]::GetExtension($inputPath) -ieq '.zip') {
            $outer = Join-Path $work 'outer'
            New-Item -LiteralPath $outer -ItemType Directory -Force | Out-Null
            Expand-Archive -LiteralPath $inputPath -DestinationPath $outer -Force -ErrorAction Stop
            foreach ($f in @(Get-ChildItem -LiteralPath $outer -Recurse -File -ErrorAction Stop)) {
                if ($f.Extension -iin @('.xml','.zip','.cab','.msu')) {
                    Copy-Item -LiteralPath ([string]$f.FullName) -Destination (Join-Path $packageRoot $f.Name) -Force
                }
            }
        }
        else {
            Copy-Item -LiteralPath ([string]$inputPath) -Destination $packageRoot -Force
        }

        $packageFiles = @(Get-PackageFiles -Root $packageRoot)
        $xml = @($packageFiles | Where-Object { $_.Extension -ieq '.xml' })
        $payload = @($packageFiles | Where-Object { $_.Extension -iin @('.zip','.cab','.msu') })
        if ($xml.Count -eq 0) { throw "SBE package contains no XML manifest: $inputPath" }
        if ($payload.Count -eq 0) { throw "SBE package contains no ZIP/CAB/MSU payload: $inputPath" }
        if ($ExpectedSbeVersion) {
            $text = (@($xml | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue }) -join "`n")
            if ($text -notmatch [regex]::Escape($ExpectedSbeVersion) -and
                ((@($packageFiles | Select-Object -ExpandProperty Name) -join "`n") -notmatch [regex]::Escape($ExpectedSbeVersion))) {
                throw "SBE package does not contain expected version '$ExpectedSbeVersion'."
            }
        }
        return [pscustomobject]@{ WorkRoot=$work; PackageRoot=$packageRoot; Files=$packageFiles; XmlCount=$xml.Count; PayloadCount=$payload.Count }
    }
    catch {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Get-RemoteSbeSummary {
    param([System.Management.Automation.Runspaces.PSSession]$Session, [string]$Path)
    return Invoke-Command -Session $Session -ScriptBlock {
        param($p)
        if ([string]::IsNullOrWhiteSpace([string]$p)) { throw 'Remote SBE path is empty.' }
        $exists = Test-Path -LiteralPath $p
        $files = @()
        if ($exists) { $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue) }
        [pscustomobject]@{
            Exists=$exists; FileCount=$files.Count
            ManifestCount=@($files | Where-Object { $_.Extension -ieq '.xml' }).Count
            PayloadCount=@($files | Where-Object { $_.Extension -iin @('.zip','.cab','.msu') }).Count
        }
    } -ArgumentList ([string]$Path)
}

$summaryRoot = $null
$sessionList = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList
try {
    Write-Host ('[INFO] Nodes: ' + ($NodeIPs -join ', '))
    Write-Host ('[INFO] SBE source: ' + $(if ($SbeSourcePath) { $SbeSourcePath } else { if ($SbeDownloadUrl) { $SbeDownloadUrl } else { '<none>' } }))
    Initialize-Ui -StageName 'stage-sbe' -TotalSteps 3 -UseGui:$UseGui

    Invoke-Step 'Resolve and validate SBE source' {
        $summaryRoot = Resolve-SbePackage -SourcePath $SbeSourcePath -DownloadUrl $SbeDownloadUrl
        if ($summaryRoot) {
            Write-Ok "SBE source valid: $($summaryRoot.Files.Count) files, $($summaryRoot.XmlCount) manifest(s), $($summaryRoot.PayloadCount) payload(s)."
        }
        elseif ($Apply) { throw 'Apply requires SbeSourcePath or SbeDownloadUrl.' }
        else { Write-Info 'No source supplied; Validate will inspect existing remote C:\SBE.' }
    }

    Invoke-Step 'Resolve credentials and WinRM connectivity' {
        if ($bound.ContainsKey('LocalAdminPassword') -and $null -ne $LocalAdminPassword) {
            $script:cred = New-Object System.Management.Automation.PSCredential($authUser,$LocalAdminPassword)
        } else { $script:cred = Get-LabNodeCredential -User $authUser }
        if ($ConfigureTrustedHosts) {
            $current=(Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
            $desired=@($current -split ',' | Where-Object { $_ }) + @($NodeIPs)
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value (($desired | Select-Object -Unique) -join ',') -Force
            Write-Ok 'TrustedHosts updated.'
        }
        foreach ($ip in $NodeIPs) {
            if ($Transport -eq 'HTTPS') {
                $so=New-PSSessionOption -SkipCACheck:$SkipCertCheck -SkipCNCheck:$SkipCertCheck
                Test-WSMan -ComputerName $ip -Port $Port -UseSSL -Authentication Negotiate -Credential $script:cred -SessionOption $so -ErrorAction Stop | Out-Null
            } else { Test-WSMan -ComputerName $ip -Port $Port -Authentication Negotiate -Credential $script:cred -ErrorAction Stop | Out-Null }
            Write-Ok "WinRM reachable: $ip"
        }
    }

    Invoke-Step 'Stage and verify SBE on every node' {
        if ($Apply -and $null -eq $summaryRoot) { throw 'Internal error: SBE package root is null in Apply mode.' }
        foreach ($ip in $NodeIPs) {
            $conn=$null
            try {
                Write-Info "$ip: opening WinRM session"
                $conn=New-PSSession -ComputerName $ip -Credential $script:cred -Port $Port -ErrorAction Stop
                [void]$sessionList.Add($conn)
                $before=Get-RemoteSbeSummary -Session $conn -Path $RemoteSbePath
                Write-Info "$ip: existing C:\SBE exists=$($before.Exists), files=$($before.FileCount)"
                if ($Apply) {
                    $remoteStage = "$RemoteSbePath.zcoffee-staging-$([guid]::NewGuid().ToString('N'))"
                    Invoke-Command -Session $conn -ScriptBlock { param($p) New-Item -LiteralPath $p -ItemType Directory -Force | Out-Null } -ArgumentList $remoteStage
                    foreach ($item in @($summaryRoot.Files)) {
                        $sourceFile=[string]$item.FullName
                        if ([string]::IsNullOrWhiteSpace($sourceFile) -or -not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { throw "$ip: source file path is empty or missing." }
                        Write-Info "$ip: copying $($item.Name)"
                        Copy-Item -Path $sourceFile -Destination $remoteStage -ToSession $conn -Force -ErrorAction Stop
                    }
                    Invoke-Command -Session $conn -ScriptBlock {
                        param($stage,$dest,$replace)
                        if ([string]::IsNullOrWhiteSpace([string]$stage) -or [string]::IsNullOrWhiteSpace([string]$dest)) { throw 'Remote staging or destination path is empty.' }
                        if ($replace -and (Test-Path -LiteralPath $dest)) { Remove-Item -LiteralPath $dest -Recurse -Force }
                        New-Item -LiteralPath $dest -ItemType Directory -Force | Out-Null
                        foreach ($f in @(Get-ChildItem -LiteralPath $stage -File -Force)) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
                        Remove-Item -LiteralPath $stage -Recurse -Force
                    } -ArgumentList $remoteStage,$RemoteSbePath,[bool]$ReplaceRemoteSbe
                }
                $after=Get-RemoteSbeSummary -Session $conn -Path $RemoteSbePath
                if (-not $after.Exists -or $after.ManifestCount -eq 0 -or $after.PayloadCount -eq 0) { throw "$ip SBE gate failed: manifest=$($after.ManifestCount), payload=$($after.PayloadCount)." }
                Write-Ok "$ip SBE verified: $($after.FileCount) files, manifests=$($after.ManifestCount), payloads=$($after.PayloadCount)"
            }
            catch { [void]$failures.Add("$ip : $($_.Exception.Message)"); Write-Err "$ip SBE staging failed: $($_.Exception.Message)" }
            finally { if ($conn) { Remove-PSSession $conn -ErrorAction SilentlyContinue }; if ($conn) { [void]$sessionList.Remove($conn) } }
        }
        if ($failures.Count -gt 0) { throw "SBE staging failed: $($failures -join ' | ')" }
    }
    Complete-Ui -FinalMessage $(if ($Apply) { 'SBE stage finished (Apply).' } else { 'SBE stage finished (Validate).' })
}
catch { Write-Err $_.Exception.Message; Complete-Ui -Failed -FinalMessage 'SBE staging failed.'; throw }
finally {
    foreach ($s in @($sessionList)) { if ($s) { Remove-PSSession $s -ErrorAction SilentlyContinue } }
    if ($summaryRoot -and (Test-Path -LiteralPath $summaryRoot.WorkRoot)) { Remove-Item -LiteralPath $summaryRoot.WorkRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
