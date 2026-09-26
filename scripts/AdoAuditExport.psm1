<#
    AdoAuditExport.psm1
    ------------------------------------------------------------------
    Azure DevOps change-management audit evidence exporter.

    Extracts pull request, pipeline run and stage approval records from the
    Azure DevOps REST API and ingests them into Azure Monitor Logs custom
    tables through the Logs Ingestion API (DCR based).

    Compatibility : Windows PowerShell 5.1 and PowerShell 7+
    Encoding      : ASCII only, English messages (self-hosted agent safe)
    Schema version: 1.0.0
    ------------------------------------------------------------------
#>

Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:SchemaVersion = '1.0.0'
$script:AdoApiVersion = '7.1'
$script:AdoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'  # Azure DevOps Entra application ID
$script:MonitorResource = 'https://monitor.azure.com'
$script:MaxPayloadBytes = 900KB   # Logs Ingestion API hard limit is 1 MB per request
$script:JiraKeyRegex = '[A-Z][A-Z0-9]+-\d+'

function Write-AuditLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host ("[{0}] [{1}] {2}" -f $stamp, $Level, $Message)
}

# ------------------------------------------------------------------
# Authentication
# ------------------------------------------------------------------

function Get-AzCliToken {
    param([Parameter(Mandatory = $true)][string]$Resource)

    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & az account get-access-token `
            --resource $Resource `
            --query accessToken `
            --output tsv `
            --only-show-errors 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw ("Failed to acquire token for resource '{0}'. Azure CLI exit code: {1}" -f $Resource, $exitCode)
    }

    $token = (@($output) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw ("Empty token returned for resource '{0}'." -f $Resource)
    }

    return $token
}


function New-AdoAuthHeader {
    <#
      Builds the Authorization header for Azure DevOps.
      AuthMode 'Entra'  : service principal / managed identity (recommended - no secret expiry)
      AuthMode 'Pat'    : personal access token (fallback)
      AuthMode 'OAuth'  : System.AccessToken of the running pipeline
    #>
    param(
        [ValidateSet('Entra', 'Pat', 'OAuth')][string]$AuthMode = 'Entra',
        [string]$PersonalAccessToken,
        [string]$SystemAccessToken
    )

    switch ($AuthMode) {
        'Pat' {
            if ([string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
                throw "AuthMode 'Pat' requires -PersonalAccessToken."
            }
            $bytes = [Text.Encoding]::ASCII.GetBytes(':' + $PersonalAccessToken)
            return @{ Authorization = 'Basic ' + [Convert]::ToBase64String($bytes) }
        }
        'OAuth' {
            if ([string]::IsNullOrWhiteSpace($SystemAccessToken)) {
                throw "AuthMode 'OAuth' requires -SystemAccessToken."
            }
            return @{ Authorization = 'Bearer ' + $SystemAccessToken }
        }
        default {
            return @{ Authorization = 'Bearer ' + (Get-AzCliToken -Resource $script:AdoResourceId) }
        }
    }
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

# ------------------------------------------------------------------
# Azure DevOps REST helper
# ------------------------------------------------------------------

function Invoke-AdoRestApi {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [int]$MaxRetry = 5
    )

    for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri $Uri `
                -Headers $Headers `
                -Method Get `
                -UseBasicParsing `
                -ContentType 'application/json' `
                -ErrorAction Stop

            $continuationToken = $null
            if ($response.Headers.ContainsKey('x-ms-continuationtoken')) {
                $continuationToken = $response.Headers['x-ms-continuationtoken']
                if ($continuationToken -is [array]) {
                    $continuationToken = $continuationToken[0]
                }
            }

            $content = $null
            if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
                $content = $response.Content | ConvertFrom-Json
            }

            return [PSCustomObject]@{
                Content           = $content
                ContinuationToken = $continuationToken
            }
        }
        catch {
            $status = Get-HttpStatusCode -Exception $_.Exception

            if ($status -eq 401 -or $status -eq 203) {
                throw ("Authentication to Azure DevOps failed (HTTP {0}). URI: {1}" -f $status, $Uri)
            }

            if ($status -eq 400) {
                throw ("Azure DevOps rejected the request (HTTP 400): {0}" -f $Uri)
            }

            if ($status -eq 404) {
                Write-AuditLog -Level WARN -Message ("Resource not found (HTTP 404), skipping: {0}" -f $Uri)
                return [PSCustomObject]@{ Content = $null; ContinuationToken = $null }
            }

            if ($attempt -ge $MaxRetry) {
                throw ("Azure DevOps API call failed after {0} attempts (HTTP {1}): {2}" -f $attempt, $status, $Uri)
            }

            $delay = [math]::Min([math]::Pow(2, $attempt), 60)
            Write-AuditLog -Level WARN -Message (
                "API call failed (HTTP {0}), retry {1}/{2} in {3}s." -f `
                    $status, $attempt, $MaxRetry, $delay
            )
            Start-Sleep -Seconds $delay
        }
    }
}


function Get-AdoPagedValue {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [int]$PageSize = 500,
        [int]$MaxPages = 200
    )

    $results = New-Object System.Collections.ArrayList
    $continuationToken = $null

    for ($page = 1; $page -le $MaxPages; $page++) {
        $separator = if ($BaseUri -match '\?') { '&' } else { '?' }
        $uri = "{0}{1}`$top={2}" -f $BaseUri, $separator, $PageSize

        if (-not [string]::IsNullOrWhiteSpace($continuationToken)) {
            $uri += ('&continuationToken={0}' -f [uri]::EscapeDataString($continuationToken))
        }

        $response = Invoke-AdoRestApi -Uri $uri -Headers $Headers
        $items = @(Get-SafeProperty -Object $response.Content -Path 'value' -Default @())

        foreach ($item in $items) {
            [void]$results.Add($item)
        }

        $continuationToken = $response.ContinuationToken
        if ([string]::IsNullOrWhiteSpace($continuationToken)) {
            return $results
        }
    }

    throw ("Paging exceeded MaxPages ({0}). Narrow the export window: {1}" -f $MaxPages, $BaseUri)
}


# ------------------------------------------------------------------
# Small utilities
# ------------------------------------------------------------------

function ConvertTo-JiraIssueKeyString {
    param([string[]]$Text)

    $keys = New-Object System.Collections.ArrayList
    foreach ($item in $Text) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        foreach ($m in [regex]::Matches($item, $script:JiraKeyRegex)) {
            if (-not $keys.Contains($m.Value)) { [void]$keys.Add($m.Value) }
        }
    }
    return ($keys -join ',')
}

function ConvertTo-UtcString {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    catch { return $null }
}

function Get-SafeProperty {
    param($Object, [string]$Path, $Default = $null)

    $current = $Object

    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }

        # Dictionary / OrderedDictionary
        if ($current -is [System.Collections.IDictionary]) {
            $matchedKey = $null

            foreach ($key in $current.Keys) {
                if ([string]$key -ieq $segment) {
                    $matchedKey = $key
                    break
                }
            }

            if ($null -eq $matchedKey) { return $Default }
            $current = $current[$matchedKey]
            continue
        }

        # PSCustomObject / REST response object / normal .NET object.
        # Do not use ".PSObject.Properties.Name" here. Under Windows
        # PowerShell 5.1 + StrictMode, member enumeration can itself throw
        # PropertyNotFoundException for some adapted API response shapes.
        $property = $current.PSObject.Properties[$segment]

        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }

    if ($null -eq $current) { return $Default }
    return $current
}

function ConvertTo-CompactJson {
    param($Value, [int]$MaxLength = 30000)

    if ($null -eq $Value) { return '' }

    # Use -InputObject instead of pipeline input. With Windows PowerShell 5.1,
    # an empty collection sent through the pipeline invokes ConvertTo-Json zero
    # times, leaving $json = $null; StrictMode then fails on $json.Length.
    # -InputObject preserves an empty collection as "[]".
    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress

    if ($null -eq $json) { return '' }

    $jsonText = [string]$json
    if ($jsonText.Length -gt $MaxLength) {
        $jsonText = $jsonText.Substring(0, $MaxLength)
    }

    return $jsonText
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally { $sha.Dispose() }
}

# ------------------------------------------------------------------
# Extraction - projects
# ------------------------------------------------------------------

function Get-AdoProject {
    param(
        [Parameter(Mandatory = $true)][string]$Organization,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [string[]]$ProjectFilter
    )

    $uri = "https://dev.azure.com/$Organization/_apis/projects?stateFilter=all&api-version=$script:AdoApiVersion"
    $projects = Get-AdoPagedValue -BaseUri $uri -Headers $Headers -PageSize 200

    if ($null -ne $ProjectFilter -and $ProjectFilter.Count -gt 0) {
        $projects = $projects | Where-Object { $ProjectFilter -contains $_.name }
    }
    return @($projects)
}

# ------------------------------------------------------------------
# Extraction - pull requests
# ------------------------------------------------------------------

function Get-AdoPullRequestRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Organization,
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][datetime]$WindowStartUtc,
        [Parameter(Mandatory = $true)][datetime]$WindowEndUtc,
        [Parameter(Mandatory = $true)][string]$ExportRunId,
        [switch]$IncludePolicyEvaluations
    )

    $records = New-Object System.Collections.ArrayList
    $projectName = $Project.name
    $projectId = $Project.id
    $encodedProject = [uri]::EscapeDataString($projectName)

    # ToUniversalTime() is deliberate: a self-hosted agent in JST parses an
    # incoming datetime as Local, and formatting it with a literal 'Z' without
    # converting first would shift the whole window by 9 hours.
    $minTime = $WindowStartUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $maxTime = $WindowEndUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # Closed PRs in the window, plus every currently active PR (their final state
    # is captured on a later run once they close).
    $queries = @(
        "searchCriteria.status=completed&searchCriteria.queryTimeRangeType=closed&searchCriteria.minTime=$minTime&searchCriteria.maxTime=$maxTime",
        "searchCriteria.status=abandoned&searchCriteria.queryTimeRangeType=closed&searchCriteria.minTime=$minTime&searchCriteria.maxTime=$maxTime",
        "searchCriteria.status=active"
    )

    $pullRequests = New-Object System.Collections.ArrayList
    foreach ($query in $queries) {
        $skip = 0
        $pageSize = 200
        while ($true) {
            $uri = "https://dev.azure.com/$Organization/$encodedProject/_apis/git/pullrequests?$query&`$top=$pageSize&`$skip=$skip&api-version=$script:AdoApiVersion"
            $response = Invoke-AdoRestApi -Uri $uri -Headers $Headers
            $values = Get-SafeProperty -Object $response.Content -Path 'value'
            if ($null -eq $values -or @($values).Count -eq 0) { break }
            foreach ($pr in $values) { [void]$pullRequests.Add($pr) }
            if (@($values).Count -lt $pageSize) { break }
            $skip += $pageSize
            if ($skip -gt 20000) {
                Write-AuditLog -Level WARN -Message "Pull request paging cap reached; narrow the window."
                break
            }
        }
    }

    Write-AuditLog -Message ("Project '{0}': {1} pull request(s) retrieved." -f $projectName, $pullRequests.Count)

    $seen = @{}
    foreach ($pr in $pullRequests) {
        $prId = [int](Get-SafeProperty -Object $pr -Path 'pullRequestId' -Default 0)
        if ($prId -eq 0) { continue }
        if ($seen.ContainsKey($prId)) { continue }
        $seen[$prId] = $true

        $repoId = [string](Get-SafeProperty -Object $pr -Path 'repository.id' -Default '')
        $repoName = [string](Get-SafeProperty -Object $pr -Path 'repository.name' -Default '')
        $creationDate = Get-SafeProperty -Object $pr -Path 'creationDate'
        $closedDate = Get-SafeProperty -Object $pr -Path 'closedDate'
        $createdById = [string](Get-SafeProperty -Object $pr -Path 'createdBy.id' -Default '')
        $createdByUpn = [string](Get-SafeProperty -Object $pr -Path 'createdBy.uniqueName' -Default '')
        $title = [string](Get-SafeProperty -Object $pr -Path 'title' -Default '')
        $sourceBranch = [string](Get-SafeProperty -Object $pr -Path 'sourceRefName' -Default '')
        $targetBranch = [string](Get-SafeProperty -Object $pr -Path 'targetRefName' -Default '')

        $reviewers = @(Get-SafeProperty -Object $pr -Path 'reviewers' -Default @())
        $approved = 0; $rejected = 0; $required = 0; $selfApproved = $false
        $reviewerSummary = New-Object System.Collections.ArrayList

        foreach ($reviewer in $reviewers) {
            $vote = [int](Get-SafeProperty -Object $reviewer -Path 'vote' -Default 0)
            $isRequired = [bool](Get-SafeProperty -Object $reviewer -Path 'isRequired' -Default $false)
            $reviewerId = [string](Get-SafeProperty -Object $reviewer -Path 'id' -Default '')
            if ($vote -ge 5) { $approved++ }
            if ($vote -le -5) { $rejected++ }
            if ($isRequired) { $required++ }
            if ($vote -ge 5 -and $reviewerId -eq $createdById -and $createdById -ne '') { $selfApproved = $true }

            [void]$reviewerSummary.Add([ordered]@{
                displayName = [string](Get-SafeProperty -Object $reviewer -Path 'displayName' -Default '')
                uniqueName  = [string](Get-SafeProperty -Object $reviewer -Path 'uniqueName' -Default '')
                vote        = $vote
                isRequired  = $isRequired
                isContainer = [bool](Get-SafeProperty -Object $reviewer -Path 'isContainer' -Default $false)
            })
        }

        $policyJson = ''
        $policyPassed = 0
        $policyFailed = 0
        if ($IncludePolicyEvaluations) {
            $artifactId = "vstfs:///CodeReview/CodeReviewId/$projectId/$prId"
            # Policy Evaluations List is a preview API even when the rest of the
            # exporter uses Azure DevOps REST API 7.1.
            $policyApiVersion = '7.1-preview.1'
            $policyUri = "https://dev.azure.com/$Organization/$encodedProject/_apis/policy/evaluations?artifactId=$([uri]::EscapeDataString($artifactId))&api-version=$policyApiVersion"
            $policyResponse = Invoke-AdoRestApi -Uri $policyUri -Headers $Headers
            $evaluations = Get-SafeProperty -Object $policyResponse.Content -Path 'value' -Default @()
            $policySummary = New-Object System.Collections.ArrayList
            foreach ($ev in @($evaluations)) {
                $evStatus = [string](Get-SafeProperty -Object $ev -Path 'status' -Default '')
                if ($evStatus -eq 'approved') { $policyPassed++ }
                elseif ($evStatus -eq 'rejected' -or $evStatus -eq 'broken') { $policyFailed++ }
                [void]$policySummary.Add([ordered]@{
                    policyType  = [string](Get-SafeProperty -Object $ev -Path 'configuration.type.displayName' -Default '')
                    displayName = [string](Get-SafeProperty -Object $ev -Path 'configuration.settings.displayName' -Default '')
                    isBlocking  = [bool](Get-SafeProperty -Object $ev -Path 'configuration.isBlocking' -Default $false)
                    status      = $evStatus
                    startedDate = [string](Get-SafeProperty -Object $ev -Path 'startedDate' -Default '')
                    completedDate = [string](Get-SafeProperty -Object $ev -Path 'completedDate' -Default '')
                })
            }
            $policyJson = ConvertTo-CompactJson -Value @($policySummary)
        }

        $timeGenerated = ConvertTo-UtcString -Value $closedDate
        if ([string]::IsNullOrWhiteSpace($timeGenerated)) {
            $timeGenerated = ConvertTo-UtcString -Value $creationDate
        }
        if ([string]::IsNullOrWhiteSpace($timeGenerated)) {
            $timeGenerated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }

        [void]$records.Add([ordered]@{
            TimeGenerated         = $timeGenerated
            RecordId              = "PR-$Organization-$projectId-$repoId-$prId"
            Organization          = $Organization
            ProjectName           = $projectName
            ProjectId             = $projectId
            RepositoryName        = $repoName
            RepositoryId          = $repoId
            PullRequestId         = $prId
            Title                 = $title
            Status                = [string](Get-SafeProperty -Object $pr -Path 'status' -Default '')
            IsDraft               = [bool](Get-SafeProperty -Object $pr -Path 'isDraft' -Default $false)
            CreatedByDisplayName  = [string](Get-SafeProperty -Object $pr -Path 'createdBy.displayName' -Default '')
            CreatedByUpn          = $createdByUpn
            CreatedById           = $createdById
            CreationDate          = ConvertTo-UtcString -Value $creationDate
            ClosedDate            = ConvertTo-UtcString -Value $closedDate
            ClosedByDisplayName   = [string](Get-SafeProperty -Object $pr -Path 'closedBy.displayName' -Default '')
            ClosedByUpn           = [string](Get-SafeProperty -Object $pr -Path 'closedBy.uniqueName' -Default '')
            SourceBranch          = $sourceBranch
            TargetBranch          = $targetBranch
            MergeStatus           = [string](Get-SafeProperty -Object $pr -Path 'mergeStatus' -Default '')
            LastMergeCommitId     = [string](Get-SafeProperty -Object $pr -Path 'lastMergeCommit.commitId' -Default '')
            ReviewerCount         = @($reviewers).Count
            RequiredReviewerCount = $required
            ApprovedCount         = $approved
            RejectedCount         = $rejected
            IsSelfApproved        = $selfApproved
            ReviewersJson         = (ConvertTo-CompactJson -Value @($reviewerSummary))
            PolicyEvaluationsJson = $policyJson
            PolicyPassedCount     = $policyPassed
            PolicyFailedCount     = $policyFailed
            WorkItemRefsJson      = ''
            JiraIssueKeys         = (ConvertTo-JiraIssueKeyString -Text @($title, $sourceBranch))
            WebUrl                = "https://dev.azure.com/$Organization/$encodedProject/_git/$([uri]::EscapeDataString($repoName))/pullrequest/$prId"
            ExportRunId           = $ExportRunId
            ExportedOn            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            SchemaVersion         = $script:SchemaVersion
        })
    }

    return @($records)
}

# ------------------------------------------------------------------
# Extraction - pipeline runs and approvals
# ------------------------------------------------------------------

function Get-AdoPipelineRunRecord {
    <#
      Returns a hashtable with two collections: Runs and Approvals.
      Approvals are resolved from the build timeline (Checkpoint.Approval records)
      and the Approvals REST API, which also returns historical (completed) approvals.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Organization,
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][datetime]$WindowStartUtc,
        [Parameter(Mandatory = $true)][datetime]$WindowEndUtc,
        [Parameter(Mandatory = $true)][string]$ExportRunId
    )

    $runRecords = New-Object System.Collections.ArrayList
    $approvalRecords = New-Object System.Collections.ArrayList

    $projectName = $Project.name
    $projectId = $Project.id
    $encodedProject = [uri]::EscapeDataString($projectName)

    # See the note in Get-AdoPullRequestRecord: always normalize to UTC before
    # formatting with a literal 'Z'.
    $minTime = $WindowStartUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $maxTime = $WindowEndUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $buildsUri = "https://dev.azure.com/$Organization/$encodedProject/_apis/build/builds?minTime=$minTime&maxTime=$maxTime&queryOrder=finishTimeAscending&api-version=$script:AdoApiVersion"
    $builds = Get-AdoPagedValue -BaseUri $buildsUri -Headers $Headers -PageSize 200

    Write-AuditLog -Message ("Project '{0}': {1} pipeline run(s) retrieved." -f $projectName, @($builds).Count)

    foreach ($build in $builds) {
        $buildId = [int](Get-SafeProperty -Object $build -Path 'id' -Default 0)
        if ($buildId -eq 0) { continue }

        $queueTime = Get-SafeProperty -Object $build -Path 'queueTime'
        $startTime = Get-SafeProperty -Object $build -Path 'startTime'
        $finishTime = Get-SafeProperty -Object $build -Path 'finishTime'

        $duration = 0.0
        if ($null -ne $startTime -and $null -ne $finishTime) {
            try { $duration = ([datetime]$finishTime - [datetime]$startTime).TotalSeconds } catch { $duration = 0.0 }
        }

        $requestedForUpn = [string](Get-SafeProperty -Object $build -Path 'requestedFor.uniqueName' -Default '')
        $sourceBranch = [string](Get-SafeProperty -Object $build -Path 'sourceBranch' -Default '')
        $sourceVersionMessage = [string](Get-SafeProperty -Object $build -Path 'triggerInfo.ci_message' -Default '')
        $buildNumber = [string](Get-SafeProperty -Object $build -Path 'buildNumber' -Default '')
        $definitionName = [string](Get-SafeProperty -Object $build -Path 'definition.name' -Default '')

        $triggerPrId = 0
        $prIdRaw = Get-SafeProperty -Object $build -Path 'triggerInfo.pr.number'
        if ($null -ne $prIdRaw) { try { $triggerPrId = [int]$prIdRaw } catch { $triggerPrId = 0 } }

        # ---- timeline: stages, agent pools, approval checkpoints ----
        $stages = New-Object System.Collections.ArrayList
        $environments = New-Object System.Collections.ArrayList
        $pools = New-Object System.Collections.ArrayList
        $approvalIds = New-Object System.Collections.ArrayList
        $approvalStageMap = @{}

        $timelineUri = "https://dev.azure.com/$Organization/$encodedProject/_apis/build/builds/$buildId/timeline?api-version=$script:AdoApiVersion"
        $timelineResponse = Invoke-AdoRestApi -Uri $timelineUri -Headers $Headers
        $timelineRecords = @(Get-SafeProperty -Object $timelineResponse.Content -Path 'records' -Default @())

        foreach ($tr in $timelineRecords) {
            $type = [string](Get-SafeProperty -Object $tr -Path 'type' -Default '')
            $name = [string](Get-SafeProperty -Object $tr -Path 'name' -Default '')

            if ($type -eq 'Stage') {
                [void]$stages.Add([ordered]@{
                    name       = $name
                    result     = [string](Get-SafeProperty -Object $tr -Path 'result' -Default '')
                    state      = [string](Get-SafeProperty -Object $tr -Path 'state' -Default '')
                    startTime  = [string](ConvertTo-UtcString -Value (Get-SafeProperty -Object $tr -Path 'startTime'))
                    finishTime = [string](ConvertTo-UtcString -Value (Get-SafeProperty -Object $tr -Path 'finishTime'))
                })
            }
            elseif ($type -eq 'Checkpoint.Approval') {
                $approvalId = [string](Get-SafeProperty -Object $tr -Path 'id' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($approvalId)) {
                    [void]$approvalIds.Add($approvalId)
                    # Resolve the owning stage through the parent chain.
                    $stageName = ''
                    $parentId = [string](Get-SafeProperty -Object $tr -Path 'parentId' -Default '')
                    $guard = 0
                    while (-not [string]::IsNullOrWhiteSpace($parentId) -and $guard -lt 10) {
                        $guard++
                        $parent = $timelineRecords | Where-Object { [string]$_.id -eq $parentId } | Select-Object -First 1
                        if ($null -eq $parent) { break }
                        $parentType = [string](Get-SafeProperty -Object $parent -Path 'type' -Default '')
                        if ($parentType -eq 'Stage') {
                            $stageName = [string](Get-SafeProperty -Object $parent -Path 'name' -Default '')
                            break
                        }
                        $parentId = [string](Get-SafeProperty -Object $parent -Path 'parentId' -Default '')
                    }
                    $approvalStageMap[$approvalId] = $stageName
                }
            }
            elseif ($type -eq 'Job') {
                $pool = [string](Get-SafeProperty -Object $tr -Path 'workerName' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($pool) -and -not $pools.Contains($pool)) { [void]$pools.Add($pool) }
            }

            $envName = [string](Get-SafeProperty -Object $tr -Path 'environmentName' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($envName) -and -not $environments.Contains($envName)) {
                [void]$environments.Add($envName)
            }
        }

        # ---- approvals ----
        foreach ($approvalId in $approvalIds) {
            $approvalUri = "https://dev.azure.com/$Organization/$encodedProject/_apis/pipelines/approvals/$approvalId" + '?$expand=steps&api-version=' + $script:AdoApiVersion
            $approvalResponse = Invoke-AdoRestApi -Uri $approvalUri -Headers $Headers
            $approval = $approvalResponse.Content
            if ($null -eq $approval) { continue }

            $stageName = ''
            if ($approvalStageMap.ContainsKey($approvalId)) { $stageName = $approvalStageMap[$approvalId] }

            $steps = @(Get-SafeProperty -Object $approval -Path 'steps' -Default @())
            $stepIndex = 0
            foreach ($step in $steps) {
                $stepIndex++
                $actualUpn = [string](Get-SafeProperty -Object $step -Path 'actualApprover.uniqueName' -Default '')
                $stepModified = Get-SafeProperty -Object $step -Path 'lastModifiedOn'
                if ($null -eq $stepModified) { $stepModified = Get-SafeProperty -Object $approval -Path 'lastModifiedOn' }

                $timeGenerated = ConvertTo-UtcString -Value $stepModified
                if ([string]::IsNullOrWhiteSpace($timeGenerated)) {
                    $timeGenerated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                }

                [void]$approvalRecords.Add([ordered]@{
                    TimeGenerated               = $timeGenerated
                    RecordId                    = "APR-$Organization-$projectId-$approvalId-$stepIndex"
                    Organization                = $Organization
                    ProjectName                 = $projectName
                    ProjectId                   = $projectId
                    ApprovalId                  = $approvalId
                    ApprovalStatus              = [string](Get-SafeProperty -Object $approval -Path 'status' -Default '')
                    BuildId                     = $buildId
                    BuildNumber                 = $buildNumber
                    DefinitionName              = $definitionName
                    StageName                   = $stageName
                    EnvironmentName             = ($environments -join ',')
                    MinRequiredApprovers        = [int](Get-SafeProperty -Object $approval -Path 'minRequiredApprovers' -Default 0)
                    ExecutionOrder              = [string](Get-SafeProperty -Object $approval -Path 'executionOrder' -Default '')
                    Instructions                = [string](Get-SafeProperty -Object $approval -Path 'instructions' -Default '')
                    CreatedOn                   = ConvertTo-UtcString -Value (Get-SafeProperty -Object $approval -Path 'createdOn')
                    LastModifiedOn              = ConvertTo-UtcString -Value (Get-SafeProperty -Object $approval -Path 'lastModifiedOn')
                    StepIndex                   = $stepIndex
                    StepStatus                  = [string](Get-SafeProperty -Object $step -Path 'status' -Default '')
                    StepComment                 = [string](Get-SafeProperty -Object $step -Path 'comment' -Default '')
                    AssignedApproverDisplayName = [string](Get-SafeProperty -Object $step -Path 'assignedApprover.displayName' -Default '')
                    AssignedApproverUpn         = [string](Get-SafeProperty -Object $step -Path 'assignedApprover.uniqueName' -Default '')
                    ActualApproverDisplayName   = [string](Get-SafeProperty -Object $step -Path 'actualApprover.displayName' -Default '')
                    ActualApproverUpn           = $actualUpn
                    ActualApproverId            = [string](Get-SafeProperty -Object $step -Path 'actualApprover.id' -Default '')
                    BuildRequestedByUpn         = $requestedForUpn
                    IsSelfApproval              = ($actualUpn -ne '' -and $actualUpn -eq $requestedForUpn)
                    WebUrl                      = "https://dev.azure.com/$Organization/$encodedProject/_build/results?buildId=$buildId&view=results"
                    ExportRunId                 = $ExportRunId
                    ExportedOn                  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    SchemaVersion               = $script:SchemaVersion
                })
            }
        }

        $timeGeneratedRun = ConvertTo-UtcString -Value $finishTime
        if ([string]::IsNullOrWhiteSpace($timeGeneratedRun)) { $timeGeneratedRun = ConvertTo-UtcString -Value $queueTime }
        if ([string]::IsNullOrWhiteSpace($timeGeneratedRun)) {
            $timeGeneratedRun = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }

        [void]$runRecords.Add([ordered]@{
            TimeGenerated           = $timeGeneratedRun
            RecordId                = "RUN-$Organization-$projectId-$buildId"
            Organization            = $Organization
            ProjectName             = $projectName
            ProjectId               = $projectId
            BuildId                 = $buildId
            BuildNumber             = $buildNumber
            DefinitionId            = [int](Get-SafeProperty -Object $build -Path 'definition.id' -Default 0)
            DefinitionName          = $definitionName
            DefinitionPath          = [string](Get-SafeProperty -Object $build -Path 'definition.path' -Default '')
            DefinitionRevision      = [int](Get-SafeProperty -Object $build -Path 'definition.revision' -Default 0)
            Status                  = [string](Get-SafeProperty -Object $build -Path 'status' -Default '')
            Result                  = [string](Get-SafeProperty -Object $build -Path 'result' -Default '')
            Reason                  = [string](Get-SafeProperty -Object $build -Path 'reason' -Default '')
            QueueTime               = ConvertTo-UtcString -Value $queueTime
            StartTime               = ConvertTo-UtcString -Value $startTime
            FinishTime              = ConvertTo-UtcString -Value $finishTime
            DurationSeconds         = [math]::Round($duration, 2)
            RequestedForDisplayName = [string](Get-SafeProperty -Object $build -Path 'requestedFor.displayName' -Default '')
            RequestedForUpn         = $requestedForUpn
            RequestedForId          = [string](Get-SafeProperty -Object $build -Path 'requestedFor.id' -Default '')
            RequestedByDisplayName  = [string](Get-SafeProperty -Object $build -Path 'requestedBy.displayName' -Default '')
            RequestedByUpn          = [string](Get-SafeProperty -Object $build -Path 'requestedBy.uniqueName' -Default '')
            RepositoryId            = [string](Get-SafeProperty -Object $build -Path 'repository.id' -Default '')
            RepositoryName          = [string](Get-SafeProperty -Object $build -Path 'repository.name' -Default '')
            RepositoryType          = [string](Get-SafeProperty -Object $build -Path 'repository.type' -Default '')
            SourceBranch            = $sourceBranch
            SourceVersion           = [string](Get-SafeProperty -Object $build -Path 'sourceVersion' -Default '')
            SourceVersionMessage    = $sourceVersionMessage
            TriggerPullRequestId    = $triggerPrId
            EnvironmentNames        = ($environments -join ',')
            StagesJson              = (ConvertTo-CompactJson -Value @($stages))
            ApprovalCount           = @($approvalIds).Count
            AgentPoolNames          = ($pools -join ',')
            JiraIssueKeys           = (ConvertTo-JiraIssueKeyString -Text @($sourceBranch, $sourceVersionMessage, $buildNumber))
            WebUrl                  = "https://dev.azure.com/$Organization/$encodedProject/_build/results?buildId=$buildId&view=results"
            ExportRunId             = $ExportRunId
            ExportedOn              = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            SchemaVersion           = $script:SchemaVersion
        })
    }

    return @{
        Runs      = @($runRecords)
        Approvals = @($approvalRecords)
    }
}

# ------------------------------------------------------------------
# Ingestion - Azure Monitor Logs Ingestion API
# ------------------------------------------------------------------

function Send-LawRecord {
    param(
        [Parameter(Mandatory = $true)][string]$IngestionEndpoint,
        [Parameter(Mandatory = $true)][string]$DcrImmutableId,
        [Parameter(Mandatory = $true)][string]$StreamName,
        [Parameter(Mandatory = $true)]$Records,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [int]$MaxRetry = 5,
        [switch]$WhatIfOnly
    )

    $items = @($Records)
    if ($items.Count -eq 0) { return 0 }

    $uri = "{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01" -f `
        $IngestionEndpoint.TrimEnd('/'), $DcrImmutableId, $StreamName

    $headers = @{
        Authorization = 'Bearer ' + $AccessToken
        'Content-Type' = 'application/json'
    }

    function Test-SelfAuditSerialization {
        param($SourceRecords, [string]$JsonBody)

        if ($StreamName -ne 'Custom-ADO_ExportAudit_CL') { return }

        $sourceHashes = @(
            @($SourceRecords) |
                ForEach-Object {
                    [string](Get-SafeProperty -Object $_ -Path 'PayloadSha256' -Default '')
                } |
                ForEach-Object { $_.Trim().ToLowerInvariant() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        # Windows PowerShell 5.1 may preserve a JSON array returned by
        # ConvertFrom-Json as one Object[] value instead of enumerating each
        # element when it is wrapped again with @(...). Flatten it explicitly.
        $parsedBody = ConvertFrom-Json -InputObject $JsonBody
        $serializedRecords = New-Object System.Collections.ArrayList

        if ($parsedBody -is [System.Array]) {
            foreach ($record in $parsedBody) {
                [void]$serializedRecords.Add($record)
            }
        }
        elseif ($null -ne $parsedBody) {
            [void]$serializedRecords.Add($parsedBody)
        }

        $serializedHashes = @(
            $serializedRecords |
                ForEach-Object {
                    [string](Get-SafeProperty -Object $_ -Path 'PayloadSha256' -Default '')
                } |
                ForEach-Object { $_.Trim().ToLowerInvariant() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        if ($sourceHashes.Count -ne 1 -or
            $serializedHashes.Count -ne 1 -or
            $sourceHashes[0] -cne $serializedHashes[0]) {
            throw ("Self-audit serialization integrity check failed. Source={0}; Serialized={1}" -f `
                ($sourceHashes -join ','), ($serializedHashes -join ','))
        }
    }

    function Send-Batch {
        param($BatchItems)

        $batchItemsArray = @($BatchItems)
        if ($batchItemsArray.Count -eq 0) { return 0 }

        $body = ConvertTo-Json -InputObject $batchItemsArray -Depth 10 -Compress
        if (-not $body.StartsWith('[')) {
            $body = '[' + $body + ']'
        }

        Test-SelfAuditSerialization -SourceRecords $batchItemsArray -JsonBody $body

        if ($WhatIfOnly) {
            Write-AuditLog -Message ("WhatIf: would send {0} record(s), {1} bytes to {2}" -f `
                $batchItemsArray.Count, [Text.Encoding]::UTF8.GetByteCount($body), $StreamName)
            return $batchItemsArray.Count
        }

        for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
            try {
                Invoke-RestMethod `
                    -Uri $uri `
                    -Method Post `
                    -Headers $headers `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                    -ErrorAction Stop | Out-Null

                return $batchItemsArray.Count
            }
            catch {
                $status = Get-HttpStatusCode -Exception $_.Exception

                if ($status -eq 403) {
                    throw "Ingestion refused (HTTP 403). The identity needs 'Monitoring Metrics Publisher' on the DCR."
                }

                if ($status -eq 400) {
                    throw ("Ingestion rejected payload for stream '{0}' (HTTP 400)." -f $StreamName)
                }

                if ($attempt -ge $MaxRetry) {
                    throw ("Ingestion failed after {0} attempts (HTTP {1})." -f $attempt, $status)
                }

                $delay = [math]::Min([math]::Pow(2, $attempt), 60)
                Write-AuditLog -Level WARN -Message (
                    "Ingestion failed (HTTP {0}), retry {1}/{2} in {3}s." -f `
                        $status, $attempt, $MaxRetry, $delay
                )
                Start-Sleep -Seconds $delay
            }
        }
    }

    $ingested = 0
    $batch = New-Object System.Collections.ArrayList
    $batchBytes = 0

    foreach ($item in $items) {
        $itemJson = ConvertTo-Json -InputObject $item -Depth 10 -Compress
        $itemBytes = [Text.Encoding]::UTF8.GetByteCount($itemJson) + 1

        if ($batch.Count -gt 0 -and ($batchBytes + $itemBytes) -gt $script:MaxPayloadBytes) {
            $ingested += Send-Batch -BatchItems $batch
            $batch = New-Object System.Collections.ArrayList
            $batchBytes = 0
        }

        [void]$batch.Add($item)
        $batchBytes += $itemBytes
    }

    if ($batch.Count -gt 0) {
        $ingested += Send-Batch -BatchItems $batch
    }

    $verb = if ($WhatIfOnly) { 'would be ingested' } else { 'ingested' }
    Write-AuditLog -Message ("Stream '{0}': {1} record(s) {2}." -f $StreamName, $ingested, $verb)

    return $ingested
}


Export-ModuleMember -Function `
    Write-AuditLog, Get-AzCliToken, New-AdoAuthHeader, Invoke-AdoRestApi, Get-AdoPagedValue, `
    ConvertTo-JiraIssueKeyString, ConvertTo-UtcString, Get-SafeProperty, ConvertTo-CompactJson, `
    Get-Sha256Hex, Get-AdoProject, Get-AdoPullRequestRecord, Get-AdoPipelineRunRecord, Send-LawRecord
