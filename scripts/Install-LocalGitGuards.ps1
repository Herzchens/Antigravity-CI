#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $RepositoryPath = '.',

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
$guardScript = Join-Path $repoRoot 'scripts\Test-PublishBoundary.ps1'

if (-not (Test-Path -LiteralPath $guardScript -PathType Leaf)) {
    throw 'scripts/Test-PublishBoundary.ps1 is required.'
}

$hooksPath = (& git -C $repoRoot rev-parse --git-path hooks 2>&1 | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hooksPath)) {
    throw 'Unable to locate the Git hooks directory.'
}

if (-not [System.IO.Path]::IsPathRooted($hooksPath)) {
    $hooksPath = Join-Path $repoRoot $hooksPath
}

New-Item -ItemType Directory -Path $hooksPath -Force | Out-Null

$repoForShell = $repoRoot.Replace('\', '/').Replace('"', '\"')
$guardForShell = $guardScript.Replace('\', '/').Replace('"', '\"')

$hooks = [ordered]@{
    'pre-commit' = @"
#!/bin/sh
exec pwsh -NoProfile -File "$guardForShell" -RepositoryPath "$repoForShell" -Staged
"@
    'pre-push' = @"
#!/bin/sh
exec pwsh -NoProfile -File "$guardForShell" -RepositoryPath "$repoForShell" -PrePush
"@
}

foreach ($entry in $hooks.GetEnumerator()) {
    $path = Join-Path $hooksPath $entry.Key

    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "Git hook '$($entry.Key)' already exists. Re-run with -Force only after reviewing the existing hook."
    }

    [System.IO.File]::WriteAllText(
        $path,
        $entry.Value.Replace([Environment]::NewLine, [string][char]10),
        [System.Text.UTF8Encoding]::new($false)
    )
}

[pscustomobject][ordered]@{
    HooksPath = [System.IO.Path]::GetFullPath($hooksPath)
    Installed = @('pre-commit', 'pre-push')
}
