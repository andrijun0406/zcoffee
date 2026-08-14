[CmdletBinding()]
param(
    [ValidateSet('Validate','Deploy')]
    [string]$DeploymentMode = 'Validate',
    [switch]$EnableDeployment,
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$TemplateFile,
    [Parameter(Mandatory)][string]$ParameterFile,
    [string]$DeploymentName,
    [string]$TenantId,
    [switch]$UseGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-common.ps1')

$cfg = Import-LabConfig
$b = $PSBoundParameters
$SubscriptionId    = Resolve-Setting -Name 'SubscriptionId'    -Bound $b -Current $SubscriptionId    -ConfigKey 'SubscriptionId' -Config $cfg
$TenantId          = Resolve-Setting -Name 'TenantId'          -Bound $b -Current $TenantId          -ConfigKey 'TenantId'       -Config $cfg
$ResourceGroupName = Resolve-Setting -Name 'ResourceGroupName' -Bound $b -Current $ResourceGroupName -ConfigKey 'ResourceGroup'  -Config $cfg; if (-not $ResourceGroupName) { $ResourceGroupName = 'azljkt01rg' }
$DeploymentName    = Resolve-Setting -Name 'DeploymentName'    -Bound $b -Current $DeploymentName    -ConfigKey 'DeploymentName' -Config $cfg; if (-not $DeploymentName) { $DeploymentName = 'azljkt01dep' }

if (-not $SubscriptionId) { throw 'SubscriptionId is required. Set it in lab-config.psd1 or pass -SubscriptionId.' }

function Invoke-AzureCli {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed:`n$($output -join [Environment]::NewLine)" }
    return $output
}

Initialize-Ui -StageName '05-deploy-azure-local' -TotalSteps 4 -UseGui:$UseGui

try {
    Invoke-Step 'Validate tooling and input files' {
        if (-not (Get-Command az -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Azure CLI was not found.' }
        if (-not (Test-Path $TemplateFile -PathType Leaf)) { throw "ARM template not found: $TemplateFile" }
        if (-not (Test-Path $ParameterFile -PathType Leaf)) { throw "Parameter file not found: $ParameterFile" }
    }
    Invoke-Step 'Confirm Azure context' {
        $account = Invoke-AzureCli -Arguments @('account','show','--output','json') | ConvertFrom-Json
        if ($TenantId -and $account.tenantId -ne $TenantId) { throw "Tenant mismatch. Expected $TenantId; current $($account.tenantId)." }
        Invoke-AzureCli -Arguments @('account','set','--subscription',$SubscriptionId) | Out-Null
        Write-Info "Subscription: $SubscriptionId"
        Write-Info "Resource group: $ResourceGroupName"
        Write-Info "Deployment: $DeploymentName ($DeploymentMode)"
    }
    if ($DeploymentMode -eq 'Validate') {
        Invoke-Step 'Run non-mutating ARM validation' {
            Invoke-AzureCli -Arguments @(
                'deployment','group','validate',
                '--resource-group',$ResourceGroupName,
                '--template-file',$TemplateFile,
                '--parameters',"@$ParameterFile",
                'deploymentMode=Validate','--output','json'
            ) | Out-Host
            Write-Warn 'Validation only. No Azure Local instance was created.'
        }
        Complete-Ui -FinalMessage 'ARM validation finished.'
        return
    }
    if (-not $EnableDeployment) { throw 'Deploy mode is disabled by default. Re-run with -EnableDeployment after review.' }
    Invoke-Step 'Preview with what-if and deploy on confirmation' {
        Invoke-AzureCli -Arguments @(
            'deployment','group','what-if',
            '--resource-group',$ResourceGroupName,'--name',$DeploymentName,
            '--template-file',$TemplateFile,'--parameters',"@$ParameterFile",
            'deploymentMode=Deploy','--result-format','FullResourcePayloads'
        ) | Out-Host
        $confirm = Read-Host 'Type DEPLOY to submit the ARM deployment'
        if ($confirm -cne 'DEPLOY') { throw 'Deployment cancelled by operator.' }
        Invoke-AzureCli -Arguments @(
            'deployment','group','create',
            '--resource-group',$ResourceGroupName,'--name',$DeploymentName,
            '--template-file',$TemplateFile,'--parameters',"@$ParameterFile",
            'deploymentMode=Deploy','--output','json'
        ) | Out-Host
    }
    Complete-Ui -FinalMessage 'ARM deployment submitted.'
}
catch { Write-Err $_.Exception.Message; Complete-Ui -Failed; throw }
