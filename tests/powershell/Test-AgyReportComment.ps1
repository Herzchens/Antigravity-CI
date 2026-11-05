#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$formatter = Join-Path $repoRoot 'scripts\New-AgyReportComment.ps1'
$fixturePath = Join-Path $repoRoot 'tests\fixtures\agy-report.valid.json'

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

$report = Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 32

$first = & $formatter -Report $report
$second = & $formatter -Report $report

if ($first.Marker -ne $second.Marker -or $first.Body -ne $second.Body) {
    throw 'Report comment formatting is not deterministic.'
}

if ($first.Marker -notmatch '^<!-- antigravity-ci-report:v1:[0-9a-f]{64} -->$') {
    throw 'Report marker is not a fixed SHA-256 marker.'
}

if ($first.Body -notmatch [regex]::Escape($report.head_sha)) {
    throw 'Formatted report does not include the exact reviewed head SHA.'
}

Write-Host '[PASS] report comment is deterministic and exact-head attributed'

$originalMarker = $first.Marker
$report.summary = (
    '<script>alert(1)</script> @Herzchens **markdown** [click](https://evil.invalid) # heading <!-- hidden -->' +
    [char]0x202E +
    'bidi-spoof' +
    [char]0x2066
)
$report.findings[0].title = 'title | @team <b>html</b> **bold**'
$report.findings[0].evidence = 'evidence with *emphasis*, [link](https://evil.invalid), and @everyone'
$report.findings[0].path = 'src/<unsafe>|file.ps1'

$hostile = & $formatter -Report $report

if ($hostile.Body -match '<script>' -or
    $hostile.Body -match '<b>html</b>' -or
    $hostile.Body -match '@Herzchens' -or
    $hostile.Body -match '@everyone' -or
    $hostile.Body.Contains('**markdown**') -or
    $hostile.Body.Contains('[click](https://evil.invalid)')) {
    throw 'Untrusted report text was not neutralized before Markdown publication.'
}

$neutralizedMention = '@' + [char]0x200B + 'Herzchens'
if ($hostile.Body -notmatch '&lt;script&gt;' -or
    -not $hostile.Body.Contains($neutralizedMention)) {
    throw 'Expected escaped or mention-neutralized content was not present.'
}

foreach ($bidiControl in @([char]0x202E, [char]0x2066, [char]0x061C, [char]0x200F)) {
    if ($hostile.Body.Contains([string] $bidiControl, [StringComparison]::Ordinal)) {
        throw 'Unicode bidi control survived report-comment sanitization.'
    }
}

if ($hostile.Marker -ne $originalMarker) {
    throw 'Report marker must be bound to review identity, not mutable report prose.'
}

Write-Host '[PASS] report prose is HTML-escaped, Markdown-literal, and mentions are neutralized'

$otherRun = Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 32
$otherRun.run_id = 'different-run'
$otherMarker = (& $formatter -Report $otherRun).Marker

if ($otherMarker -eq $originalMarker) {
    throw 'Different run IDs produced the same report marker.'
}

Write-Host '[PASS] report marker changes across review runs'

$oversize = Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 32
$oversize.summary = 'x' * 4000

Assert-Throws -Name 'comment size limit is enforced' -Action {
    & $formatter -Report $oversize -MaxCharacters 1024
}
