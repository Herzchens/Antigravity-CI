#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$prepare = Join-Path $repoRoot 'scripts\Prepare-AgyReview.ps1'

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

foreach ($command in @('git', 'ssh-keygen')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required."
    }
}

$sshKeygenProgram = (Get-Command ssh-keygen -ErrorAction Stop | Select-Object -First 1).Source

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-review-preparation-' + [Guid]::NewGuid().ToString('N')
)
$targetRepo = Join-Path $tempRoot 'target'
$outputRoot = Join-Path $tempRoot 'output'
$signingKey = Join-Path $tempRoot 'signing-key'
$wrongKey = Join-Path $tempRoot 'wrong-key'

New-Item -ItemType Directory -Path $targetRepo -Force | Out-Null
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

try {
    Invoke-Checked -FilePath 'ssh-keygen' -Arguments @('-q', '-t', 'ed25519', '-N', '', '-f', $signingKey)
    Invoke-Checked -FilePath 'ssh-keygen' -Arguments @('-q', '-t', 'ed25519', '-N', '', '-f', $wrongKey)

    Invoke-Checked -FilePath 'git' -Arguments @('init', '--quiet', '-b', 'main') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.name', 'AGY Fixture') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.email', 'fixture@example.invalid') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'gpg.format', 'ssh') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'gpg.ssh.program', $sshKeygenProgram) -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.signingkey', $signingKey) -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'commit.gpgsign', 'false') -WorkingDirectory $targetRepo

    New-Item -ItemType Directory -Path (Join-Path $targetRepo '.agy') -Force | Out-Null
    @"
schema_version = 1

[project]
name = "Fixture"
type = "powershell"

[build]
windows = "Write-Host trusted-build"

[features]
adb = false
network = false
gui = false
"@ | Set-Content -LiteralPath (Join-Path $targetRepo '.agy\project.toml') -Encoding utf8NoBOM

    Set-Content -LiteralPath (Join-Path $targetRepo 'source.txt') -Value 'base' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', '.agy/project.toml', 'source.txt') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'base') -WorkingDirectory $targetRepo

    $commonBase = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $targetRepo |
        Select-Object -First 1
    ).Trim()

    Invoke-Checked -FilePath 'git' -Arguments @('checkout', '-q', '-b', 'feature') -WorkingDirectory $targetRepo

    @"
schema_version = 1

[project]
name = "Fixture"
type = "powershell"

[build]
windows = "Set-Content should-never-run.txt pwned"

[features]
adb = false
network = true
gui = true
"@ | Set-Content -LiteralPath (Join-Path $targetRepo '.agy\project.toml') -Encoding utf8NoBOM

    Add-Content -LiteralPath (Join-Path $targetRepo 'source.txt') -Value 'feature'
    Invoke-Checked -FilePath 'git' -Arguments @('add', '.agy/project.toml', 'source.txt') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('-c', 'commit.gpgsign=true', 'commit', '--quiet', '-m', 'signed feature') -WorkingDirectory $targetRepo

    $featureHead = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $targetRepo |
        Select-Object -First 1
    ).Trim()

    Invoke-Checked -FilePath 'git' -Arguments @('checkout', '-q', 'main') -WorkingDirectory $targetRepo

    @"
schema_version = 1

[project]
name = "Fixture"
type = "powershell"

[build]
windows = "Write-Host trusted-current-base"

[features]
adb = false
network = false
gui = false
"@ | Set-Content -LiteralPath (Join-Path $targetRepo '.agy\project.toml') -Encoding utf8NoBOM

    Set-Content -LiteralPath (Join-Path $targetRepo 'base-only.txt') -Value 'base advanced' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', '.agy/project.toml', 'base-only.txt') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'advance base policy') -WorkingDirectory $targetRepo

    $currentBase = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $targetRepo |
        Select-Object -First 1
    ).Trim()

    Invoke-Checked -FilePath 'git' -Arguments @('checkout', '-q', 'feature') -WorkingDirectory $targetRepo

    $parameters = @{
        RepositoryPath = $targetRepo
        BaseSha = $currentBase
        HeadSha = $featureHead
        Repository = 'Herzchens/Example'
        PrNumber = 42
        RunId = 'prepare-test'
        TrustedPublicKey = "$signingKey.pub"
        OutputDirectory = $outputRoot
    }

    $result = & $prepare @parameters

    if ($result.BaseSha -ne $currentBase) {
        throw 'Preparation did not retain the current trusted base SHA.'
    }

    if ($result.HistoryBaseSha -ne $commonBase) {
        throw 'Preparation did not use the merge base for feature history.'
    }

    if ($result.HeadSha -ne $featureHead -or $result.CommitCount -ne 1) {
        throw 'Preparation did not bind the exact signed feature head and commit range.'
    }

    $trustedConfig = Get-Content -LiteralPath $result.TrustedConfigJsonPath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 16

    if ($trustedConfig.features.network -or $trustedConfig.features.gui) {
        throw 'PR-head capability escalation leaked into trusted project configuration.'
    }

    if ($trustedConfig.build.windows -ne 'Write-Host trusted-current-base') {
        throw 'Trusted project configuration did not come from the current base SHA.'
    }

    if (@($result.ChangedFiles) -notcontains '.agy/project.toml' -or
        @($result.ChangedFiles) -notcontains 'source.txt') {
        throw 'Changed-file set did not include the feature changes from merge base to head.'
    }

    if (@($result.ChangedFiles) -contains 'base-only.txt') {
        throw 'Changed-file set incorrectly included base-only changes.'
    }

    $prompt = Get-Content -LiteralPath $result.PromptPath -Raw -Encoding utf8

    if ($prompt -match 'Set-Content should-never-run' -or
        $prompt -match '"network": true' -or
        $prompt -match '"gui": true') {
        throw 'Prompt included policy or commands from the untrusted PR-head config.'
    }

    if ($prompt -notmatch 'trusted-current-base') {
        throw 'Prompt does not include the trusted current-base command declaration.'
    }

    Write-Host '[PASS] current base config stays trusted while merge-base defines signed review history'
    Write-Host '[PASS] PR-head config capability escalation is excluded from the AGY prompt'
    Write-Host '[PASS] changed-file range excludes base-only changes'

    $linkedOutput = Join-Path $tempRoot 'linked-output'
    $linkedOutputCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $linkedOutput -Target $targetRepo -ErrorAction Stop | Out-Null
        $linkedOutputCreated = $true
    }
    catch {
        Write-Host '[SKIP] preparation reparse-point fixture is unavailable on this host'
    }

    if ($linkedOutputCreated) {
        $linkedOutputParameters = $parameters.Clone()
        $linkedOutputParameters.OutputDirectory = $linkedOutput

        Assert-Throws -Name 'review preparation rejects a reparse-point output directory' -Action {
            & $prepare @linkedOutputParameters
        }
    }

    $wrongKeyParameters = $parameters.Clone()
    $wrongKeyParameters.TrustedPublicKey = "$wrongKey.pub"
    $wrongKeyParameters.OutputDirectory = Join-Path $tempRoot 'wrong-key-output'

    Assert-Throws -Name 'feature commit signed by an untrusted key is rejected' -Action {
        & $prepare @wrongKeyParameters
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
