#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Get-TrackedPaths {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('ls-files')
    $startInfo.ArgumentList.Add('-z')

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $memory = [System.IO.MemoryStream]::new()

    try {
        if (-not $process.Start()) {
            throw 'Unable to start git ls-files.'
        }

        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()
        $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            throw "git ls-files failed: $stderr"
        }

        $bytes = $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }

    $decoder = [System.Text.UTF8Encoding]::new($false, $true)
    $paths = [System.Collections.Generic.List[string]]::new()
    $start = 0

    for ($index = 0; $index -le $bytes.Length; $index++) {
        $boundary = $index -eq $bytes.Length -or $bytes[$index] -eq 0
        if (-not $boundary) {
            continue
        }

        $length = $index - $start
        if ($length -gt 0) {
            try {
                $paths.Add($decoder.GetString($bytes, $start, $length))
            }
            catch {
                throw 'Tracked path list contains invalid UTF-8.'
            }
        }

        $start = $index + 1
    }

    $paths
}

$tracked = @(Get-TrackedPaths)

$localOnlyPattern = '(?i)(^|/)(?:PLAN[^/]*\.md|HANDOFF[^/]*\.md|[^/]*HANDOFF[^/]*\.md|AGENTS\.md)$'
$localOnly = @($tracked | Where-Object { $_ -match $localOnlyPattern })

if ($localOnly.Count -gt 0) {
    throw "Local-only governance artifacts are tracked: $($localOnly -join ', ')"
}

Write-Host '[PASS] no local-only planning, handoff, or AGENTS artifacts are tracked'

$workflowPaths = @(
    $tracked |
    Where-Object {
        $_ -match '^\.github/workflows/.+\.ya?ml$'
    }
)

foreach ($workflowPath in $workflowPaths) {
    $fullPath = Join-Path $repoRoot ($workflowPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $text = Get-Content -LiteralPath $fullPath -Raw -Encoding utf8

    foreach ($forbidden in @(
        'pull_request_target',
        'secrets: inherit',
        'persist-credentials: true',
        'write-all',
        '--dangerously-skip-permissions'
    )) {
        if ($text.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Workflow '$workflowPath' contains forbidden text '$forbidden'."
        }
    }

    $matches = [regex]::Matches(
        $text,
        '(?m)^\s*uses:\s*(?<target>[^\s#]+)\s*$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )

    foreach ($match in $matches) {
        $target = $match.Groups['target'].Value

        if ($target.StartsWith('./', [StringComparison]::Ordinal)) {
            continue
        }

        if ($target -notmatch '@[0-9a-f]{40}$') {
            throw "Workflow '$workflowPath' uses an action or reusable workflow without an immutable 40-character SHA: $target"
        }
    }
}

Write-Host '[PASS] tracked workflows avoid forbidden triggers/secret shortcuts and pin external uses by SHA'

$scriptPaths = @(
    $tracked |
    Where-Object { $_ -match '^scripts/.+\.ps1$' }
)

foreach ($scriptPath in $scriptPaths) {
    $fullPath = Join-Path $repoRoot ($scriptPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $text = Get-Content -LiteralPath $fullPath -Raw -Encoding utf8

    $forbiddenPatterns = [ordered]@{
        'Invoke-Expression' = '(?i)\bInvoke-Expression\b|\biex\b'
        'encoded PowerShell command' = '(?i)-EncodedCommand\b'
        'cmd /c dynamic shell' = '(?i)\bcmd(?:\.exe)?\s+/c\b'
    }

    foreach ($entry in $forbiddenPatterns.GetEnumerator()) {
        if ($text -match $entry.Value) {
            throw "Production script '$scriptPath' contains forbidden construct '$($entry.Key)'."
        }
    }
}

Write-Host '[PASS] production PowerShell scripts avoid dynamic-shell execution primitives'
