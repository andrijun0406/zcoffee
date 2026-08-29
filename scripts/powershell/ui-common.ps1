<#
.SYNOPSIS
Shared verbose progress/UI helper for the Azure Local lab deployment scripts.

Provides:
- Colored console dashboard (stages, steps, ok/warn/error, elapsed time)
- Transcript-style log file under .\logs
- Optional Windows Forms status window (-UseGui) that mirrors console output

Dot-source this file at the top of each stage:
    . (Join-Path $PSScriptRoot 'ui-common.ps1')
#>

Set-StrictMode -Version Latest

$script:UiState = [ordered]@{
    StageName   = 'Stage'
    StartTime   = Get-Date
    LogPath     = $null
    UseGui      = $false
    Gui         = $null
    Warnings    = 0
    Errors      = 0
    TotalSteps  = 0
    CurrentStep = 0
}

function Initialize-Ui {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageName,
        [int]$TotalSteps = 0,
        [switch]$UseGui,
        [string]$LogDirectory
    )

    $script:UiState.StageName   = $StageName
    $script:UiState.StartTime   = Get-Date
    $script:UiState.Warnings    = 0
    $script:UiState.Errors      = 0
    $script:UiState.TotalSteps  = $TotalSteps
    $script:UiState.CurrentStep = 0
    $script:UiState.UseGui      = [bool]$UseGui

    if (-not $LogDirectory) {
        $LogDirectory = Join-Path $PSScriptRoot 'logs'
    }
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:UiState.LogPath = Join-Path $LogDirectory "$StageName-$stamp.log"

    "==== $StageName started $(Get-Date -Format o) ====" |
        Out-File -FilePath $script:UiState.LogPath -Encoding utf8

    if ($script:UiState.UseGui) {
        Initialize-GuiWindow -Title "Azure Local Lab - $StageName"
    }

    $bar = '=' * 60
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host " STAGE: $StageName" -ForegroundColor Cyan
    Write-Host " Log:   $($script:UiState.LogPath)" -ForegroundColor DarkCyan
    Write-Host $bar -ForegroundColor Cyan
}

function Write-LogLine {
    param([string]$Level, [string]$Message)

    $ts = (Get-Date).ToString('HH:mm:ss')
    $line = "[{0}] [{1}] {2}" -f $ts, $Level, $Message

    if ($script:UiState.LogPath) {
        $line | Out-File -FilePath $script:UiState.LogPath -Append -Encoding utf8
    }

    if ($script:UiState.UseGui -and $script:UiState.Gui) {
        Update-GuiLog -Line $line -Level $Level
    }
}

function Write-Step {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    $script:UiState.CurrentStep++

    $prefix = if ($script:UiState.TotalSteps -gt 0) {
        "[{0}/{1}]" -f $script:UiState.CurrentStep, $script:UiState.TotalSteps
    } else {
        "[step $($script:UiState.CurrentStep)]"
    }

    Write-Host ''
    Write-Host "$prefix $Message" -ForegroundColor White
    Write-LogLine -Level 'STEP' -Message $Message

    if ($script:UiState.TotalSteps -gt 0) {
        $percent = [int](($script:UiState.CurrentStep / $script:UiState.TotalSteps) * 100)
        Write-Progress `
            -Activity $script:UiState.StageName `
            -Status $Message `
            -PercentComplete ([Math]::Min($percent, 100))
        if ($script:UiState.UseGui -and $script:UiState.Gui) {
            Update-GuiProgress -Percent ([Math]::Min($percent, 100)) -Status $Message
        }
    }
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  [OK]   $Message" -ForegroundColor Green
    Write-LogLine -Level 'OK' -Message $Message
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Gray
    Write-LogLine -Level 'INFO' -Message $Message
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    $script:UiState.Warnings++
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
    Write-LogLine -Level 'WARN' -Message $Message
}

function Write-Err {
    param([Parameter(Mandatory)][string]$Message)
    $script:UiState.Errors++
    Write-Host "  [ERR]  $Message" -ForegroundColor Red
    Write-LogLine -Level 'ERROR' -Message $Message
}

function Complete-Ui {
    [CmdletBinding()]
    param([switch]$Failed, [string]$FinalMessage)

    $elapsed = (Get-Date) - $script:UiState.StartTime
    $elapsedText = '{0:mm\:ss}' -f $elapsed

    if ($script:UiState.TotalSteps -gt 0) {
        Write-Progress -Activity $script:UiState.StageName -Completed
    }

    $bar = '=' * 60
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan

    if ($Failed) {
        Write-Host " RESULT: FAILED - $($script:UiState.StageName)" -ForegroundColor Red
    } else {
        Write-Host " RESULT: SUCCESS - $($script:UiState.StageName)" -ForegroundColor Green
    }

    Write-Host (" Warnings: {0}   Errors: {1}   Elapsed: {2}" -f `
        $script:UiState.Warnings, $script:UiState.Errors, $elapsedText) `
        -ForegroundColor DarkCyan

    if ($FinalMessage) {
        Write-Host " $FinalMessage" -ForegroundColor DarkCyan
    }

    Write-Host " Log: $($script:UiState.LogPath)" -ForegroundColor DarkCyan
    Write-Host $bar -ForegroundColor Cyan

    Write-LogLine -Level 'RESULT' -Message ("Failed={0} Warnings={1} Errors={2} Elapsed={3}" -f `
        [bool]$Failed, $script:UiState.Warnings, $script:UiState.Errors, $elapsedText)

    if ($script:UiState.UseGui -and $script:UiState.Gui) {
        Complete-GuiWindow -Failed:$Failed
    }
}

function Invoke-Step {
    <#
    Runs a scriptblock as a named step with automatic OK/ERR handling.
    On error: logs it, marks the UI failed, and rethrows (fail-fast).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Step -Message $Name
    try {
        & $Action
        Write-Ok -Message "$Name completed"
    }
    catch {
        Write-Err -Message "$Name failed: $($_.Exception.Message)"
        throw
    }
}

# ---------------- Lab config (single source of truth) ----------------

$script:LabConfigCache = $null

function Import-LabConfig {
    [CmdletBinding()]
    param([string]$Path)

    if ($script:LabConfigCache) { return $script:LabConfigCache }

    if (-not $Path) {
        $Path = Join-Path $PSScriptRoot 'config\lab-config.psd1'
        # Backward compatibility: fall back to the old location beside the scripts.
        if (-not (Test-Path $Path)) {
            $legacy = Join-Path $PSScriptRoot 'lab-config.psd1'
            if (Test-Path $legacy) { $Path = $legacy }
        }
    }

    if (-not (Test-Path $Path -PathType Leaf)) {
        Write-Warn "lab-config.psd1 not found at $Path. Using built-in parameter defaults."
        $script:LabConfigCache = @{}
        return $script:LabConfigCache
    }

    $script:LabConfigCache = Import-PowerShellDataFile -Path $Path
    return $script:LabConfigCache
}

function Resolve-Setting {
    <#
    Precedence: explicitly bound parameter > lab-config value > built-in default.
      -Name      parameter name to check in $Bound
      -Bound     the caller's $PSBoundParameters
      -Current   the parameter's current value (built-in default if not bound)
      -ConfigKey key to read from lab-config
      -Config    the imported config hashtable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Bound,
        $Current,
        [string]$ConfigKey,
        [hashtable]$Config
    )

    if ($Bound.ContainsKey($Name)) { return $Current }

    if ($ConfigKey -and $Config -and $Config.ContainsKey($ConfigKey)) {
        $val = $Config[$ConfigKey]
        if ($null -ne $val -and -not ($val -is [string] -and $val -eq '')) {
            return $val
        }
    }

    return $Current
}

# ---------------- Optional Windows Forms window ----------------

function Initialize-GuiWindow {
    param([string]$Title = 'Azure Local Lab')

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    }
    catch {
        Write-Host '  [WARN] Windows Forms is unavailable; continuing with console output only.' `
            -ForegroundColor Yellow
        $script:UiState.UseGui = $false
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(760, 480)
    $form.StartPosition = 'CenterScreen'

    $status = New-Object System.Windows.Forms.Label
    $status.Text = 'Starting...'
    $status.Dock = 'Top'
    $status.Height = 28
    $status.TextAlign = 'MiddleLeft'
    $form.Controls.Add($status)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Dock = 'Top'
    $progress.Height = 24
    $progress.Minimum = 0
    $progress.Maximum = 100
    $form.Controls.Add($progress)

    $log = New-Object System.Windows.Forms.RichTextBox
    $log.Dock = 'Fill'
    $log.ReadOnly = $true
    $log.Font = New-Object System.Drawing.Font('Consolas', 9)
    $form.Controls.Add($log)

    $form.Show()
    $form.Refresh()

    $script:UiState.Gui = [ordered]@{
        Form = $form; Status = $status; Progress = $progress; Log = $log
    }
}

function Update-GuiLog {
    param([string]$Line, [string]$Level)

    $gui = $script:UiState.Gui
    if (-not $gui) { return }

    $color = switch ($Level) {
        'ERROR'  { [System.Drawing.Color]::Red }
        'WARN'   { [System.Drawing.Color]::DarkGoldenrod }
        'OK'     { [System.Drawing.Color]::Green }
        'STEP'   { [System.Drawing.Color]::Black }
        default  { [System.Drawing.Color]::DimGray }
    }

    $gui.Log.SelectionStart = $gui.Log.TextLength
    $gui.Log.SelectionColor = $color
    $gui.Log.AppendText("$Line`n")
    $gui.Log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-GuiProgress {
    param([int]$Percent, [string]$Status)

    $gui = $script:UiState.Gui
    if (-not $gui) { return }

    $gui.Progress.Value = [Math]::Max(0, [Math]::Min(100, $Percent))
    $gui.Status.Text = $Status
    [System.Windows.Forms.Application]::DoEvents()
}

function Complete-GuiWindow {
    param([switch]$Failed)

    $gui = $script:UiState.Gui
    if (-not $gui) { return }

    if ($Failed) {
        $gui.Status.Text = 'FAILED - review the log pane.'
        $gui.Status.ForeColor = [System.Drawing.Color]::Red
    } else {
        $gui.Status.Text = 'SUCCESS'
        $gui.Status.ForeColor = [System.Drawing.Color]::Green
        $gui.Progress.Value = 100
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Connect-AzForStage {
    <#
      Unified Azure sign-in for Stages 4/5. Precedence:
        1. -ServicePrincipalId + -ServicePrincipalSecret  (unattended, secret)
        2. -ServicePrincipalId + -CertificateThumbprint   (unattended, cert)
        3. -UseManagedIdentity                            (jump host is an Azure VM/Arc box)
        4. -UseExistingAzLogin                            (reuse current Az context)
        5. interactive device-code                         (fallback)
      Returns the Az context. Never logs the secret.
    #>
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$ServicePrincipalId,
        [SecureString]$ServicePrincipalSecret,
        [string]$CertificateThumbprint,
        [switch]$UseManagedIdentity,
        [switch]$UseExistingAzLogin
    )
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw 'Az.Accounts not found on this host. Install-Module Az.Accounts -Scope CurrentUser'
    }
    Import-Module Az.Accounts -ErrorAction Stop

    $ctx = $null
    if ($ServicePrincipalId -and $ServicePrincipalSecret) {
        Write-Info "Service-principal sign-in (secret) as appId $ServicePrincipalId (unattended)."
        $cred = [System.Management.Automation.PSCredential]::new($ServicePrincipalId, $ServicePrincipalSecret)
        Connect-AzAccount -ServicePrincipal -Tenant $TenantId -Credential $cred -ErrorAction Stop | Out-Null
    }
    elseif ($ServicePrincipalId -and $CertificateThumbprint) {
        Write-Info "Service-principal sign-in (certificate) as appId $ServicePrincipalId (unattended)."
        Connect-AzAccount -ServicePrincipal -Tenant $TenantId -ApplicationId $ServicePrincipalId `
            -CertificateThumbprint $CertificateThumbprint -ErrorAction Stop | Out-Null
    }
    elseif ($UseManagedIdentity) {
        Write-Info 'Managed-identity sign-in (unattended).'
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    }
    elseif ($UseExistingAzLogin) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($ctx) { Write-Info "Reusing existing Az context ($($ctx.Account.Id))." }
    }
    if (-not $ctx -and -not ($ServicePrincipalId -or $UseManagedIdentity)) {
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
            Write-Info 'Launching device-code sign-in (follow the URL + code)...'
            Connect-AzAccount -TenantId $TenantId -UseDeviceAuthentication -ErrorAction Stop | Out-Null
        }
    }
    Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId -ErrorAction Stop | Out-Null
    return Get-AzContext
}
