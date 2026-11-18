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

        $errorScript = Join-Path $tempRoot 'error-agy.ps1'
        $errorCommand = Join-Path $tempRoot 'error-agy.cmd'
        $errorOutput = Join-Path $outside 'error-report.json'

        @'
[ordered]@{
    conversation_id = 'fake-error'
    status = 'ERROR'
    error = 'structured output did not match schema'
    response = ''
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@ | Set-Content -LiteralPath $errorScript -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$errorScript"
"@ | Set-Content -LiteralPath $errorCommand -Encoding ascii

        $errorParameters = $baseParameters.Clone()
        $errorParameters.AgyExecutable = $errorCommand
        $errorParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $errorCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $errorParameters.OutputPath = $errorOutput

        $caughtError = $null
        try {
            & $runner @errorParameters
        }
        catch {
            $caughtError = $_.Exception.Message
        }

        $expectedErrorFragment = "Antigravity CLI returned terminal status 'ERROR': structured output did not match schema"
        if ($null -eq $caughtError -or -not $caughtError.Contains($expectedErrorFragment)) {
            throw "Expected error containing '$expectedErrorFragment', got '$caughtError'."
        }

        if (Test-Path -LiteralPath $errorOutput) {
            throw 'Terminal ERROR AGY run left a publishable final report.'
        }

        Write-Host '[PASS] AGY terminal ERROR surfaces bounded error detail'

        $genericErrorScript = Join-Path $tempRoot 'generic-error-agy.ps1'
        $genericErrorCommand = Join-Path $tempRoot 'generic-error-agy.cmd'
        $genericErrorOutput = Join-Path $outside 'generic-error-report.json'

        @'
[ordered]@{
    conversation_id = 'fake-generic-error'
    status = 'ERROR'
    response = ''
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@ | Set-Content -LiteralPath $genericErrorScript -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$genericErrorScript"
"@ | Set-Content -LiteralPath $genericErrorCommand -Encoding ascii

        $genericErrorParameters = $baseParameters.Clone()
        $genericErrorParameters.AgyExecutable = $genericErrorCommand
        $genericErrorParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $genericErrorCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $genericErrorParameters.OutputPath = $genericErrorOutput

        $caughtGenericError = $null
        try {
            & $runner @genericErrorParameters
        }
        catch {
            $caughtGenericError = $_.Exception.Message
        }

        $expectedGenericFragment = "Antigravity CLI returned terminal status 'ERROR'."
        if ($null -eq $caughtGenericError -or -not $caughtGenericError.Contains($expectedGenericFragment)) {
            throw "Expected error containing '$expectedGenericFragment', got '$caughtGenericError'."
        }

        if (Test-Path -LiteralPath $genericErrorOutput) {
            throw 'Terminal generic ERROR AGY run without error field left a publishable final report.'
        }

        Write-Host '[PASS] AGY terminal ERROR without error detail falls back to generic message'

        $longErrorScript = Join-Path $tempRoot 'long-error-agy.ps1'
        $longErrorCommand = Join-Path $tempRoot 'long-error-agy.cmd'
        $longErrorOutput = Join-Path $outside 'long-error-report.json'

        $longErrorText = ('E' * 1000)
        @"
[ordered]@{
    conversation_id = 'fake-long-error'
    status = 'ERROR'
    error = '$longErrorText'
    response = ''
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
"@ | Set-Content -LiteralPath $longErrorScript -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$longErrorScript"
"@ | Set-Content -LiteralPath $longErrorCommand -Encoding ascii

        $longErrorParameters = $baseParameters.Clone()
        $longErrorParameters.AgyExecutable = $longErrorCommand
        $longErrorParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $longErrorCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $longErrorParameters.OutputPath = $longErrorOutput

        $caughtLongError = $null
        try {
            & $runner @longErrorParameters
        }
        catch {
            $caughtLongError = $_.Exception.Message
        }

        $expectedPrefix = "Antigravity CLI returned terminal status 'ERROR': " + ('E' * 512) + '...'
        if ($null -eq $caughtLongError -or -not $caughtLongError.Contains($expectedPrefix)) {
            throw "Expected truncated error ending in '...', got: $caughtLongError"
        }

        if ($caughtLongError.Contains(('E' * 513))) {
            throw "Surfaced error exceeded 512 character boundary: $caughtLongError"
        }

        if (Test-Path -LiteralPath $longErrorOutput) {
            throw 'Long ERROR AGY run left a publishable final report.'
        }

        Write-Host '[PASS] AGY terminal ERROR bounds long error strings'

        $controlCharScript = Join-Path $tempRoot 'ctrl-char-agy.ps1'
        $controlCharCommand = Join-Path $tempRoot 'ctrl-char-agy.cmd'
        $controlCharOutput = Join-Path $outside 'ctrl-char-report.json'

        @'
[ordered]@{
    conversation_id = 'fake-ctrl-char-error'
    status = 'ERROR'
    error = "line1`r`nline2`tline3"
    response = ''
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@ | Set-Content -LiteralPath $controlCharScript -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$controlCharScript"
"@ | Set-Content -LiteralPath $controlCharCommand -Encoding ascii

        $controlCharParameters = $baseParameters.Clone()
        $controlCharParameters.AgyExecutable = $controlCharCommand
        $controlCharParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $controlCharCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $controlCharParameters.OutputPath = $controlCharOutput

        $caughtCtrlError = $null
        try {
            & $runner @controlCharParameters
        }
        catch {
            $caughtCtrlError = $_.Exception.Message
        }

        $expectedNormalizedFragment = "Antigravity CLI returned terminal status 'ERROR': line1 line2 line3"
        if ($null -eq $caughtCtrlError -or -not $caughtCtrlError.Contains($expectedNormalizedFragment)) {
            throw "Expected normalized single-line error, got: $caughtCtrlError"
        }

        if ($caughtCtrlError -match '[\r\n\t]') {
            throw "Surfaced error contained raw control characters: $caughtCtrlError"
        }

        if (Test-Path -LiteralPath $controlCharOutput) {
            throw 'Control-character ERROR AGY run left a publishable final report.'
        }

        Write-Host '[PASS] AGY terminal ERROR normalizes control characters'

        $responseLeakScript = Join-Path $tempRoot 'response-leak-agy.ps1'
        $responseLeakCommand = Join-Path $tempRoot 'response-leak-agy.cmd'
        $responseLeakOutput = Join-Path $outside 'response-leak-report.json'

        @'
[ordered]@{
    conversation_id = 'fake-response-leak-error'
    status = 'ERROR'
    error = 'safe diagnostic'
    response = 'RESPONSE_SECRET_SENTINEL'
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@ | Set-Content -LiteralPath $responseLeakScript -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$responseLeakScript"
"@ | Set-Content -LiteralPath $responseLeakCommand -Encoding ascii

        $responseLeakParameters = $baseParameters.Clone()
        $responseLeakParameters.AgyExecutable = $responseLeakCommand
        $responseLeakParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $responseLeakCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $responseLeakParameters.OutputPath = $responseLeakOutput

        $caughtResponseLeakError = $null
        try {
            & $runner @responseLeakParameters
        }
        catch {
            $caughtResponseLeakError = $_.Exception.Message
        }

        if ($null -eq $caughtResponseLeakError -or -not $caughtResponseLeakError.Contains("safe diagnostic")) {
            throw "Expected error to contain safe diagnostic, got: $caughtResponseLeakError"
        }

        if ($caughtResponseLeakError.Contains('RESPONSE_SECRET_SENTINEL')) {
            throw "Surfaced error leaked response body: $caughtResponseLeakError"
        }

        if (Test-Path -LiteralPath $responseLeakOutput) {
            throw 'Response-leak ERROR AGY run left a publishable final report.'
        }

        Write-Host '[PASS] AGY terminal ERROR never leaks response body'

        $structuredErrorScript = Join-Path $tempRoot 'structured-error-agy.ps1'
        $structuredErrorCommand = Join-Path $tempRoot 'structured-error-agy.cmd'
        $structuredErrorOutput = Join-Path $outside 'structured-error-report.json'

        @'
[ordered]@{
    conversation_id = 'fake-structured-error'
    status = 'ERROR'
    error = [ordered]@{
        message = 'STRUCTURED_ERROR_SECRET_SENTINEL'
    }
    response = ''
    duration_seconds = 0
    num_turns = 1
    usage = @{}
} | ConvertTo-Json -Depth 32 -Compress
'@ | Set-Content -LiteralPath $structuredErrorScript -Encoding utf8NoBOM

        @"
@echo off
pwsh -NoProfile -File "$structuredErrorScript"
"@ | Set-Content -LiteralPath $structuredErrorCommand -Encoding ascii

        $structuredErrorParameters = $baseParameters.Clone()
        $structuredErrorParameters.AgyExecutable = $structuredErrorCommand
        $structuredErrorParameters.ExpectedAgySha256 = (
            Get-FileHash -LiteralPath $structuredErrorCommand -Algorithm SHA256 -ErrorAction Stop
        ).Hash.ToLowerInvariant()
        $structuredErrorParameters.OutputPath = $structuredErrorOutput

        $caughtStructuredError = $null
        try {
            & $runner @structuredErrorParameters
        }
        catch {
            $caughtStructuredError = $_.Exception.Message
        }

        $expectedGenericFragment = "Antigravity CLI returned terminal status 'ERROR'."
        if ($null -eq $caughtStructuredError -or -not $caughtStructuredError.Contains($expectedGenericFragment)) {
            throw "Expected generic error message for structured error, got: $caughtStructuredError"
        }

        if ($caughtStructuredError.Contains('STRUCTURED_ERROR_SECRET_SENTINEL')) {
            throw "Surfaced error leaked structured error content: $caughtStructuredError"
        }

        if (Test-Path -LiteralPath $structuredErrorOutput) {
            throw 'Structured ERROR AGY run left a publishable final report.'
        }

        Write-Host '[PASS] AGY terminal ERROR with structured error falls back to generic message'
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
