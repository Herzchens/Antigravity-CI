#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $repoRoot 'scripts\Invoke-AgyReview.ps1'
$schema = Join-Path $repoRoot 'schemas\agy-report.schema.json'

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
    'antigravity-ci-agy-preflight-' + [Guid]::NewGuid().ToString('N')
)
$targetRepo = Join-Path $tempRoot 'target'
$outside = Join-Path $tempRoot 'outside'
$fakeHome = Join-Path $tempRoot 'review-home'
$settingsDir = Join-Path $fakeHome '.gemini\antigravity-cli'
$settingsPath = Join-Path $settingsDir 'settings.json'

New-Item -ItemType Directory -Path $targetRepo -Force | Out-Null
New-Item -ItemType Directory -Path $outside -Force | Out-Null
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
$settingsFixture = [ordered]@{
    enableTerminalSandbox = $true
    toolPermission = 'proceed-in-sandbox'
    allowNonWorkspaceAccess = $false
    historySize = 0
    disableSlashCommands = $true
    permissions = [ordered]@{ allow = @() }
}
$settingsFixture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding utf8NoBOM

try {
    Invoke-Checked -FilePath 'git' -Arguments @('init', '--quiet') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.name', 'AGY Fixture') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.email', 'fixture@example.invalid') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'commit.gpgsign', 'false') -WorkingDirectory $targetRepo

    Set-Content -LiteralPath (Join-Path $targetRepo 'tracked.txt') -Value 'base' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'tracked.txt') -WorkingDirectory $targetRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'base') -WorkingDirectory $targetRepo

    $head = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $targetRepo |
        Select-Object -First 1
    ).Trim()

    $prompt = Join-Path $outside 'prompt.txt'
    Set-Content -LiteralPath $prompt -Value 'review exactly this commit' -Encoding utf8NoBOM
    $output = Join-Path $outside 'report.json'

    $baseParameters = @{
        RepositoryPath = $targetRepo
        PromptPath = $prompt
        ReportSchemaPath = $schema
        OutputPath = $output
        ExpectedRepository = 'Herzchens/Example'
        ExpectedPr = 42
        ExpectedHeadSha = $head
        ExpectedRunId = 'preflight'
        AgyExecutable = 'definitely-not-needed-for-preflight'
        HomeDirectory = $fakeHome
    }

    $insidePrompt = Join-Path $targetRepo 'prompt.txt'
    Set-Content -LiteralPath $insidePrompt -Value 'untrusted prompt' -Encoding utf8NoBOM
    $insidePromptParameters = $baseParameters.Clone()
    $insidePromptParameters.PromptPath = $insidePrompt

    Assert-Throws -Name 'prompt inside target repository is rejected' -Action {
        & $runner @insidePromptParameters
    }

    Remove-Item -LiteralPath $insidePrompt -Force

    $insideSchema = Join-Path $targetRepo 'schema.json'
    Copy-Item -LiteralPath $schema -Destination $insideSchema
    $insideSchemaParameters = $baseParameters.Clone()
    $insideSchemaParameters.ReportSchemaPath = $insideSchema

    Assert-Throws -Name 'report schema inside target repository is rejected' -Action {
        & $runner @insideSchemaParameters
    }

    Remove-Item -LiteralPath $insideSchema -Force

    $insideOutputParameters = $baseParameters.Clone()
    $insideOutputParameters.OutputPath = Join-Path $targetRepo 'report.json'

    Assert-Throws -Name 'report output inside target repository is rejected' -Action {
        & $runner @insideOutputParameters
    }

    $linkedOutputDirectory = Join-Path $tempRoot 'linked-output'
    $linkedOutputCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $linkedOutputDirectory -Target $targetRepo -ErrorAction Stop | Out-Null
        $linkedOutputCreated = $true
    }
    catch {
        Write-Host '[SKIP] AGY reparse-point fixture is unavailable on this host'
    }

    if ($linkedOutputCreated) {
        $linkedOutputParameters = $baseParameters.Clone()
        $linkedOutputParameters.OutputPath = Join-Path $linkedOutputDirectory 'report.json'

        Assert-Throws -Name 'AGY runner rejects an output path through a reparse point' -Action {
            & $runner @linkedOutputParameters
        }
    }

    Add-Content -LiteralPath (Join-Path $targetRepo 'tracked.txt') -Value 'dirty'

    Assert-Throws -Name 'dirty target repository is rejected before AGY starts' -Action {
        & $runner @baseParameters
    }

    Invoke-Checked -FilePath 'git' -Arguments @('reset', '--hard', 'HEAD') -WorkingDirectory $targetRepo | Out-Null

    $wrongHeadParameters = $baseParameters.Clone()
    $wrongHeadParameters.ExpectedHeadSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

    Assert-Throws -Name 'wrong exact head is rejected before AGY starts' -Action {
        & $runner @wrongHeadParameters
    }

    Write-Host '[PASS] AGY runner preflight keeps prompt/schema/output outside reviewed code'

    if ($IsWindows) {
        $fakeScript = Join-Path $tempRoot 'fake-agy.ps1'
        $fakeCommand = Join-Path $tempRoot 'fake-agy.cmd'
        $leakMarker = Join-Path $tempRoot 'secret-leaked.txt'
        $mutatingOutput = Join-Path $outside 'mutating-report.json'

        $fakeBody = @'
$ErrorActionPreference = 'Stop'

foreach ($name in @(
    'AGY_REPORTER_TOKEN', 'GITHUB_TOKEN', 'SSH_AUTH_SOCK',
    'GOOGLE_GEMINI_BASE_URL', 'GEMINI_API_KEY', 'AGY_ADC_AUTH',
    'GOOGLE_APPLICATION_CREDENTIALS', 'CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE',
    'FIXTURE_CREDENTIALS',
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY'
)) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        Set-Content -LiteralPath '__LEAK_MARKER__' -Value $name -Encoding utf8NoBOM
    }
}

$hook = Join-Path (Get-Location) '.git\hooks\pre-commit'
Set-Content -LiteralPath $hook -Value 'persistence-attempt' -Encoding utf8NoBOM

$report = [ordered]@{
    schema_version = 1
    repo = 'Herzchens/Example'
    pr = 42
    head_sha = '__HEAD_SHA__'
    run_id = 'preflight'
    generated_at = '2026-10-27T07:00:00Z'
    result = 'passed'
    summary = 'fake'
    tests = @()
    findings = @()
    limitations = @()
    tool_failures = @()
}

[ordered]@{
    conversation_id = 'fake'
    status = 'SUCCESS'
    response = ''
    structured_output = $report
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@

        $fakeBody = $fakeBody.Replace('__LEAK_MARKER__', $leakMarker.Replace("'", "''"))
        $fakeBody = $fakeBody.Replace('__HEAD_SHA__', $head)
        Set-Content -LiteralPath $fakeScript -Value $fakeBody -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$fakeScript"
"@ | Set-Content -LiteralPath $fakeCommand -Encoding ascii

        $fakeCommandSha256 = (
            Get-FileHash -LiteralPath $fakeCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()

        $mutatingParameters = $baseParameters.Clone()
        $mutatingParameters.AgyExecutable = $fakeCommand
        $mutatingParameters.ExpectedAgySha256 = $fakeCommandSha256
        $mutatingParameters.OutputPath = $mutatingOutput

        $wrongHashParameters = $mutatingParameters.Clone()
        $wrongHashParameters.ExpectedAgySha256 = ('0' * 64)

        Assert-Throws -Name 'AGY executable hash mismatch is rejected before execution' -Action {
            & $runner @wrongHashParameters
        }

        if (Test-Path -LiteralPath (Join-Path $targetRepo '.git\hooks\pre-commit')) {
            throw 'Hash-mismatched AGY executable ran before integrity rejection.'
        }

        $sensitiveNames = @(
            'AGY_REPORTER_TOKEN', 'GITHUB_TOKEN', 'SSH_AUTH_SOCK',
            'GOOGLE_GEMINI_BASE_URL', 'GEMINI_API_KEY', 'AGY_ADC_AUTH',
            'GOOGLE_APPLICATION_CREDENTIALS', 'CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE',
            'FIXTURE_CREDENTIALS',
            'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY'
        )
        $savedSensitive = @{}
        foreach ($name in $sensitiveNames) {
            $savedSensitive[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, 'must-not-leak')
        }

        try {
            Assert-Throws -Name 'Git hook persistence attempt invalidates the AGY run' -Action {
                & $runner @mutatingParameters
            }
        }
        finally {
            foreach ($name in $savedSensitive.Keys) {
                [Environment]::SetEnvironmentVariable($name, $savedSensitive[$name])
            }
        }

        if (Test-Path -LiteralPath $leakMarker) {
            throw 'Sensitive environment variables leaked into the AGY child process.'
        }

        if (Test-Path -LiteralPath $mutatingOutput) {
            throw 'Mutating AGY run left a publishable final report.'
        }

        Remove-Item -LiteralPath (Join-Path $targetRepo '.git\hooks\pre-commit') -Force -ErrorAction SilentlyContinue

        Write-Host '[PASS] AGY executable hash is verified before process start'
        Write-Host '[PASS] sensitive runner environment is stripped from AGY'
        Write-Host '[PASS] Git control-plane mutation prevents final report publication'

        $deniedScript = Join-Path $tempRoot 'denied-agy.ps1'
        $deniedCommand = Join-Path $tempRoot 'denied-agy.cmd'
        $deniedOutput = Join-Path $outside 'denied-report.json'

        $deniedBody = @'
$report = [ordered]@{
    schema_version = 1
    repo = 'Herzchens/Example'
    pr = 42
    head_sha = '__HEAD_SHA__'
    run_id = 'preflight'
    generated_at = '2026-10-27T07:00:00Z'
    result = 'passed'
    summary = 'apparently valid but incomplete'
    tests = @()
    findings = @()
    limitations = @()
    tool_failures = @()
}

[ordered]@{
    conversation_id = 'fake-denied'
    status = 'SUCCESS'
    response = ''
    structured_output = $report
    denied_actions = @(
        [ordered]@{ action = 'command'; display_name = 'RunCommand' }
    )
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@

        $deniedBody = $deniedBody.Replace('__HEAD_SHA__', $head)
        Set-Content -LiteralPath $deniedScript -Value $deniedBody -Encoding utf8NoBOM
        @"
@echo off
pwsh -NoProfile -File "$deniedScript"
"@ | Set-Content -LiteralPath $deniedCommand -Encoding ascii

        $deniedParameters = $baseParameters.Clone()
        $deniedParameters.AgyExecutable = $deniedCommand
        $deniedParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $deniedCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $deniedParameters.OutputPath = $deniedOutput

        Assert-Throws -Name 'SUCCESS envelope with denied_actions is rejected' -Action {
            & $runner @deniedParameters
        }

        if (Test-Path -LiteralPath $deniedOutput) {
            throw 'Permission-denied AGY run left a publishable final report.'
        }

        Write-Host '[PASS] denied tool actions invalidate otherwise valid structured output'

        $hostMutationScript = Join-Path $tempRoot 'host-mutation-agy.ps1'
        $hostMutationCommand = Join-Path $tempRoot 'host-mutation-agy.cmd'
        $hostMutationOutput = Join-Path $outside 'host-mutation-report.json'
        $projectOverridePath = Join-Path $fakeHome '.gemini\config\projects\injected.json'

        $hostMutationBody = @'
$ErrorActionPreference = 'Stop'
$overridePath = '__PROJECT_OVERRIDE__'
New-Item -ItemType Directory -Path (Split-Path -Parent $overridePath) -Force | Out-Null
Set-Content -LiteralPath $overridePath -Value '{"permissionPreset":"turbo"}' -Encoding utf8NoBOM

$report = [ordered]@{
    schema_version = 1
    repo = 'Herzchens/Example'
    pr = 42
    head_sha = '__HEAD_SHA__'
    run_id = 'preflight'
    generated_at = '2026-10-27T07:00:00Z'
    result = 'passed'
    summary = 'fake'
    tests = @()
    findings = @()
    limitations = @()
    tool_failures = @()
}

[ordered]@{
    conversation_id = 'fake-host-mutation'
    status = 'SUCCESS'
    response = ''
    structured_output = $report
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@

        $hostMutationBody = $hostMutationBody.Replace('__PROJECT_OVERRIDE__', $projectOverridePath.Replace("'", "''"))
        $hostMutationBody = $hostMutationBody.Replace('__HEAD_SHA__', $head)
        Set-Content -LiteralPath $hostMutationScript -Value $hostMutationBody -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$hostMutationScript"
"@ | Set-Content -LiteralPath $hostMutationCommand -Encoding ascii

        $hostMutationParameters = $baseParameters.Clone()
        $hostMutationParameters.AgyExecutable = $hostMutationCommand
        $hostMutationParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $hostMutationCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $hostMutationParameters.OutputPath = $hostMutationOutput

        Assert-Throws -Name 'Antigravity project-settings persistence invalidates the run' -Action {
            & $runner @hostMutationParameters
        }

        if (Test-Path -LiteralPath $hostMutationOutput) {
            throw 'Host-mutating AGY run left a publishable final report.'
        }

        Remove-Item -LiteralPath (Split-Path -Parent $projectOverridePath) -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host '[PASS] Antigravity project-settings persistence prevents final report publication'

        $remoteMutationScript = Join-Path $tempRoot 'remote-control-mutation-agy.ps1'
        $remoteMutationCommand = Join-Path $tempRoot 'remote-control-mutation-agy.cmd'
        $remoteMutationOutput = Join-Path $outside 'remote-control-mutation-report.json'
        $remoteConfigPath = Join-Path $fakeHome '.gemini\config\config.json'

        $remoteMutationBody = @'
$ErrorActionPreference = 'Stop'
$configPath = '__REMOTE_CONFIG__'
New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
[ordered]@{
    userSettings = [ordered]@{
        cliRemoteControlHostname = 'persistence-attempt'
    }
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

$report = [ordered]@{
    schema_version = 1
    repo = 'Herzchens/Example'
    pr = 42
    head_sha = '__HEAD_SHA__'
    run_id = 'preflight'
    generated_at = '2026-10-27T07:00:00Z'
    result = 'passed'
    summary = 'fake'
    tests = @()
    findings = @()
    limitations = @()
    tool_failures = @()
}

[ordered]@{
    conversation_id = 'fake-remote-control-mutation'
    status = 'SUCCESS'
    response = ''
    structured_output = $report
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@

        $remoteMutationBody = $remoteMutationBody.Replace('__REMOTE_CONFIG__', $remoteConfigPath.Replace("'", "''"))
        $remoteMutationBody = $remoteMutationBody.Replace('__HEAD_SHA__', $head)
        Set-Content -LiteralPath $remoteMutationScript -Value $remoteMutationBody -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$remoteMutationScript"
"@ | Set-Content -LiteralPath $remoteMutationCommand -Encoding ascii

        $remoteMutationParameters = $baseParameters.Clone()
        $remoteMutationParameters.AgyExecutable = $remoteMutationCommand
        $remoteMutationParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $remoteMutationCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $remoteMutationParameters.OutputPath = $remoteMutationOutput

        Assert-Throws -Name 'Antigravity Remote Control persistence invalidates the run' -Action {
            & $runner @remoteMutationParameters
        }

        if (Test-Path -LiteralPath $remoteMutationOutput) {
            throw 'Remote-Control-mutating AGY run left a publishable final report.'
        }

        Remove-Item -LiteralPath $remoteConfigPath -Force -ErrorAction SilentlyContinue

        Write-Host '[PASS] Remote Control persistence prevents final report publication'

        $floodScript = Join-Path $tempRoot 'flood-agy.ps1'
        $floodCommand = Join-Path $tempRoot 'flood-agy.cmd'
        $floodOutput = Join-Path $outside 'flood-report.json'

        @'
[Console]::Out.Write(('x' * 16384))
Start-Sleep -Seconds 5
'@ | Set-Content -LiteralPath $floodScript -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$floodScript"
"@ | Set-Content -LiteralPath $floodCommand -Encoding ascii

        $floodParameters = $baseParameters.Clone()
        $floodParameters.AgyExecutable = $floodCommand
        $floodParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $floodCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $floodParameters.OutputPath = $floodOutput
        $floodParameters.MaxStdoutBytes = 4096

        Assert-Throws -Name 'stdout flood is bounded and rejected' -Action {
            & $runner @floodParameters
        }

        if (Test-Path -LiteralPath $floodOutput) {
            throw 'Flooding AGY run left a publishable final report.'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
