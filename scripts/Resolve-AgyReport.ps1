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

function Assert-NoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Element
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )

        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) {
                throw 'AGY report contains a duplicate JSON property.'
            }

            Assert-NoDuplicateJsonProperties -Element $property.Value
        }

        return
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties -Element $item
        }
    }
}

$null = Get-Command Test-Json -ErrorAction Stop

$resolvedReportPath = (Resolve-Path -LiteralPath $ReportPath -ErrorAction Stop).Path
$reportItem = Get-Item -LiteralPath $resolvedReportPath -ErrorAction Stop

if ($reportItem.PSIsContainer) {
    throw 'AGY report path must reference a file.'
}

if (($reportItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'AGY report path must not be a symbolic link or reparse point.'
}

if ($reportItem.Length -gt $MaxBytes) {
    throw "AGY report exceeds the maximum allowed size of $MaxBytes bytes."
}

if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path $PSScriptRoot '..\schemas\agy-report.schema.json'
}

$resolvedSchemaPath = (Resolve-Path -LiteralPath $SchemaPath -ErrorAction Stop).Path

$reportBytes = [System.IO.File]::ReadAllBytes($resolvedReportPath)
$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

try {
    $reportJson = $strictUtf8.GetString($reportBytes)
}
catch [System.Text.DecoderFallbackException] {
    throw 'AGY report is not valid UTF-8.'
}

$jsonDocument = $null
try {
    $jsonOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $jsonDocument = [System.Text.Json.JsonDocument]::Parse($reportJson, $jsonOptions)
    Assert-NoDuplicateJsonProperties -Element $jsonDocument.RootElement
}
catch [System.Text.Json.JsonException] {
    throw 'AGY report is not valid JSON.'
}
finally {
    if ($null -ne $jsonDocument) {
        $jsonDocument.Dispose()
    }
}

$matchesSchema = [bool](
    Test-Json -Json $reportJson -SchemaFile $resolvedSchemaPath -ErrorAction SilentlyContinue
)

if (-not $matchesSchema) {
    throw 'AGY report does not match schemas/agy-report.schema.json.'
}

$report = ConvertFrom-Json -InputObject $reportJson -Depth 32 -DateKind String -ErrorAction Stop

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

if ([string] $report.result -ceq 'passed') {
    $failedTests = @(
        @($report.tests) |
        Where-Object { [string] $_.status -ceq 'failed' }
    )

    if ($failedTests.Count -gt 0) {
        throw 'AGY report result is contradictory: a passed review cannot contain failed tests.'
    }

    if (@($report.tool_failures).Count -gt 0) {
        throw 'AGY report result is contradictory: a passed review cannot contain tool failures.'
    }
}

$report
