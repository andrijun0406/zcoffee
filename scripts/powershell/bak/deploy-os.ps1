param(
    [string]$NodeIP,
    [string]$iDRACUser,
    [object]$iDRACPassword,
    [string]$ISOUrl,
    [string]$RACADMPath = 'racadm'
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

function Test-RACADMConnection {
    param(
        [string]$NodeIP,
        [string]$RACADMPath,
        [string]$iDRACUser,
        [string]$iDRACPassword
    )

    Write-Host "Testing iDRAC connectivity to $NodeIP..."
    # Resolve the racadm executable first so we can show helpful diagnostics
    $cmd = Get-Command $RACADMPath -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host "ERROR: Could not find executable '$RACADMPath' in PATH." -ForegroundColor Red
        Write-Host "Provide the full path to the RACADM binary using -RACADMPath, or install Dell RACADM and ensure it's on PATH." -ForegroundColor Yellow
        Write-Host "Current PATH:"
        $env:PATH -split ';' | ForEach-Object { Write-Host " - $_" }
        throw "RACADM executable not found"
    }

    $exe = $cmd.Source
    Write-Host "Using RACADM: $exe"

    $result = & $exe -r $NodeIP --nocertwarn -u $iDRACUser -p $iDRACPassword getsysinfo 2>&1
    Write-Host $result
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Unable to connect to iDRAC at $NodeIP." -ForegroundColor Red
        Write-Host "Command output:" -ForegroundColor Yellow
        Write-Host $result

        Write-Host "-- Additional diagnostics --"
        Write-Host "Testing network reachability to $NodeIP (ping):"
        try {
            Test-Connection -ComputerName $NodeIP -Count 2 -ErrorAction Stop | ForEach-Object { Write-Host $_ }
        } catch {
            Write-Host "Ping failed or blocked." -ForegroundColor Yellow
        }

        Write-Host "Testing TCP port 443 to $NodeIP (common iDRAC HTTPS port):"
        try {
            $tc = Test-NetConnection -ComputerName $NodeIP -Port 443 -InformationLevel Detailed -WarningAction SilentlyContinue
            Write-Host $tc | Out-String
        } catch {
            Write-Host "Port check failed or Test-NetConnection not available." -ForegroundColor Yellow
        }

        throw "iDRAC connectivity test failed for $NodeIP"
    }

    Write-Host "iDRAC connectivity to $NodeIP verified."
}

# Accept either plain text or SecureString password and convert to plain text before calling racadm
$iDRACPasswordPlain = switch ($iDRACPassword) {
    { $_ -is [SecureString] } { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
    { $_ -is [string] } { $_ }
    default { throw "iDRAC password must be a string or SecureString." }
}

#Test-RACADMConnection -NodeIP $NodeIP -RACADMPath $RACADMPath -iDRACUser $iDRACUser -iDRACPassword $iDRACPasswordPlain

Write-Host "Mounting ISO to $NodeIP via RACADM on $ISOurl" 

& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPasswordPlain --nocertwarn remoteimage -c -l $ISOUrl
#& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPasswordPlain --nocertwarn set iDRAC.ServerBoot.NextBootDevice VCD-DVD
#& $RACADMPath -r $NodeIP -u $iDRACUser -p $iDRACPasswordPlain --nocertwarn serveraction powercycle

Write-Host "OS deployment initiated for $NodeIP"
