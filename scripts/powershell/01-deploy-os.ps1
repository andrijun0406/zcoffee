[CmdletBinding()]
param(
    [string]$iDRACUser = 'root',
    [SecureString]$iDRACPassword,
    [string]$ISOFile,
    [string]$ExpectedISOHash,
    [ValidateRange(1,65535)]
    [int]$HttpPort = 8080,
    [string]$HttpHost,
    [string]$RACADMPath = 'racadm',
    [switch]$StartInstallation,
    [switch]$NoCertWarn,
    [int]$ServerLifetimeMinutes = 240,
    [switch]$NoWait,
    [switch]$UseGui,
    [string[]]$iDRACIPs = @('10.8.230.84','10.8.230.86')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

function Get-ManagementHostAddress {
    $address = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -like '10.8.230.*' -and
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*'
        } |
        Select-Object -First 1 -ExpandProperty IPAddress

    if (-not $address) {
        throw 'Unable to determine a management IP on 10.8.230.0/24. Provide -HttpHost.'
    }
    return $address
}

Initialize-Ui -StageName '01-deploy-os' -TotalSteps 6 -UseGui:$UseGui
$serverProcess = $null

try {
    Invoke-Step 'Verify Administrator privileges' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($id)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Administrator privileges are required.'
        }
    }

    Invoke-Step 'Resolve ISO, host address, and RACADM (preflight)' {
        $preflight = Join-Path $PSScriptRoot 'preflight-os.ps1'
        if (-not (Test-Path $preflight -PathType Leaf)) {
            throw "Missing preflight script: $preflight"
        }

        if (-not $script:ISOFile) {
            $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
            $script:ISOFile = Join-Path $repoRoot `
                'isos\AzureLocal24H2.26100.32230.LCM.12.2604.1.3008_DellSBE.5.0.2606.1510_15G-Intel_A01.en-us.iso'
            Write-Info "Using default ISO path: $script:ISOFile"
        }

        if (-not $script:HttpHost) {
            $script:HttpHost = Get-ManagementHostAddress
            Write-Info "Auto-selected HTTP host: $script:HttpHost"
        }

        & $preflight `
            -ISOFile $script:ISOFile `
            -ExpectedISOHash $script:ExpectedISOHash `
            -HttpHost $script:HttpHost `
            -HttpPort $script:HttpPort `
            -RACADMPath $script:RACADMPath `
            -iDRACIPs $script:iDRACIPs
    }

    Invoke-Step 'Prompt for iDRAC credentials if needed' {
        if (-not $PSBoundParameters.ContainsKey('iDRACPassword') -or $null -eq $script:iDRACPassword) {
            $script:iDRACPassword = Read-Host `
                -Prompt "Enter the iDRAC password for '$script:iDRACUser'" -AsSecureString
        }
        Write-Info 'iDRAC credential is available (value is never logged).'
    }

    Invoke-Step 'Locate Python for the temporary ISO server' {
        $script:pythonCommand = $null
        foreach ($candidate in @('py','python','python3')) {
            $cmd = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
            if ($cmd) { $script:pythonCommand = $cmd.Source; break }
        }
        if (-not $script:pythonCommand) {
            throw 'Python was not found on PATH.'
        }
        Write-Info "Python: $script:pythonCommand"
    }

    Invoke-Step 'Start ISO HTTP server and confirm reachability' {
        $script:ISOFile = (Resolve-Path $script:ISOFile).Path
        $isoName = Split-Path $script:ISOFile -Leaf
        $isoDir = Split-Path $script:ISOFile -Parent

        if ($script:HttpHost -in @('127.0.0.1','localhost','0.0.0.0')) {
            throw 'HttpHost must be a reachable management IP.'
        }

        $script:serverProcess = Start-Process -FilePath $script:pythonCommand `
            -ArgumentList @('-m','http.server',[string]$script:HttpPort,'--bind',$script:HttpHost) `
            -WorkingDirectory $isoDir -PassThru -WindowStyle Minimized
        $serverProcess = $script:serverProcess
        Start-Sleep -Seconds 3

        if ($serverProcess.HasExited) { throw 'ISO HTTP server exited unexpectedly.' }

        if (-not (Test-NetConnection -ComputerName $script:HttpHost -Port $script:HttpPort `
            -InformationLevel Quiet -WarningAction SilentlyContinue)) {
            throw "ISO server not reachable at $script:HttpHost`:$script:HttpPort"
        }

        $encoded = [Uri]::EscapeDataString($isoName)
        $script:isoUrl = "http://$script:HttpHost`:$script:HttpPort/$encoded"
        $null = Invoke-WebRequest -Uri $script:isoUrl -Method Head -TimeoutSec 15
        Write-Ok "ISO URL live: $script:isoUrl"
        Write-Warn 'Confirm both iDRAC interfaces can reach this URL on the chosen port.'
    }

    Invoke-Step 'Mount ISO on each node via RACADM worker' {
        $worker = Join-Path $PSScriptRoot 'deploy-os.ps1'
        if (-not (Test-Path $worker -PathType Leaf)) { throw "Missing worker: $worker" }

        foreach ($node in $script:iDRACIPs) {
            Write-Info "Node iDRAC: $node"
            & $worker `
                -NodeIP $node `
                -iDRACUser $script:iDRACUser `
                -iDRACPassword $script:iDRACPassword `
                -ISOUrl $script:isoUrl `
                -RACADMPath $script:RACADMPath `
                -StartInstallation:$script:StartInstallation `
                -NoCertWarn:$script:NoCertWarn
            Write-Ok "Node processed: $node"
        }
    }

    if (-not $NoWait) {
        Write-Info "Keeping ISO server alive up to $ServerLifetimeMinutes minutes for installation."
        for ($m = 1; $m -le $ServerLifetimeMinutes; $m++) {
            if ($serverProcess.HasExited) { throw 'ISO server exited during installation.' }
            Start-Sleep -Seconds 60
            if (($m % 10) -eq 0) { Write-Info "ISO server elapsed: $m minute(s)" }
        }
    }
    else {
        Write-Warn 'NoWait selected; ISO server stops when this stage exits.'
    }

    Complete-Ui -FinalMessage 'OS deployment stage finished.'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'OS deployment stage failed.'
    throw
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Info 'Temporary ISO server stopped.'
    }
}
