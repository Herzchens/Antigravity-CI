#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $BaseSha,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $HeadSha,

    [Parameter(Mandatory)]
    [string] $BranchName,

    [string] $RepositoryPath = '.',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $RemoteName = 'origin',

    [string] $TrustedPublicKey,

    [string] $SigningKey,

    [ValidatePattern('^[A-Za-z0-9@._+-]+$')]
    [string] $Principal = 'antigravity-ci',

    [switch] $Push,

    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $ExpectedRemoteHead,

    [string] $ExpectedRemoteUrl,

    [ValidateRange(1, 10000)]
    [int] $MaxCommits = 250,

    [ValidateRange(1024, 104857600)]
    [long] $MaxCommitObjectBytes = 1048576
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

function Get-RemoteUrls {
    param(
        [switch] $PushUrls
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('remote')
    $arguments.Add('get-url')

    if ($PushUrls) {
        $arguments.Add('--push')
    }

    $arguments.Add('--all')
    $arguments.Add($RemoteName)

    $result = Invoke-Git -Arguments @($arguments) -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "Unable to resolve remote URLs for '$RemoteName'."
    }

    @(
        $result.Output |
        ForEach-Object { [string] $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
    )
}

function Assert-ExpectedRemote {
    if ([string]::IsNullOrWhiteSpace($ExpectedRemoteUrl)) {
        throw 'ExpectedRemoteUrl is required when -Push is used.'
    }

    $fetchUrls = @(Get-RemoteUrls)
    $pushUrls = @(Get-RemoteUrls -PushUrls)

    if ($fetchUrls.Count -ne 1) {
        throw "Remote '$RemoteName' must expose exactly one fetch URL."
    }

    if ($pushUrls.Count -ne 1) {
        throw "Remote '$RemoteName' must expose exactly one effective push URL."
    }

    if ($fetchUrls[0] -cne $ExpectedRemoteUrl) {
        throw "Remote '$RemoteName' fetch URL does not match the expected endpoint."
    }

    if ($pushUrls[0] -cne $ExpectedRemoteUrl) {
        throw "Remote '$RemoteName' push URL does not match the expected endpoint."
    }
}

function Resolve-Commit {
    param(
        [Parameter(Mandatory)]
        [string] $Sha
    )

    $resolved = (Invoke-Git -Arguments @(
        'rev-parse',
        '--verify',
        "$Sha^{commit}"
    )).Output | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "Unable to resolve commit $Sha."
    }

    $resolved.Trim().ToLowerInvariant()
}

function Get-CommitField {
    param(
        [Parameter(Mandatory)]
        [string] $Sha,

        [Parameter(Mandatory)]
        [string] $Format
    )

    $value = (Invoke-Git -Arguments @(
        'show',
        '--no-patch',
        "--format=$Format",
        $Sha
    )).Output | Select-Object -First 1

    if ($null -eq $value) {
        return ''
    }

    [string] $value
}

function Get-CommitRecord {
    param(
        [Parameter(Mandatory)]
        [string] $Sha
    )

    $tree = (Invoke-Git -Arguments @(
        'rev-parse',
        "$Sha^{tree}"
    )).Output | Select-Object -First 1

    $parentsLine = (Invoke-Git -Arguments @(
        'rev-list',
        '--parents',
        '-n',
        '1',
        $Sha
    )).Output | Select-Object -First 1

    $parentParts = @($parentsLine.Trim() -split '\s+')
    $parents = @()
    if ($parentParts.Count -gt 1) {
        $parents = @($parentParts[1..($parentParts.Count - 1)])
    }

    if ($parents.Count -gt 1) {
        throw "Merge commit $Sha is not supported by preserve-commit signing mode."
    }

    [pscustomobject]@{
        Sha = $Sha
        Tree = $tree.Trim()
        Parents = $parents
        AuthorName = Get-CommitField -Sha $Sha -Format '%an'
        AuthorEmail = Get-CommitField -Sha $Sha -Format '%ae'
        AuthorDate = Get-CommitField -Sha $Sha -Format '%aI'
        CommitterName = Get-CommitField -Sha $Sha -Format '%cn'
        CommitterEmail = Get-CommitField -Sha $Sha -Format '%ce'
        CommitterDate = Get-CommitField -Sha $Sha -Format '%cI'
    }
}

function Test-TrustedSignature {
    param(
        [Parameter(Mandatory)]
        [string] $Sha,

        [switch] $ThrowOnFailure
    )

    $verifyParameters = @{
        RepositoryPath = $script:RepositoryRoot
        CommitSha = $Sha
        Principal = $Principal
    }

    if (-not [string]::IsNullOrWhiteSpace($TrustedPublicKey)) {
        $verifyParameters.SigningKey = $TrustedPublicKey
    }

    try {
        & $script:VerificationScript @verifyParameters | Out-Null
        return $true
    }
    catch {
        if ($ThrowOnFailure) {
            throw
        }

        return $false
    }
}

function Assert-CommitObjectSize {
    param(
        [Parameter(Mandatory)]
        [string] $Sha
    )

    $sizeLine = (
        (Invoke-Git -Arguments @('cat-file', '-s', $Sha)).Output |
        Select-Object -First 1
    )

    $objectSize = 0L
    if ($null -eq $sizeLine -or
        -not [long]::TryParse(([string] $sizeLine).Trim(), [ref] $objectSize) -or
        $objectSize -lt 0) {
        throw "Unable to determine commit object size for $Sha."
    }

    if ($objectSize -gt $MaxCommitObjectBytes) {
        throw "Commit object $Sha exceeds the maximum allowed size of $MaxCommitObjectBytes bytes."
    }

    $objectSize
}

function Get-CommitObjectBytes {
    param(
        [Parameter(Mandatory)]
        [string] $Sha
    )

    $null = Assert-CommitObjectSize -Sha $Sha

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($script:RepositoryRoot)
    $startInfo.ArgumentList.Add('cat-file')
    $startInfo.ArgumentList.Add('commit')
    $startInfo.ArgumentList.Add($Sha)

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw "Unable to read commit object $Sha."
    }

    $memory = [System.IO.MemoryStream]::new()
    try {
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()
        $null = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            throw "git cat-file failed for commit $Sha."
        }

        $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Get-CommitHeaderBoundary {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [Parameter(Mandatory)]
        [string] $Sha
    )

    for ($index = 0; $index -lt ($Bytes.Length - 1); $index++) {
        if ($Bytes[$index] -eq 10 -and $Bytes[$index + 1] -eq 10) {
            return $index
        }
    }

    throw "Commit $Sha does not contain a valid header/message separator."
}

function Assert-RewritableCommitHeaders {
    param(
        [Parameter(Mandatory)]
        [string] $Sha,

        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    $headerEnd = Get-CommitHeaderBoundary -Bytes $Bytes -Sha $Sha
    $allowedHeaders = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($name in @(
        'tree',
        'parent',
        'author',
        'committer',
        'gpgsig',
        'gpgsig-sha256'
    )) {
        [void] $allowedHeaders.Add($name)
    }

    $headerCounts = @{}
    $currentHeader = $null
    $lineStart = 0

    while ($lineStart -lt $headerEnd) {
        $lineEnd = $lineStart
        while ($lineEnd -lt $headerEnd -and $Bytes[$lineEnd] -ne 10) {
            $lineEnd++
        }

        if ($Bytes[$lineStart] -eq 32 -or $Bytes[$lineStart] -eq 9) {
            if ($currentHeader -notin @('gpgsig', 'gpgsig-sha256')) {
                throw "Commit $Sha contains an invalid continuation line outside a signature header."
            }

            $lineStart = $lineEnd + 1
            continue
        }

        $space = $lineStart
        while ($space -lt $lineEnd -and $Bytes[$space] -ne 32) {
            $space++
        }

        if ($space -eq $lineStart -or $space -ge $lineEnd) {
            throw "Commit $Sha contains a malformed commit header."
        }

        $name = [System.Text.Encoding]::ASCII.GetString(
            $Bytes,
            $lineStart,
            $space - $lineStart
        )

        if (-not $allowedHeaders.Contains($name)) {
            throw "Commit $Sha contains unsupported header '$name'; refusing a lossy signing rewrite."
        }

        $currentHeader = $name
        if ($headerCounts.ContainsKey($name)) {
            $headerCounts[$name]++
        }
        else {
            $headerCounts[$name] = 1
        }

        $lineStart = $lineEnd + 1
    }

    foreach ($requiredHeader in @('tree', 'parent', 'author', 'committer')) {
        $count = if ($headerCounts.ContainsKey($requiredHeader)) {
            [int] $headerCounts[$requiredHeader]
        }
        else {
            0
        }

        if ($count -ne 1) {
            throw "Commit $Sha must contain exactly one '$requiredHeader' header; found $count."
        }
    }
}

function Get-SingleCommitHeaderLineBase64 {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [Parameter(Mandatory)]
        [string] $Sha,

        [Parameter(Mandatory)]
        [ValidateSet('author', 'committer')]
        [string] $HeaderName
    )

    $headerEnd = Get-CommitHeaderBoundary -Bytes $Bytes -Sha $Sha
    $matches = [System.Collections.Generic.List[string]]::new()
    $lineStart = 0

    while ($lineStart -lt $headerEnd) {
        $lineEnd = $lineStart
        while ($lineEnd -lt $headerEnd -and $Bytes[$lineEnd] -ne 10) {
            $lineEnd++
        }

        if ($Bytes[$lineStart] -ne 32 -and $Bytes[$lineStart] -ne 9) {
            $space = $lineStart
            while ($space -lt $lineEnd -and $Bytes[$space] -ne 32) {
                $space++
            }

            if ($space -gt $lineStart -and $space -lt $lineEnd) {
                $name = [System.Text.Encoding]::ASCII.GetString(
                    $Bytes,
                    $lineStart,
                    $space - $lineStart
                )

                if ($name -ceq $HeaderName) {
                    $lineLength = $lineEnd - $lineStart
                    $lineBytes = [byte[]]::new($lineLength)
                    [System.Array]::Copy(
                        $Bytes,
                        $lineStart,
                        $lineBytes,
                        0,
                        $lineLength
                    )
                    $matches.Add([Convert]::ToBase64String($lineBytes))
                }
            }
        }

        $lineStart = $lineEnd + 1
    }

    if ($matches.Count -ne 1) {
        throw "Commit $Sha must contain exactly one raw '$HeaderName' header; found $($matches.Count)."
    }

    $matches[0]
}

function Assert-RawIdentityHeadersPreserved {
    param(
        [Parameter(Mandatory)]
        [byte[]] $OriginalBytes,

        [Parameter(Mandatory)]
        [string] $OriginalSha,

        [Parameter(Mandatory)]
        [byte[]] $SignedBytes,

        [Parameter(Mandatory)]
        [string] $SignedSha
    )

    foreach ($headerName in @('author', 'committer')) {
        $originalParameters = @{
            Bytes = $OriginalBytes
            Sha = $OriginalSha
            HeaderName = $headerName
        }
        $signedParameters = @{
            Bytes = $SignedBytes
            Sha = $SignedSha
            HeaderName = $headerName
        }

        $originalHeader = Get-SingleCommitHeaderLineBase64 @originalParameters
        $signedHeader = Get-SingleCommitHeaderLineBase64 @signedParameters

        if ($signedHeader -cne $originalHeader) {
            throw "Signing rewrite changed the raw $headerName header for commit $OriginalSha."
        }
    }
}

function Get-CommitMessageBytes {
    param(
        [Parameter(Mandatory)]
        [string] $Sha,

        [byte[]] $CommitBytes
    )

    $bytes = if ($null -eq $CommitBytes) {
        Get-CommitObjectBytes -Sha $Sha
    }
    else {
        $CommitBytes
    }

    $headerEnd = Get-CommitHeaderBoundary -Bytes $bytes -Sha $Sha
    $messageStart = $headerEnd + 2
    $messageLength = $bytes.Length - $messageStart
    $message = [byte[]]::new($messageLength)
    [System.Array]::Copy($bytes, $messageStart, $message, 0, $messageLength)
    $message
}

function New-SignedCommit {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Record,

        [Parameter(Mandatory)]
        [string] $ParentSha
    )

    $messagePath = Join-Path $script:TempDirectory ($Record.Sha + '.message')
    $commitBytes = Get-CommitObjectBytes -Sha $Record.Sha
    Assert-RewritableCommitHeaders -Sha $Record.Sha -Bytes $commitBytes
    $messageBytes = Get-CommitMessageBytes -Sha $Record.Sha -CommitBytes $commitBytes
    [System.IO.File]::WriteAllBytes($messagePath, $messageBytes)

    $savedEnvironment = @{
        GIT_AUTHOR_NAME = $env:GIT_AUTHOR_NAME
        GIT_AUTHOR_EMAIL = $env:GIT_AUTHOR_EMAIL
        GIT_AUTHOR_DATE = $env:GIT_AUTHOR_DATE
        GIT_COMMITTER_NAME = $env:GIT_COMMITTER_NAME
        GIT_COMMITTER_EMAIL = $env:GIT_COMMITTER_EMAIL
        GIT_COMMITTER_DATE = $env:GIT_COMMITTER_DATE
    }

    try {
        $env:GIT_AUTHOR_NAME = $Record.AuthorName
        $env:GIT_AUTHOR_EMAIL = $Record.AuthorEmail
        $env:GIT_AUTHOR_DATE = $Record.AuthorDate
        $env:GIT_COMMITTER_NAME = $Record.CommitterName
        $env:GIT_COMMITTER_EMAIL = $Record.CommitterEmail
        $env:GIT_COMMITTER_DATE = $Record.CommitterDate

        $result = Invoke-Git -Arguments @(
            '-c',
            'gpg.format=ssh',
            '-c',
            "gpg.ssh.program=$script:SshKeygenProgram",
            '-c',
            "user.signingkey=$script:SigningKey",
            'commit-tree',
            $Record.Tree,
            '-p',
            $ParentSha,
            '-S',
            '-F',
            $messagePath
        )

        $shaCandidates = @(
            $result.Output |
            ForEach-Object { ([string] $_).Trim().ToLowerInvariant() } |
            Where-Object { $_ -match '^[0-9a-f]{40}$' }
        )

        if ($shaCandidates.Count -ne 1) {
            throw "Signing commit $($Record.Sha) did not return exactly one commit SHA."
        }

        $newSha = $shaCandidates[0]

        $newTree = (Invoke-Git -Arguments @(
            'rev-parse',
            "$newSha^{tree}"
        )).Output | Select-Object -First 1

        if ($newTree.Trim() -ne $Record.Tree) {
            throw "Tree changed while signing commit $($Record.Sha)."
        }

        $signedCommitBytes = Get-CommitObjectBytes -Sha $newSha
        Assert-RewritableCommitHeaders -Sha $newSha -Bytes $signedCommitBytes
        $identityParameters = @{
            OriginalBytes = $commitBytes
            OriginalSha = $Record.Sha
            SignedBytes = $signedCommitBytes
            SignedSha = $newSha
        }
        Assert-RawIdentityHeadersPreserved @identityParameters

        $null = Test-TrustedSignature -Sha $newSha -ThrowOnFailure

        $newSha
    }
    finally {
        foreach ($entry in $savedEnvironment.GetEnumerator()) {
            if ($null -eq $entry.Value) {
                Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
            }
        }
    }
}

$null = Get-Command git -ErrorAction Stop
$sshKeygenCommand = Get-Command ssh-keygen -ErrorAction Stop

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
$script:RepositoryRoot = $RepositoryRoot
$script:VerificationScript = Join-Path $PSScriptRoot 'Test-CommitSignature.ps1'

$script:SshKeygenProgram = $sshKeygenCommand.Source

if ([string]::IsNullOrWhiteSpace($SigningKey)) {
    if (-not [string]::IsNullOrWhiteSpace($TrustedPublicKey)) {
        $SigningKey = $TrustedPublicKey
    }
    else {
        $SigningKey = (Invoke-Git -Arguments @(
            'config',
            '--get',
            'user.signingkey'
        ) -AllowFailure).Output | Select-Object -First 1
    }
}

if ([string]::IsNullOrWhiteSpace($SigningKey)) {
    throw 'SigningKey or TrustedPublicKey is required for deterministic SSH signing.'
}

$script:SigningKey = $SigningKey.Trim()

if (-not (Test-Path -LiteralPath $script:VerificationScript -PathType Leaf)) {
    throw 'Test-CommitSignature.ps1 is required next to the signing gate.'
}

$branchCheck = Invoke-Git -Arguments @(
    'check-ref-format',
    '--branch',
    $BranchName
) -AllowFailure

if ($branchCheck.ExitCode -ne 0) {
    throw 'Branch name is not a valid Git branch name.'
}

if ($Push) {
    Assert-ExpectedRemote
}

$base = Resolve-Commit -Sha $BaseSha
$head = Resolve-Commit -Sha $HeadSha

$ancestorCheck = Invoke-Git -Arguments @(
    'merge-base',
    '--is-ancestor',
    $base,
    $head
) -AllowFailure

if ($ancestorCheck.ExitCode -ne 0) {
    throw 'BaseSha must be an ancestor of HeadSha.'
}

$originalHeadTree = (Invoke-Git -Arguments @(
    'rev-parse',
    "$head^{tree}"
)).Output | Select-Object -First 1
$originalHeadTree = $originalHeadTree.Trim()

$commitCountLine = (
    (Invoke-Git -Arguments @(
        'rev-list',
        '--count',
        "--max-count=$($MaxCommits + 1)",
        "$base..$head"
    )).Output |
    Select-Object -First 1
)

$commitCount = 0
if ($null -eq $commitCountLine -or
    -not [int]::TryParse(([string] $commitCountLine).Trim(), [ref] $commitCount) -or
    $commitCount -lt 0) {
    throw 'Unable to determine the number of commits in the signing range.'
}

if ($commitCount -gt $MaxCommits) {
    throw "Signing range contains $commitCount commits, exceeding the maximum allowed $MaxCommits."
}

$commitLines = (Invoke-Git -Arguments @(
    'rev-list',
    '--reverse',
    "$base..$head"
)).Output

$commits = @($commitLines | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
} | ForEach-Object {
    $_.Trim().ToLowerInvariant()
})

if ($commits.Count -ne $commitCount) {
    throw 'Enumerated signing range does not match the preflight commit count.'
}

if ($commits.Count -eq 0) {
    [pscustomobject]@{
        BaseSha = $base
        OriginalHeadSha = $head
        SignedHeadSha = $head
        CommitCount = 0
        RewritePerformed = $false
        Pushed = $false
        HeadTree = $originalHeadTree
    }
    return
}

$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-signing-gate-' + [Guid]::NewGuid().ToString('N')
)
$script:TempDirectory = $tempDirectory
New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null

try {
    $currentParent = $base
    $previousOldCommit = $null
    $rewritePerformed = $false

    foreach ($oldCommit in $commits) {
        $null = Assert-CommitObjectSize -Sha $oldCommit
        $record = Get-CommitRecord -Sha $oldCommit

        if ($record.Parents.Count -ne 1) {
            throw "Commit $oldCommit must have exactly one parent."
        }

        $expectedOldParent = if ($null -eq $previousOldCommit) {
            $base
        }
        else {
            $previousOldCommit
        }

        if ($record.Parents[0].ToLowerInvariant() -ne $expectedOldParent) {
            throw "PR history is not linear at commit $oldCommit."
        }

        $signatureTrusted = Test-TrustedSignature -Sha $oldCommit
        $parentUnchanged = $record.Parents[0].ToLowerInvariant() -eq $currentParent

        if ($signatureTrusted -and $parentUnchanged) {
            $newCommit = $oldCommit
        }
        else {
            $newCommit = New-SignedCommit -Record $record -ParentSha $currentParent
            $rewritePerformed = $true
        }

        $currentParent = $newCommit
        $previousOldCommit = $oldCommit
    }

    $signedHead = $currentParent
    $signedHeadTree = (Invoke-Git -Arguments @(
        'rev-parse',
        "$signedHead^{tree}"
    )).Output | Select-Object -First 1
    $signedHeadTree = $signedHeadTree.Trim()

    if ($signedHeadTree -ne $originalHeadTree) {
        throw 'Final tree does not match the original PR head tree.'
    }

    $signedCommitLines = (Invoke-Git -Arguments @(
        'rev-list',
        '--reverse',
        "$base..$signedHead"
    )).Output

    foreach ($signedCommit in @($signedCommitLines)) {
        if ([string]::IsNullOrWhiteSpace($signedCommit)) {
            continue
        }

        if (-not (Test-TrustedSignature -Sha $signedCommit.Trim())) {
            throw "Final history contains an untrusted commit: $($signedCommit.Trim())."
        }
    }

    $pushed = $false

    if ($Push -and $rewritePerformed) {
        if ([string]::IsNullOrWhiteSpace($ExpectedRemoteHead)) {
            throw 'ExpectedRemoteHead is required when -Push is used.'
        }

        $expectedHead = $ExpectedRemoteHead.ToLowerInvariant()
        if ($expectedHead -ne $head) {
            throw 'ExpectedRemoteHead must equal the input HeadSha.'
        }

        $remoteLine = (Invoke-Git -Arguments @(
            'ls-remote',
            '--heads',
            $RemoteName,
            "refs/heads/$BranchName"
        )).Output | Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace($remoteLine)) {
            throw 'Remote branch does not exist.'
        }

        $remoteHead = ($remoteLine.Trim() -split '\s+')[0].ToLowerInvariant()
        if ($remoteHead -ne $expectedHead) {
            throw "Remote branch moved from expected head $expectedHead to $remoteHead."
        }

        $leaseArgument = '--force-with-lease=refs/heads/' + $BranchName + ':' + $expectedHead
        $refSpec = $signedHead + ':refs/heads/' + $BranchName

        Invoke-Git -Arguments @(
            'push',
            $leaseArgument,
            $RemoteName,
            $refSpec
        ) | Out-Null

        $pushed = $true
    }

    [pscustomobject]@{
        BaseSha = $base
        OriginalHeadSha = $head
        SignedHeadSha = $signedHead
        CommitCount = $commits.Count
        RewritePerformed = $rewritePerformed
        Pushed = $pushed
        HeadTree = $signedHeadTree
    }
}
finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
