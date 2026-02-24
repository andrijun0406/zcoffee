param(
    [string]$ConfigPath = "C:\LabInfra\config\LabInfra.json"
)

$cfg          = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$domainName   = $cfg.DomainName
$domainNetbios= $cfg.DomainNetbios
$dcIP         = $cfg.DC.IP

Write-Host "Setting DNS to DC ($dcIP)..." -ForegroundColor Cyan
$Adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $dcIP

$User = "$domainNetbios\Administrator"
$Pass = Read-Host "Enter domain admin password" -AsSecureString
$Cred = New-Object System.Management.Automation.PSCredential($User, $Pass)

Write-Host "Joining domain $domainName..." -ForegroundColor Cyan
Add-Computer -DomainName $domainName -Credential $Cred -Restart
