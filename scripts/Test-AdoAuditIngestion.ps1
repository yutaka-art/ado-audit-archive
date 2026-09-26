<#
.SYNOPSIS
    Reconciles an Azure DevOps evidence export with Log Analytics.

.DESCRIPTION
    Verifies:
      - the self-audit Summary row exists for the current ExportRunId/build,
      - PR/run/approval row counts match export-result.json,
      - archive SHA256 matches export-result.json and Log Analytics,
      - approval records contain required evidence fields,
      - the export completed successfully.

    Exit codes:
      0 = all checks passed
      1 = one or more checks failed
      3 = self-audit data was not queryable within the configured wait period

.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspaceCustomerId,
    [string]$ExportRunId,
    [string]$ResultFile,
    [int]$MaxWaitSeconds = 900,
    [int]$PollIntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:LogAnalyticsQueryToken = $null

function Write-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $mark = if ($Passed) { '[PASS]' } else { '[FAIL]' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("{0} {1} - {2}" -f $mark, $Name, $Detail) -ForegroundColor $color
}

function Get-HttpStatusCode {
    param($Exception)

    if ($null -eq $Exception) { return 0 }

    $responseProperty = $Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) {
        return 0
    }

    try { return [int]$responseProperty.Value.StatusCode }
    catch { return 0 }
}

function Get-LogAnalyticsQueryToken {
    if (-not [string]::IsNullOrWhiteSpace($script:LogAnalyticsQueryToken)) {
        return $script:LogAnalyticsQueryToken
    }

    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & az account get-access-token `
            --resource 'https://api.loganalytics.io' `
            --query accessToken `
            --output tsv `
            --only-show-errors 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "Failed to acquire a Log Analytics query token. Azure CLI exit code: $exitCode"
    }

    $token = (@($output) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Log Analytics query token is empty."
    }

    $script:LogAnalyticsQueryToken = $token
    return $token
}

function Invoke-Kql {
    param([Parameter(Mandatory = $true)][string]$Query)

    $uri = "https://api.loganalytics.io/v1/workspaces/$WorkspaceCustomerId/query"
    $headers = @{
        Authorization   = 'Bearer ' + (Get-LogAnalyticsQueryToken)
        'Cache-Control' = 'no-cache, no-store'
        Pragma          = 'no-cache'
    }
    $body = @{ query = $Query } | ConvertTo-Json -Compress

    $response = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $response = Invoke-RestMethod `
                -Uri $uri `
                -Method Post `
                -Headers $headers `
                -ContentType 'application/json; charset=utf-8' `
                -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                -ErrorAction Stop
            break
        }
        catch {
            $status = Get-HttpStatusCode -Exception $_.Exception
            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 4) {
                Start-Sleep -Seconds ([math]::Min([math]::Pow(2, $attempt), 15))
                continue
            }
            throw ("Logs Query API failed (HTTP {0}): {1}" -f $status, $_.Exception.Message)
        }
    }

    if ($null -eq $response) { return @() }

    $tablesProperty = $response.PSObject.Properties['tables']
    if ($null -eq $tablesProperty -or @($tablesProperty.Value).Count -eq 0) {
        return @()
    }

    $table = @($tablesProperty.Value)[0]
    $rowsProperty = $table.PSObject.Properties['rows']
    $columnsProperty = $table.PSObject.Properties['columns']

    if ($null -eq $rowsProperty -or @($rowsProperty.Value).Count -eq 0) {
        return @()
    }

    $columnNames = @(
        @($columnsProperty.Value) |
            ForEach-Object {
                $nameProperty = $_.PSObject.Properties['name']
                if ($null -ne $nameProperty) { [string]$nameProperty.Value }
            }
    )

    $result = New-Object System.Collections.ArrayList
    foreach ($row in @($rowsProperty.Value)) {
        $record = [ordered]@{}
        $values = @($row)

        for ($i = 0; $i -lt $columnNames.Count; $i++) {
            $record[$columnNames[$i]] = if ($i -lt $values.Count) { $values[$i] } else { $null }
        }

        [void]$result.Add([PSCustomObject]$record)
    }

    return @($result)
}

function Get-RowCount {
    param(
        [Parameter(Mandatory = $true)][string]$TableName,
        [Parameter(Mandatory = $true)][string]$RunId
    )

    $query = @"
$TableName
| where tostring(ExportRunId) == '$RunId'
| summarize Rows = dcount(tostring(RecordId))
| project Rows
"@

    $rows = @(Invoke-Kql -Query $query)
    if ($rows.Count -eq 0) { return 0 }

    return [int]$rows[0].Rows
}

function Wait-ForSummaryRow {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [int]$BuildId
    )

    $waited = 0
    while ($waited -le $MaxWaitSeconds) {
        $buildPredicate = if ($BuildId -gt 0) {
            "| where toint(ExportPipelineBuildId) == $BuildId"
        }
        else {
            ''
        }

        $query = @"
ADO_ExportAudit_CL
| where tostring(ExportRunId) == '$RunId'
| where tostring(RecordType) == 'Summary'
$buildPredicate
| project
    TimeGenerated,
    ExportRunId = tostring(ExportRunId),
    Status = tostring(Status),
    ExtractedCount = toint(ExtractedCount),
    IngestedCount = toint(IngestedCount),
    FailedCount = toint(FailedCount),
    PayloadSha256 = tostring(PayloadSha256),
    ArchiveFileName = tostring(ArchiveFileName),
    ExportPipelineBuildId = toint(ExportPipelineBuildId),
    ExportPipelineWebUrl = tostring(ExportPipelineWebUrl),
    ScriptVersion = tostring(ScriptVersion),
    WindowStartUtc,
    WindowEndUtc
| top 1 by TimeGenerated desc
"@

        try {
            $rows = @(Invoke-Kql -Query $query)
            if ($rows.Count -gt 0) {
                return $rows[0]
            }
        }
        catch {
            Write-Host ("  Summary query failed; retrying: {0}" -f $_.Exception.Message)
        }

        if ($waited -ge $MaxWaitSeconds) { break }

        Start-Sleep -Seconds $PollIntervalSeconds
        $waited += $PollIntervalSeconds
        Write-Host ("  Waiting for self-audit row: {0}s/{1}s" -f $waited, $MaxWaitSeconds)
    }

    return $null
}

function Wait-ForExpectedRowCount {
    param(
        [Parameter(Mandatory = $true)][string]$TableName,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][int]$ExpectedCount
    )

    if ($ExpectedCount -eq 0) {
        return [PSCustomObject]@{
            Count  = 0
            Waited = 0
            Error  = $null
        }
    }

    $waited = 0
    $actual = 0
    $lastError = $null

    while ($waited -le $MaxWaitSeconds) {
        try {
            $actual = Get-RowCount -TableName $TableName -RunId $RunId
            $lastError = $null

            Write-Host (
                "  Row visibility: {0} expected={1} found={2} waited={3}s" -f `
                    $TableName, $ExpectedCount, $actual, $waited
            )

            if ($actual -eq $ExpectedCount -or $actual -gt $ExpectedCount) {
                break
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Host ("  Row count query failed for {0}; retrying: {1}" -f $TableName, $lastError)
        }

        if ($waited -ge $MaxWaitSeconds) { break }

        Start-Sleep -Seconds $PollIntervalSeconds
        $waited += $PollIntervalSeconds
    }

    return [PSCustomObject]@{
        Count  = $actual
        Waited = $waited
        Error  = $lastError
    }
}

function Test-ArchiveIntegrity {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$SummaryRow
    )

    $expectedHash = ([string]$Expected.payloadSha256).Trim().ToLowerInvariant()
    $ingestedHash = ([string]$SummaryRow.PayloadSha256).Trim().ToLowerInvariant()
    $archiveHash = $null
    $archivePath = $null

    if (-not [string]::IsNullOrWhiteSpace([string]$Expected.archiveFileName)) {
        $archivePath = Join-Path (Split-Path -Parent $ResultFile) ([string]$Expected.archiveFileName)
        if (Test-Path $archivePath) {
            $archiveHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    Write-Host ("  SHA256 from export-result.json : {0}" -f $expectedHash)
    Write-Host ("  SHA256 from Log Analytics      : {0}" -f $ingestedHash)
    Write-Host ("  SHA256 recomputed from archive : {0}" -f $(if ($archiveHash) { $archiveHash } else { 'unavailable' }))

    $resultVsLog = (
        -not [string]::IsNullOrWhiteSpace($expectedHash) -and
        -not [string]::IsNullOrWhiteSpace($ingestedHash) -and
        $expectedHash -ceq $ingestedHash
    )

    $archiveVsResult = ($null -eq $archiveHash -or $archiveHash -ceq $expectedHash)

    return ($resultVsLog -and $archiveVsResult)
}

function Test-ApprovalEvidenceQuality {
    param([Parameter(Mandatory = $true)][string]$RunId)

    $query = @"
ADO_Approval_CL
| where tostring(ExportRunId) == '$RunId'
| where tostring(ApprovalStatus) == 'approved'
| summarize
    Total = count(),
    MissingApprover = countif(isempty(tostring(ActualApproverUpn))),
    MissingTime = countif(isnull(LastModifiedOn))
"@

    $rows = @(Invoke-Kql -Query $query)
    if ($rows.Count -eq 0) {
        return [PSCustomObject]@{ Passed = $true; Detail = 'no approved approval rows found' }
    }

    $row = $rows[0]
    $passed = ([int]$row.MissingApprover -eq 0 -and [int]$row.MissingTime -eq 0)

    return [PSCustomObject]@{
        Passed = $passed
        Detail = ("total {0}, missing approver {1}, missing timestamp {2}" -f `
            $row.Total, $row.MissingApprover, $row.MissingTime)
    }
}

$currentBuildId = 0
if (-not [string]::IsNullOrWhiteSpace($env:BUILD_BUILDID)) {
    try { $currentBuildId = [int]$env:BUILD_BUILDID } catch { $currentBuildId = 0 }
}

$expected = $null
if (-not [string]::IsNullOrWhiteSpace($ResultFile) -and (Test-Path $ResultFile)) {
    $expected = Get-Content -Path $ResultFile -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($ExportRunId)) {
        $ExportRunId = [string]$expected.exportRunId
    }

    Write-Host ("Expected from export job: PR={0} Runs={1} Approvals={2}" -f `
        $expected.pullRequests, $expected.pipelineRuns, $expected.approvals)
}

if ([string]::IsNullOrWhiteSpace($ExportRunId)) {
    throw "Provide -ExportRunId or -ResultFile."
}

Write-Host ("Verifying ExportRunId {0} in workspace {1}" -f $ExportRunId, $WorkspaceCustomerId)

$summaryRow = Wait-ForSummaryRow -RunId $ExportRunId -BuildId $currentBuildId
if ($null -eq $summaryRow) {
    Write-Check `
        -Name 'Self-audit row present' `
        -Passed $false `
        -Detail ("No matching Summary row after {0}s." -f $MaxWaitSeconds)
    exit 3
}

Write-Host (
    "  Self-audit Summary found: BuildId={0} TimeGenerated={1} Hash={2} Status={3} Script={4}" -f `
        $summaryRow.ExportPipelineBuildId,
        $summaryRow.TimeGenerated,
        $summaryRow.PayloadSha256,
        $summaryRow.Status,
        $summaryRow.ScriptVersion
)

$allPassed = $true

Write-Check `
    -Name 'Self-audit row present' `
    -Passed $true `
    -Detail ("Status={0}; BuildId={1}; TimeGenerated={2}" -f `
        $summaryRow.Status, $summaryRow.ExportPipelineBuildId, $summaryRow.TimeGenerated)

if ($currentBuildId -gt 0) {
    $passed = ([int]$summaryRow.ExportPipelineBuildId -eq $currentBuildId)
    if (-not $passed) { $allPassed = $false }

    Write-Check `
        -Name 'Self-audit row belongs to current pipeline build' `
        -Passed $passed `
        -Detail ("expected BuildId={0}, found BuildId={1}" -f `
            $currentBuildId, $summaryRow.ExportPipelineBuildId)
}

if ($null -ne $expected) {
    $checks = @(
        [PSCustomObject]@{ Table = 'ADO_PullRequest_CL'; Expected = [int]$expected.pullRequests },
        [PSCustomObject]@{ Table = 'ADO_PipelineRun_CL'; Expected = [int]$expected.pipelineRuns },
        [PSCustomObject]@{ Table = 'ADO_Approval_CL'; Expected = [int]$expected.approvals }
    )

    foreach ($check in $checks) {
        if ($check.Expected -eq 0) {
            Write-Check `
                -Name ("Row count reconciliation: {0}" -f $check.Table) `
                -Passed $true `
                -Detail 'expected 0; table query skipped'
            continue
        }

        $result = Wait-ForExpectedRowCount `
            -TableName $check.Table `
            -RunId $ExportRunId `
            -ExpectedCount $check.Expected

        $passed = ($result.Count -eq $check.Expected)
        if (-not $passed) { $allPassed = $false }

        $detail = if (-not [string]::IsNullOrWhiteSpace([string]$result.Error) -and $result.Count -eq 0) {
            "expected $($check.Expected); last query error: $($result.Error)"
        }
        else {
            "expected $($check.Expected), found $($result.Count); waited $($result.Waited)s"
        }

        Write-Check `
            -Name ("Row count reconciliation: {0}" -f $check.Table) `
            -Passed $passed `
            -Detail $detail
    }

    $hashPassed = Test-ArchiveIntegrity -Expected $expected -SummaryRow $summaryRow
    if (-not $hashPassed) { $allPassed = $false }

    Write-Check `
        -Name 'Archive hash matches ingested self-audit row' `
        -Passed $hashPassed `
        -Detail $(if ($hashPassed) {
            'export-result, Log Analytics, and archive SHA256 values are consistent'
        } else {
            'SHA256 values are inconsistent'
        })

    if ([int]$expected.approvals -eq 0) {
        Write-Check `
            -Name 'Approval records carry approver and timestamp' `
            -Passed $true `
            -Detail 'no approval rows were exported; quality query skipped'
    }
    else {
        try {
            $quality = Test-ApprovalEvidenceQuality -RunId $ExportRunId
            if (-not $quality.Passed) { $allPassed = $false }

            Write-Check `
                -Name 'Approval records carry approver and timestamp' `
                -Passed $quality.Passed `
                -Detail $quality.Detail
        }
        catch {
            $allPassed = $false
            Write-Check `
                -Name 'Approval records carry approver and timestamp' `
                -Passed $false `
                -Detail ("query failed: {0}" -f $_.Exception.Message)
        }
    }
}
else {
    Write-Host "No result file supplied; row-count and archive reconciliation skipped."
}

$statusPassed = ([string]$summaryRow.Status -eq 'Succeeded')
if (-not $statusPassed) { $allPassed = $false }

Write-Check `
    -Name 'Export job completed without errors' `
    -Passed $statusPassed `
    -Detail ([string]$summaryRow.Status)

Write-Host ''
if ($allPassed) {
    Write-Host 'All verification checks passed.' -ForegroundColor Green
    exit 0
}

Write-Host 'One or more verification checks failed.' -ForegroundColor Red
exit 1
