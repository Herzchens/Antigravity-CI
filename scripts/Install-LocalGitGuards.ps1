#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $RepositoryPath = '.',

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    $output = @(& git -C $script:RepoRoot @Arguments 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git command failed with exit code $exitCode."
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Resolve-GitPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot $Path))
}

function ConvertTo-ShSingleQuotedValue {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Value.IndexOfAny([char[]] @(0, 10, 13)) -ge 0) {
        throw "$Name must not contain NUL or line breaks."
    }

    $normalized = $Value.Replace('\', '/')
    $singleQuote = [string] [char] 39
    $doubleQuote = [string] [char] 34
    $embeddedQuote = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    $singleQuote + $normalized.Replace($singleQuote, $embeddedQuote) + $singleQuote
}

$null = Get-Command git -ErrorAction Stop
$null = Get-Command pwsh -ErrorAction Stop

$RepoRoot = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
$script:RepoRoot = $RepoRoot

$insideWorkTree = (
    Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree')
).Output | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($insideWorkTree) -or
    $insideWorkTree.Trim().ToLowerInvariant() -ne 'true') {
    throw 'Local Git guards require a non-bare working repository.'
}

$guardScript = Join-Path $RepoRoot 'scripts\Test-PublishBoundary.ps1'
if (-not (Test-Path -LiteralPath $guardScript -PathType Leaf)) {
    throw 'scripts/Test-PublishBoundary.ps1 is required.'
}

$defaultHooksOutput = Invoke-Git -Arguments @('rev-parse', '--git-path', 'hooks')
$defaultHooksText = [string] ($defaultHooksOutput.Output | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($defaultHooksText)) {
    throw 'Unable to locate the repository Git hooks directory.'
}
$hooksPath = Resolve-GitPath -Path $defaultHooksText.Trim()

$localHooksConfig = Invoke-Git -Arguments @(
    'config',
    '--local',
    '--path',
    '--get',
    'core.hooksPath'
) -AllowFailure

if ($localHooksConfig.ExitCode -eq 0) {
    $configuredText = [string] ($localHooksConfig.Output | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($configuredText)) {
        $configuredPath = Resolve-GitPath -Path $configuredText.Trim()

        if (-not $configuredPath.Equals($hooksPath, [StringComparison]::OrdinalIgnoreCase) -and
            -not $Force) {
            throw "Repository already configures a different core.hooksPath: $configuredPath"
        }
    }
}

New-Item -ItemType Directory -Path $hooksPath -Force | Out-Null

$repoForShell = ConvertTo-ShSingleQuotedValue -Value $RepoRoot -Name 'RepositoryPath'
$guardForShell = ConvertTo-ShSingleQuotedValue -Value $guardScript -Name 'GuardScript'

$hooks = [ordered]@{
    'pre-commit' = @"
#!/bin/sh
exec pwsh -NoProfile -File $guardForShell -RepositoryPath $repoForShell -Staged
"@
    'pre-push' = @"
#!/bin/sh
exec pwsh -NoProfile -File $guardForShell -RepositoryPath $repoForShell -PrePush
"@
}

foreach ($entry in $hooks.GetEnumerator()) {
    $path = Join-Path $hooksPath $entry.Key

    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "Git hook '$($entry.Key)' already exists. Re-run with -Force only after reviewing the existing hook."
    }
}

foreach ($entry in $hooks.GetEnumerator()) {
    $path = Join-Path $hooksPath $entry.Key
    [System.IO.File]::WriteAllText(
        $path,
        $entry.Value.Replace([Environment]::NewLine, [string][char]10),
        [System.Text.UTF8Encoding]::new($false)
    )
}

Invoke-Git -Arguments @(
    'config',
    '--local',
    'core.hooksPath',
    $hooksPath.Replace('\', '/')
) | Out-Null

$effectiveHooksConfig = Invoke-Git -Arguments @(
    'config',
    '--path',
    '--get',
    'core.hooksPath'
)
$effectiveHooksText = [string] ($effectiveHooksConfig.Output | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($effectiveHooksText)) {
    throw 'Git did not retain the repository-local core.hooksPath override.'
}

$effectiveHooksPath = Resolve-GitPath -Path $effectiveHooksText.Trim()
if (-not $effectiveHooksPath.Equals($hooksPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Effective core.hooksPath '$effectiveHooksPath' does not match installed guard path '$hooksPath'."
}

[pscustomobject][ordered]@{
    HooksPath = $hooksPath
    EffectiveHooksPath = $effectiveHooksPath
    Installed = @('pre-commit', 'pre-push')
    Valid = $true
}
