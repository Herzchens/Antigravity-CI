#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $OutputPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^@[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)?$')]
    [string] $CodeOwner,

    [string] $CallerWorkflowPath = '.github/workflows/antigravity-review.yml',

    [switch] $Force,

    [ValidateRange(1024, 3000000)]
    [int] $MaxBytes = 2900000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-RepositoryPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Path.IndexOfAny([char[]] @(0, 10, 13)) -ge 0) {
        throw "$Name must not contain NUL or line breaks."
    }

    $normalized = $Path.Replace('\', '/').Trim()

    if ([string]::IsNullOrWhiteSpace($normalized) -or
        $normalized.StartsWith('/', [StringComparison]::Ordinal) -or
        $normalized.Contains('..', [StringComparison]::Ordinal) -or
        $normalized.Contains('//', [StringComparison]::Ordinal)) {
        throw "$Name must be a safe repository-relative path."
    }

    if ($normalized -match '[\s*?\[\]#!]') {
        throw "$Name must be an exact CODEOWNERS-safe path without whitespace or pattern metacharacters."
    }

    $normalized
}

$callerPath = Normalize-RepositoryPath -Path $CallerWorkflowPath -Name 'CallerWorkflowPath'
if (-not $callerPath.StartsWith('.github/workflows/', [StringComparison]::Ordinal) -or
    [System.IO.Path]::GetExtension($callerPath) -notin @('.yml', '.yaml')) {
    throw 'CallerWorkflowPath must reference a YAML workflow under .github/workflows/.'
}

$policyPaths = [ordered]@{
    '/.github/CODEOWNERS' = @('/.github/CODEOWNERS', '.github/CODEOWNERS')
    ('/' + $callerPath) = @(('/' + $callerPath), $callerPath)
    '/.agy/project.toml' = @('/.agy/project.toml', '.agy/project.toml')
}

$fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetFileName($fullOutputPath) -cne 'CODEOWNERS') {
    throw 'OutputPath must end in the exact filename CODEOWNERS.'
}

$parent = Split-Path -Parent $fullOutputPath
if ([string]::IsNullOrWhiteSpace($parent)) {
    throw 'OutputPath must have a parent directory.'
}

if ((Split-Path -Leaf $parent) -cne '.github') {
    throw 'OutputPath must be the repository .github/CODEOWNERS file.'
}

$existingLines = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $fullOutputPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $fullOutputPath -Encoding utf8) {
        $existingLines.Add([string] $line)
    }
}

$preserved = [System.Collections.Generic.List[string]]::new()
foreach ($line in $existingLines) {
    $trimmed = $line.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#', [StringComparison]::Ordinal)) {
        $preserved.Add($line)
        continue
    }

    $parts = @($trimmed -split '\s+')
    $pattern = $parts[0]
    $canonicalPattern = $null

    foreach ($entry in $policyPaths.GetEnumerator()) {
        if (@($entry.Value) -ccontains $pattern) {
            $canonicalPattern = [string] $entry.Key
            break
        }
    }

    if ($null -ne $canonicalPattern) {
        $owners = if ($parts.Count -gt 1) {
            @($parts[1..($parts.Count - 1)] | Where-Object {
                -not $_.StartsWith('#', [StringComparison]::Ordinal)
            })
        }
        else {
            @()
        }

        $sameOwner = $owners.Count -eq 1 -and $owners[0] -ceq $CodeOwner
        if (-not $sameOwner -and -not $Force) {
            throw "CODEOWNERS already defines '$pattern' with a different owner. Use -Force only after reviewing the existing policy."
        }

        continue
    }

    $preserved.Add($line)
}

while ($preserved.Count -gt 0 -and [string]::IsNullOrWhiteSpace($preserved[$preserved.Count - 1])) {
    $preserved.RemoveAt($preserved.Count - 1)
}

if ($preserved.Count -gt 0) {
    $preserved.Add('')
}

$preserved.Add('# Antigravity-CI privileged policy files. Keep these exact entries last so they override broader patterns.')
foreach ($path in $policyPaths.Keys) {
    $preserved.Add("$path $CodeOwner")
}

$content = ($preserved -join [Environment]::NewLine) + [Environment]::NewLine
$bytes = [System.Text.UTF8Encoding]::new($false).GetByteCount($content)

if ($bytes -gt $MaxBytes) {
    throw "Generated CODEOWNERS exceeds the configured maximum of $MaxBytes bytes."
}

New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
[System.IO.File]::WriteAllText(
    $fullOutputPath,
    $content,
    [System.Text.UTF8Encoding]::new($false)
)

[pscustomobject][ordered]@{
    Path = $fullOutputPath
    CodeOwner = $CodeOwner
    CodeOwnersPath = '.github/CODEOWNERS'
    CallerWorkflowPath = $callerPath
    ProjectConfigPath = '.agy/project.toml'
    PolicyEntryCount = 3
}
