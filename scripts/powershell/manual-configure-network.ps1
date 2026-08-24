# on .84
$if = 'Integrated NIC 1 Port 1-1'

# 1. Tag VLAN 230 host-side (switch port is trunked, 230 not native)
#Set-NetAdapterAdvancedProperty -Name $if -DisplayName 'VLAN ID' -DisplayValue 230

# 2. Static IP + gateway
New-NetIPAddress -InterfaceAlias $if -IPAddress 10.8.230.232 -PrefixLength 24 -DefaultGateway 10.8.230.1

# 3. DNS
#Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 10.8.230.51

# 4. Hostname
#Rename-Computer -NewName azljkt01n1 -Force

# 5. Reboot to apply hostname + settle VLAN
#Restart-Computer -Force

#on .86
$if = 'Integrated NIC 1 Port 1-1'

# 1. Tag VLAN 230 host-side (switch port is trunked, 230 not native)
#Set-NetAdapterAdvancedProperty -Name $if -DisplayName 'VLAN ID' -DisplayValue 230

# 2. Static IP + gateway
New-NetIPAddress -InterfaceAlias $if -IPAddress 10.8.230.235 -PrefixLength 24 -DefaultGateway 10.8.230.1

# 3. DNS
#Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 10.8.230.51

# 4. Hostname
#Rename-Computer -NewName azljkt01n1 -Force

# 5. Reboot to apply hostname + settle VLAN
#Restart-Computer -Force