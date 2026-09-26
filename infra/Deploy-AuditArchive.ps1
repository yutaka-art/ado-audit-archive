<#
.SYNOPSIS
    Deploys the Azure DevOps ITGC evidence archive (custom tables + DCR) and
    grants the ingestion identity the required role on the DCR.

.DESCRIPTION
    Idempotent. Safe to re-run. Written for Windows PowerShell 5.1 and PowerShell 7+.
    Requires Azure CLI 2.60 or later, signed in with an account that has
    Contributor on the resource group and can assign roles (User Access Administrator
    or Owner) - or run with -SkipRoleAssignment and have the role assigned separately.

.EXAMPLE
    .\Deploy-AuditArchive.ps1 `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -ResourceGroupName rg-contoso-dev `
        -WorkspaceName law-contoso-dev `
        -IngestionPrincipalObjectId <object id of the service connection SPN>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$WorkspaceName,

    [string]$DcrName = 'dcr-ado-audit',
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'deploy-ado-audit-archive.json'),
    [int]$InteractiveRetentionInDays = 730,
    [int]$TotalRetentionInDays = 1095,

    # Object ID (not application ID) of the identity the export pipeline uses.
    [string]$IngestionPrincipalObjectId,
    [switch]$SkipRoleAssignment
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

Write-Step "Checking Azure CLI"
$null = & az version 2>$null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not found on PATH." }

Write-Step "Selecting subscription $SubscriptionId"
& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to select subscription." }

Write-Step "Verifying workspace $WorkspaceName exists"
$wsJson = & az monitor log-analytics workspace show `
    --resource-group $ResourceGroupName --workspace-name $WorkspaceName -o json
if ($LASTEXITCODE -ne 0) { throw "Log Analytics workspace not found." }
$ws = $wsJson | ConvertFrom-Json
Write-Host "    location   : $($ws.location)"
Write-Host "    customerId : $($ws.customerId)"

Write-Step "Deploying tables and data collection rule"
$deploymentName = "ado-audit-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss')
$deployJson = & az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroupName `
    --template-file $TemplateFile `
    --parameters `
        workspaceName=$WorkspaceName `
        location=$($ws.location) `
        dcrName=$DcrName `
        interactiveRetentionInDays=$InteractiveRetentionInDays `
        totalRetentionInDays=$TotalRetentionInDays `
    -o json
if ($LASTEXITCODE -ne 0) { throw "Deployment failed." }

$deploy = $deployJson | ConvertFrom-Json
$dcrResourceId = $deploy.properties.outputs.dcrResourceId.value
$dcrImmutableId = $deploy.properties.outputs.dcrImmutableId.value
$logsIngestionEndpoint = $deploy.properties.outputs.logsIngestionEndpoint.value

if ($SkipRoleAssignment -or [string]::IsNullOrWhiteSpace($IngestionPrincipalObjectId)) {
    Write-Step "Skipping role assignment (assign 'Monitoring Metrics Publisher' on the DCR manually)"
}
else {
    Write-Step "Granting 'Monitoring Metrics Publisher' on the DCR to $IngestionPrincipalObjectId"
    $existing = & az role assignment list `
        --assignee $IngestionPrincipalObjectId `
        --scope $dcrResourceId `
        --role "Monitoring Metrics Publisher" -o tsv --query "[].id"
    if ([string]::IsNullOrWhiteSpace($existing)) {
        & az role assignment create `
            --assignee-object-id $IngestionPrincipalObjectId `
            --assignee-principal-type ServicePrincipal `
            --role "Monitoring Metrics Publisher" `
            --scope $dcrResourceId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Role assignment failed." }
        Write-Host "    role assigned."
    }
    else {
        Write-Host "    role already assigned - nothing to do."
    }
}

Write-Host ""
Write-Host "-------------------------------------------------------------" -ForegroundColor Green
Write-Host " Deployment complete. Record these values in the variable group" -ForegroundColor Green
Write-Host "-------------------------------------------------------------" -ForegroundColor Green
Write-Host " LAW_DCR_ENDPOINT     = $logsIngestionEndpoint"
Write-Host " LAW_DCR_IMMUTABLE_ID = $dcrImmutableId"
Write-Host " LAW_DCR_RESOURCE_ID  = $dcrResourceId"
Write-Host " LAW_CUSTOMER_ID      = $($ws.customerId)"
Write-Host ""
Write-Host " Note: custom table data becomes queryable a few minutes after the"
Write-Host "       first successful ingestion call."
