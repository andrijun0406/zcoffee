<#
.SYNOPSIS
Bootstraps Azure Local 2-node cluster (Jakarta Lab 01)
Runs OS deployment, networking config, and node preparation in sequence.
Serves Golden Image ISO via local HTTP server for RACADM mounting.
#>

param(
    [string]$iDRACUser = "root",
    [object]$iDRACPassword,
    [string]$ISOFile,
    [int]$HttpPort = 8080,
    [string]$HttpHost,
    [string]$MgmtGateway = "10.8.230.1",
    [string]$DnsServer = "10.8.230.51",
    [string]$RACADMPath
)

function Ensure-RunningAsAdministrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "ERROR: This script must be run with Administrator privileges." -ForegroundColor Red
        Write-Host "Right-click PowerShell and select 'Run as Administrator', then rerun this script." -ForegroundColor Yellow
        throw "Administrator privileges required."
    }
}

Ensure-RunningAsAdministrator

if (-not $PSBoundParameters.ContainsKey('iDRACPassword')) {
    Write-Host "Enter the iDRAC password for user '$iDRACUser':"
    $iDRACPassword = Read-Host -AsSecureString
}

$secureiDRACPassword = switch ($iDRACPassword) {
    { $_ -is [SecureString] } { $_ }
    { $_ -is [string] -and $_.Length -gt 0 } { ConvertTo-SecureString -String $_ -AsPlainText -Force }
    default { throw "An iDRAC password is required. Provide one or enter it when prompted." }
}

function Ensure-RACADMInstalled {
    param([string]$PathHint)

    if ($PathHint) {
        $hintCommand = Get-Command $PathHint -ErrorAction SilentlyContinue
        if ($hintCommand) {
            return $hintCommand.Source
        }
        if (Test-Path $PathHint) {
            return $PathHint
        }
        Write-Host "WARNING: Provided RACADM path '$PathHint' was not found. Falling back to PATH and default locations." -ForegroundColor Yellow
    }

    $candidates = @('racadm', 'racdm')
    $installed = $candidates | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Where-Object { $_ }
    if ($installed) {
        return $installed[0].Source
    }

    $defaultPaths = @(
        'C:\Program Files\Dell\SysMgt\iDRACTools\racadm.exe',
        'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racdm.exe',
        'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe'
    )
    foreach ($path in $defaultPaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    Write-Host "ERROR: RACADM was not found on PATH or in the default Dell install location." -ForegroundColor Red
    Write-Host "Download Dell iDRAC Tools for Microsoft Windows Server, v11.3.0.0:" -ForegroundColor Yellow
    Write-Host "https://www.dell.com/support/home/en-id/drivers/driversdetails?driverId=W3M24" -ForegroundColor Cyan
    Write-Host "After installing, reopen PowerShell and rerun this script."
    throw "RACADM/iDRAC tool is required."
}

$racadmPath = Ensure-RACADMInstalled -PathHint $RACADMPath
Write-Host "Using RACADM tool at $racadmPath"

# Node definitions
$nodes = @(
    @{ 
        Name = "azljkt01n1"
        iDRACIP = "10.8.230.84"
        MgmtIP = "10.8.230.222"
    }
    #@{ 
    #    Name = "azljkt01n2"
    #    iDRACIP = "10.8.230.86"
    #    MgmtIP = "10.8.230.232"
    #}
)

# Step 0: Start local HTTP server to serve ISO
if (-not $ISOFile) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $defaultISO = Join-Path $repoRoot 'isos\AzureLocal24H2.26100.32230.LCM.12.2604.1.3008_DellSBE.5.0.2606.1510_15G-Intel_A01.en-us.iso'
    if (Test-Path $defaultISO) {
        $ISOFile = $defaultISO
    }
    else {
        throw "ISO file not found. Provide -ISOFile with the correct path to the Azure Local ISO."
    }
}

Write-Host "Starting local HTTP server on port $HttpPort..."
$isoDirectory = Split-Path $ISOFile -Parent
if ($isoDirectory) {
    $pythonCommand = $null
    foreach ($candidate in @('py', 'python', 'python3')) {
        $commandInfo = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($commandInfo) {
            $pythonCommand = $commandInfo.Source
            break
        }
    }

    if (-not $pythonCommand) {
        throw "Python is required to serve the ISO. Install Python and ensure 'py' or 'python' is available on PATH."
    }

    $serverProcess = Start-Process -FilePath $pythonCommand -ArgumentList @('-m', 'http.server', $HttpPort, '--bind', '0.0.0.0') -WorkingDirectory $isoDirectory -PassThru -WindowStyle Minimized
    Start-Sleep -Seconds 2

    $connection = Test-NetConnection -ComputerName 'localhost' -Port $HttpPort -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $connection) {
        throw "The HTTP server did not start listening on port $HttpPort. Check Python installation and firewall settings."
    }
}

if (-not $HttpHost) {
    $HttpHost = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1 -ExpandProperty IPAddress)
    if (-not $HttpHost) {
        throw "Unable to determine a network-accessible HTTP host address. Provide -HttpHost explicitly."
    }
}

$ISOUrl = "http://${HttpHost}:${HttpPort}/$(Split-Path $ISOFile -Leaf)"
Write-Host "ISO available at $ISOUrl"

foreach ($node in $nodes) {
    Write-Host "=== Bootstrapping $($node.Name) ==="

    # Step 1: OS Deployment (delegated to deploy-os.ps1)
    .\deploy-os.ps1 -NodeIP $node.iDRACIP -iDRACUser $iDRACUser -iDRACPassword $secureiDRACPassword -ISOUrl $ISOUrl -RACADMPath $racadmPath

    # Step 2: Networking
    # .\configure-network.ps1 -MgmtIP $node.MgmtIP -MgmtGateway $MgmtGateway -MgmtSubnet "255.255.255.0" -StorageVlan1 "711" -StorageVlan2 "712"

    # Step 3: Node Preparation
    #.\prepare-node.ps1 -NewHostname $node.Name -MgmtIP $node.MgmtIP -DnsServer $DnsServer

    Write-Host "=== $($node.Name) bootstrap complete ==="
}

Write-Host "All nodes prepared. Proceed with ARM template deployment for cluster creation."
