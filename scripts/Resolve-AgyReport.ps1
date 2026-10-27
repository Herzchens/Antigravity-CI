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

    [string] $SchemaPath,

    [ValidateRange(1024, 10485760)]
    [int] $MaxBytes = 131072
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$null = Get-Command Test-Json -ErrorAction Stop

$resolvedReportPath = (Resolve-Path -LiteralPath $ReportPath -ErrorAction Stop).Path
$reportItem = Get-Item -LiteralPath $resolvedReportPath -ErrorAction Stop

if ($reportItem.PSIsContainer) {
    throw 'AGY report path must reference a file.'
}

if ($reportItem.Length -gt $MaxBytes) {
    throw "AGY report exceeds the maximum allowed size of $MaxBytes bytes."
}

if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path $PSScriptRoot '..\schemas\agy-report.schema.json'
}

$resolvedSchemaPath = (Resolve-Path -LiteralPath $SchemaPath -ErrorAction Stop).Path
$reportJson = Get-Content -LiteralPath $resolvedReportPath -Raw -Encoding utf8

$matchesSchema = [bool](
    Test-Json -Json $reportJson -SchemaFile $resolvedSchemaPath -ErrorAction SilentlyContinue
)

if (-not $matchesSchema) {
    throw 'AGY report does not match schemas/agy-report.schema.json.'
}

$report = ConvertFrom-Json -InputObject $reportJson -Depth 32 -ErrorAction Stop

if ([string] $report.repo -cne $ExpectedRepository) {
    throw 'AGY report repository does not match the expected repository.'
}

if ([int] $report.pr -ne $ExpectedPr) {
    throw 'AGY report PR number does not match the expected PR.'
}

if ([string] $report.head_sha -cne $ExpectedHeadSha) {
    throw 'AGY report head SHA does not match the expected signed head.'
}

if ([string] $report.run_id -cne $ExpectedRunId) {
    throw 'AGY report run ID does not match the expected run.'
}

$generatedAt = [string] $report.generated_at
if ($generatedAt -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') {
    throw 'AGY report generated_at is not a valid RFC 3339 timestamp.'
}

try {
    $null = [DateTimeOffset]::Parse(
        $generatedAt,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    )
}
catch {
    throw 'AGY report generated_at is not a valid RFC 3339 timestamp.'
}

$report
