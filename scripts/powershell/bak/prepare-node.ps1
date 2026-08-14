<#
.SYNOPSIS
Prepares node with hostname, firewall, and security baseline
#>

param(
    [string]$NewHostname,
    [string]$MgmtIP,
    [string]$DnsServer = "10.8.230.51"
)

Write-Host "Renaming computer to $NewHostname..."
Rename-Computer -NewName $NewHostname -Restart

Write-Host "Configuring DNS..."
Set-DnsClientServerAddress -InterfaceAlias "Ethernet1" -ServerAddresses $DnsServer

Write-Host "Applying security baseline..."
# BitLocker
Enable-BitLocker -MountPoint "C:" -RecoveryPasswordProtector
# Credential Guard, WDAC, SMB signing enforced (example placeholders)
# These would be applied via Group Policy or DSC in production

Write-Host "Node preparation complete."
