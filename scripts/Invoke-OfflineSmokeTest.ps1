# Offline smoke test: exercises the pure helpers and the record builders
# against mocked Azure DevOps API responses. No network access required.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AdoAuditExport.psm1') -Force

$failures = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "[PASS] $Name $Detail" }
    else { Write-Host "[FAIL] $Name $Detail"; $script:failures++ }
}

# ---- helpers -------------------------------------------------------
Assert-That 'Jira key extraction' `
    ((ConvertTo-JiraIssueKeyString -Text @('feature/PROJ-123-add-login', 'fix PROJ-456 and PROJ-123')) -eq 'PROJ-123,PROJ-456')

Assert-That 'Jira key extraction on empty input' `
    ((ConvertTo-JiraIssueKeyString -Text @('', $null, 'no key here')) -eq '')

Assert-That 'UTC normalization' `
    ((ConvertTo-UtcString -Value '2026-10-05T12:34:56.789Z') -eq '2026-10-05T12:34:56.789Z')

Assert-That 'UTC normalization of null' ($null -eq (ConvertTo-UtcString -Value $null))

$obj = [PSCustomObject]@{ a = [PSCustomObject]@{ b = 'value' } }
Assert-That 'Nested property access' ((Get-SafeProperty -Object $obj -Path 'a.b') -eq 'value')
Assert-That 'Missing property returns default' ((Get-SafeProperty -Object $obj -Path 'a.zzz' -Default 'dflt') -eq 'dflt')
Assert-That 'Missing root returns default' ((Get-SafeProperty -Object $null -Path 'a.b' -Default 'dflt') -eq 'dflt')

$hash = Get-Sha256Hex -Text 'sample'
Assert-That 'SHA256 length' ($hash.Length -eq 64) "($hash)"

# ---- mock the Azure DevOps API inside the module scope -------------
$module = Get-Module AdoAuditExport
& $module {
    function script:Invoke-AdoRestApi {
        param([string]$Uri, [hashtable]$Headers, [int]$MaxRetry = 5)

        if ($Uri -match '/_apis/git/pullrequests') {
            if ($Uri -match 'status=completed') {
                return [PSCustomObject]@{ ContinuationToken = $null; Content = [PSCustomObject]@{ value = @(
                    [PSCustomObject]@{
                        pullRequestId = 42
                        title         = 'PROJ-123 add audit export'
                        status        = 'completed'
                        isDraft       = $false
                        creationDate  = '2026-10-01T01:00:00Z'
                        closedDate    = '2026-10-02T05:30:00Z'
                        sourceRefName = 'refs/heads/feature/PROJ-123-export'
                        targetRefName = 'refs/heads/main'
                        mergeStatus   = 'succeeded'
                        repository    = [PSCustomObject]@{ id = 'repo-guid'; name = 'app-repo' }
                        createdBy     = [PSCustomObject]@{ id = 'user-1'; displayName = 'Taro Yamada'; uniqueName = 'taro@contoso.example' }
                        closedBy      = [PSCustomObject]@{ id = 'user-2'; displayName = 'Hanako Suzuki'; uniqueName = 'hanako@contoso.example' }
                        lastMergeCommit = [PSCustomObject]@{ commitId = 'abc123def456' }
                        reviewers     = @(
                            [PSCustomObject]@{ id = 'user-2'; displayName = 'Hanako Suzuki'; uniqueName = 'hanako@contoso.example'; vote = 10; isRequired = $true; isContainer = $false },
                            [PSCustomObject]@{ id = 'user-1'; displayName = 'Taro Yamada'; uniqueName = 'taro@contoso.example'; vote = 0; isRequired = $false; isContainer = $false }
                        )
                    }
                ) } }
            }
            return [PSCustomObject]@{ ContinuationToken = $null; Content = [PSCustomObject]@{ value = @() } }
        }

        if ($Uri -match '/_apis/policy/evaluations') {
            return [PSCustomObject]@{ ContinuationToken = $null; Content = [PSCustomObject]@{ value = @(
                [PSCustomObject]@{
                    status = 'approved'
                    startedDate = '2026-10-01T01:05:00Z'
                    completedDate = '2026-10-01T01:12:00Z'
                    configuration = [PSCustomObject]@{
                        isBlocking = $true
                        type = [PSCustomObject]@{ displayName = 'Build' }
                        settings = [PSCustomObject]@{ displayName = 'CI validation' }
                    }
                }
            ) } }
        }

        if ($Uri -match '/timeline') {
            return [PSCustomObject]@{ ContinuationToken = $null; Content = [PSCustomObject]@{ records = @(
                [PSCustomObject]@{ id = 'stage-1'; parentId = $null; type = 'Stage'; name = 'Prod'; result = 'succeeded'; state = 'completed'; startTime = '2026-10-02T06:00:00Z'; finishTime = '2026-10-02T06:20:00Z'; environmentName = 'prod' },
                [PSCustomObject]@{ id = 'phase-1'; parentId = 'stage-1'; type = 'Phase'; name = 'Deploy'; result = 'succeeded'; state = 'completed' },
                [PSCustomObject]@{ id = 'appr-1'; parentId = 'phase-1'; type = 'Checkpoint.Approval'; name = 'Approval'; result = 'succeeded'; state = 'completed' },
                [PSCustomObject]@{ id = 'job-1'; parentId = 'phase-1'; type = 'Job'; name = 'DeployJob'; workerName = 'AGENT-01' }
            ) } }
        }

        if ($Uri -match '/_apis/pipelines/approvals/') {
            return [PSCustomObject]@{ ContinuationToken = $null; Content = [PSCustomObject]@{
                id = 'appr-1'
                status = 'approved'
                createdOn = '2026-10-02T05:50:00Z'
                lastModifiedOn = '2026-10-02T05:58:00Z'
                executionOrder = 'anyOrder'
                minRequiredApprovers = 1
                instructions = 'Confirm the change ticket'
                steps = @(
                    [PSCustomObject]@{
                        status = 'approved'
                        comment = 'Reviewed against PROJ-123'
                        lastModifiedOn = '2026-10-02T05:58:00Z'
                        assignedApprover = [PSCustomObject]@{ id = 'user-3'; displayName = 'Manager'; uniqueName = 'manager@contoso.example' }
                        actualApprover   = [PSCustomObject]@{ id = 'user-3'; displayName = 'Manager'; uniqueName = 'manager@contoso.example' }
                    }
                )
            } }
        }

        return [PSCustomObject]@{ ContinuationToken = $null; Content = $null }
    }

    function script:Get-AdoPagedValue {
        param([string]$BaseUri, [hashtable]$Headers, [int]$PageSize = 500, [int]$MaxPages = 200)
        if ($BaseUri -match '/_apis/build/builds') {
            return @(
                [PSCustomObject]@{
                    id = 9001
                    buildNumber = '20261002.1'
                    status = 'completed'
                    result = 'succeeded'
                    reason = 'manual'
                    queueTime = '2026-10-02T05:40:00Z'
                    startTime = '2026-10-02T05:45:00Z'
                    finishTime = '2026-10-02T06:20:00Z'
                    sourceBranch = 'refs/heads/main'
                    sourceVersion = 'abc123def456'
                    definition = [PSCustomObject]@{ id = 5; name = 'app-release'; path = '\'; revision = 12 }
                    repository = [PSCustomObject]@{ id = 'repo-guid'; name = 'app-repo'; type = 'TfsGit' }
                    requestedFor = [PSCustomObject]@{ id = 'user-1'; displayName = 'Taro Yamada'; uniqueName = 'taro@contoso.example' }
                    requestedBy  = [PSCustomObject]@{ id = 'user-1'; displayName = 'Taro Yamada'; uniqueName = 'taro@contoso.example' }
                    triggerInfo  = [PSCustomObject]@{ ci_message = 'PROJ-123 merge' }
                }
            )
        }
        return @()
    }
}

# ---- regression: the API window must be sent in UTC ----------------
# A self-hosted agent in JST parses an incoming datetime as Local. If the
# window is formatted with a literal 'Z' without converting to UTC first,
# every query silently shifts by 9 hours.
$global:CapturedUris = New-Object System.Collections.ArrayList
& $module {
    $script:OriginalMock = ${function:Invoke-AdoRestApi}
    function script:Invoke-AdoRestApi {
        param([string]$Uri, [hashtable]$Headers, [int]$MaxRetry = 5)
        [void]$global:CapturedUris.Add($Uri)
        return & $script:OriginalMock -Uri $Uri -Headers $Headers -MaxRetry $MaxRetry
    }
}

$project = [PSCustomObject]@{ id = 'proj-guid'; name = 'SampleApp' }
$headers = @{ Authorization = 'Bearer dummy' }
$runId = [guid]::NewGuid().ToString()
$start = ([datetime]'2026-10-01T00:00:00Z').ToUniversalTime()
$end = ([datetime]'2026-10-03T00:00:00Z').ToUniversalTime()

# ---- pull requests -------------------------------------------------
$prs = Get-AdoPullRequestRecord -Organization 'contoso' -Project $project -Headers $headers `
    -WindowStartUtc $start -WindowEndUtc $end -ExportRunId $runId -IncludePolicyEvaluations

Assert-That 'PR record count' (@($prs).Count -eq 1)
$pr = @($prs)[0]
Assert-That 'PR RecordId' ($pr.RecordId -eq 'PR-contoso-proj-guid-repo-guid-42') "($($pr.RecordId))"
Assert-That 'PR Jira keys' ($pr.JiraIssueKeys -eq 'PROJ-123') "($($pr.JiraIssueKeys))"
Assert-That 'PR approved count' ($pr.ApprovedCount -eq 1)
Assert-That 'PR required reviewers' ($pr.RequiredReviewerCount -eq 1)
Assert-That 'PR self-approval flag is false' ($pr.IsSelfApproved -eq $false)
Assert-That 'PR TimeGenerated uses closed date' ($pr.TimeGenerated -eq '2026-10-02T05:30:00.000Z') "($($pr.TimeGenerated))"
Assert-That 'PR policy evaluation captured' ($pr.PolicyPassedCount -eq 1 -and $pr.PolicyEvaluationsJson -match 'CI validation')

# ---- pipeline runs and approvals -----------------------------------
$result = Get-AdoPipelineRunRecord -Organization 'contoso' -Project $project -Headers $headers `
    -WindowStartUtc $start -WindowEndUtc $end -ExportRunId $runId

Assert-That 'Run record count' (@($result.Runs).Count -eq 1)
$run = @($result.Runs)[0]
Assert-That 'Run RecordId' ($run.RecordId -eq 'RUN-contoso-proj-guid-9001') "($($run.RecordId))"
Assert-That 'Run definition revision' ($run.DefinitionRevision -eq 12)
Assert-That 'Run duration' ($run.DurationSeconds -eq 2100) "($($run.DurationSeconds))"
Assert-That 'Run stages captured' ($run.StagesJson -match 'Prod')
Assert-That 'Run environments captured' ($run.EnvironmentNames -eq 'prod') "($($run.EnvironmentNames))"
Assert-That 'Run agent captured' ($run.AgentPoolNames -eq 'AGENT-01') "($($run.AgentPoolNames))"
Assert-That 'Run Jira keys' ($run.JiraIssueKeys -eq 'PROJ-123') "($($run.JiraIssueKeys))"
Assert-That 'Run approval count' ($run.ApprovalCount -eq 1)

Assert-That 'Approval record count' (@($result.Approvals).Count -eq 1)
$appr = @($result.Approvals)[0]
Assert-That 'Approval RecordId' ($appr.RecordId -eq 'APR-contoso-proj-guid-appr-1-1') "($($appr.RecordId))"
Assert-That 'Approval stage resolved through parent chain' ($appr.StageName -eq 'Prod') "($($appr.StageName))"
Assert-That 'Approver captured' ($appr.ActualApproverUpn -eq 'manager@contoso.example')
Assert-That 'Approval comment captured' ($appr.StepComment -eq 'Reviewed against PROJ-123')
Assert-That 'SOD flag false (approver <> requester)' ($appr.IsSelfApproval -eq $false)
Assert-That 'Approval TimeGenerated' ($appr.TimeGenerated -eq '2026-10-02T05:58:00.000Z') "($($appr.TimeGenerated))"

# ---- regression assertions on the captured window ------------------
$prUri = $global:CapturedUris | Where-Object { $_ -match 'status=completed' } | Select-Object -First 1
Assert-That 'PR query window is sent in UTC (not shifted by the agent timezone)' `
    ($prUri -match 'minTime=2026-10-01T00:00:00Z' -and $prUri -match 'maxTime=2026-10-03T00:00:00Z') `
    "($prUri)"

# ---- batching ------------------------------------------------------
$bulk = 1..2500 | ForEach-Object {
    [ordered]@{
        TimeGenerated = '2026-10-02T00:00:00.000Z'
        RecordId      = "REC-$_"
        Payload       = ('x' * 400)
    }
}
$sent = Send-LawRecord -IngestionEndpoint 'https://example.ingest.monitor.azure.com' `
    -DcrImmutableId 'dcr-test' -StreamName 'Custom-ADO_PullRequest_CL' `
    -Records $bulk -AccessToken 'dummy' -WhatIfOnly
Assert-That 'Batching sends every record' ($sent -eq 2500) "(sent=$sent)"

$single = Send-LawRecord -IngestionEndpoint 'https://example.ingest.monitor.azure.com' `
    -DcrImmutableId 'dcr-test' -StreamName 'Custom-ADO_PullRequest_CL' `
    -Records @($bulk[0]) -AccessToken 'dummy' -WhatIfOnly
Assert-That 'Single record is sent as a JSON array' ($single -eq 1)

$empty = Send-LawRecord -IngestionEndpoint 'https://example.ingest.monitor.azure.com' `
    -DcrImmutableId 'dcr-test' -StreamName 'Custom-ADO_PullRequest_CL' `
    -Records @() -AccessToken 'dummy' -WhatIfOnly
Assert-That 'Empty record set is a no-op' ($empty -eq 0)

Write-Host ''
if ($failures -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$failures TEST(S) FAILED" -ForegroundColor Red
exit 1
