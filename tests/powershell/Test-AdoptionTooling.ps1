#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$callerGenerator = Join-Path $repoRoot 'scripts\New-AntigravityCaller.ps1'
$configGenerator = Join-Path $repoRoot 'scripts\New-ProjectConfig.ps1'
$configResolver = Join-Path $repoRoot 'scripts\Resolve-ProjectConfig.ps1'

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
    'antigravity-ci-adoption-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $callerPath = Join-Path (Join-Path (Join-Path $tempRoot '.github') 'workflows') 'antigravity-ci.yml'
    $callerParameters = @{
        OutputPath = $callerPath
        InfrastructureRepository = 'Herzchens/Antigravity-CI'
        InfrastructureCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        SigningRunnerLabel = 'agy-signing'
        ReviewRunnerLabel = 'agy-review'
        PublisherRunnerLabel = 'agy-publisher'
        SigningPublicKeyPath = "C:\Users\Owner's Key\signing.pub"
        ReviewPublicKeyPath = 'C:\ProgramData\Antigravity-CI\trusted.pub'
        ExpectedReporterLogin = 'Example-AGY[bot]'
    }

    $caller = & $callerGenerator @callerParameters
    $callerText = Get-Content -LiteralPath $caller.Path -Raw -Encoding utf8

    if ($callerText.Contains('REPLACE_WITH_', [StringComparison]::Ordinal)) {
        throw 'Generated caller workflow contains unresolved template tokens.'
    }

    if ($callerText -notmatch 'Herzchens/Antigravity-CI/.github/workflows/review\.yml@a{40}') {
        throw 'Generated caller workflow is not pinned to the requested infrastructure commit.'
    }

    if (-not $callerText.Contains('  pull_request_target:', [StringComparison]::Ordinal)) {
        throw 'Generated caller workflow must use trusted-base pull_request_target.'
    }

    if ($callerText.Contains(([string][char]10 + '  pull_request:' + [string][char]10), [StringComparison]::Ordinal)) {
        throw 'Generated caller workflow must not execute PR-controlled pull_request workflow code.'
    }

    if (-not $callerText.Contains('github.event.pull_request.base.ref == github.event.repository.default_branch', [StringComparison]::Ordinal) -or
        -not $callerText.Contains('github.event.pull_request.head.repo.id == github.event.pull_request.base.repo.id', [StringComparison]::Ordinal)) {
        throw 'Generated caller workflow is missing pre-allocation trusted PR guards.'
    }

    if ($callerText -notmatch "Owner''s Key") {
        throw 'Single quote in YAML path was not escaped safely.'
    }

    if ($callerText -notmatch 'reporter_app_private_key') {
        throw 'Generated caller workflow does not expose the GitHub App reporter secret mapping.'
    }

    Write-Host '[PASS] caller generator renders an exact-SHA reusable workflow reference'
    Write-Host '[PASS] caller generator uses trusted-base trigger and pre-allocation guards'
    Write-Host '[PASS] caller generator safely quotes Windows key paths'

    Assert-Throws -Name 'caller generator refuses overwrite without Force' -Action {
        & $callerGenerator @callerParameters
    }

    $callerParameters.Force = $true
    & $callerGenerator @callerParameters | Out-Null
    Write-Host '[PASS] caller generator requires explicit Force for overwrite'

    $configPath = Join-Path (Join-Path $tempRoot '.agy') 'project.toml'
    $configParameters = @{
        OutputPath = $configPath
        ProjectName = 'Example "quoted" project'
        ProjectType = 'rust-android'
        Build = @{
            windows = 'cargo build --workspace'
            android = '.\gradlew.bat assembleDebug'
        }
        Test = @{
            windows = 'cargo test --workspace'
        }
        Lint = @{
            windows = 'cargo fmt --check'
        }
        Adb = $true
        Network = $false
        Gui = $false
    }

    $generated = & $configGenerator @configParameters
    $resolved = & $configResolver -ConfigPath $generated.Path

    if ($resolved.project.name -ne 'Example "quoted" project') {
        throw 'Generated TOML did not round-trip the project name.'
    }

    if ($resolved.build.android -ne '.\gradlew.bat assembleDebug') {
        throw 'Generated TOML did not round-trip the Android build command.'
    }

    if (-not $resolved.features.adb -or $resolved.features.network -or $resolved.features.gui) {
        throw 'Generated TOML did not preserve feature flags.'
    }

    Write-Host '[PASS] project config generator round-trips through the strict loader'

    $invalidConfigParameters = $configParameters.Clone()
    $invalidConfigParameters.OutputPath = Join-Path (Join-Path $tempRoot '.agy') 'invalid.toml'
    $invalidConfigParameters.Build = @{
        'Bad Name' = 'echo no'
    }

    Assert-Throws -Name 'project config generator rejects invalid command names' -Action {
        & $configGenerator @invalidConfigParameters
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
