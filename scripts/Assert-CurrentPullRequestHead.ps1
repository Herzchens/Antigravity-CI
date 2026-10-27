#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository,

    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int] $PrNumber,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedHeadSha,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedBaseSha,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string] $ExpectedBaseRef,

    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
    [string] $TokenEnvironmentVariable = 'GITHUB_TOKEN'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tokenItem = Get-Item -LiteralPath "Env:$TokenEnvironmentVariable" -ErrorAction SilentlyContinue
if ($null -eq $tokenItem -or [string]::IsNullOrWhiteSpace([string] $tokenItem.Value)) {
    throw "GitHub read token environment variable '$TokenEnvironmentVariable' is not set."
}

$token = [string] $tokenItem.Value
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('Antigravity-CI/1')
$client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
$client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')
$client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)

try {
    $uri = [uri] "https://api.github.com/repos/$Repository/pulls/$PrNumber"
    $response = $client.GetAsync($uri).GetAwaiter().GetResult()

    try {
        if (-not $response.IsSuccessStatusCode) {
            throw "GitHub pull-request lookup failed with HTTP $([int] $response.StatusCode)."
        }

        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $pull = ConvertFrom-Json -InputObject $text -Depth 32 -ErrorAction Stop
    }
    finally {
        $response.Dispose()
    }

    if ([string] $pull.state -cne 'open') {
        throw 'Pull request is no longer open.'
    }

    if ([bool] $pull.draft) {
        throw 'Pull request became draft.'
    }

    if ([string] $pull.head.repo.full_name -cne $Repository -or
        [string] $pull.base.repo.full_name -cne $Repository) {
        throw 'Pull request repositories no longer match the trusted repository.'
    }

    $headRepositoryId = [long] $pull.head.repo.id
    $baseRepositoryId = [long] $pull.base.repo.id
    if ($headRepositoryId -le 0 -or
        $baseRepositoryId -le 0 -or
        $headRepositoryId -ne $baseRepositoryId) {
        throw 'Pull request head/base repository identity no longer matches.'
    }

    if ([string] $pull.base.ref -cne $ExpectedBaseRef) {
        throw 'Pull request base branch no longer matches the expected trusted base.'
    }

    if ([string] $pull.base.sha -cne $ExpectedBaseSha) {
        throw "Pull request base moved from expected SHA $ExpectedBaseSha."
    }

    if ([string] $pull.head.sha -cne $ExpectedHeadSha) {
        throw "Pull request head moved from expected SHA $ExpectedHeadSha."
    }

    [pscustomobject][ordered]@{
        Repository = $Repository
        RepositoryId = $baseRepositoryId
        PrNumber = $PrNumber
        BaseRef = $ExpectedBaseRef
        BaseSha = $ExpectedBaseSha
        HeadSha = $ExpectedHeadSha
        Open = $true
        Draft = $false
    }
}
finally {
    $client.Dispose()
    $token = $null
}
