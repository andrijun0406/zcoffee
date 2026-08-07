<#
.SYNOPSIS
Configures host networking for Mgmt/Compute and Storage
#>

param(
    [string]$MgmtIP,
    [string]$MgmtGateway,
    [string]$MgmtSubnet = "255.255.255.0",
    [string]$StorageVlan1 = "711",
    [string]$StorageVlan2 = "712"
)

Write-Host "Configuring Mgmt/Compute network..."

New-NetIPAddress -InterfaceAlias "Ethernet1" -IPAddress $MgmtIP -PrefixLength 24 -DefaultGateway $MgmtGateway

Write-Host "Configuring Storage networks..."

# VLAN tagging example
Set-NetAdapterAdvancedProperty -Name "Ethernet3" -DisplayName "VLAN ID" -DisplayValue $StorageVlan1
Set-NetAdapterAdvancedProperty -Name "Ethernet4" -DisplayName "VLAN ID" -DisplayValue $StorageVlan2

Write-Host "Networking configuration complete."
