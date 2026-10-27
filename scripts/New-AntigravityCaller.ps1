#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $OutputPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $InfrastructureRepository,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $InfrastructureCommit,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $SigningRunnerLabel,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ReviewRunnerLabel,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $PublisherRunnerLabel,

    [Parameter(Mandatory)]
    [ValidateLength(1, 1024)]
    [string] $SigningPublicKeyPath,

    [Parameter(Mandatory)]
    [ValidateLength(1, 1024)]
    [string] $ReviewPublicKeyPath,

    [Parameter(Mandatory)]
    [ValidateLength(1, 128)]
    [string] $ExpectedReporterLogin,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-YamlSingleQuotedValue {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Value.IndexOfAny([char[]] @(0, 10, 13)) -ge 0) {
        throw "$Name must not contain NUL or line breaks."
    }

    $Value.Replace("'", "''")
}

function Replace-TemplateToken {
    param(
        [Parameter(Mandatory)]
        [string] $Text,

        [Parameter(Mandatory)]
        [string] $Token,

        [Parameter(Mandatory)]
        [string] $Value
    )

    $count = [regex]::Matches(
        $Text,
        [regex]::Escape($Token),
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    ).Count

    if ($count -ne 1) {
        throw "Template token '$Token' must occur exactly once; found $count."
    }

    $Text.Replace($Token, $Value)
}

$templatePath = Join-Path $PSScriptRoot '..\templates\caller-workflow.yml'
$templatePath = (Resolve-Path -LiteralPath $templatePath -ErrorAction Stop).Path
$template = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8

$signingPath = ConvertTo-YamlSingleQuotedValue -Value $SigningPublicKeyPath -Name 'SigningPublicKeyPath'
$reviewPath = ConvertTo-YamlSingleQuotedValue -Value $ReviewPublicKeyPath -Name 'ReviewPublicKeyPath'
$reporterLogin = ConvertTo-YamlSingleQuotedValue -Value $ExpectedReporterLogin -Name 'ExpectedReporterLogin'

$replacements = [ordered]@{
    'REPLACE_WITH_INFRASTRUCTURE_REPOSITORY' = $InfrastructureRepository
    'REPLACE_WITH_PINNED_COMMIT_SHA' = $InfrastructureCommit
    'REPLACE_WITH_SIGNING_RUNNER_LABEL' = $SigningRunnerLabel
    'REPLACE_WITH_REVIEW_RUNNER_LABEL' = $ReviewRunnerLabel
    'REPLACE_WITH_PUBLISHER_RUNNER_LABEL' = $PublisherRunnerLabel
    'REPLACE_WITH_SIGNING_PUBLIC_KEY_PATH' = $signingPath
    'REPLACE_WITH_REVIEW_PUBLIC_KEY_PATH' = $reviewPath
    'REPLACE_WITH_REPORTER_LOGIN' = $reporterLogin
}

$rendered = $template
foreach ($entry in $replacements.GetEnumerator()) {
    $rendered = Replace-TemplateToken -Text $rendered -Token $entry.Key -Value $entry.Value
}

if ($rendered.Contains('REPLACE_WITH_', [StringComparison]::Ordinal)) {
    throw 'Caller workflow template still contains unresolved replacement tokens.'
}

$fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$extension = [System.IO.Path]::GetExtension($fullOutputPath)
if ($extension -notin @('.yml', '.yaml')) {
    throw 'Caller workflow output must use a .yml or .yaml extension.'
}

if ((Test-Path -LiteralPath $fullOutputPath) -and -not $Force) {
    throw "Caller workflow already exists: $fullOutputPath"
}

$parent = Split-Path -Parent $fullOutputPath
if ([string]::IsNullOrWhiteSpace($parent)) {
    throw 'Caller workflow output must have a parent directory.'
}

New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
[System.IO.File]::WriteAllText(
    $fullOutputPath,
    $rendered,
    [System.Text.UTF8Encoding]::new($false)
)

[pscustomobject][ordered]@{
    Path = $fullOutputPath
    InfrastructureRepository = $InfrastructureRepository
    InfrastructureCommit = $InfrastructureCommit
    SigningRunnerLabel = $SigningRunnerLabel
    ReviewRunnerLabel = $ReviewRunnerLabel
    PublisherRunnerLabel = $PublisherRunnerLabel
}
