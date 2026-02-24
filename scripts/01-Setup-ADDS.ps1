param(
    [string]$ConfigPath = "C:\LabInfra\config\LabInfra.json"
)

# Load config
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$domainName    = $cfg.DomainName
$domainNetbios = $cfg.DomainNetbios

Write-Host "Installing AD DS and DNS for domain $domainName..." -ForegroundColor Cyan

Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools

Import-Module ADDSDeployment

Install-ADDSForest `
    -DomainName $domainName `
    -DomainNetbiosName $domainNetbios `
    -SafeModeAdministratorPassword (Read-Host -AsSecureString "Enter DSRM password") `
    -InstallDNS:$true `
    -Force
