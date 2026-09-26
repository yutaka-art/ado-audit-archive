<#
.SYNOPSIS
    US-SOX ITGC - exports Azure DevOps pull request, pipeline run and
    approval records into Azure Monitor Logs custom tables.

.DESCRIPTION
    Runs inside an Azure Pipelines AzureCLI@2 task (the Azure CLI is already
    signed in as the workload-identity service principal).

    Flow:
      1. Resolve the time window.
      2. Enumerate projects in the organization.
      3. Extract PR / pipeline run / approval records via the Azure DevOps REST API.
      4. Write the raw payload to disk and publish it as a pipeline artifact.
      5. Ingest the records into Log Analytics via the Logs Ingestion API.
      6. Write a self-audit summary record (completeness evidence).

    Re-running the same window is safe: Log Analytics is append-only, and the
    supplied KQL views deduplicate on RecordId with arg_max(ExportedOn, *).

.NOTES
    Compatibility : Windows PowerShell 5.1 and PowerShell 7+
    Exit codes    : 0 success, 1 failure, 2 partial success
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Organization,

    [Parameter(Mandatory = $true)][string]$IngestionEndpoint,
    [Parameter(Mandatory = $true)][string]$DcrImmutableId,

    # Time window. Omit both to use -LookbackHours from now.
    [string]$WindowStartUtc,
    [string]$WindowEndUtc,
    [int]$LookbackHours = 24,
    # Re-scan overlap so records that settle late are not missed. Deduplicated at query time.
    [int]$OverlapHours = 6,

    [string[]]$ProjectFilter = @(),

    [ValidateSet('Entra', 'Pat', 'OAuth')][string]$AuthMode = 'Entra',
    [string]$PersonalAccessToken,
    [string]$SystemAccessToken,

    [switch]$IncludePolicyEvaluations,
    [switch]$WhatIfOnly,

    [string]$OutputDirectory = (Join-Path (Get-Location) 'export-output'),
    [string]$ExportPipelineWebUrl = '',
    [int]$ExportPipelineBuildId = 0,
    [string]$AgentName = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Import-Module (Join-Path $PSScriptRoot 'AdoAuditExport.psm1') -Force

$scriptVersion = '1.1.1'
$exportRunId = [guid]::NewGuid().ToString()
$overallStart = Get-Date
$exitCode = 0

# ------------------------------------------------------------------
# Resolve time window
# ------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($WindowEndUtc)) {
    $endUtc = (Get-Date).ToUniversalTime()
}
else {
    $endUtc = ([datetime]$WindowEndUtc).ToUniversalTime()
}

if ([string]::IsNullOrWhiteSpace($WindowStartUtc)) {
    $startUtc = $endUtc.AddHours(-1 * ($LookbackHours + $OverlapHours))
}
else {
    $startUtc = ([datetime]$WindowStartUtc).ToUniversalTime().AddHours(-1 * $OverlapHours)
}

if ($startUtc -ge $endUtc) { throw "WindowStartUtc must be earlier than WindowEndUtc." }

Write-AuditLog -Message "=============================================================="
Write-AuditLog -Message ("ADO audit export - script version {0}" -f $scriptVersion)
Write-AuditLog -Message ("ExportRunId   : {0}" -f $exportRunId)
Write-AuditLog -Message ("Organization  : {0}" -f $Organization)
Write-AuditLog -Message ("Window (UTC)  : {0} .. {1}" -f $startUtc.ToString('s'), $endUtc.ToString('s'))
Write-AuditLog -Message ("AuthMode      : {0}" -f $AuthMode)
Write-AuditLog -Message ("WhatIfOnly    : {0}" -f [bool]$WhatIfOnly)
Write-AuditLog -Message "=============================================================="

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

# ------------------------------------------------------------------
# Authentication
# ------------------------------------------------------------------
Write-AuditLog -Message ("Authenticating to Azure DevOps and Azure Monitor using {0}." -f $AuthMode)

$adoHeaders = New-AdoAuthHeader `
    -AuthMode $AuthMode `
    -PersonalAccessToken $PersonalAccessToken `
    -SystemAccessToken $SystemAccessToken

$monitorToken = Get-AzCliToken -Resource 'https://monitor.azure.com'

if ([string]::IsNullOrWhiteSpace($monitorToken)) {
    throw "Azure Monitor access token is empty."
}

Write-AuditLog -Message "Authentication completed."

# ------------------------------------------------------------------
# Extract
# ------------------------------------------------------------------
$allPullRequests = New-Object System.Collections.ArrayList
$allRuns = New-Object System.Collections.ArrayList
$allApprovals = New-Object System.Collections.ArrayList
$perProjectSummary = New-Object System.Collections.ArrayList
$errors = New-Object System.Collections.ArrayList

$projects = Get-AdoProject -Organization $Organization -Headers $adoHeaders -ProjectFilter $ProjectFilter
Write-AuditLog -Message ("Projects in scope: {0}" -f @($projects).Count)
if (@($projects).Count -eq 0) {
    throw "No projects in scope. Check the ProjectFilter value and the identity's project read permissions."
}

foreach ($project in $projects) {
    $projectStart = Get-Date
    Write-AuditLog -Message ("--- Project: {0} ---" -f $project.name)

    try {
        $prRecords = Get-AdoPullRequestRecord -Organization $Organization -Project $project `
            -Headers $adoHeaders -WindowStartUtc $startUtc -WindowEndUtc $endUtc `
            -ExportRunId $exportRunId -IncludePolicyEvaluations:$IncludePolicyEvaluations
        foreach ($r in $prRecords) { [void]$allPullRequests.Add($r) }

        $pipelineResult = Get-AdoPipelineRunRecord -Organization $Organization -Project $project `
            -Headers $adoHeaders -WindowStartUtc $startUtc -WindowEndUtc $endUtc -ExportRunId $exportRunId
        foreach ($r in $pipelineResult.Runs) { [void]$allRuns.Add($r) }
        foreach ($r in $pipelineResult.Approvals) { [void]$allApprovals.Add($r) }

        [void]$perProjectSummary.Add([PSCustomObject]@{
            ProjectName     = $project.name
            PullRequests    = @($prRecords).Count
            PipelineRuns    = @($pipelineResult.Runs).Count
            Approvals       = @($pipelineResult.Approvals).Count
            DurationSeconds = [math]::Round(((Get-Date) - $projectStart).TotalSeconds, 2)
            Status          = 'Succeeded'
            ErrorMessage    = ''
        })
    }
    catch {
        $message = $_.Exception.Message
        Write-AuditLog -Level ERROR -Message ("Project '{0}' failed: {1}" -f $project.name, $message)
        [void]$errors.Add(("{0}: {1}" -f $project.name, $message))
        [void]$perProjectSummary.Add([PSCustomObject]@{
            ProjectName     = $project.name
            PullRequests    = 0
            PipelineRuns    = 0
            Approvals       = 0
            DurationSeconds = [math]::Round(((Get-Date) - $projectStart).TotalSeconds, 2)
            Status          = 'Failed'
            ErrorMessage    = $message
        })
        $exitCode = 2
    }
}

Write-AuditLog -Message ("Extracted totals - PR: {0}, Runs: {1}, Approvals: {2}" -f `
    $allPullRequests.Count, $allRuns.Count, $allApprovals.Count)

# ------------------------------------------------------------------
# Archive raw payload (tamper-evidence hash)
# ------------------------------------------------------------------
$archive = [ordered]@{
    exportRunId    = $exportRunId
    organization   = $Organization
    windowStartUtc = $startUtc.ToString('o')
    windowEndUtc   = $endUtc.ToString('o')
    scriptVersion  = $scriptVersion
    generatedOnUtc = (Get-Date).ToUniversalTime().ToString('o')
    pullRequests   = @($allPullRequests)
    pipelineRuns   = @($allRuns)
    approvals      = @($allApprovals)
}

$archiveFileName = "ado-audit-{0}-{1}.json" -f $Organization, $endUtc.ToString('yyyyMMddHHmmss')
$archivePath = Join-Path $OutputDirectory $archiveFileName
$archiveJson = $archive | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($archivePath, $archiveJson, (New-Object Text.UTF8Encoding($false)))

# The persisted archive file is the authoritative audit artifact.
# Hash the exact bytes written to disk so the pipeline artifact, result JSON,
# and Log Analytics self-audit record all use the same immutable value.
$payloadHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-AuditLog -Message ("Archive written: {0}" -f $archivePath)
Write-AuditLog -Message ("SHA256        : {0}" -f $payloadHash)

# ------------------------------------------------------------------
# Ingest
# ------------------------------------------------------------------
$ingestedPr = 0; $ingestedRun = 0; $ingestedApproval = 0

try {
    $ingestedPr = Send-LawRecord -IngestionEndpoint $IngestionEndpoint -DcrImmutableId $DcrImmutableId `
        -StreamName 'Custom-ADO_PullRequest_CL' -Records $allPullRequests `
        -AccessToken $monitorToken -WhatIfOnly:$WhatIfOnly

    $ingestedRun = Send-LawRecord -IngestionEndpoint $IngestionEndpoint -DcrImmutableId $DcrImmutableId `
        -StreamName 'Custom-ADO_PipelineRun_CL' -Records $allRuns `
        -AccessToken $monitorToken -WhatIfOnly:$WhatIfOnly

    $ingestedApproval = Send-LawRecord -IngestionEndpoint $IngestionEndpoint -DcrImmutableId $DcrImmutableId `
        -StreamName 'Custom-ADO_Approval_CL' -Records $allApprovals `
        -AccessToken $monitorToken -WhatIfOnly:$WhatIfOnly
}
catch {
    Write-AuditLog -Level ERROR -Message ("Ingestion failed: {0}" -f $_.Exception.Message)
    [void]$errors.Add(("Ingestion: {0}" -f $_.Exception.Message))
    $exitCode = 1
}

# ------------------------------------------------------------------
# Self-audit records (completeness evidence)
# ------------------------------------------------------------------
$totalDuration = [math]::Round(((Get-Date) - $overallStart).TotalSeconds, 2)
$overallStatus = 'Succeeded'
if ($exitCode -eq 2) { $overallStatus = 'PartiallySucceeded' }
if ($exitCode -eq 1) { $overallStatus = 'Failed' }

$auditRecords = New-Object System.Collections.ArrayList
$nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

function New-AuditRecord {
    param(
        [string]$RecordType,
        [string]$ProjectName,
        [int]$Extracted,
        [int]$Ingested,
        [int]$Failed,
        [double]$Duration,
        [string]$Status,
        [string]$ErrorMessage,
        [Parameter(Mandatory = $true)][string]$PayloadSha256
    )
    return [ordered]@{
        TimeGenerated          = $nowUtc
        ExportRunId            = $exportRunId
        Organization           = $Organization
        RecordType             = $RecordType
        ProjectName            = $ProjectName
        WindowStartUtc         = $startUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        WindowEndUtc           = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        ExtractedCount         = $Extracted
        IngestedCount          = $Ingested
        FailedCount            = $Failed
        DurationSeconds        = $Duration
        Status                 = $Status
        ErrorMessage           = $ErrorMessage
        PayloadSha256          = $PayloadSha256
        ArchiveFileName        = $archiveFileName
        ExportPipelineBuildId  = $ExportPipelineBuildId
        ExportPipelineWebUrl   = $ExportPipelineWebUrl
        AgentName              = $AgentName
        ScriptVersion          = $scriptVersion
    }
}

foreach ($summary in $perProjectSummary) {
    [void]$auditRecords.Add((New-AuditRecord -RecordType 'PullRequest' -ProjectName $summary.ProjectName `
        -Extracted $summary.PullRequests -Ingested $summary.PullRequests -Failed 0 `
        -Duration $summary.DurationSeconds -Status $summary.Status -ErrorMessage $summary.ErrorMessage `
        -PayloadSha256 $payloadHash))
    [void]$auditRecords.Add((New-AuditRecord -RecordType 'PipelineRun' -ProjectName $summary.ProjectName `
        -Extracted $summary.PipelineRuns -Ingested $summary.PipelineRuns -Failed 0 `
        -Duration $summary.DurationSeconds -Status $summary.Status -ErrorMessage $summary.ErrorMessage `
        -PayloadSha256 $payloadHash))
    [void]$auditRecords.Add((New-AuditRecord -RecordType 'Approval' -ProjectName $summary.ProjectName `
        -Extracted $summary.Approvals -Ingested $summary.Approvals -Failed 0 `
        -Duration $summary.DurationSeconds -Status $summary.Status -ErrorMessage $summary.ErrorMessage `
        -PayloadSha256 $payloadHash))
}

$totalExtracted = $allPullRequests.Count + $allRuns.Count + $allApprovals.Count
$totalIngested = $ingestedPr + $ingestedRun + $ingestedApproval
[void]$auditRecords.Add((New-AuditRecord -RecordType 'Summary' -ProjectName '(all)' `
    -Extracted $totalExtracted -Ingested $totalIngested -Failed ($totalExtracted - $totalIngested) `
    -Duration $totalDuration -Status $overallStatus -ErrorMessage (($errors | Select-Object -First 5) -join ' | ') `
    -PayloadSha256 $payloadHash))

# Integrity guard: every self-audit record for this export must carry exactly
# the SHA256 of the persisted archive file.
$auditHashes = @(
    $auditRecords |
        ForEach-Object { ([string]$_.PayloadSha256).Trim().ToLowerInvariant() } |
        Sort-Object -Unique
)

if ($auditHashes.Count -ne 1 -or $auditHashes[0] -cne $payloadHash) {
    throw ("Self-audit SHA256 integrity check failed before ingestion. Archive={0}; AuditRecordHashes={1}" -f `
        $payloadHash, ($auditHashes -join ','))
}

Write-AuditLog -Message ("Self-audit outbound SHA256: {0}" -f $payloadHash)

try {
    Send-LawRecord -IngestionEndpoint $IngestionEndpoint -DcrImmutableId $DcrImmutableId `
        -StreamName 'Custom-ADO_ExportAudit_CL' -Records $auditRecords `
        -AccessToken $monitorToken -WhatIfOnly:$WhatIfOnly | Out-Null
}
catch {
    Write-AuditLog -Level ERROR -Message ("Self-audit ingestion failed: {0}" -f $_.Exception.Message)
    [void]$errors.Add(("Self-audit ingestion: {0}" -f $_.Exception.Message))
    $exitCode = 1
    $overallStatus = 'Failed'
}

# ------------------------------------------------------------------
# Result file for the pipeline summary step
# ------------------------------------------------------------------
$result = [ordered]@{
    exportRunId     = $exportRunId
    status          = $overallStatus
    windowStartUtc  = $startUtc.ToString('o')
    windowEndUtc    = $endUtc.ToString('o')
    pullRequests    = $allPullRequests.Count
    pipelineRuns    = $allRuns.Count
    approvals       = $allApprovals.Count
    ingestedTotal   = $totalIngested
    payloadSha256   = $payloadHash
    archiveFileName = $archiveFileName
    durationSeconds = $totalDuration
    errors          = @($errors)
}
$resultPath = Join-Path $OutputDirectory 'export-result.json'
[IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

Write-AuditLog -Message "=============================================================="
Write-AuditLog -Message ("Status: {0} | extracted {1} | ingested {2} | {3}s" -f `
    $overallStatus, $totalExtracted, $totalIngested, $totalDuration)
Write-AuditLog -Message "=============================================================="

if ($errors.Count -gt 0) {
    foreach ($e in $errors) { Write-AuditLog -Level ERROR -Message $e }
}

exit $exitCode
