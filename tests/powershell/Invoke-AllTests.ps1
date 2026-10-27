#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$testsRoot = $PSScriptRoot

$tests = @(
    'Test-PowerShellSyntax.ps1',
    'Test-Contracts.ps1',
    'Test-ProjectConfig.ps1',
    'Test-SignatureVerification.ps1',
    'Test-SigningGate.ps1',
    'Test-SigningRepositoryContract.ps1',
    'Test-AgyPrompt.ps1',
    'Test-AgyReport.ps1',
    'Test-PullRequestContext.ps1',
    'Test-AgyReportComment.ps1',
    'Test-AgyReviewPreflight.ps1',
    'Test-PrepareAgyReview.ps1',
    'Test-ProjectCapabilities.ps1',
    'Test-WorkflowContract.ps1',
    'Test-PublisherSecurityContract.ps1',
    'Test-LivePrStateTransport.ps1',
    'Test-AgyRemoteControlPolicyContract.ps1',
    'Test-RunnerSecurity.ps1',
    'Test-AgySettingsPolicy.ps1',
    'Test-AgyHostPolicy.ps1',
    'Test-AgyWorkspaceTrust.ps1',
    'Test-ReviewFilesystemBoundary.ps1',
    'Test-ReviewFilesystemBoundaryContract.ps1',
    'Test-SandboxSmokeContract.ps1',
    'Test-WindowsProcessJob.ps1',
    'Test-AdoptionTooling.ps1',
    'Test-PolicyCodeOwners.ps1',
    'Test-RepositoryPolicy.ps1',
    'Test-PublishBoundary.ps1',
    'Test-LocalGitGuards.ps1',
    'Test-LocalCiAccountInitializationContract.ps1'
)

$failed = [System.Collections.Generic.List[string]]::new()

foreach ($name in $tests) {
    $path = Join-Path $testsRoot $name

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failed.Add("$name (missing)")
        Write-Host "[FAIL] $name (missing)" -ForegroundColor Red
        continue
    }

    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan

    & $pwsh -NoProfile -File $path
    if ($LASTEXITCODE -ne 0) {
        $failed.Add($name)
        Write-Host "[FAIL] $name" -ForegroundColor Red
    }
    else {
        Write-Host "[PASS] $name" -ForegroundColor Green
    }
}

if ($failed.Count -gt 0) {
    throw "PowerShell test suite failed: $($failed -join ', ')"
}

Write-Host ""
Write-Host "[PASS] all $($tests.Count) PowerShell test files passed" -ForegroundColor Green
