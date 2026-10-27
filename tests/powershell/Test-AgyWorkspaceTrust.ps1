#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$policy = Join-Path $repoRoot 'scripts\Assert-AgyWorkspaceTrust.ps1'

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
    'antigravity-ci-workspace-trust-' + [Guid]::NewGuid().ToString('N')
)
$repo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $repo -Force | Out-Null

try {
    Invoke-Checked -FilePath git -Arguments @('init', '--quiet') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('config', 'user.name', 'Workspace Trust Fixture') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('config', 'user.email', 'fixture@example.invalid') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('config', 'commit.gpgsign', 'false') -WorkingDirectory $repo

    Set-Content -LiteralPath (Join-Path $repo 'AGENTS.md') -Value 'trusted policy' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $repo 'app.txt') -Value 'base' -Encoding utf8NoBOM
    Invoke-Checked -FilePath git -Arguments @('add', '.') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'base') -WorkingDirectory $repo

    $base = (Invoke-Checked -FilePath git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo | Select-Object -First 1).Trim()

    Add-Content -LiteralPath (Join-Path $repo 'app.txt') -Value 'feature'
    Invoke-Checked -FilePath git -Arguments @('add', 'app.txt') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'feature') -WorkingDirectory $repo

    $safeHead = (Invoke-Checked -FilePath git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo | Select-Object -First 1).Trim()

    $safe = & $policy -RepositoryPath $repo -BaseSha $base -HeadSha $safeHead
    if (-not $safe.Valid) {
        throw 'Safe feature did not pass workspace trust policy.'
    }

    Write-Host '[PASS] normal code changes with unchanged trusted AGENTS.md are accepted'

    Set-Content -LiteralPath (Join-Path $repo 'AGENTS.md') -Value 'untrusted replacement' -Encoding utf8NoBOM
    Invoke-Checked -FilePath git -Arguments @('add', 'AGENTS.md') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'change agent policy') -WorkingDirectory $repo
    $changedPolicyHead = (Invoke-Checked -FilePath git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo | Select-Object -First 1).Trim()

    Assert-Throws -Name 'PR changes to AGENTS.md are rejected' -Action {
        & $policy -RepositoryPath $repo -BaseSha $base -HeadSha $changedPolicyHead
    }

    Invoke-Checked -FilePath git -Arguments @('reset', '--hard', $safeHead) -WorkingDirectory $repo | Out-Null

    $hookPath = Join-Path $repo '.agents\hooks.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $hookPath) -Force | Out-Null
    Set-Content -LiteralPath $hookPath -Value '{"hooks":[]}' -Encoding utf8NoBOM
    Invoke-Checked -FilePath git -Arguments @('add', '.agents/hooks.json') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'add workspace hook') -WorkingDirectory $repo
    $hookHead = (Invoke-Checked -FilePath git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo | Select-Object -First 1).Trim()

    Assert-Throws -Name 'workspace .agents content is rejected' -Action {
        & $policy -RepositoryPath $repo -BaseSha $base -HeadSha $hookHead
    }

    Invoke-Checked -FilePath git -Arguments @('reset', '--hard', $safeHead) -WorkingDirectory $repo | Out-Null
    Remove-Item -LiteralPath (Join-Path $repo '.agents') -Recurse -Force -ErrorAction SilentlyContinue

    $legacyPath = Join-Path $repo '.gemini\settings.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyPath) -Force | Out-Null
    Set-Content -LiteralPath $legacyPath -Value '{}' -Encoding utf8NoBOM
    Invoke-Checked -FilePath git -Arguments @('add', '.gemini/settings.json') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'add legacy customization') -WorkingDirectory $repo
    $legacyHead = (Invoke-Checked -FilePath git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo | Select-Object -First 1).Trim()

    Assert-Throws -Name 'workspace .gemini content is rejected' -Action {
        & $policy -RepositoryPath $repo -BaseSha $base -HeadSha $legacyHead
    }

    Invoke-Checked -FilePath git -Arguments @('reset', '--hard', $safeHead) -WorkingDirectory $repo | Out-Null
    Remove-Item -LiteralPath (Join-Path $repo '.gemini') -Recurse -Force -ErrorAction SilentlyContinue

    $legacyRulePath = Join-Path $repo '.agent\rules\legacy.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyRulePath) -Force | Out-Null
    Set-Content -LiteralPath $legacyRulePath -Value 'legacy injected rule' -Encoding utf8NoBOM
    Invoke-Checked -FilePath git -Arguments @('add', '.agent/rules/legacy.md') -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'add legacy rule') -WorkingDirectory $repo
    $legacyRuleHead = (Invoke-Checked -FilePath git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo | Select-Object -First 1).Trim()

    Assert-Throws -Name 'legacy workspace .agent rules are rejected' -Action {
        & $policy -RepositoryPath $repo -BaseSha $base -HeadSha $legacyRuleHead
    }

    Invoke-Checked -FilePath git -Arguments @('reset', '--hard', $safeHead) -WorkingDirectory $repo | Out-Null
    Remove-Item -LiteralPath (Join-Path $repo '.agent') -Recurse -Force -ErrorAction SilentlyContinue

    $symlinkTargetPath = Join-Path $repo 'symlink-target.txt'
    [System.IO.File]::WriteAllText(
        $symlinkTargetPath,
        '..\outside-secret.txt',
        [System.Text.UTF8Encoding]::new($false)
    )
    $symlinkBlob = (
        Invoke-Checked -FilePath git -Arguments @('hash-object', '-w', 'symlink-target.txt') -WorkingDirectory $repo |
        Select-Object -First 1
    ).Trim()
    Remove-Item -LiteralPath $symlinkTargetPath -Force
    Invoke-Checked -FilePath git -Arguments @(
        'update-index',
        '--add',
        '--cacheinfo',
        "120000,$symlinkBlob,escape-link"
    ) -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'add symlink entry') -WorkingDirectory $repo
    $symlinkHead = (
        Invoke-Checked -FilePath git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo |
        Select-Object -First 1
    ).Trim()

    Assert-Throws -Name 'Git symlink tree entry is rejected before AGY review' -Action {
        & $policy -RepositoryPath $repo -BaseSha $base -HeadSha $symlinkHead
    }

    Invoke-Checked -FilePath git -Arguments @('reset', '--hard', $safeHead) -WorkingDirectory $repo | Out-Null

    Invoke-Checked -FilePath git -Arguments @(
        'update-index',
        '--add',
        '--cacheinfo',
        "160000,$base,embedded-repository"
    ) -WorkingDirectory $repo
    Invoke-Checked -FilePath git -Arguments @('commit', '--quiet', '-m', 'add gitlink entry') -WorkingDirectory $repo
    $gitlinkHead = (
        Invoke-Checked -FilePath git -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo |
        Select-Object -First 1
    ).Trim()

    Assert-Throws -Name 'Git gitlink/submodule tree entry is rejected before AGY review' -Action {
        & $policy -RepositoryPath $repo -BaseSha $base -HeadSha $gitlinkHead
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
