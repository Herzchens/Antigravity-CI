#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ReportPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $ExpectedRepository,

    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int] $ExpectedPr,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedHeadSha,

    [Parameter(Mandatory)]
    [ValidateLength(1, 128)]
    [string] $ExpectedRunId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]+(?:\[bot\])?$')]
    [string] $ExpectedReporterLogin,

    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
    [string] $TokenEnvironmentVariable = 'AGY_REPORTER_TOKEN',

    [ValidateRange(1024, 60000)]
    [int] $MaxCommentCharacters = 58000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitHubRequest {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [System.Net.Http.HttpMethod] $Method,

        [Parameter(Mandatory)]
        [uri] $Uri,

        [AllowNull()]
        [object] $Body
    )

    $request = [System.Net.Http.HttpRequestMessage]::new($Method, $Uri)

    try {
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 32 -Compress
            $request.Content = [System.Net.Http.StringContent]::new(
                $json,
                [System.Text.Encoding]::UTF8,
                'application/json'
            )
        }

        $response = $Client.Send($request)
        try {
            $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

            if (-not $response.IsSuccessStatusCode) {
                $status = [int] $response.StatusCode
                $message = ''

                if (-not [string]::IsNullOrWhiteSpace($responseText)) {
                    try {
                        $errorObject = ConvertFrom-Json -InputObject $responseText -Depth 16 -ErrorAction Stop
                        if ($null -ne $errorObject.PSObject.Properties['message']) {
                            $message = [string] $errorObject.message
                        }
                    }
                    catch {
                        $message = ''
                    }
                }

                if ($message.Length -gt 512) {
                    $message = $message.Substring(0, 512)
                }

                if ([string]::IsNullOrWhiteSpace($message)) {
                    throw "GitHub API request failed with HTTP $status."
                }

                throw "GitHub API request failed with HTTP $status: $message"
            }

            $jsonObject = if ([string]::IsNullOrWhiteSpace($responseText)) {
                $null
            }
            else {
                ConvertFrom-Json -InputObject $responseText -Depth 64 -ErrorAction Stop
            }

            [pscustomobject]@{
                StatusCode = [int] $response.StatusCode
                Json = $jsonObject
            }
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $request.Dispose()
    }
}

$tokenItem = Get-Item -LiteralPath "Env:$TokenEnvironmentVariable" -ErrorAction SilentlyContinue
if ($null -eq $tokenItem -or [string]::IsNullOrWhiteSpace([string] $tokenItem.Value)) {
    throw "Publisher token environment variable '$TokenEnvironmentVariable' is not set."
}

$token = [string] $tokenItem.Value
$reportResolver = Join-Path $PSScriptRoot 'Resolve-AgyReport.ps1'
$commentFormatter = Join-Path $PSScriptRoot 'New-AgyReportComment.ps1'

if (-not (Test-Path -LiteralPath $reportResolver -PathType Leaf)) {
    throw 'Resolve-AgyReport.ps1 is required next to the publisher.'
}

if (-not (Test-Path -LiteralPath $commentFormatter -PathType Leaf)) {
    throw 'New-AgyReportComment.ps1 is required next to the publisher.'
}

$reportParameters = @{
    ReportPath = $ReportPath
    ExpectedRepository = $ExpectedRepository
    ExpectedPr = $ExpectedPr
    ExpectedHeadSha = $ExpectedHeadSha
    ExpectedRunId = $ExpectedRunId
}

$report = & $reportResolver @reportParameters
$formatted = & $commentFormatter -Report $report -MaxCharacters $MaxCommentCharacters

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('Antigravity-CI/1')
$client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
$client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')
$client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)

try {
    $base = 'https://api.github.com'
    $pullUri = [uri] "$base/repos/$ExpectedRepository/pulls/$ExpectedPr"
    $pullResponse = Invoke-GitHubRequest -Client $client -Method ([System.Net.Http.HttpMethod]::Get) -Uri $pullUri -Body $null
    $pull = $pullResponse.Json

    if ($null -eq $pull) {
        throw 'GitHub pull-request lookup returned no JSON body.'
    }

    if ([string] $pull.state -cne 'open') {
        throw 'Pull request is no longer open; refusing to publish an AGY report.'
    }

    if ([string] $pull.head.sha -cne $ExpectedHeadSha) {
        throw 'Pull request head moved after review; refusing to publish a stale AGY report.'
    }

    if ([string] $pull.head.repo.full_name -cne $ExpectedRepository) {
        throw 'Pull request head repository no longer matches the expected trusted repository.'
    }

    $alreadyPublished = $false
    $existingComment = $null

    for ($page = 1; $page -le 50; $page++) {
        $commentsUri = [uri] "$base/repos/$ExpectedRepository/issues/$ExpectedPr/comments?per_page=100&page=$page"
        $commentsResponse = Invoke-GitHubRequest -Client $client -Method ([System.Net.Http.HttpMethod]::Get) -Uri $commentsUri -Body $null
        $comments = @($commentsResponse.Json)

        foreach ($comment in $comments) {
            if ([string] $comment.user.login -ceq $ExpectedReporterLogin -and
                [string] $comment.body -like "*$($formatted.Marker)*") {
                $alreadyPublished = $true
                $existingComment = $comment
                break
            }
        }

        if ($alreadyPublished -or $comments.Count -lt 100) {
            break
        }

        if ($page -eq 50) {
            throw 'Too many PR comments to establish report idempotency safely.'
        }
    }

    if ($alreadyPublished) {
        $existingFreshResponse = Invoke-GitHubRequest -Client $client -Method ([System.Net.Http.HttpMethod]::Get) -Uri $pullUri -Body $null
        $existingFresh = $existingFreshResponse.Json

        if ($null -eq $existingFresh -or
            [string] $existingFresh.state -cne 'open' -or
            [string] $existingFresh.head.sha -cne $ExpectedHeadSha -or
            [string] $existingFresh.head.repo.full_name -cne $ExpectedRepository) {
            throw 'Pull request changed while checking report idempotency; refusing to accept a stale existing report.'
        }

        [pscustomobject][ordered]@{
            AlreadyPublished = $true
            CommentId = [long] $existingComment.id
            CommentUrl = [string] $existingComment.html_url
            ReporterLogin = [string] $existingComment.user.login
            HeadSha = $ExpectedHeadSha
            RunId = $ExpectedRunId
        }
        return
    }

    $freshPullResponse = Invoke-GitHubRequest -Client $client -Method ([System.Net.Http.HttpMethod]::Get) -Uri $pullUri -Body $null
    $freshPull = $freshPullResponse.Json

    if ($null -eq $freshPull -or
        [string] $freshPull.state -cne 'open' -or
        [string] $freshPull.head.sha -cne $ExpectedHeadSha -or
        [string] $freshPull.head.repo.full_name -cne $ExpectedRepository) {
        throw 'Pull request changed while preparing publication; refusing to publish a stale AGY report.'
    }

    $commentsUri = [uri] "$base/repos/$ExpectedRepository/issues/$ExpectedPr/comments"
    $postResponse = Invoke-GitHubRequest -Client $client -Method ([System.Net.Http.HttpMethod]::Post) -Uri $commentsUri -Body @{
        body = $formatted.Body
    }

    $created = $postResponse.Json
    if ($null -eq $created -or $null -eq $created.PSObject.Properties['id']) {
        throw 'GitHub comment creation returned an unexpected response.'
    }

    $actualReporter = [string] $created.user.login
    if ($actualReporter -cne $ExpectedReporterLogin) {
        $commentId = [long] $created.id
        $deleteUri = [uri] "$base/repos/$ExpectedRepository/issues/comments/$commentId"
        $deleteFailed = $false

        try {
            $null = Invoke-GitHubRequest -Client $client -Method ([System.Net.Http.HttpMethod]::Delete) -Uri $deleteUri -Body $null
        }
        catch {
            $deleteFailed = $true
        }

        if ($deleteFailed) {
            throw "Publisher identity mismatch: expected '$ExpectedReporterLogin', received '$actualReporter'. Cleanup of comment $commentId also failed."
        }

        throw "Publisher identity mismatch: expected '$ExpectedReporterLogin', received '$actualReporter'. The unexpected comment was deleted."
    }

    $postPublishResponse = Invoke-GitHubRequest -Client $client -Method ([System.Net.Http.HttpMethod]::Get) -Uri $pullUri -Body $null
    $postPublishPull = $postPublishResponse.Json

    if ($null -eq $postPublishPull -or
        [string] $postPublishPull.state -cne 'open' -or
        [string] $postPublishPull.head.sha -cne $ExpectedHeadSha -or
        [string] $postPublishPull.head.repo.full_name -cne $ExpectedRepository) {
        $commentId = [long] $created.id
        $deleteUri = [uri] "$base/repos/$ExpectedRepository/issues/comments/$commentId"
        $cleanupFailed = $false

        try {
            $null = Invoke-GitHubRequest -Client $client -Method ([System.Net.Http.HttpMethod]::Delete) -Uri $deleteUri -Body $null
        }
        catch {
            $cleanupFailed = $true
        }

        if ($cleanupFailed) {
            throw "Pull request head changed immediately after publication. Cleanup of stale comment $commentId failed."
        }

        throw 'Pull request head changed immediately after publication. The stale report comment was deleted.'
    }

    [pscustomobject][ordered]@{
        AlreadyPublished = $false
        CommentId = [long] $created.id
        CommentUrl = [string] $created.html_url
        ReporterLogin = $actualReporter
        HeadSha = $ExpectedHeadSha
        RunId = $ExpectedRunId
    }
}
finally {
    $client.Dispose()
    $token = $null
}
