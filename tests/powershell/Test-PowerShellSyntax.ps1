#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scanRoots = @(
    (Join-Path $repoRoot 'scripts'),
    (Join-Path $repoRoot 'tests\powershell')
)

$files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach ($root in $scanRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "PowerShell syntax scan root is missing: $root"
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1' -Recurse -Force)) {
        $files.Add($file)
    }
}

$files.Sort([System.Comparison[System.IO.FileInfo]]{
    param($left, $right)
    [System.StringComparer]::Ordinal.Compare($left.FullName, $right.FullName)
})

if ($files.Count -eq 0) {
    throw 'PowerShell syntax gate found no scripts to parse.'
}

$failures = [System.Collections.Generic.List[string]]::new()

foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null

    [void] [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref] $tokens,
        [ref] $parseErrors
    )

    foreach ($parseError in @($parseErrors)) {
        $relative = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName)
        $line = $parseError.Extent.StartLineNumber
        $column = $parseError.Extent.StartColumnNumber
        $failures.Add(
            $relative + ':' + $line + ':' + $column + ' ' + $parseError.Message
        )
    }
}

if ($failures.Count -gt 0) {
    throw "PowerShell syntax errors detected:$([Environment]::NewLine)$($failures -join [Environment]::NewLine)"
}

Write-Host "[PASS] parsed $($files.Count) PowerShell files without syntax errors"
