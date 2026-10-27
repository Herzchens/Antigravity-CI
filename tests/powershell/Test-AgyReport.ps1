#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$resolver = Join-Path $repoRoot 'scripts\Resolve-AgyReport.ps1'
$schema = Join-Path $repoRoot 'schemas\agy-report.schema.json'
$validFixture = Join-Path $repoRoot 'tests\fixtures\agy-report.valid.json'
$invalidFixture = Join-Path $repoRoot 'tests\fixtures\agy-report.invalid.json'

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        throw "Expected failure: $Name"
    }

    Write-Host "[PASS] $Name"
}

$expected = @{
    ReportPath = $validFixture
    ExpectedRepository = 'Herzchens/Example'
    ExpectedPr = 42
    ExpectedHeadSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ExpectedRunId = '123456789'
    SchemaPath = $schema
}

$report = & $resolver @expected

if ($report.result -ne 'changes_requested') {
    throw 'Valid report result was not preserved.'
}

if ($report.findings.Count -ne 1 -or $report.findings[0].severity -ne 'high') {
    throw 'Valid report findings were not preserved.'
}

Write-Host '[PASS] valid report is schema-validated and context-bound'

$invalid = $expected.Clone()
$invalid.ReportPath = $invalidFixture

Assert-Throws -Name 'schema-invalid report is rejected' -Action {
    & $resolver @invalid
}

$staleHead = $expected.Clone()
$staleHead.ExpectedHeadSha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

Assert-Throws -Name 'stale head report is rejected' -Action {
    & $resolver @staleHead
}

$wrongRun = $expected.Clone()
$wrongRun.ExpectedRunId = 'different-run'

Assert-Throws -Name 'wrong run report is rejected' -Action {
    & $resolver @wrongRun
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-report-test-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $badTimestampPath = Join-Path $tempRoot 'bad-timestamp.json'
    $badTimestamp = Get-Content -LiteralPath $validFixture -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 32
    $badTimestamp.generated_at = 'not-a-timestamp'
    $badTimestamp |
        ConvertTo-Json -Depth 32 |
        Set-Content -LiteralPath $badTimestampPath -Encoding utf8NoBOM

    $badTimestampParameters = $expected.Clone()
    $badTimestampParameters.ReportPath = $badTimestampPath

    Assert-Throws -Name 'invalid generated_at timestamp is rejected' -Action {
        & $resolver @badTimestampParameters
    }

    $oversizePath = Join-Path $tempRoot 'oversize.json'
    [System.IO.File]::WriteAllText(
        $oversizePath,
        (' ' * 2048),
        [System.Text.UTF8Encoding]::new($false)
    )

    $oversizeParameters = $expected.Clone()
    $oversizeParameters.ReportPath = $oversizePath
    $oversizeParameters.MaxBytes = 1024

    Assert-Throws -Name 'oversize report is rejected before parsing' -Action {
        & $resolver @oversizeParameters
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
