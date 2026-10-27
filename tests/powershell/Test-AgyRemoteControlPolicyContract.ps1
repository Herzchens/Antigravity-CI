#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$policyPath = Join-Path $repoRoot 'scripts\Assert-AgyRemoteControlPolicy.ps1'
$runnerPath = Join-Path $repoRoot 'scripts\Assert-RunnerSecurity.ps1'
$reviewPath = Join-Path $repoRoot 'scripts\Invoke-AgyReview.ps1'

$policy = Get-Content -LiteralPath $policyPath -Raw -Encoding utf8
$runner = Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
$review = Get-Content -LiteralPath $reviewPath -Raw -Encoding utf8

foreach ($strictRequirement in @(
    'ConvertFrom-StrictHostJson',
    'Assert-NoDuplicateJsonProperties',
    '[System.Text.UTF8Encoding]::new($false, $true)',
    'ConvertFrom-StrictHostJson -Path'
)) {
    if (-not $policy.Contains($strictRequirement, [StringComparison]::Ordinal)) {
        throw "Remote Control policy contract is missing strict JSON guard '$strictRequirement'."
    }
}

foreach ($required in @(
    'Get-ScheduledTask -ErrorAction Stop',
    'Get-CimInstance -ClassName Win32_Process -ErrorAction Stop',
    'cliRemoteControlHostname',
    'remoteControlEnabled',
    'remoteControlHostname',
    'Scheduled Task marker',
    'concurrent Antigravity/Remote Control process marker'
)) {
    if (-not $policy.Contains($required, [StringComparison]::Ordinal)) {
        throw "Remote Control policy contract is missing '$required'."
    }
}

if ($policy.Contains('& $agyPath remote-control', [StringComparison]::OrdinalIgnoreCase) -or
    $policy.Contains('ArgumentList.Add(''remote-control'')', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Remote Control policy must detect local persistence without invoking the network/authenticated remote-control command.'
}

if (-not $runner.Contains("Assert-AgyRemoteControlPolicy.ps1", [StringComparison]::Ordinal) -or
    -not $runner.Contains('RemoteControlPolicyValid', [StringComparison]::Ordinal)) {
    throw 'Review runner preflight must enforce the Remote Control policy.'
}

$reviewCallCount = [regex]::Matches(
    $review,
    '& \$remoteControlPolicy @(?:initial|final)RemoteControlParameters',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
).Count

if ($reviewCallCount -ne 2) {
    throw "AGY review wrapper must check Remote Control before and after execution; found $reviewCallCount checks."
}

$reportWritePosition = $review.IndexOf(
    '[System.IO.File]::WriteAllText(' + [Environment]::NewLine + '        $outputFullPath',
    [StringComparison]::Ordinal
)
$finalRemoteControlPosition = $review.LastIndexOf(
    '& $remoteControlPolicy @finalRemoteControlParameters',
    [StringComparison]::Ordinal
)

if ($finalRemoteControlPosition -lt 0 -or
    $reportWritePosition -lt 0 -or
    $finalRemoteControlPosition -gt $reportWritePosition) {
    throw 'Post-review Remote Control check must happen before final report publication.'
}

Write-Host '[PASS] Remote Control daemon/process/config persistence is denied without invoking remote-control status'
Write-Host '[PASS] Remote Control boundary is checked before and after AGY and before final report output'
