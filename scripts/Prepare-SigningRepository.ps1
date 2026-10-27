#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepositoryPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository,

    [Parameter(Mandatory)]
    [string] $BaseRef,

    [Parameter(Mandatory)]
    [string] $HeadRef,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedBaseSha,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedHeadSha,

    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
    [string] $TokenEnvironmentVariable = 'GITHUB_TOKEN'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-BranchRef {
    param([string] $Ref, [string] $Name)
    $null = & git check-ref-format --branch $Ref 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$Name is not a valid Git branch ref." }
    $Ref
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [hashtable] $Environment = @{}
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -eq $entry.Value) { [void] $startInfo.Environment.Remove($entry.Key) }
        else { $startInfo.Environment[$entry.Key] = [string] $entry.Value }
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start git.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git command failed with exit code $($process.ExitCode)."
        }
        $stdout
    }
    finally { $process.Dispose() }
}

$null = Get-Command git -ErrorAction Stop
$BaseRef = Assert-BranchRef -Ref $BaseRef -Name 'BaseRef'
$HeadRef = Assert-BranchRef -Ref $HeadRef -Name 'HeadRef'
if ($BaseRef -ceq $HeadRef) { throw 'BaseRef and HeadRef must differ.' }

$tokenItem = Get-Item -LiteralPath "Env:$TokenEnvironmentVariable" -ErrorAction SilentlyContinue
if ($null -eq $tokenItem -or [string]::IsNullOrWhiteSpace([string] $tokenItem.Value)) {
    throw "Read token environment variable '$TokenEnvironmentVariable' is not set."
}

$token = [string] $tokenItem.Value
$repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryPath)
$expectedRemoteUrl = 'https://github.com/' + $Repository + '.git'

if (Test-Path -LiteralPath $repositoryRoot) {
    $existing = @(Get-ChildItem -LiteralPath $repositoryRoot -Force -ErrorAction Stop)
    if ($existing.Count -gt 0) { throw 'Signing repository path must not contain existing files.' }
}
else {
    New-Item -ItemType Directory -Path $repositoryRoot -Force -ErrorAction Stop | Out-Null
}

$encodedCredential = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes('x-access-token:' + $token)
)
$gitEnvironment = @{
    GIT_CONFIG_COUNT = '1'
    GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
    GIT_CONFIG_VALUE_0 = 'AUTHORIZATION: basic ' + $encodedCredential
    GIT_TERMINAL_PROMPT = '0'
    GCM_INTERACTIVE = 'Never'
}

try {
    Invoke-Git -Arguments @('init', '--bare', $repositoryRoot) | Out-Null
    Invoke-Git -Arguments @('-C', $repositoryRoot, 'remote', 'add', 'origin', $expectedRemoteUrl) | Out-Null

    $configuredPushUrls = @(& git -C $repositoryRoot config --local --get-all remote.origin.pushurl 2>$null)
    if ($LASTEXITCODE -eq 0 -and $configuredPushUrls.Count -gt 0) {
        throw 'Bare signing repository must not configure a separate origin pushurl.'
    }

    Invoke-Git -Arguments @(
        '-C', $repositoryRoot,
        'fetch', '--no-tags', '--no-recurse-submodules',
        'origin',
        "+refs/heads/$BaseRef:refs/remotes/origin/$BaseRef",
        "+refs/heads/$HeadRef:refs/remotes/origin/$HeadRef"
    ) -Environment $gitEnvironment | Out-Null

    $fetchUrl = (Invoke-Git -Arguments @('-C', $repositoryRoot, 'remote', 'get-url', 'origin')).Trim()
    $pushUrl = (Invoke-Git -Arguments @('-C', $repositoryRoot, 'remote', 'get-url', '--push', 'origin')).Trim()
    if ($fetchUrl -cne $expectedRemoteUrl -or $pushUrl -cne $expectedRemoteUrl) {
        throw 'Bare signing repository origin is not bound to the canonical repository URL.'
    }

    $base = (Invoke-Git -Arguments @('-C', $repositoryRoot, 'rev-parse', '--verify', "refs/remotes/origin/$BaseRef^{commit}")).Trim().ToLowerInvariant()
    $head = (Invoke-Git -Arguments @('-C', $repositoryRoot, 'rev-parse', '--verify', "refs/remotes/origin/$HeadRef^{commit}")).Trim().ToLowerInvariant()
    if ($base -cne $ExpectedBaseSha) { throw "Trusted base moved from event SHA $ExpectedBaseSha before signing." }
    if ($head -cne $ExpectedHeadSha) { throw "PR head moved from event SHA $ExpectedHeadSha before signing." }

    $mergeBase = (Invoke-Git -Arguments @('-C', $repositoryRoot, 'merge-base', $base, $head)).Trim().ToLowerInvariant()
    if ($mergeBase -cnotmatch '^[0-9a-f]{40}$') { throw 'Unable to resolve a valid PR merge base.' }

    $bare = (Invoke-Git -Arguments @('-C', $repositoryRoot, 'rev-parse', '--is-bare-repository')).Trim().ToLowerInvariant()
    if ($bare -cne 'true') { throw 'Signing repository unexpectedly materialized a worktree.' }

    [pscustomobject][ordered]@{
        Repository = $Repository
        RepositoryPath = $repositoryRoot
        ExpectedRemoteUrl = $expectedRemoteUrl
        BaseRef = $BaseRef
        BaseSha = $base
        HeadRef = $HeadRef
        HeadSha = $head
        MergeBase = $mergeBase
        Bare = $true
        Valid = $true
    }
}
finally {
    $token = $null
    $encodedCredential = $null
}
