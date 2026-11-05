#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$helper = Join-Path $repoRoot 'scripts\WindowsProcessJob.ps1'
$runner = Join-Path $repoRoot 'scripts\Invoke-AgyReview.ps1'

$runnerText = Get-Content -LiteralPath $runner -Raw -Encoding utf8
foreach ($needle in @(
    'WindowsProcessJob.ps1',
    'New-WindowsKillOnCloseJob',
    'Add-ProcessToWindowsJob',
    'Close-WindowsProcessJob'
)) {
    if (-not $runnerText.Contains($needle, [StringComparison]::Ordinal)) {
        throw "AGY runner containment contract is missing '$needle'."
    }
}

Write-Host '[PASS] AGY runner requires Windows kill-on-close process containment'

if (-not $IsWindows) {
    Write-Host '[SKIP] Windows process-job runtime fixture requires Windows'
    return
}

. $helper

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-process-job-' + [Guid]::NewGuid().ToString('N')
)
$parentScript = Join-Path $tempRoot 'parent.ps1'
$childPidPath = Join-Path $tempRoot 'child.pid'

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$parent = $null
$job = [IntPtr]::Zero
$childPid = $null

try {
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $parentBody = @'
$child = Start-Process -FilePath '__PWSH__' -ArgumentList @(
    '-NoProfile',
    '-Command',
    'Start-Sleep -Seconds 120'
) -PassThru
Set-Content -LiteralPath '__CHILD_PID_PATH__' -Value $child.Id -Encoding ascii
Start-Sleep -Seconds 120
'@

    $parentBody = $parentBody.Replace('__PWSH__', $pwsh.Replace("'", "''"))
    $parentBody = $parentBody.Replace('__CHILD_PID_PATH__', $childPidPath.Replace("'", "''"))
    Set-Content -LiteralPath $parentScript -Value $parentBody -Encoding utf8NoBOM

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-File')
    $startInfo.ArgumentList.Add($parentScript)

    $parent = [System.Diagnostics.Process]::new()
    $parent.StartInfo = $startInfo

    $job = New-WindowsKillOnCloseJob

    if (-not $parent.Start()) {
        throw 'Unable to start process-job fixture parent.'
    }

    try {
        Add-ProcessToWindowsJob -Job $job -Process $parent
    }
    catch {
        try {
            $parent.Kill($true)
        }
        catch {
        }

        throw
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $childPidPath)) {
        if ($parent.HasExited) {
            throw 'Fixture parent exited before creating its child process.'
        }

        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw 'Timed out waiting for the fixture child process.'
        }

        Start-Sleep -Milliseconds 100
    }

    $childPid = [int] (
        Get-Content -LiteralPath $childPidPath -Raw -Encoding ascii
    ).Trim()

    $child = Get-Process -Id $childPid -ErrorAction Stop
    if ($child.HasExited) {
        throw 'Fixture child exited before containment could be verified.'
    }

    Close-WindowsProcessJob -Job $job
    $job = [IntPtr]::Zero

    if (-not $parent.WaitForExit(5000)) {
        throw 'Closing the process job did not terminate the fixture parent.'
    }

    $childGone = $false
    $childDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while ([DateTimeOffset]::UtcNow -lt $childDeadline) {
        if ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) {
            $childGone = $true
            break
        }

        Start-Sleep -Milliseconds 100
    }

    if (-not $childGone) {
        throw 'Closing the process job did not terminate the inherited child process.'
    }

    Write-Host '[PASS] kill-on-close job terminates the attached parent process'
    Write-Host '[PASS] child created after attachment inherits containment and is terminated'
}
finally {
    if ($job -ne [IntPtr]::Zero) {
        try {
            Close-WindowsProcessJob -Job $job
        }
        catch {
        }
    }

    if ($null -ne $parent) {
        if (-not $parent.HasExited) {
            try {
                $parent.Kill($true)
            }
            catch {
            }
        }

        $parent.Dispose()
    }

    if ($null -ne $childPid) {
        $leftover = Get-Process -Id $childPid -ErrorAction SilentlyContinue
        if ($null -ne $leftover) {
            try {
                Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
