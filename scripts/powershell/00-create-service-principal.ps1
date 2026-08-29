<#
.SYNOPSIS
    Stage 0 (prerequisite) - Create/repair the service principal used for unattended
    Arc registration (Stage 4) and Azure Local deployment (Stage 5).

.DESCRIPTION
    This is a ONE-TIME bootstrap that must be run by a privileged human (Subscription Owner or
    Global Administrator + Owner/User Access Administrator). It:
      1. Ensures Az.Accounts / Az.Resources are present.
      2. Signs the privileged user in INTERACTIVELY - supports MFA (browser) or device code.
         (Service principals cannot create other service principals with these roles, so the
          first sign-in is necessarily a human with rights to create app registrations.)
      3. Creates (or reuses) the SP, resets its secret if asked, and assigns the roles that
         Arc onboarding + Azure Local deployment require.
      4. Writes the SP identity to a GITIGNORED secret file the orchestrator can consume, and
         prints the values once.

    Subsequent automated stages authenticate with the SP (no human, no MFA) via:
      -ServicePrincipalId <appId> -ServicePrincipalSecret <secure>   (or -SpCertThumbprint)

.NOTES
    Never commit the secret file. Prefer an SP CERTIFICATE (thumbprint) over a secret for
    truly unattended runs. Secret output is shown ONCE by Azure and cannot be retrieved later.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$DisplayName = 'zcoffee-azlocal-deployer',

    # Scope role assignments here. Default subscription; pass an RG resource id to tighten.
    [string]$Scope,

    # Sign-in method for the privileged bootstrap user.
    [ValidateSet('Interactive','DeviceCode','UseExistingAzLogin')]
    [string]$SignInMethod = 'Interactive',

    # Where to persist the SP identity for the orchestrator (gitignored). Secret stored as
    # a DPAPI-protected string (per-user/per-machine) unless -PlainSecretFile is set.
    [string]$OutFile = (Join-Path $PSScriptRoot 'config\sp-credentials.local.json'),
    [switch]$PlainSecretFile,

    # Use a self-signed certificate instead of a client secret (recommended for unattended).
    [switch]$UseCertificate,
    [int]$CertValidityMonths = 12,

    # Reset/rotate the client secret if the SP already exists.
    [switch]$ResetSecret,

    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load shared UI/config helpers if present; otherwise define minimal shims so this script
# can run standalone before the rest of the framework is wired up.
$uiCommon = Join-Path $PSScriptRoot 'ui-common.ps1'
if (Test-Path $uiCommon) {
    . $uiCommon
} else {
    function Initialize-Ui { param($StageName,$TotalSteps,[switch]$UseGui) }
    function Invoke-Step { param([string]$Name,[scriptblock]$Body) Write-Host "== $Name =="; & $Body; Write-Host "  [OK] $Name" }
    function Write-Info { param($m) Write-Host "  [INFO] $m" }
    function Write-Ok   { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
    function Write-Warn { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
    function Write-Err  { param($m) Write-Host "  [ERR]  $m" -ForegroundColor Red }
    function Complete-Ui { param([switch]$Failed,[string]$FinalMessage) if ($Failed) { Write-Err $FinalMessage } else { Write-Ok $FinalMessage } }
    function Import-LabConfig {
        $p = Join-Path $PSScriptRoot 'config\lab-config.psd1'
        if (Test-Path $p) { return Import-PowerShellDataFile $p }
        return @{}
    }
}

$cfg = Import-LabConfig
if (-not $SubscriptionId -and $cfg.ContainsKey('SubscriptionId')) { $SubscriptionId = $cfg.SubscriptionId }
if (-not $TenantId       -and $cfg.ContainsKey('TenantId'))       { $TenantId       = $cfg.TenantId }
if (-not $SubscriptionId) { throw 'Provide -SubscriptionId (or set it in lab-config.psd1).' }
if (-not $TenantId)       { throw 'Provide -TenantId (or set it in lab-config.psd1).' }
if (-not $Scope) { $Scope = "/subscriptions/$SubscriptionId" }

# Roles Arc onboarding + Azure Local deployment require.
$roles = @(
    'Azure Connected Machine Onboarding',
    'Azure Connected Machine Resource Administrator',
    'Contributor',
    'User Access Administrator'
)

Initialize-Ui -StageName '00-create-service-principal' -TotalSteps 6 -UseGui:$UseGui

try {
    Invoke-Step 'Ensure Az modules present' {
        foreach ($m in @('Az.Accounts','Az.Resources')) {
            if (-not (Get-Module -ListAvailable -Name $m)) {
                Write-Info "Installing $m ..."
                try { Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch { }
                Install-Module $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            }
            Import-Module $m -ErrorAction Stop
            Write-Ok "$m available"
        }
    }

    Invoke-Step 'Privileged interactive sign-in (supports MFA)' {
        $ctx = $null
        try { $ctx = (Get-AzContext) } catch { }

        switch ($script:SignInMethod) {
            'UseExistingAzLogin' {
                if (-not $ctx) { throw 'No existing Az login found. Re-run with -SignInMethod Interactive.' }
                Write-Info "Reusing existing sign-in: $($ctx.Account.Id)"
            }
            'DeviceCode' {
                Write-Info 'Launching device-code sign-in (open the URL, enter the code; MFA supported)...'
                Connect-AzAccount -TenantId $script:TenantId -UseDeviceAuthentication -ErrorAction Stop | Out-Null
            }
            default {
                Write-Info 'Launching interactive browser sign-in (MFA supported)...'
                # Interactive browser flow handles username/password AND multifactor prompts.
                Connect-AzAccount -TenantId $script:TenantId -ErrorAction Stop | Out-Null
            }
        }
        Set-AzContext -Subscription $script:SubscriptionId -Tenant $script:TenantId -ErrorAction Stop | Out-Null
        $me = (Get-AzContext).Account.Id
        Write-Ok "Signed in as $me; subscription $script:SubscriptionId"

        # Fail early if the signed-in user cannot create app registrations / assign roles.
        Write-Info 'Note: this bootstrap requires app-registration + role-assignment rights (Owner / User Access Administrator, and Application Administrator or Global Administrator).'
    }

    Invoke-Step 'Create or reuse the service principal' {
        $existing = Get-AzADServicePrincipal -DisplayName $script:DisplayName -ErrorAction SilentlyContinue
        $script:secretPlain = $null
        $script:certThumb   = $null

        if ($script:UseCertificate) {
            # Self-signed cert in the current user's store; SP authenticates by thumbprint.
            $notAfter = (Get-Date).AddMonths($script:CertValidityMonths)
            $cert = New-SelfSignedCertificate -Subject "CN=$script:DisplayName" `
                        -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable `
                        -KeySpec Signature -NotAfter $notAfter -ErrorAction Stop
            $script:certThumb = $cert.Thumbprint
            $keyValue = [Convert]::ToBase64String($cert.RawData)

            if ($existing) {
                $script:sp = $existing
                Write-Info "SP '$script:DisplayName' exists (AppId $($existing.AppId)); adding certificate credential."
                New-AzADAppCredential -ApplicationId $existing.AppId -CertValue $keyValue -EndDate $notAfter -ErrorAction Stop | Out-Null
            } else {
                $app = New-AzADApplication -DisplayName $script:DisplayName -ErrorAction Stop
                New-AzADAppCredential -ApplicationId $app.AppId -CertValue $keyValue -EndDate $notAfter -ErrorAction Stop | Out-Null
                $script:sp = New-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction Stop
                Write-Ok "Created SP '$script:DisplayName' (AppId $($app.AppId)) with certificate."
            }
            Write-Ok "Certificate thumbprint: $script:certThumb (in Cert:\CurrentUser\My)"
        }
        else {
            if ($existing) {
                $script:sp = $existing
                if ($script:ResetSecret) {
                    Write-Info "SP exists; resetting client secret."
                    $cred = New-AzADSpCredential -ObjectId $existing.Id -ErrorAction Stop
                    $script:secretPlain = $cred.SecretText
                    Write-Ok "Secret reset for AppId $($existing.AppId)."
                } else {
                    Write-Warn "SP '$script:DisplayName' already exists (AppId $($existing.AppId)). Secret NOT shown (Azure reveals it once). Re-run with -ResetSecret to rotate."
                }
            } else {
                $script:sp = New-AzADServicePrincipal -DisplayName $script:DisplayName -ErrorAction Stop
                $script:secretPlain = $script:sp.PasswordCredentials.SecretText
                Write-Ok "Created SP '$script:DisplayName' (AppId $($script:sp.AppId)) with client secret."
            }
        }

        $script:appId = $script:sp.AppId
        $script:objId = $script:sp.Id
    }

    Invoke-Step 'Assign roles (idempotent)' {
        foreach ($r in $script:roles) {
            $have = Get-AzRoleAssignment -ObjectId $script:objId -RoleDefinitionName $r -Scope $script:Scope -ErrorAction SilentlyContinue
            if ($have) { Write-Ok "Role present: $r"; continue }
            try {
                New-AzRoleAssignment -ObjectId $script:objId -RoleDefinitionName $r -Scope $script:Scope -ErrorAction Stop | Out-Null
                Write-Ok "Assigned: $r"
            } catch {
                Write-Warn "Could not assign '$r' at $script:Scope : $($_.Exception.Message)"
            }
        }
        Write-Info "Roles scoped to: $script:Scope"
    }

    Invoke-Step 'Persist SP identity for the orchestrator' {
        $dir = Split-Path -Path $script:OutFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        $record = [ordered]@{
            displayName    = $script:DisplayName
            appId          = $script:appId
            objectId       = $script:objId
            tenantId       = $script:TenantId
            subscriptionId = $script:SubscriptionId
            authType       = if ($script:UseCertificate) { 'certificate' } else { 'secret' }
            certThumbprint = $script:certThumb
            createdUtc     = (Get-Date).ToUniversalTime().ToString('o')
        }

        if (-not $script:UseCertificate -and $script:secretPlain) {
            if ($script:PlainSecretFile) {
                $record['secret'] = $script:secretPlain
                Write-Warn 'Secret stored in PLAINTEXT (-PlainSecretFile). Protect this file; never commit it.'
            } else {
                # DPAPI-protected: only decryptable by the same user on the same machine.
                $record['secretProtected'] = (ConvertTo-SecureString $script:secretPlain -AsPlainText -Force | ConvertFrom-SecureString)
                Write-Info 'Secret stored DPAPI-protected (same-user/same-machine decrypt only).'
            }
        }

        ($record | ConvertTo-Json -Depth 4) | Set-Content -Path $script:OutFile -Encoding UTF8
        Write-Ok "Wrote $script:OutFile"

        Write-Host ''
        Write-Host '  ----- SERVICE PRINCIPAL (record now; store in your private runbook) -----' -ForegroundColor Cyan
        Write-Host "   AppId     : $script:appId"
        Write-Host "   ObjectId  : $script:objId"
        Write-Host "   Tenant    : $script:TenantId"
        if ($script:UseCertificate) {
            Write-Host "   Cert      : $script:certThumb (Cert:\CurrentUser\My)"
        } elseif ($script:secretPlain) {
            Write-Host "   Secret    : $script:secretPlain" -ForegroundColor Yellow
            Write-Host "   (Azure shows the secret ONCE - it cannot be retrieved later.)" -ForegroundColor Yellow
        }
        Write-Host '  -------------------------------------------------------------------------' -ForegroundColor Cyan
    }

    Invoke-Step 'Capture node local-admin credential (DPAPI, one-time)' {
        if (Get-Command Set-LabNodeCredential -ErrorAction SilentlyContinue) {
            [void](Set-LabNodeCredential -User 'Administrator')
            Write-Info 'Stages 2/3/4 and the orchestrator will reuse this - no more WinRM password prompts.'
        } else {
            Write-Warn 'Set-LabNodeCredential not found (append ui-credstore block to ui-common.ps1). Skipping node-credential capture.'
        }
    }

    Complete-Ui -FinalMessage 'Service principal ready. Use it for Stage 4/5 unattended runs.'
}
catch {
    Write-Err $_.Exception.Message
    Complete-Ui -Failed -FinalMessage 'Service principal bootstrap failed.'
    throw
}
