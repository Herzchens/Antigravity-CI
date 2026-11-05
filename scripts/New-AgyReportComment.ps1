#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [psobject] $Report,

    [ValidateRange(1024, 60000)]
    [int] $MaxCharacters = 58000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SafeHtmlText {
    param(
        [AllowNull()]
        [object] $Value,

        [switch] $SingleLine,

        [switch] $Code
    )

    $text = if ($null -eq $Value) { '' } else { [string] $Value }
    $cr = [string][char]13
    $lf = [string][char]10
    $crlf = $cr + $lf
    $text = $text.Replace($crlf, $lf).Replace($cr, $lf)

    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $text.ToCharArray()) {
        $codePoint = [int] $character
        $isBidiControl = (
            $codePoint -eq 0x061C -or
            $codePoint -eq 0x200E -or
            $codePoint -eq 0x200F -or
            ($codePoint -ge 0x202A -and $codePoint -le 0x202E) -or
            ($codePoint -ge 0x2066 -and $codePoint -le 0x2069)
        )

        if (-not $isBidiControl -and
            ($character -eq [char]10 -or $character -eq [char]9 -or $codePoint -ge 32)) {
            [void] $builder.Append($character)
        }
    }

    $text = $builder.ToString()
    $text = $text.Replace('@', '@' + [char]0x200B)

    if ($SingleLine) {
        $text = $text.Replace($lf, ' ')
    }

    if (-not $Code) {
        $text = [regex]::Replace($text, '([\\`*_{}\[\]()#+\-.!|~])', '\$1')
    }

    $encoded = [System.Net.WebUtility]::HtmlEncode($text)

    if (-not $SingleLine) {
        $encoded = $encoded.Replace($lf, '<br>')
    }

    $encoded
}

function Get-OptionalValue {
    param(
        [Parameter(Mandatory)]
        [psobject] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    $property.Value
}

function Get-ReportMarker {
    param(
        [Parameter(Mandatory)]
        [psobject] $InputReport
    )

    $identity = @(
        [string] $InputReport.repo,
        [string] $InputReport.pr,
        [string] $InputReport.head_sha,
        [string] $InputReport.run_id
    ) -join ([string][char]10)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hex = [Convert]::ToHexString($hash).ToLowerInvariant()

    "<!-- antigravity-ci-report:v1:$hex -->"
}

$resultLabel = switch ([string] $Report.result) {
    'passed' { 'passed' }
    'changes_requested' { 'changes requested' }
    'failed' { 'failed' }
    default { throw "Unsupported report result '$($Report.result)'." }
}

$resultIcon = switch ([string] $Report.result) {
    'passed' { '✅' }
    'changes_requested' { '❌' }
    'failed' { '⚠️' }
}

$marker = Get-ReportMarker -InputReport $Report
$lines = [System.Collections.Generic.List[string]]::new()

$lines.Add($marker)
$lines.Add("### $resultIcon Antigravity review: $resultLabel")
$lines.Add('')
$lines.Add("**Exact head:** <code>$(ConvertTo-SafeHtmlText -Value $Report.head_sha -SingleLine -Code)</code>  ")
$lines.Add("**Run:** <code>$(ConvertTo-SafeHtmlText -Value $Report.run_id -SingleLine -Code)</code>  ")
$lines.Add("**Generated:** <code>$(ConvertTo-SafeHtmlText -Value $Report.generated_at -SingleLine -Code)</code>")
$lines.Add('')
$lines.Add((ConvertTo-SafeHtmlText -Value $Report.summary))
$lines.Add('')
$lines.Add('#### Tests')

if (@($Report.tests).Count -eq 0) {
    $lines.Add('_No tests reported._')
}
else {
    foreach ($test in @($Report.tests)) {
        $statusIcon = switch ([string] $test.status) {
            'passed' { '✅' }
            'failed' { '❌' }
            'skipped' { '⏭️' }
            default { '•' }
        }

        $testName = ConvertTo-SafeHtmlText -Value $test.name -SingleLine
        $line = "$statusIcon $testName"

        $evidence = Get-OptionalValue -InputObject $test -Name 'evidence'
        if ($null -ne $evidence) {
            $line += " — $(ConvertTo-SafeHtmlText -Value $evidence)"
        }

        $lines.Add("- $line")
    }
}

$lines.Add('')
$lines.Add('#### Findings')

if (@($Report.findings).Count -eq 0) {
    $lines.Add('_No findings._')
}
else {
    foreach ($finding in @($Report.findings)) {
        $severity = (ConvertTo-SafeHtmlText -Value $finding.severity -SingleLine -Code).ToUpperInvariant()
        $title = ConvertTo-SafeHtmlText -Value $finding.title -SingleLine
        $locationParts = [System.Collections.Generic.List[string]]::new()

        $path = Get-OptionalValue -InputObject $finding -Name 'path'
        if ($null -ne $path) {
            $locationParts.Add("<code>$(ConvertTo-SafeHtmlText -Value $path -SingleLine -Code)</code>")
        }

        $lineNumber = Get-OptionalValue -InputObject $finding -Name 'line'
        if ($null -ne $lineNumber) {
            $locationParts.Add("line $(ConvertTo-SafeHtmlText -Value $lineNumber -SingleLine -Code)")
        }

        $location = if ($locationParts.Count -gt 0) {
            ' (' + ($locationParts -join ', ') + ')'
        }
        else {
            ''
        }

        $lines.Add("- **$severity** — $title$location")
        $lines.Add("  - Evidence: $(ConvertTo-SafeHtmlText -Value $finding.evidence)")
    }
}

if (@($Report.limitations).Count -gt 0) {
    $lines.Add('')
    $lines.Add('#### Limitations')
    foreach ($limitation in @($Report.limitations)) {
        $lines.Add("- $(ConvertTo-SafeHtmlText -Value $limitation)")
    }
}

if (@($Report.tool_failures).Count -gt 0) {
    $lines.Add('')
    $lines.Add('#### Tool failures')
    foreach ($failure in @($Report.tool_failures)) {
        $tool = ConvertTo-SafeHtmlText -Value $failure.tool -SingleLine -Code
        $errorText = ConvertTo-SafeHtmlText -Value $failure.error
        $lines.Add("- <code>$tool</code> — $errorText")
    }
}

$body = $lines -join [Environment]::NewLine

if ($body.Length -gt $MaxCharacters) {
    throw "Formatted AGY report exceeds the maximum comment size of $MaxCharacters characters."
}

[pscustomobject][ordered]@{
    Marker = $marker
    Body = $body
    CharacterCount = $body.Length
}
