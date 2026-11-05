#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$stateVerifierPath = Join-Path $repoRoot 'scripts\Assert-CurrentPullRequestHead.ps1'

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $stateVerifierPath,
    [ref] $tokens,
    [ref] $parseErrors
)

if (@($parseErrors).Count -ne 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "Assert-CurrentPullRequestHead.ps1 does not parse cleanly: $messages"
}

$text = Get-Content -LiteralPath $stateVerifierPath -Raw -Encoding utf8

foreach ($required in @(
    '[System.Net.Http.HttpClientHandler]::new()',
    '$handler.AllowAutoRedirect = $false',
    '$handler.UseCookies = $false',
    '$handler.UseDefaultCredentials = $false',
    '[System.Net.Http.HttpClient]::new($handler, $true)',
    'https://api.github.com/repos/$Repository/pulls/$PrNumber',
    '$pull.head.sha -cne $ExpectedHeadSha',
    '$pull.base.sha -cne $ExpectedBaseSha',
    '$pull.base.ref -cne $ExpectedBaseRef',
    '$pull.head.repo.full_name -cne $Repository',
    '$headRepositoryId -ne $baseRepositoryId'
)) {
    if (-not $text.Contains($required, [StringComparison]::Ordinal)) {
        throw "Live PR-state transport contract missing: $required"
    }
}

if ($text.Contains('[System.Net.Http.HttpClient]::new()' + [Environment]::NewLine, [StringComparison]::Ordinal)) {
    throw 'Live PR-state verifier must not use the ambient default HttpClient handler.'
}

Write-Host '[PASS] live PR-state verifier rejects automatic redirects and ambient HTTP credentials'
Write-Host '[PASS] live PR-state verifier binds exact head, trusted base, and same-repository identity'
