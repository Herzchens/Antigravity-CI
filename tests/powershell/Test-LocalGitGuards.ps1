#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$installer = Join-Path $repoRoot 'scripts\Install-LocalGitGuards.ps1'
$guardSource = Join-Path $repoRoot 'scripts\Test-PublishBoundary.ps1'

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string[]] $Arguments,
        [string] $WorkingDirectory
    )

    if ($WorkingDirectory) { Push-Location -LiteralPath $WorkingDirectory }
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "$FilePath failed with exit code $LASTEXITCODE." }
        $output
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock] $Action,[Parameter(Mandatory)][string] $Name)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw "Expected failure: $Name" }
    Write-Host "[PASS] $Name"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-hook-install-' + [Guid]::NewGuid().ToString('N')
)
$repo = Join-Path $tempRoot 'repo $HOME ''quote'''
$fakeGlobal = Join-Path $tempRoot 'global.gitconfig'

New-Item -ItemType Directory -Path $repo -Force | Out-Null
$savedGlobal = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL')

try {
    $env:GIT_CONFIG_GLOBAL = $fakeGlobal

    Invoke-Checked -FilePath git -Arguments @('init', '--quiet') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('config', 'user.name', 'Fixture') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('config', 'user.email', 'fixture@example.invalid') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('config', 'commit.gpgsign', 'false') -WorkingDirectory $repo

    New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $guardSource -Destination (Join-Path $repo 'scripts\Test-PublishBoundary.ps1')

    Invoke-Checked -FilePath git -Arguments @(
        'config', '--global', 'core.hooksPath', (Join-Path $tempRoot 'global-hooks')
    ) -WorkingDirectory $repo

    $installed = & $installer -RepositoryPath $repo
    if (-not $installed.Valid -or
        -not $installed.HooksPath.Equals($installed.EffectiveHooksPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installed hooks path is not the effective Git hooks path.'
    }

    $localHooksPath = (
        Invoke-Checked -FilePath git -Arguments @('config', '--local', '--path', '--get', 'core.hooksPath') -WorkingDirectory $repo |
        Select-Object -First 1
    ).Trim()
    if ([string]::IsNullOrWhiteSpace($localHooksPath)) {
        throw 'Installer did not pin repository-local core.hooksPath.'
    }

    Write-Host '[PASS] repository-local hooks override a conflicting global core.hooksPath'

    Set-Content -LiteralPath (Join-Path $repo 'safe.txt') -Value 'safe' -Encoding utf8NoBOM
    Invoke-Checked -FilePath git -Arguments @('add', 'safe.txt') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'safe') -WorkingDirectory $repo

    Write-Host '[PASS] generated hook safely handles literal $HOME and single quote characters in repository paths'

    Invoke-Checked -FilePath git -Arguments @('config', '--local', 'core.hooksPath', 'custom-hooks') -WorkingDirectory $repo
    Assert-Throws -Name 'existing custom local hooksPath requires explicit Force' -Action {
        & $installer -RepositoryPath $repo
    }

    & $installer -RepositoryPath $repo -Force | Out-Null
    Write-Host '[PASS] Force explicitly replaces a custom local hooksPath with the guarded repository path'
}
finally {
    if ($null -eq $savedGlobal) {
        Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
    }
    else {
        $env:GIT_CONFIG_GLOBAL = $savedGlobal
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
