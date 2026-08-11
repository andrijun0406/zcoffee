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
    [string]$MgmtGateway = "10.8.230.1",
    [string]$DnsServer = "10.8.230.248"
)

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
    $candidates = @('racadm', 'racdm')
    $installed = $candidates | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Where-Object { $_ }
    if (-not $installed) {
        Write-Host "ERROR: Neither 'racadm' nor 'racdm' was found in your PATH."
        Write-Host "Download Dell iDRAC Tools for Microsoft Windows Server, v11.3.0.0:" -ForegroundColor Yellow
        Write-Host "https://www.dell.com/support/home/en-id/drivers/driversdetails?driverId=W3M24" -ForegroundColor Cyan
        Write-Host "After installing, reopen PowerShell and rerun this script."
        throw "RACADM/iDRAC tool is required."
    }
    return $installed[0].Source
}

$racadmPath = Ensure-RACADMInstalled
Write-Host "Found RACADM tool at $racadmPath"

# Node definitions
$nodes = @(
    @{ Name = "azljkt01n1"; iDRACIP = "10.8.230.222"; MgmtIP = "10.8.230.222" },
    #@{ Name = "azljkt01n2"; iDRACIP = "10.8.230.232"; MgmtIP = "10.8.230.232" }
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

    $serverProcess = Start-Process -FilePath $pythonCommand -ArgumentList @('-m', 'http.server', $HttpPort, '--bind', '127.0.0.1') -WorkingDirectory $isoDirectory -PassThru -WindowStyle Minimized
    Start-Sleep -Seconds 2

    $connection = Test-NetConnection -ComputerName 127.0.0.1 -Port $HttpPort -InformationLevel Quiet -WarningAction SilentlyContinue
    if (-not $connection) {
        throw "The HTTP server did not start listening on port $HttpPort. Check Python installation and firewall settings."
    }
}

$ISOUrl = "http://127.0.0.1:$HttpPort/$(Split-Path $ISOFile -Leaf)"
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
