#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$publisherPath = Join-Path $repoRoot 'scripts\Publish-AgyReport.ps1'
$workflowPath = Join-Path $repoRoot '.github\workflows\review.yml'

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $publisherPath,
    [ref] $tokens,
    [ref] $parseErrors
)

if (@($parseErrors).Count -ne 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "Publish-AgyReport.ps1 does not parse cleanly: $messages"
}

$publisher = Get-Content -LiteralPath $publisherPath -Raw -Encoding utf8
$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8

foreach ($required in @(
    '[string] $ExpectedBaseSha',
    '[string] $ExpectedBaseRef',
    'function Assert-ExpectedPullState',
    '$Pull.base.sha -cne $ExpectedBaseSha',
    '$Pull.base.ref -cne $ExpectedBaseRef',
    '$Pull.base.repo.full_name -cne $ExpectedRepository',
    '$headRepositoryId -ne $baseRepositoryId',
    '[bool] $Pull.draft',
    '$handler.AllowAutoRedirect = $false',
    '$handler.UseCookies = $false',
    '$handler.UseDefaultCredentials = $false',
    '$base = ''https://api.github.com'''
)) {
    if (-not $publisher.Contains($required, [StringComparison]::Ordinal)) {
        throw "Publisher security contract missing: $required"
    }
}

$stateChecks = [regex]::Matches(
    $publisher,
    'Assert-ExpectedPullState\s+-Pull\s+\$[A-Za-z]+'
).Count
if ($stateChecks -ne 4) {
    throw "Expected four exact PR-state checks in publisher, found $stateChecks."
}

$publisherJobStart = $workflow.IndexOf('  publisher:', [StringComparison]::Ordinal)
if ($publisherJobStart -lt 0) {
    throw 'Publisher job is missing from workflow.'
}
$publisherJob = $workflow.Substring($publisherJobStart)

$baseShaCalls = [regex]::Matches($publisherJob, '-ExpectedBaseSha \$env:TARGET_BASE').Count
$baseRefCalls = [regex]::Matches($publisherJob, '-ExpectedBaseRef \$env:TARGET_BASE_REF').Count
if ($baseShaCalls -ne 3 -or $baseRefCalls -ne 3) {
    throw "Expected base state in publisher preflight and both publish paths; found SHA=$baseShaCalls ref=$baseRefCalls."
}

Write-Host '[PASS] publisher rejects automatic HTTP redirects and ambient HTTP credentials'
Write-Host '[PASS] publisher binds every API state check to exact head and trusted base state'
Write-Host '[PASS] publisher rejects draft and cross-repository transitions'
