#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepositoryPath,

    [Parameter(Mandatory)]
    [string] $PromptPath,

    [Parameter(Mandatory)]
    [string] $ReportSchemaPath,

    [Parameter(Mandatory)]
    [string] $OutputPath,

    [string] $EnvelopePath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $ExpectedRepository,

    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int] $ExpectedPr,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedHeadSha,

    [Parameter(Mandatory)]
    [ValidateLength(1, 128)]
    [string] $ExpectedRunId,

    [string] $AgyExecutable = 'agy',

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedAgySha256,

    [string] $HomeDirectory = $HOME,

    [ValidateRange(30, 3600)]
    [int] $PrintTimeoutSeconds = 1200,

    [ValidateRange(4096, 16777216)]
    [int] $MaxStdoutBytes = 4194304,

    [ValidateRange(4096, 1048576)]
    [int] $MaxStderrBytes = 262144,

    [ValidateRange(1024, 30000)]
    [int] $MaxPromptCharacters = 24000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    $output = @(& git -C $script:RepositoryRoot @Arguments 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git command failed with exit code $exitCode."
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

function Get-FullPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    [System.IO.Path]::GetFullPath($Path)
}

function Assert-OutsideRepository {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $fullPath = Get-FullPath -Path $Path
    $relative = [System.IO.Path]::GetRelativePath($script:RepositoryRoot, $fullPath)

    if ($relative -eq '.' -or
        (-not $relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar)) -and
        -not [System.IO.Path]::IsPathRooted($relative)) {
        throw "$Name must be outside the target repository."
    }

    $fullPath
}

function Assert-NoReparsePointInExistingPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)

    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "$Name does not have a valid path root."
    }

    $current = $root
    $relative = $fullPath.Substring($root.Length)
    $separators = [char[]] @(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    foreach ($component in $relative.Split(
        $separators,
        [System.StringSplitOptions]::RemoveEmptyEntries
    )) {
        $current = Join-Path $current $component

        if (-not (Test-Path -LiteralPath $current)) {
            break
        }

        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name traverses a symbolic link or reparse point."
        }
    }

    $fullPath
}

function Get-FileHashOrMissing {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return '<missing>'
    }

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-RefSnapshot {
    $result = Invoke-Git -Arguments @(
        'for-each-ref',
        '--format=%(refname) %(objectname)',
        'refs/heads',
        'refs/tags',
        'refs/remotes'
    )

    (@($result.Output) -join [string][char]10)
}

function Get-DirectoryDigest {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return '<missing>'
    }

    $entries = [System.Collections.Generic.List[string]]::new()

    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)) {
        $relative = [System.IO.Path]::GetRelativePath($Path, $file.FullName)
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $entries.Add($relative + [char]0 + $hash)
    }

    $entries.Sort([System.StringComparer]::Ordinal)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($entries -join ([string][char]10)))
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    [Convert]::ToHexString($hashBytes).ToLowerInvariant()
}

function Assert-RepositoryIntegrity {
    param(
        [Parameter(Mandatory)]
        [string] $ExpectedRefs,

        [Parameter(Mandatory)]
        [string] $ExpectedConfigHash,

        [Parameter(Mandatory)]
        [string] $ExpectedIndexHash,

        [Parameter(Mandatory)]
        [string] $ExpectedHooksDigest,

        [Parameter(Mandatory)]
        [string] $ExpectedInfoDigest,

        [Parameter(Mandatory)]
        [string] $ExpectedObjectsInfoDigest
    )

    $currentHead = (
        (Invoke-Git -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')).Output |
        Select-Object -First 1
    ).Trim().ToLowerInvariant()

    if ($currentHead -ne $ExpectedHeadSha) {
        throw 'AGY changed HEAD or the checked-out commit.'
    }

    $worktreeDiff = Invoke-Git -Arguments @('diff', '--quiet', '--') -AllowFailure
    if ($worktreeDiff.ExitCode -ne 0) {
        throw 'AGY changed tracked working-tree content.'
    }

    $indexDiff = Invoke-Git -Arguments @('diff', '--cached', '--quiet', '--') -AllowFailure
    if ($indexDiff.ExitCode -ne 0) {
        throw 'AGY changed the Git index.'
    }

    $currentRefs = Get-RefSnapshot
    if ($currentRefs -cne $ExpectedRefs) {
        throw 'AGY changed local Git refs.'
    }

    $currentConfigHash = Get-FileHashOrMissing -Path $script:GitConfigPath
    if ($currentConfigHash -cne $ExpectedConfigHash) {
        throw 'AGY changed repository-local Git configuration.'
    }

    $currentIndexHash = Get-FileHashOrMissing -Path $script:GitIndexPath
    if ($currentIndexHash -cne $ExpectedIndexHash) {
        throw 'AGY changed the Git index file.'
    }

    if ((Get-DirectoryDigest -Path $script:GitHooksPath) -cne $ExpectedHooksDigest) {
        throw 'AGY changed Git hooks.'
    }

    if ((Get-DirectoryDigest -Path $script:GitInfoPath) -cne $ExpectedInfoDigest) {
        throw 'AGY changed Git info control files.'
    }

    if ((Get-DirectoryDigest -Path $script:GitObjectsInfoPath) -cne $ExpectedObjectsInfoDigest) {
        throw 'AGY changed Git object-control files.'
    }
}

$null = Get-Command git -ErrorAction Stop

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
$script:RepositoryRoot = $RepositoryRoot
$null = Assert-NoReparsePointInExistingPath -Path $RepositoryRoot -Name 'RepositoryPath'

$resolvedPromptPath = (Resolve-Path -LiteralPath $PromptPath -ErrorAction Stop).Path
$resolvedSchemaPath = (Resolve-Path -LiteralPath $ReportSchemaPath -ErrorAction Stop).Path

$null = Assert-OutsideRepository -Path $resolvedPromptPath -Name 'PromptPath'
$null = Assert-OutsideRepository -Path $resolvedSchemaPath -Name 'ReportSchemaPath'
$null = Assert-NoReparsePointInExistingPath -Path $resolvedPromptPath -Name 'PromptPath'
$null = Assert-NoReparsePointInExistingPath -Path $resolvedSchemaPath -Name 'ReportSchemaPath'

$outputFullPath = Assert-OutsideRepository -Path (Get-FullPath -Path $OutputPath) -Name 'OutputPath'
$null = Assert-NoReparsePointInExistingPath -Path $outputFullPath -Name 'OutputPath'
$outputDirectory = Split-Path -Parent $outputFullPath
if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
    throw 'OutputPath must have a parent directory.'
}
New-Item -ItemType Directory -Path $outputDirectory -Force -ErrorAction Stop | Out-Null
$null = Assert-NoReparsePointInExistingPath -Path $outputFullPath -Name 'OutputPath'

$envelopeFullPath = $null
if (-not [string]::IsNullOrWhiteSpace($EnvelopePath)) {
    $envelopeFullPath = Assert-OutsideRepository -Path (Get-FullPath -Path $EnvelopePath) -Name 'EnvelopePath'
    $null = Assert-NoReparsePointInExistingPath -Path $envelopeFullPath -Name 'EnvelopePath'
    $envelopeDirectory = Split-Path -Parent $envelopeFullPath
    New-Item -ItemType Directory -Path $envelopeDirectory -Force -ErrorAction Stop | Out-Null
    $null = Assert-NoReparsePointInExistingPath -Path $envelopeFullPath -Name 'EnvelopePath'
}

$prompt = Get-Content -LiteralPath $resolvedPromptPath -Raw -Encoding utf8
if ([string]::IsNullOrWhiteSpace($prompt)) {
    throw 'AGY prompt is empty.'
}

if ($prompt.Length -gt $MaxPromptCharacters) {
    throw "AGY prompt exceeds the maximum of $MaxPromptCharacters characters."
}

$initialStatus = @((Invoke-Git -Arguments @('status', '--porcelain=v1', '--untracked-files=all')).Output)
if ($initialStatus.Count -gt 0) {
    throw 'Target repository must be clean before AGY review.'
}

$initialHead = (
    (Invoke-Git -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')).Output |
    Select-Object -First 1
).Trim().ToLowerInvariant()

if ($initialHead -ne $ExpectedHeadSha) {
    throw "Checked-out HEAD $initialHead does not match expected signed head $ExpectedHeadSha."
}

$gitDirectory = (
    (Invoke-Git -Arguments @('rev-parse', '--absolute-git-dir')).Output |
    Select-Object -First 1
).Trim()
$script:GitConfigPath = Join-Path $gitDirectory 'config'
$script:GitIndexPath = Join-Path $gitDirectory 'index'
$script:GitHooksPath = Join-Path $gitDirectory 'hooks'
$script:GitInfoPath = Join-Path $gitDirectory 'info'
$script:GitObjectsInfoPath = Join-Path (Join-Path $gitDirectory 'objects') 'info'

$initialRefs = Get-RefSnapshot
$initialConfigHash = Get-FileHashOrMissing -Path $script:GitConfigPath
$initialIndexHash = Get-FileHashOrMissing -Path $script:GitIndexPath
$initialHooksDigest = Get-DirectoryDigest -Path $script:GitHooksPath
$initialInfoDigest = Get-DirectoryDigest -Path $script:GitInfoPath
$initialObjectsInfoDigest = Get-DirectoryDigest -Path $script:GitObjectsInfoPath

$agyCommand = Get-Command $AgyExecutable -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
$agyPath = [System.IO.Path]::GetFullPath($agyCommand.Source)
$null = Assert-OutsideRepository -Path $agyPath -Name 'AgyExecutable'
$null = Assert-NoReparsePointInExistingPath -Path $agyPath -Name 'AgyExecutable'

if ([string]::IsNullOrWhiteSpace($ExpectedAgySha256)) {
    throw 'ExpectedAgySha256 is required before Antigravity execution.'
}

$expectedAgyHash = $ExpectedAgySha256.ToLowerInvariant()
$initialAgyHash = (
    Get-FileHash -LiteralPath $agyPath -Algorithm SHA256 -ErrorAction Stop
).Hash.ToLowerInvariant()

if ($initialAgyHash -cne $expectedAgyHash) {
    throw "Antigravity CLI SHA-256 '$initialAgyHash' does not match the expected pinned hash."
}

$reportResolver = Join-Path $PSScriptRoot 'Resolve-AgyReport.ps1'
$processJobHelper = Join-Path $PSScriptRoot 'WindowsProcessJob.ps1'
$hostPolicy = Join-Path $PSScriptRoot 'Assert-AgyHostPolicy.ps1'
$remoteControlPolicy = Join-Path $PSScriptRoot 'Assert-AgyRemoteControlPolicy.ps1'

foreach ($requiredScript in @($reportResolver, $processJobHelper, $hostPolicy, $remoteControlPolicy)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Required AGY review helper is missing: $requiredScript"
    }
}

$initialHostPolicy = & $hostPolicy -HomeDirectory $HomeDirectory

if ($IsWindows) {
    $initialRemoteControlParameters = @{
        AgyExecutable = $agyPath
        HomeDirectory = $HomeDirectory
    }
    $null = & $remoteControlPolicy @initialRemoteControlParameters
}

. $processJobHelper

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-agy-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force -ErrorAction Stop | Out-Null
$emptyGitConfig = Join-Path $tempRoot 'empty-gitconfig'
[System.IO.File]::WriteAllText($emptyGitConfig, '', [System.Text.UTF8Encoding]::new($false))
$safeHooksPath = Join-Path $tempRoot 'empty-hooks'
New-Item -ItemType Directory -Path $safeHooksPath -Force | Out-Null
$stdoutPath = Join-Path $tempRoot 'agy.stdout'
$stderrPath = Join-Path $tempRoot 'agy.stderr'

$process = $null
$processJob = [IntPtr]::Zero
$stdoutStream = $null
$stderrStream = $null
$stdout = ''
$stderr = ''
$exitCode = $null
$runFailure = $null
$envelope = $null
$validatedJson = $null
$safeEnvelopeJson = $null

try {
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $agyPath
        $startInfo.WorkingDirectory = $RepositoryRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        foreach ($argument in @(
            '-p',
            $prompt,
            '--output-format',
            'json',
            '--json-schema',
            $resolvedSchemaPath,
            '--print-timeout',
            "$($PrintTimeoutSeconds)s",
            '--sandbox',
            '--disable-slash-commands'
        )) {
            $startInfo.ArgumentList.Add($argument)
        }

        $explicitSensitiveNames = @(
            'GITHUB_TOKEN',
            'GH_TOKEN',
            'AGY_REPORTER_TOKEN',
            'ACTIONS_RUNTIME_TOKEN',
            'ACTIONS_ID_TOKEN_REQUEST_TOKEN',
            'ACTIONS_ID_TOKEN_REQUEST_URL',
            'SSH_AUTH_SOCK',
            'SSH_AGENT_PID',
            'GIT_ASKPASS',
            'SSH_ASKPASS',
            'GITHUB_ENV',
            'GITHUB_OUTPUT',
            'GITHUB_PATH',
            'GITHUB_STEP_SUMMARY',
            'GITHUB_STATE',
            'GOOGLE_GEMINI_BASE_URL',
            'GEMINI_API_KEY',
            'AGY_ADC_AUTH',
            'GOOGLE_APPLICATION_CREDENTIALS',
            'CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE',
            'HTTP_PROXY',
            'HTTPS_PROXY',
            'ALL_PROXY',
            'NO_PROXY'
        )

        foreach ($name in @($startInfo.Environment.Keys)) {
            if ($explicitSensitiveNames -contains $name -or
                $name -match '(?i)(^|_)(token|secret|password|passwd|credentials?|private_key|api_key|access_key)(_|$)' -or
                $name.StartsWith('GIT_CONFIG_', [StringComparison]::OrdinalIgnoreCase)) {
                [void] $startInfo.Environment.Remove($name)
            }
        }

        $startInfo.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
        $startInfo.Environment['GIT_CONFIG_GLOBAL'] = $emptyGitConfig
        $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
        $startInfo.Environment['GIT_OPTIONAL_LOCKS'] = '0'
        $startInfo.Environment['GCM_INTERACTIVE'] = 'Never'
        $startInfo.Environment['GH_PROMPT_DISABLED'] = '1'
        $startInfo.Environment['AGY_CLI_DISABLE_AUTO_UPDATE'] = 'true'
        $startInfo.Environment['GIT_CONFIG_COUNT'] = '3'
        $startInfo.Environment['GIT_CONFIG_KEY_0'] = 'credential.helper'
        $startInfo.Environment['GIT_CONFIG_VALUE_0'] = ''
        $startInfo.Environment['GIT_CONFIG_KEY_1'] = 'remote.origin.pushurl'
        $startInfo.Environment['GIT_CONFIG_VALUE_1'] = 'https://invalid.invalid/antigravity-ci-push-blocked'
        $startInfo.Environment['GIT_CONFIG_KEY_2'] = 'core.hooksPath'
        $startInfo.Environment['GIT_CONFIG_VALUE_2'] = $safeHooksPath

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $processJob = New-WindowsKillOnCloseJob

        if (-not $process.Start()) {
            throw 'Failed to start Antigravity CLI.'
        }

        try {
            Add-ProcessToWindowsJob -Job $processJob -Process $process
        }
        catch {
            try {
                $process.Kill($true)
            }
            catch {
            }

            throw 'Antigravity CLI could not be attached to the Windows kill-on-close process job.'
        }

        $stdoutStream = [System.IO.File]::Open(
            $stdoutPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
        $stderrStream = [System.IO.File]::Open(
            $stderrPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )

        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)

        $hardTimeoutMilliseconds = [Math]::Min(
            [int]::MaxValue,
            ($PrintTimeoutSeconds + 90) * 1000
        )
        $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($hardTimeoutMilliseconds)
        $limitFailure = $null

        while (-not $process.WaitForExit(500)) {
            if ($stdoutStream.Length -gt $MaxStdoutBytes) {
                $limitFailure = "Antigravity stdout exceeded $MaxStdoutBytes bytes."
                break
            }

            if ($stderrStream.Length -gt $MaxStderrBytes) {
                $limitFailure = "Antigravity stderr exceeded $MaxStderrBytes bytes."
                break
            }

            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                $limitFailure = 'Antigravity CLI exceeded the hard process timeout.'
                break
            }
        }

        if ($null -ne $limitFailure) {
            try {
                $process.Kill($true)
            }
            catch {
            }

            $process.WaitForExit()
        }

        $stdoutTask.GetAwaiter().GetResult()
        $stderrTask.GetAwaiter().GetResult()
        $stdoutStream.Flush()
        $stderrStream.Flush()
        $stdoutLength = $stdoutStream.Length
        $stderrLength = $stderrStream.Length
        $stdoutStream.Dispose()
        $stderrStream.Dispose()
        $stdoutStream = $null
        $stderrStream = $null

        if ($stdoutLength -gt $MaxStdoutBytes) {
            throw "Antigravity stdout exceeded $MaxStdoutBytes bytes."
        }

        if ($stderrLength -gt $MaxStderrBytes) {
            throw "Antigravity stderr exceeded $MaxStderrBytes bytes."
        }

        if ($null -ne $limitFailure) {
            throw $limitFailure
        }

        $stdout = [System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::UTF8)
        $stderr = [System.IO.File]::ReadAllText($stderrPath, [System.Text.Encoding]::UTF8)
        $exitCode = $process.ExitCode

        if ($exitCode -ne 0) {
            throw "Antigravity CLI exited with code $exitCode."
        }

        try {
            $envelope = ConvertFrom-Json -InputObject $stdout -Depth 64 -ErrorAction Stop
        }
        catch {
            throw 'Antigravity CLI stdout was not a valid JSON envelope.'
        }

        if ([string] $envelope.status -cne 'SUCCESS') {
            throw "Antigravity CLI returned terminal status '$($envelope.status)'."
        }

        $structuredProperty = $envelope.PSObject.Properties['structured_output']
        if ($null -eq $structuredProperty -or $null -eq $structuredProperty.Value) {
            throw 'Antigravity CLI did not return structured_output.'
        }

        $reportJson = $structuredProperty.Value | ConvertTo-Json -Depth 64
        $tempReportPath = Join-Path $tempRoot 'report.json'
        [System.IO.File]::WriteAllText(
            $tempReportPath,
            $reportJson,
            [System.Text.UTF8Encoding]::new($false)
        )

        $reportValidationParameters = @{
            ReportPath = $tempReportPath
            ExpectedRepository = $ExpectedRepository
            ExpectedPr = $ExpectedPr
            ExpectedHeadSha = $ExpectedHeadSha
            ExpectedRunId = $ExpectedRunId
            SchemaPath = $resolvedSchemaPath
        }

        $validatedReport = & $reportResolver @reportValidationParameters

        $validatedJson = $validatedReport | ConvertTo-Json -Depth 64

        if ($null -ne $envelopeFullPath) {
            $safeEnvelope = [ordered]@{
                conversation_id = [string] $envelope.conversation_id
                status = [string] $envelope.status
                duration_seconds = $envelope.duration_seconds
                num_turns = $envelope.num_turns
                usage = $envelope.usage
            }

            $safeEnvelopeJson = $safeEnvelope | ConvertTo-Json -Depth 16
        }
    }
    catch {
        $runFailure = $_
    }

    Assert-RepositoryIntegrity `
        -ExpectedRefs $initialRefs `
        -ExpectedConfigHash $initialConfigHash `
        -ExpectedIndexHash $initialIndexHash `
        -ExpectedHooksDigest $initialHooksDigest `
        -ExpectedInfoDigest $initialInfoDigest `
        -ExpectedObjectsInfoDigest $initialObjectsInfoDigest

    $finalHostPolicy = & $hostPolicy -HomeDirectory $HomeDirectory
    if ($finalHostPolicy.SettingsSha256 -cne $initialHostPolicy.SettingsSha256) {
        throw 'Antigravity review-account settings changed during the review run.'
    }

    if ($IsWindows) {
        $finalRemoteControlParameters = @{
            AgyExecutable = $agyPath
            HomeDirectory = $HomeDirectory
        }
        $null = & $remoteControlPolicy @finalRemoteControlParameters
    }

    $finalAgyHash = (
        Get-FileHash -LiteralPath $agyPath -Algorithm SHA256 -ErrorAction Stop
    ).Hash.ToLowerInvariant()

    if ($finalAgyHash -cne $expectedAgyHash) {
        throw 'Antigravity CLI changed during the review run.'
    }

    if ($null -ne $runFailure) {
        throw $runFailure
    }

    if ([string]::IsNullOrWhiteSpace($validatedJson)) {
        throw 'Validated AGY report payload is missing.'
    }

    [System.IO.File]::WriteAllText(
        $outputFullPath,
        $validatedJson,
        [System.Text.UTF8Encoding]::new($false)
    )

    if ($null -ne $envelopeFullPath) {
        if ([string]::IsNullOrWhiteSpace($safeEnvelopeJson)) {
            throw 'Sanitized AGY envelope payload is missing.'
        }

        [System.IO.File]::WriteAllText(
            $envelopeFullPath,
            $safeEnvelopeJson,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    $finalStatus = @((Invoke-Git -Arguments @('status', '--porcelain=v1', '--untracked-files=all')).Output)
    $generatedPaths = @(
        $finalStatus |
        Where-Object { $_ -like '?? *' } |
        ForEach-Object { $_.Substring(3) }
    )

    [pscustomobject][ordered]@{
        HeadSha = $ExpectedHeadSha
        RunId = $ExpectedRunId
        ReportPath = $outputFullPath
        EnvelopePath = $envelopeFullPath
        AgyExitCode = $exitCode
        AgySha256 = $finalAgyHash
        GeneratedPathCount = $generatedPaths.Count
        GeneratedPaths = $generatedPaths
    }
}
finally {
    if ($null -ne $stdoutStream) {
        $stdoutStream.Dispose()
    }

    if ($null -ne $stderrStream) {
        $stderrStream.Dispose()
    }

    $containmentCloseFailure = $null

    if ($processJob -ne [IntPtr]::Zero) {
        try {
            Close-WindowsProcessJob -Job $processJob
        }
        catch {
            $containmentCloseFailure = $_
        }
        finally {
            $processJob = [IntPtr]::Zero
        }
    }

    if ($null -ne $process) {
        $process.Dispose()
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $stdout = $null
    $stderr = $null

    if ($null -ne $containmentCloseFailure) {
        throw $containmentCloseFailure
    }
}
