#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepositoryPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $BaseSha,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $HeadSha,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository,

    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int] $PrNumber,

    [Parameter(Mandatory)]
    [ValidateLength(1, 128)]
    [string] $RunId,

    [Parameter(Mandatory)]
    [string] $TrustedPublicKey,

    [Parameter(Mandatory)]
    [string] $OutputDirectory,

    [ValidatePattern('^[A-Za-z0-9@._+-]+$')]
    [string] $Principal = 'antigravity-ci',

    [ValidateRange(1, 10000)]
    [int] $MaxChangedFiles = 2000,

    [ValidateRange(1024, 1048576)]
    [int] $MaxConfigBytes = 65536,

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

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($script:RepositoryRoot)

    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw 'Unable to start git.'
    }

    $memory = [System.IO.MemoryStream]::new()

    try {
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()
        $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            throw "git command failed with exit code $($process.ExitCode)."
        }

        $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Assert-OutsideRepository {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $relative = [System.IO.Path]::GetRelativePath($script:RepositoryRoot, $fullPath)

    if ($relative -eq '.' -or
        (-not $relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar)) -and
        -not [System.IO.Path]::IsPathRooted($relative)) {
        throw "$Name must be outside the target repository."
    }

    $fullPath
}

function ConvertFrom-NullSeparatedUtf8 {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    $decoder = [System.Text.UTF8Encoding]::new($false, $true)
    $items = [System.Collections.Generic.List[string]]::new()
    $start = 0

    for ($index = 0; $index -le $Bytes.Length; $index++) {
        $isBoundary = $index -eq $Bytes.Length -or $Bytes[$index] -eq 0
        if (-not $isBoundary) {
            continue
        }

        $length = $index - $start
        if ($length -gt 0) {
            try {
                $item = $decoder.GetString($Bytes, $start, $length)
            }
            catch {
                throw 'Git returned a changed path that is not valid UTF-8.'
            }

            $items.Add($item)
        }

        $start = $index + 1
    }

    $items
}

$null = Get-Command git -ErrorAction Stop

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
$script:RepositoryRoot = $RepositoryRoot

$outputRoot = Assert-OutsideRepository -Path $OutputDirectory -Name 'OutputDirectory'
New-Item -ItemType Directory -Path $outputRoot -Force -ErrorAction Stop | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $outputRoot -ErrorAction Stop).Path

$verifyScript = Join-Path $PSScriptRoot 'Test-CommitSignature.ps1'
$configResolver = Join-Path $PSScriptRoot 'Resolve-ProjectConfig.ps1'
$promptGenerator = Join-Path $PSScriptRoot 'New-AgyPrompt.ps1'

foreach ($requiredScript in @($verifyScript, $configResolver, $promptGenerator)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Required review helper is missing: $requiredScript"
    }
}

$checkedOutHead = (
    (Invoke-Git -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')).Output |
    Select-Object -First 1
).Trim().ToLowerInvariant()

if ($checkedOutHead -ne $HeadSha) {
    throw "Checked-out HEAD $checkedOutHead does not match expected head $HeadSha."
}

$baseResolved = (
    (Invoke-Git -Arguments @('rev-parse', '--verify', "$BaseSha^{commit}")).Output |
    Select-Object -First 1
).Trim().ToLowerInvariant()

$headResolved = (
    (Invoke-Git -Arguments @('rev-parse', '--verify', "$HeadSha^{commit}")).Output |
    Select-Object -First 1
).Trim().ToLowerInvariant()

if ($baseResolved -ne $BaseSha -or $headResolved -ne $HeadSha) {
    throw 'Resolved base/head commit does not match the expected SHA.'
}

$mergeBase = (
    (Invoke-Git -Arguments @('merge-base', $baseResolved, $headResolved)).Output |
    Select-Object -First 1
)

if ([string]::IsNullOrWhiteSpace($mergeBase)) {
    throw 'Base and head do not share a merge base.'
}

$historyBase = $mergeBase.Trim().ToLowerInvariant()
if ($historyBase -eq $headResolved) {
    throw 'Pull request head contains no commits beyond the merge base.'
}

$commitLines = (Invoke-Git -Arguments @(
    'rev-list',
    '--reverse',
    "$historyBase..$headResolved"
)).Output

$commits = @(
    $commitLines |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim().ToLowerInvariant() }
)

if ($commits.Count -eq 0) {
    throw 'No review commits were found beyond the merge base.'
}

$expectedParent = $historyBase
foreach ($commit in $commits) {
    $parentsLine = (
        (Invoke-Git -Arguments @('rev-list', '--parents', '-n', '1', $commit)).Output |
        Select-Object -First 1
    )

    $parts = @($parentsLine.Trim() -split '\s+')
    if ($parts.Count -ne 2) {
        throw "Review history must be linear; commit $commit is not a single-parent commit."
    }

    if ($parts[1].ToLowerInvariant() -ne $expectedParent) {
        throw "Review history is not linear at commit $commit."
    }

    $verifyParameters = @{
        RepositoryPath = $RepositoryRoot
        CommitSha = $commit
        SigningKey = $TrustedPublicKey
        Principal = $Principal
    }

    $verification = & $verifyScript @verifyParameters
    if (-not $verification.Valid) {
        throw "Commit $commit did not pass trusted signature verification."
    }

    $expectedParent = $commit
}

$configSpec = $baseResolved + ':.agy/project.toml'
$configBytes = Invoke-GitBytes -Arguments @('cat-file', 'blob', $configSpec)

if ($configBytes.Length -eq 0) {
    throw 'Trusted base .agy/project.toml is empty.'
}

if ($configBytes.Length -gt $MaxConfigBytes) {
    throw "Trusted base .agy/project.toml exceeds $MaxConfigBytes bytes."
}

$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
try {
    $configText = $strictUtf8.GetString($configBytes)
}
catch {
    throw 'Trusted base .agy/project.toml is not valid UTF-8.'
}

$trustedTomlPath = Join-Path $outputRoot 'trusted-project.toml'
[System.IO.File]::WriteAllText(
    $trustedTomlPath,
    $configText,
    [System.Text.UTF8Encoding]::new($false)
)

$projectConfig = & $configResolver -ConfigPath $trustedTomlPath

$configJsonPath = Join-Path $outputRoot 'trusted-project.json'
[System.IO.File]::WriteAllText(
    $configJsonPath,
    ($projectConfig | ConvertTo-Json -Depth 16),
    [System.Text.UTF8Encoding]::new($false)
)

$changedBytes = Invoke-GitBytes -Arguments @(
    'diff',
    '--name-only',
    '-z',
    $historyBase,
    $headResolved,
    '--'
)

$changedFiles = ConvertFrom-NullSeparatedUtf8 -Bytes $changedBytes

if ($changedFiles.Count -gt $MaxChangedFiles) {
    throw "Pull request changes more than $MaxChangedFiles files."
}

foreach ($path in $changedFiles) {
    if ($path.Length -gt 1024) {
        throw 'Changed file path exceeds 1024 characters.'
    }

    if ([System.IO.Path]::IsPathRooted($path) -or
        $path -eq '..' -or
        $path.StartsWith('../', [StringComparison]::Ordinal) -or
        $path.Contains('/../', [StringComparison]::Ordinal)) {
        throw 'Changed file path is not repository-relative.'
    }
}

$promptParameters = @{
    Repository = $Repository
    PrNumber = $PrNumber
    BaseSha = $baseResolved
    HeadSha = $headResolved
    RunId = $RunId
    ChangedFiles = @($changedFiles)
    ProjectConfig = $projectConfig
}

$promptText = & $promptGenerator @promptParameters

if ([string]::IsNullOrWhiteSpace($promptText)) {
    throw 'Generated AGY prompt is empty.'
}

if ($promptText.Length -gt $MaxPromptCharacters) {
    throw "Generated AGY prompt exceeds $MaxPromptCharacters characters."
}

$promptPath = Join-Path $outputRoot 'agy-prompt.txt'
[System.IO.File]::WriteAllText(
    $promptPath,
    [string] $promptText,
    [System.Text.UTF8Encoding]::new($false)
)

[pscustomobject][ordered]@{
    Repository = $Repository
    PrNumber = $PrNumber
    BaseSha = $baseResolved
    HistoryBaseSha = $historyBase
    HeadSha = $headResolved
    RunId = $RunId
    CommitCount = $commits.Count
    ChangedFileCount = $changedFiles.Count
    ChangedFiles = @($changedFiles)
    TrustedConfigTomlPath = $trustedTomlPath
    TrustedConfigJsonPath = $configJsonPath
    PromptPath = $promptPath
}
