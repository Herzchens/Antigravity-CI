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
        AuthorizedPrLogin = 'Herzchens'
        SigningRunnerLabel = 'agy-signing'
        ReviewRunnerLabel = 'agy-review'
        PublisherRunnerLabel = 'agy-publisher'
        SigningPublicKeyPath = "C:\Users\Owner's Key\signing.pub"
        ReviewPublicKeyPath = 'C:\ProgramData\Antigravity-CI\trusted.pub'
        ExpectedReporterLogin = 'Example-AGY[bot]'
        AgySha256 = ('b' * 64)
    }

    $caller = & $callerGenerator @callerParameters
    $callerText = Get-Content -LiteralPath $caller.Path -Raw -Encoding utf8

    if ($callerText.Contains('REPLACE_WITH_', [StringComparison]::Ordinal)) {
        throw 'Generated caller workflow contains unresolved template tokens.'
    }

    if ($callerText -notmatch 'Herzchens/Antigravity-CI/.github/workflows/review\.yml@a{40}') {
        throw 'Generated caller workflow is not pinned to the requested infrastructure commit.'
    }

    if ($callerText -notmatch "Owner''s Key") {
        throw 'Single quote in YAML path was not escaped safely.'
    }

    if ($callerText -notmatch 'reporter_app_private_key') {
        throw 'Generated caller workflow does not expose the GitHub App reporter secret mapping.'
    }

    if ($callerText -notmatch '(?m)^  pull_request_target:\r?$') {
        throw 'Generated caller workflow does not use the trusted-base pull_request_target entrypoint.'
    }

    if ($callerText -match '(?m)^  pull_request:\r?$') {
        throw 'Generated caller workflow must not use a PR-controlled pull_request entrypoint.'
    }

    if (-not $callerText.Contains('  pull-requests: read', [StringComparison]::Ordinal)) {
        throw 'Generated caller workflow does not grant pull-request read permission required by the reusable workflow.'
    }

    if ($callerText -notmatch "github.event.pull_request.user.login == 'Herzchens'" -or
        $callerText -notmatch "authorized_pr_login: 'Herzchens'") {
        throw 'Generated caller workflow does not bind automatic signing to the authorized PR login.'
    }

    if ($callerText -notmatch "agy_sha256: 'b{64}'") {
        throw 'Generated caller workflow does not pin the expected AGY executable SHA-256.'
    }

    Write-Host '[PASS] caller generator renders an exact-SHA reusable workflow reference'
    Write-Host '[PASS] caller generator safely quotes Windows key paths'
    Write-Host '[PASS] caller generator uses the trusted default-branch PR event'
    Write-Host '[PASS] caller generator pins the AGY executable SHA-256'
    Write-Host '[PASS] caller generator binds automatic signing to one authorized PR login'

    Assert-Throws -Name 'caller generator refuses overwrite without Force' -Action {
        & $callerGenerator @callerParameters
    }

    $callerParameters.Force = $true
    & $callerGenerator @callerParameters | Out-Null
    Write-Host '[PASS] caller generator requires explicit Force for overwrite'

    $duplicateLabelParameters = $callerParameters.Clone()
    $duplicateLabelParameters.ReviewRunnerLabel = 'AGY-SIGNING'
    Assert-Throws -Name 'caller generator rejects duplicate runner trust-domain labels' -Action {
        & $callerGenerator @duplicateLabelParameters
    }

    $badAuthorParameters = $callerParameters.Clone()
    $badAuthorParameters.AuthorizedPrLogin = 'bad author'
    Assert-Throws -Name 'caller generator rejects malformed authorized PR login' -Action {
        & $callerGenerator @badAuthorParameters
    }

    $badReporterParameters = $callerParameters.Clone()
    $badReporterParameters.ExpectedReporterLogin = 'bad reporter'
    Assert-Throws -Name 'caller generator rejects malformed reporter login' -Action {
        & $callerGenerator @badReporterParameters
    }

    $wrongCallerPathParameters = $callerParameters.Clone()
    $wrongCallerPathParameters.OutputPath = Join-Path $tempRoot 'antigravity-ci.yml'
    Assert-Throws -Name 'caller generator rejects output outside .github/workflows' -Action {
        & $callerGenerator @wrongCallerPathParameters
    }

    $nestedWrongCallerPathParameters = $callerParameters.Clone()
    $nestedWrongCallerPathParameters.OutputPath = Join-Path (Join-Path (Join-Path $tempRoot '.github') 'not-workflows') 'antigravity-ci.yml'
    Assert-Throws -Name 'caller generator requires exact .github/workflows parent' -Action {
        & $callerGenerator @nestedWrongCallerPathParameters
    }

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
    $invalidConfigParameters.Force = $true
    $invalidConfigParameters.Build = @{
        'Bad Name' = 'echo no'
    }

    Assert-Throws -Name 'project config generator rejects invalid command names' -Action {
        & $configGenerator @invalidConfigParameters
    }

    $wrongConfigPathParameters = $configParameters.Clone()
    $wrongConfigPathParameters.OutputPath = Join-Path $tempRoot 'project.toml'
    Assert-Throws -Name 'project config generator rejects output outside .agy' -Action {
        & $configGenerator @wrongConfigPathParameters
    }

    $wrongConfigNameParameters = $configParameters.Clone()
    $wrongConfigNameParameters.OutputPath = Join-Path (Join-Path $tempRoot '.agy') 'other.toml'
    Assert-Throws -Name 'project config generator requires exact project.toml filename' -Action {
        & $configGenerator @wrongConfigNameParameters
    }

    Write-Host '[PASS] adoption generators enforce canonical policy-file locations'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
