#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$guard = Join-Path $repoRoot 'scripts\Test-PublishBoundary.ps1'

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Arguments,
        [string] $WorkingDirectory
    )

    if ($WorkingDirectory) {
        Push-Location -LiteralPath $WorkingDirectory
    }

    try {
        $output = @(& $FilePath @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath failed with exit code $LASTEXITCODE."
        }

        $output
    }
    finally {
        if ($WorkingDirectory) {
            Pop-Location
        }
    }
}

function Invoke-PrePushGuard {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryPath,

        [Parameter(Mandatory)]
        [string] $InputText
    )

    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-File')
    $startInfo.ArgumentList.Add($guard)
    $startInfo.ArgumentList.Add('-RepositoryPath')
    $startInfo.ArgumentList.Add($RepositoryPath)
    $startInfo.ArgumentList.Add('-PrePush')

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw 'Unable to start pre-push guard fixture.'
        }

        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,
        [Parameter(Mandatory)]
        [string] $Name
    )

    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        throw "Expected failure: $Name"
    }

    Write-Host "[PASS] $Name"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-publish-boundary-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Invoke-Checked -FilePath 'git' -Arguments @('init', '--quiet') -WorkingDirectory $tempRoot
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.name', 'Fixture') -WorkingDirectory $tempRoot
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.email', 'fixture@example.invalid') -WorkingDirectory $tempRoot
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'commit.gpgsign', 'false') -WorkingDirectory $tempRoot

    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'src') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot 'src\planner.ts') -Value 'safe' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'src/planner.ts') -WorkingDirectory $tempRoot

    $safe = & $guard -RepositoryPath $tempRoot -Staged
    if (-not $safe.Valid) {
        throw 'Safe staged path was unexpectedly rejected.'
    }

    Write-Host '[PASS] ordinary source names are not blocked'

    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'safe base') -WorkingDirectory $tempRoot
    $remoteBase = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $tempRoot |
        Select-Object -First 1
    ).Trim()

    Set-Content -LiteralPath (Join-Path $tempRoot 'PLAN2.md') -Value 'local only' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', '-f', 'PLAN2.md') -WorkingDirectory $tempRoot

    Assert-Throws -Name 'PLAN artifact is rejected from staged content' -Action {
        & $guard -RepositoryPath $tempRoot -Staged
    }

    Invoke-Checked -FilePath 'git' -Arguments @('reset', '--', 'PLAN2.md') -WorkingDirectory $tempRoot | Out-Null
    Remove-Item -LiteralPath (Join-Path $tempRoot 'PLAN2.md') -Force

    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'docs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tempRoot 'docs\Project-HANDOFF.txt') -Value 'local only' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'src/planner.ts', '-f', 'docs/Project-HANDOFF.txt') -WorkingDirectory $tempRoot
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'fixture') -WorkingDirectory $tempRoot

    Assert-Throws -Name 'HANDOFF artifact is rejected from a committed ref' -Action {
        & $guard -RepositoryPath $tempRoot -Ref HEAD
    }

    Invoke-Checked -FilePath 'git' -Arguments @('rm', '-q', 'docs/Project-HANDOFF.txt') -WorkingDirectory $tempRoot
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'remove local-only artifact') -WorkingDirectory $tempRoot
    $cleanTip = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $tempRoot |
        Select-Object -First 1
    ).Trim()

    $prePushLine = "refs/heads/main $cleanTip refs/heads/main $remoteBase" + [Environment]::NewLine
    $prePushResult = Invoke-PrePushGuard -RepositoryPath $tempRoot -InputText $prePushLine

    if ($prePushResult.ExitCode -eq 0) {
        throw 'Pre-push guard accepted a clean tip whose newly pushed history contains a local-only HANDOFF artifact.'
    }

    Write-Host '[PASS] pre-push rejects local-only artifacts hidden in intermediate commit history'
    Set-Content -LiteralPath (Join-Path $tempRoot 'src\AGENTS.md') -Value 'local governance' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', '-f', 'src/AGENTS.md') -WorkingDirectory $tempRoot

    Assert-Throws -Name 'AGENTS.md is rejected from staged content' -Action {
        & $guard -RepositoryPath $tempRoot -Staged
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
