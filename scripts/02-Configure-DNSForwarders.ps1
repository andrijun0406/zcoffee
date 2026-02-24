param(
    [string]$ConfigPath = "C:\LabInfra\config\LabInfra.json"
)

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$forwarders = $cfg.DnsForwarders

Import-Module DnsServer

Write-Host "Clearing existing DNS forwarders..." -ForegroundColor Cyan
Get-DnsServerForwarder -ErrorAction SilentlyContinue | Remove-DnsServerForwarder -Force

Write-Host "Adding DNS forwarders: $($forwarders -join ', ')" -ForegroundColor Cyan
Add-DnsServerForwarder -IPAddress $forwarders

Write-Host "Current forwarders:" -ForegroundColor Yellow
Get-DnsServerForwarder
