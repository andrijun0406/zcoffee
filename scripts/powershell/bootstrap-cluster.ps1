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

    # Optional Autounattend media (Stage 01 only). Mounted via iDRAC RFS2.
    [string]$AutounattendIso,
    [string]$AutounattendUrl,

    [string]$DnsServer,
    [switch]$Apply,

    [ValidateSet('Validate','Register')]
    [string]$ArcMode = 'Validate',
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName,
    [string]$TemplateFile,
    [string]$ParameterFile,
    [string]$DeploymentName,
    [switch]$EnableDeployment,
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
$stageParams = (Get-Command $stageScript).Parameters.Keys
$clean = @{}
foreach ($k in $forward.Keys) {
    if ($stageParams -contains $k) { $clean[$k] = $forward[$k] }
}

& $stageScript @clean

Write-Host ''
Write-Host "Dispatcher finished stage: $Stage" -ForegroundColor Magenta
