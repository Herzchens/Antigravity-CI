#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $repoRoot 'scripts\Test-ReviewFilesystemBoundary.ps1'
$text = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8

foreach ($required in @(
    '[System.UnauthorizedAccessException]',
    '[System.Security.SecurityException]',
    'must target a sentinel outside the review account profile',
    'must be operator-managed outside the review account profile',
    'parent directory is writable by the review account',
    'did not prove an ACL denial',
    'is readable by the review account'
)) {
    if (-not $text.Contains($required, [StringComparison]::Ordinal)) {
        throw "Filesystem-boundary contract is missing '$required'."
    }
}

if ($text.Contains('Get-Content -LiteralPath $fullPath', [StringComparison]::Ordinal)) {
    throw 'Filesystem-boundary verifier must not read sentinel contents into PowerShell strings.'
}

Write-Host '[PASS] filesystem boundary requires real ACL denial outside the review profile'
