@'
param(
    [string]$ConfigPath = "C:\LabInfra\config\LabInfra.json",
    [string]$DownloadPath = "C:\Temp\WAC",
    [string]$MsiPath = ""
)

# Load config
$cfg        = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$waccfg     = $cfg.WAC
$wacPort    = $waccfg.Port
$wacMsiUrl  = $waccfg.MsiUrl

if (-not (Test-Path $DownloadPath)) {
    New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO ] $Message" -ForegroundColor Cyan
}

function Write-ErrorAndExit {
    param([string]$Message)
    Write-Error $Message
    throw $Message
}

Write-Info "Starting Windows Admin Center installation script..."

# 1) Locate or download MSI
if ([string]::IsNullOrWhiteSpace($MsiPath)) {
    $MsiPath = Join-Path $DownloadPath "WindowsAdminCenter.msi"
    if (-not (Test-Path $MsiPath)) {
        Write-Info "Downloading Windows Admin Center from $wacMsiUrl ..."
        try {
            Invoke-WebRequest -Uri $wacMsiUrl -OutFile $MsiPath -UseBasicParsing
        }
        catch {
            Write-ErrorAndExit "Failed to download WAC MSI from $wacMsiUrl. Specify -MsiPath if you have it locally."
        }
    }
} else {
    if (-not (Test-Path $MsiPath)) {
        Write-ErrorAndExit "Specified MSI path '$MsiPath' does not exist."
    }
}

Write-Info "Using WAC MSI at: $MsiPath"

# 2) Create a self-signed certificate for WAC if needed
Write-Info "Creating self-signed certificate for WAC (if not existing)..."

$certSubject = "CN=Windows Admin Center"
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $certSubject } | Select-Object -First 1

if (-not $cert) {
    $cert = New-SelfSignedCertificate `
        -DnsName "localhost" `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -FriendlyName "Windows Admin Center Self-Signed" `
        -Subject $certSubject
    Write-Info "Created new self-signed cert with thumbprint: $($cert.Thumbprint)"
} else {
    Write-Info "Found existing WAC cert with thumbprint: $($cert.Thumbprint)"
}

$thumbprint = $cert.Thumbprint

# 3) Install WAC silently as gateway
Write-Info "Installing Windows Admin Center on port $wacPort ..."

$msiArgs = @(
    "/i `"$MsiPath`"",
    "/qn",
    "SME_PORT=$wacPort",
    "SSL_CERTIFICATE_OPTION=installed",
    "SSL_CERTIFICATE_THUMBPRINT=$thumbprint",
    "ENABLE_TELEMETRY=0"
) -join " "

Write-Info "Running msiexec with arguments: $msiArgs"

$proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-ErrorAndExit "WAC installation failed with exit code $($proc.ExitCode)."
}

Write-Info "Windows Admin Center installation completed successfully."

# 4) Output URL
$hostname = (Get-CimInstance Win32_ComputerSystem).DNSHostName
Write-Host ""
Write-Host "WAC should now be available at:" -ForegroundColor Yellow
Write-Host "    https://$hostname`:$wacPort/" -ForegroundColor Yellow
Write-Host ""
'@ | Set-Content C:\LabInfra\scripts\05-Install-WAC.ps1 -Encoding UTF8
