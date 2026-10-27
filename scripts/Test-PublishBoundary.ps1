#requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'Ref')]
param(
    [string] $RepositoryPath = '.',

    [Parameter(ParameterSetName = 'Ref')]
    [ValidatePattern('^[0-9A-Za-z._/@{}^~:+-]+$')]
    [string] $Ref = 'HEAD',

    [Parameter(Mandatory, ParameterSetName = 'Staged')]
    [switch] $Staged,

    [Parameter(Mandatory, ParameterSetName = 'PrePush')]
    [switch] $PrePush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $copyTask.GetAwaiter().GetResult()
        $null = $errorTask.GetAwaiter().GetResult()

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

function Invoke-GitLines {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = @(& git -C $script:RepositoryRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git command failed with exit code $LASTEXITCODE."
    }

    @(
        $output |
        ForEach-Object { [string] $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function ConvertFrom-NulPaths {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $paths = [System.Collections.Generic.List[string]]::new()
$checkedCommitCount = 0
    $start = 0

    for ($index = 0; $index -le $Bytes.Length; $index++) {
        if ($index -lt $Bytes.Length -and $Bytes[$index] -ne 0) {
            continue
        }

        $length = $index - $start
        if ($length -gt 0) {
            try {
                $paths.Add($utf8.GetString($Bytes, $start, $length))
            }
            catch {
                throw 'Git returned a path that is not valid UTF-8.'
            }
        }

        $start = $index + 1
    }

    $paths
}

function Test-ForbiddenPublishPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $leaf = [System.IO.Path]::GetFileName($Path)

    if ($leaf.Equals('AGENTS.md', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if ($leaf -match '(?i)^PLAN(?:[^/]*)\.(?:md|txt|json|ya?ml|zip)$') {
        return $true
    }

    if ($leaf -match '(?i)HANDOFF') {
        return $true
    }

    $false
}

function Get-PathsForRef {
    param(
        [Parameter(Mandatory)]
        [string] $Commitish
    )

    $bytes = Invoke-GitBytes -Arguments @(
        'ls-tree',
        '-r',
        '--name-only',
        '-z',
        $Commitish
    )

    ConvertFrom-NulPaths -Bytes $bytes
}

$null = Get-Command git -ErrorAction Stop
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
$script:RepositoryRoot = $RepositoryRoot

$paths = [System.Collections.Generic.List[string]]::new()

if ($PSCmdlet.ParameterSetName -eq 'Staged') {
    $bytes = Invoke-GitBytes -Arguments @(
        'diff',
        '--cached',
        '--name-only',
        '--diff-filter=ACMR',
        '-z',
        '--'
    )

    foreach ($path in ConvertFrom-NulPaths -Bytes $bytes) {
        $paths.Add($path)
    }
}
elseif ($PSCmdlet.ParameterSetName -eq 'PrePush') {
    $inputText = [Console]::In.ReadToEnd()
    $seenCommits = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($line in @($inputText -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $parts = @($line.Trim() -split '\s+')
        if ($parts.Count -ne 4) {
            throw 'Unexpected pre-push hook input.'
        }

        $localSha = $parts[1].ToLowerInvariant()
        $remoteSha = $parts[3].ToLowerInvariant()

        if ($localSha -match '^0+$') {
            continue
        }

        if ($localSha -notmatch '^[0-9a-f]{40,64}$') {
            throw 'Pre-push hook input contains an invalid local object ID.'
        }

        if ($remoteSha -notmatch '^(?:0+|[0-9a-f]{40,64})$') {
            throw 'Pre-push hook input contains an invalid remote object ID.'
        }

        $revisionArguments = if ($remoteSha -match '^0+$') {
            @('rev-list', $localSha)
        }
        else {
            @('rev-list', "$remoteSha..$localSha")
        }

        foreach ($commit in Invoke-GitLines -Arguments $revisionArguments) {
            $commitSha = $commit.Trim().ToLowerInvariant()
            if ($commitSha -notmatch '^[0-9a-f]{40,64}$') {
                throw 'git rev-list returned an invalid commit object ID.'
            }

            if (-not $seenCommits.Add($commitSha)) {
                continue
            }

            $checkedCommitCount++
            foreach ($path in Get-PathsForRef -Commitish $commitSha) {
                $paths.Add($path)
            }
        }
    }
}
else {
    foreach ($path in Get-PathsForRef -Commitish $Ref) {
        $paths.Add($path)
    }
}

$violations = @(
    $paths |
    Where-Object { Test-ForbiddenPublishPath -Path $_ } |
    Sort-Object -Unique
)

if ($violations.Count -gt 0) {
    $list = $violations -join ', '
    throw "Publish boundary rejected local-only artifact path(s): $list"
}

[pscustomobject][ordered]@{
    CheckedPathCount = $paths.Count
    CheckedCommitCount = $checkedCommitCount
    ViolationCount = 0
    Valid = $true
}
