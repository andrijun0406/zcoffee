<#
.SYNOPSIS
Bootstraps Azure Local 2-node cluster (Jakarta Lab 01)
Runs OS deployment, networking config, and node preparation in sequence.
#>

param(
    [string]$iDRACUser = "root",
    [string]$iDRACPassword = "REPLACE_WITH_SECURE_PASSWORD",
    [string]$ISOPath = "C:\ISOs\AzureLocalGoldenImage.iso",
    [string]$MgmtGateway = "10.8.230.1",
    [string]$DnsServer = "10.8.230.248"
)

# Node definitions
$nodes = @(
    @{ Name = "azljkt01n1"; iDRACIP = "10.8.230.222"; MgmtIP = "10.8.230.222" },
    @{ Name = "azljkt01n2"; iDRACIP = "10.8.230.232"; MgmtIP = "10.8.230.232" }
)

foreach ($node in $nodes) {
    Write-Host "=== Bootstrapping $($node.Name) ==="

    # Step 1: OS Deployment
    .\deploy-os.ps1 -NodeIP $node.iDRACIP -iDRACUser $iDRACUser -iDRACPassword $iDRACPassword -ISOPath $ISOPath

    # Step 2: Networking
    .\configure-network.ps1 -MgmtIP $node.MgmtIP -MgmtGateway $MgmtGateway -MgmtSubnet "255.255.255.0" -StorageVlan1 "711" -StorageVlan2 "712"

    # Step 3: Node Preparation
    .\prepare-node.ps1 -NewHostname $node.Name -MgmtIP $node.MgmtIP -DnsServer $DnsServer

    Write-Host "=== $($node.Name) bootstrap complete ==="
}

Write-Host "All nodes prepared. Proceed with ARM template deployment for cluster creation."
