[CmdletBinding()]
param(
    [ValidateSet(
        '01-deploy-os','02-configure-network','03-prepare-node',
        '04-register-arc','05-deploy-azure-local','06-validate-cluster'
    )]
    [string]$Stage = '01-deploy-os',

    [switch]$UseGui,

    # Overrides (optional). If omitted, values come from lab-config.psd1.
    [string]$iDRACUser,
    [SecureString]$iDRACPassword,
    [string]$ISOFile,
    [string]$ISOUrl,
    [string]$ExpectedISOHash,
    [int]$HttpPort,
    [string]$HttpHost,
    [string]$HttpBind,
    [string]$RACADMPath = 'racadm',
    [switch]$StartInstallation,
    [switch]$NoCertWarn,
    [int]$ServerLifetimeMinutes = 240,
    [switch]$NoWait,


    [string]$DnsServer,
    [switch]$Apply,

    # Stage 2 (host network readiness validation)
    [string[]]$NodeIPs,
    [string]$LocalAdminUser,
    [SecureString]$LocalAdminPassword,
    [ValidateSet('HTTPS','HTTP')]
    [string]$Transport,
    [int]$Port,
    [switch]$ConfigureTrustedHosts,
    [switch]$SkipCertCheck,
    [switch]$SkipEnvChecker,
    [switch]$ConnectivityOnly,
    [switch]$ApplyVlanTag,
    [switch]$RebootIfRenamed,
    [switch]$ForceIpChange,

    [ValidateSet('Validate','Register')]
    [string]$ArcMode = 'Validate',
    [string]$Region,
    [string]$Cloud,
    [switch]$UseExistingAzLogin,
    [string]$ServicePrincipalId,
    [SecureString]$ServicePrincipalSecret,
    [string]$CertificateThumbprint,
    [switch]$UseManagedIdentity,
    [string]$AccountId,
    [switch]$ForceReregister,
    [switch]$UseArcGateway,
    [string]$ArcGatewayID,
    [string]$ArcGatewayName,
    [int]$ArcGatewayTimeoutMin,
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName,
    [string]$TemplateFile,
    [string]$ParameterFile,
    [string]$DeploymentName,
    [switch]$EnableDeployment,
    [ValidateSet('Validate','Deploy')]
    [string]$DeploymentMode,
    [switch]$SkipArcCheck,
    [string]$ClusterName,

    # Hardware prep (Stage 01 only)
    [switch]$FirmwareCheckOnly,
    [switch]$UpdateFirmware,
    [string]$CatalogUrl,
    [switch]$UpdateBios,
    [string]$BiosDupFile,
    [string]$BiosRepoUrl,
    [string]$BiosRepoProtocol = 'HTTPS',
    [switch]$UpdateIdrac,
    [string]$IdracDupFile,
    [string]$IdracRepoUrl,
    [string]$IdracRepoProtocol = 'HTTPS',
    [switch]$RecreateBossVd,
    [switch]$ForceHardwarePrep,
    [switch]$DisableSecureBoot,
    [switch]$EnableSecureBoot,

    # Target a single node by iDRAC IP, node name, or host IP (Stage 01 only)
    [string]$OnlyNode,

    # Multi-node boot pacing (Stage 01 only). Sequential is the default for >1 node.
    [switch]$ParallelNodes,
    [int]$NodeBootGapSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$root = $PSScriptRoot
$stageScript = Join-Path $root "$Stage.ps1"
if (-not (Test-Path $stageScript -PathType Leaf)) { throw "Stage script not found: $stageScript" }

Write-Host ''
Write-Host '############################################################' -ForegroundColor Magenta
Write-Host " Azure Local Lab (Jakarta 01) - dispatching stage: $Stage" -ForegroundColor Magenta
Write-Host " Source of truth: lab-config.psd1 (parameters override it)" -ForegroundColor Magenta
Write-Host '############################################################' -ForegroundColor Magenta

# Forward only parameters the caller actually provided, so each stage can
# fall back to lab-config.psd1 for everything else.
$forward = @{}
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -in @('Stage')) { continue }
    $forward[$k] = $PSBoundParameters[$k]
}

switch ($Stage) {
    '01-deploy-os' {
        if (-not $forward.ContainsKey('iDRACPassword')) {
            $u = if ($forward.ContainsKey('iDRACUser')) { $forward['iDRACUser'] } else { 'root' }
            $forward['iDRACPassword'] = Read-Host -Prompt "Enter the iDRAC password for '$u'" -AsSecureString
        }
    }
    '05-deploy-azure-local' {
        if (-not $forward.ContainsKey('TemplateFile') -or -not $forward.ContainsKey('ParameterFile')) {
            throw 'Provide -TemplateFile and -ParameterFile for the Azure Local stage.'
        }
        if ($forward.ContainsKey('EnableDeployment') -and $EnableDeployment) {
            $forward['DeploymentMode'] = 'Deploy'
        }
    }
}

# ArcMode maps to the stage's -Mode parameter.
if ($Stage -eq '04-register-arc') {
    if ($forward.ContainsKey('ArcMode')) { $forward['Mode'] = $forward['ArcMode']; $forward.Remove('ArcMode') }
}
else {
    $forward.Remove('ArcMode') | Out-Null
}

# Drop parameters not accepted by the target stage to avoid binding errors.
# Resolve the stage script's parameter names. Get-Command.Parameters can be $null
# in some contexts (under StrictMode that then throws on .Keys), so fall back to
# parsing the param() block via the PowerShell AST.
$stageParams = $null
try {
    $cmdInfo = Get-Command $stageScript -ErrorAction Stop
    if ($cmdInfo.Parameters) { $stageParams = @($cmdInfo.Parameters.Keys) }
} catch { $stageParams = $null }

if (-not $stageParams) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($stageScript, [ref]$tokens, [ref]$errors)
    $paramBlock = $ast.ParamBlock
    if (-not $paramBlock -and $ast.EndBlock) { $paramBlock = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ParamBlockAst] } | Select-Object -First 1 }
    if ($paramBlock) {
        $stageParams = @($paramBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    } else {
        $stageParams = @()
    }
}

$clean = @{}
foreach ($k in $forward.Keys) {
    if ($stageParams -contains $k) { $clean[$k] = $forward[$k] }
}

& $stageScript @clean

Write-Host ''
Write-Host "Dispatcher finished stage: $Stage" -ForegroundColor Magenta
