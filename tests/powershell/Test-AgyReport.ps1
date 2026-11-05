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

    $duplicatePath = Join-Path $tempRoot 'duplicate.json'
    $compactReport = (
        Get-Content -LiteralPath $validFixture -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 32 |
        ConvertTo-Json -Depth 32 -Compress
    )
    $duplicateNeedle = '"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
    $duplicateReplacement = '"head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'

    if (-not $compactReport.Contains($duplicateNeedle, [StringComparison]::Ordinal)) {
        throw 'Duplicate-property fixture could not locate head_sha.'
    }

    $duplicateReport = $compactReport.Replace($duplicateNeedle, $duplicateReplacement)
    [System.IO.File]::WriteAllText(
        $duplicatePath,
        $duplicateReport,
        [System.Text.UTF8Encoding]::new($false)
    )

    $duplicateParameters = $expected.Clone()
    $duplicateParameters.ReportPath = $duplicatePath

    Assert-Throws -Name 'duplicate JSON properties are rejected before object conversion' -Action {
        & $resolver @duplicateParameters
    }

    $invalidUtf8Path = Join-Path $tempRoot 'invalid-utf8.json'
    [System.IO.File]::WriteAllBytes(
        $invalidUtf8Path,
        [byte[]] @(0x7B, 0x22, 0x78, 0x22, 0x3A, 0xFF, 0x7D)
    )

    $invalidUtf8Parameters = $expected.Clone()
    $invalidUtf8Parameters.ReportPath = $invalidUtf8Path

    Assert-Throws -Name 'invalid UTF-8 report bytes are rejected' -Action {
        & $resolver @invalidUtf8Parameters
    }

    $contradictoryPath = Join-Path $tempRoot 'contradictory-passed.json'
    $contradictory = Get-Content -LiteralPath $validFixture -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 32
    $contradictory.result = 'passed'
    $contradictory |
        ConvertTo-Json -Depth 32 |
        Set-Content -LiteralPath $contradictoryPath -Encoding utf8NoBOM

    $contradictoryParameters = $expected.Clone()
    $contradictoryParameters.ReportPath = $contradictoryPath

    Assert-Throws -Name 'passed report containing a failed test is rejected' -Action {
        & $resolver @contradictoryParameters
    }

    $advisoryFindingPath = Join-Path $tempRoot 'advisory-finding-passed.json'
    $advisoryFinding = Get-Content -LiteralPath $validFixture -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 32
    $advisoryFinding.result = 'passed'
    foreach ($test in @($advisoryFinding.tests)) {
        $test.status = 'passed'
        if ($null -ne $test.PSObject.Properties['evidence']) {
            $test.PSObject.Properties.Remove('evidence')
        }
    }
    $advisoryFinding |
        ConvertTo-Json -Depth 32 |
        Set-Content -LiteralPath $advisoryFindingPath -Encoding utf8NoBOM

    $advisoryFindingParameters = $expected.Clone()
    $advisoryFindingParameters.ReportPath = $advisoryFindingPath
    $advisoryResult = & $resolver @advisoryFindingParameters

    if ($advisoryResult.result -ne 'passed' -or $advisoryResult.findings.Count -ne 1) {
        throw 'Advisory findings should remain reportable without an invented severity-to-result policy.'
    }

    $toolFailurePath = Join-Path $tempRoot 'tool-failure-passed.json'
    $toolFailure = Get-Content -LiteralPath $validFixture -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 32
    $toolFailure.result = 'passed'
    foreach ($case in @($toolFailure.tests)) {
        $case.status = 'passed'
        if ($null -ne $case.PSObject.Properties['evidence']) {
            $case.PSObject.Properties.Remove('evidence')
        }
    }
    $toolFailure.tool_failures = @(
        [pscustomobject][ordered]@{
            tool = 'run_command'
            error = 'permission denied'
        }
    )
    $toolFailure |
        ConvertTo-Json -Depth 32 |
        Set-Content -LiteralPath $toolFailurePath -Encoding utf8NoBOM

    $toolFailureParameters = $expected.Clone()
    $toolFailureParameters.ReportPath = $toolFailurePath

    Assert-Throws -Name 'passed report containing a tool failure is rejected' -Action {
        & $resolver @toolFailureParameters
    }

    Write-Host '[PASS] report result cannot contradict failed test evidence'
    Write-Host '[PASS] report result cannot hide tool execution failures'
    Write-Host '[PASS] finding severity remains advisory rather than an automatic result override'

    $symlinkPath = Join-Path $tempRoot 'report-link.json'
    $symlinkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $validFixture -ErrorAction Stop | Out-Null
        $symlinkCreated = $true
    }
    catch {
        Write-Host '[SKIP] symbolic-link fixture is unavailable on this host'
    }

    if ($symlinkCreated) {
        $symlinkParameters = $expected.Clone()
        $symlinkParameters.ReportPath = $symlinkPath

        Assert-Throws -Name 'symbolic-link report path is rejected' -Action {
            & $resolver @symlinkParameters
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
