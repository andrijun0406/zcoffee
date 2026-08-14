[CmdletBinding()]
param(
    [ValidateSet(
        '01-deploy-os',
        '02-configure-network',
        '03-prepare-node',
        '04-register-arc',
        '05-deploy-azure-local',
        '06-validate-cluster'
    )]
    [string]$Stage = '01-deploy-os',

    [switch]$UseGui,

    [string]$iDRACUser = 'root',
    [SecureString]$iDRACPassword,
    [string]$ISOFile,
    [string]$ExpectedISOHash,
    [int]$HttpPort = 8080,
    [string]$HttpHost,
    [string]$RACADMPath = 'racadm',
    [switch]$StartInstallation,
    [switch]$NoCertWarn,
    [int]$ServerLifetimeMinutes = 240,
    [switch]$NoWait,

    [string]$DnsServer = '10.8.230.51',
    [switch]$Apply,

    [ValidateSet('Validate','Register')]
    [string]$ArcMode = 'Validate',
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName = 'azljkt01rg',
    [string]$TemplateFile,
    [string]$ParameterFile,
    [string]$DeploymentName = 'azljkt01dep',
    [switch]$EnableDeployment,
    [string]$ClusterName = 'azl-jkt-01-clu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$root = $PSScriptRoot
$stageScript = Join-Path $root "$Stage.ps1"
if (-not (Test-Path $stageScript -PathType Leaf)) {
    throw "Stage script not found: $stageScript"
}

Write-Host ''
Write-Host '############################################################' -ForegroundColor Magenta
Write-Host " Azure Local Lab (Jakarta 01) - dispatching stage: $Stage" -ForegroundColor Magenta
Write-Host '############################################################' -ForegroundColor Magenta

switch ($Stage) {
    '01-deploy-os' {
        if (-not $PSBoundParameters.ContainsKey('iDRACPassword') -or $null -eq $iDRACPassword) {
            $iDRACPassword = Read-Host -Prompt "Enter the iDRAC password for '$iDRACUser'" -AsSecureString
        }
        & $stageScript `
            -iDRACUser $iDRACUser `
            -iDRACPassword $iDRACPassword `
            -ISOFile $ISOFile `
            -ExpectedISOHash $ExpectedISOHash `
            -HttpPort $HttpPort `
            -HttpHost $HttpHost `
            -RACADMPath $RACADMPath `
            -StartInstallation:$StartInstallation `
            -NoCertWarn:$NoCertWarn `
            -ServerLifetimeMinutes $ServerLifetimeMinutes `
            -NoWait:$NoWait `
            -UseGui:$UseGui
    }

    '02-configure-network' {
        & $stageScript -MgmtGateway '10.8.230.1' -DnsServer $DnsServer -Apply:$Apply -UseGui:$UseGui
    }

    '03-prepare-node' {
        & $stageScript -DnsServer $DnsServer -Apply:$Apply -UseGui:$UseGui
    }

    '04-register-arc' {
        & $stageScript `
            -Mode $ArcMode `
            -SubscriptionId $SubscriptionId `
            -TenantId $TenantId `
            -ResourceGroupName $ResourceGroupName `
            -Apply:$Apply `
            -UseGui:$UseGui
    }

    '05-deploy-azure-local' {
        if (-not $SubscriptionId -or -not $TemplateFile -or -not $ParameterFile) {
            throw 'Provide -SubscriptionId, -TemplateFile, and -ParameterFile.'
        }
        $deploymentMode = if ($EnableDeployment) { 'Deploy' } else { 'Validate' }
        & $stageScript `
            -DeploymentMode $deploymentMode `
            -EnableDeployment:$EnableDeployment `
            -SubscriptionId $SubscriptionId `
            -TenantId $TenantId `
            -ResourceGroupName $ResourceGroupName `
            -TemplateFile $TemplateFile `
            -ParameterFile $ParameterFile `
            -DeploymentName $DeploymentName `
            -UseGui:$UseGui
    }

    '06-validate-cluster' {
        & $stageScript -ClusterName $ClusterName -NodeNames @('azljkt01n1','azljkt01n2') -UseGui:$UseGui
    }
}

Write-Host ''
Write-Host "Dispatcher finished stage: $Stage" -ForegroundColor Magenta
