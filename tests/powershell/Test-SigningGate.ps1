#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

foreach ($command in @('git', 'ssh-keygen')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required."
    }
}

$sshKeygenProgram = (Get-Command ssh-keygen -ErrorAction Stop).Source

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$gateScript = Join-Path $repoRoot 'scripts\Invoke-SigningGate.ps1'
$verifyScript = Join-Path $repoRoot 'scripts\Test-CommitSignature.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-signing-gate-test-' + [Guid]::NewGuid().ToString('N')
)
$remoteRepo = Join-Path $tempRoot 'remote.git'
$workRepo = Join-Path $tempRoot 'work'
$signingKey = Join-Path $tempRoot 'signing_key'

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Invoke-Checked -FilePath 'ssh-keygen' -Arguments @('-q', '-t', 'ed25519', '-N', '', '-f', $signingKey)
    Invoke-Checked -FilePath 'git' -Arguments @('init', '--bare', '--quiet', $remoteRepo)
    Invoke-Checked -FilePath 'git' -Arguments @('init', '--quiet', $workRepo)

    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.name', 'Connector Author') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.email', 'connector@example.invalid') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'gpg.format', 'ssh') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'gpg.ssh.program', $sshKeygenProgram) -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.signingkey', $signingKey) -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'commit.gpgsign', 'false') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('remote', 'add', 'origin', $remoteRepo) -WorkingDirectory $workRepo

    Set-Content -LiteralPath (Join-Path $workRepo 'fixture.txt') -Value 'base' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'fixture.txt') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'base') -WorkingDirectory $workRepo

    $baseSha = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    Invoke-Checked -FilePath 'git' -Arguments @('checkout', '-q', '-b', 'feature') -WorkingDirectory $workRepo

    Add-Content -LiteralPath (Join-Path $workRepo 'fixture.txt') -Value 'one'
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'fixture.txt') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'first change', '-m', 'first body') -WorkingDirectory $workRepo

    Add-Content -LiteralPath (Join-Path $workRepo 'fixture.txt') -Value 'two'
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'fixture.txt') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'second change', '-m', 'second body') -WorkingDirectory $workRepo

    $originalHead = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    $originalTree = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD^{tree}') -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    $originalSubjects = @(
        Invoke-Checked -FilePath 'git' -Arguments @('log', '--reverse', '--format=%s', "$baseSha..$originalHead") -WorkingDirectory $workRepo
    )

    $originalCommits = @(
        Invoke-Checked -FilePath 'git' -Arguments @('rev-list', '--reverse', "$baseSha..$originalHead") -WorkingDirectory $workRepo
    )

    Invoke-Checked -FilePath 'git' -Arguments @('push', '-q', '-u', 'origin', 'feature') -WorkingDirectory $workRepo

    $gateArguments = @{
        RepositoryPath = $workRepo
        BaseSha = $baseSha
        HeadSha = $originalHead
        BranchName = 'feature'
        TrustedPublicKey = "$signingKey.pub"
        SigningKey = $signingKey
        ExpectedRemoteHead = $originalHead
        Push = $true
    }

    $result = & $gateScript @gateArguments

    if (-not $result.RewritePerformed) {
        throw 'Expected unsigned commits to be rewritten.'
    }

    if (-not $result.Pushed) {
        throw 'Expected signed history to be pushed.'
    }

    if ($result.CommitCount -ne 2) {
        throw "Expected two preserved commits, got $($result.CommitCount)."
    }

    $remoteHeadLine = (
        Invoke-Checked -FilePath 'git' -Arguments @('ls-remote', '--heads', 'origin', 'refs/heads/feature') -WorkingDirectory $workRepo |
        Select-Object -First 1
    )
    $remoteHead = ($remoteHeadLine.Trim() -split '\s+')[0]

    if ($remoteHead -ne $result.SignedHeadSha) {
        throw 'Remote head does not match the signed head.'
    }

    $signedTree = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', "$($result.SignedHeadSha)^{tree}") -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    if ($signedTree -ne $originalTree) {
        throw 'Signed history changed the final tree.'
    }

    $signedSubjects = @(
        Invoke-Checked -FilePath 'git' -Arguments @('log', '--reverse', '--format=%s', "$baseSha..$($result.SignedHeadSha)") -WorkingDirectory $workRepo
    )

    if (($signedSubjects -join [Environment]::NewLine) -ne ($originalSubjects -join [Environment]::NewLine)) {
        throw 'Commit subjects were not preserved.'
    }

    $signedCommits = @(
        Invoke-Checked -FilePath 'git' -Arguments @('rev-list', '--reverse', "$baseSha..$($result.SignedHeadSha)") -WorkingDirectory $workRepo
    )

    if ($signedCommits.Count -ne 2) {
        throw 'Signed history did not preserve commit count.'
    }

    for ($index = 0; $index -lt $originalCommits.Count; $index++) {
        $oldSha = $originalCommits[$index].Trim()
        $newSha = $signedCommits[$index].Trim()

        $oldTree = (
            Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', "$oldSha^{tree}") -WorkingDirectory $workRepo |
            Select-Object -First 1
        ).Trim()

        $newTree = (
            Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', "$newSha^{tree}") -WorkingDirectory $workRepo |
            Select-Object -First 1
        ).Trim()

        if ($oldTree -ne $newTree) {
            throw "Commit tree changed at preserved position $index."
        }

        $oldMetadata = (
            Invoke-Checked -FilePath 'git' -Arguments @('show', '--no-patch', '--format=%an|%ae|%aI|%cn|%ce|%cI', $oldSha) -WorkingDirectory $workRepo |
            Select-Object -First 1
        )

        $newMetadata = (
            Invoke-Checked -FilePath 'git' -Arguments @('show', '--no-patch', '--format=%an|%ae|%aI|%cn|%ce|%cI', $newSha) -WorkingDirectory $workRepo |
            Select-Object -First 1
        )

        if ($oldMetadata -ne $newMetadata) {
            throw "Commit metadata changed at preserved position $index."
        }

        $oldMessage = @(
            Invoke-Checked -FilePath 'git' -Arguments @('show', '--no-patch', '--format=%B', $oldSha) -WorkingDirectory $workRepo
        )

        $newMessage = @(
            Invoke-Checked -FilePath 'git' -Arguments @('show', '--no-patch', '--format=%B', $newSha) -WorkingDirectory $workRepo
        )

        if (($oldMessage -join [Environment]::NewLine) -ne ($newMessage -join [Environment]::NewLine)) {
            throw "Commit message changed at preserved position $index."
        }
    }

    foreach ($sha in $signedCommits) {
        $verifyArguments = @{
            RepositoryPath = $workRepo
            CommitSha = $sha.Trim()
            SigningKey = "$signingKey.pub"
        }
        $verification = & $verifyScript @verifyArguments

        if (-not $verification.Valid) {
            throw "Signed commit $sha failed verification."
        }
    }

    Invoke-Checked -FilePath 'git' -Arguments @('checkout', '-q', '-B', 'feature', $result.SignedHeadSha) -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'commit.gpgsign', 'false') -WorkingDirectory $workRepo

    Add-Content -LiteralPath (Join-Path $workRepo 'fixture.txt') -Value 'three'
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'fixture.txt') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'third change') -WorkingDirectory $workRepo

    $staleCandidate = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    Invoke-Checked -FilePath 'git' -Arguments @('push', '-q', 'origin', 'feature') -WorkingDirectory $workRepo

    Add-Content -LiteralPath (Join-Path $workRepo 'fixture.txt') -Value 'four'
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'fixture.txt') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'remote moves again') -WorkingDirectory $workRepo
    Invoke-Checked -FilePath 'git' -Arguments @('push', '-q', 'origin', 'feature') -WorkingDirectory $workRepo

    $remoteMovedHead = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    if ($remoteMovedHead -eq $staleCandidate) {
        throw 'Stale-race fixture did not advance the remote branch.'
    }

    Invoke-Checked -FilePath 'git' -Arguments @('reset', '--hard', $staleCandidate) -WorkingDirectory $workRepo | Out-Null

    $staleGateArguments = @{
        RepositoryPath = $workRepo
        BaseSha = $baseSha
        HeadSha = $staleCandidate
        BranchName = 'feature'
        TrustedPublicKey = "$signingKey.pub"
        SigningKey = $signingKey
        ExpectedRemoteHead = $staleCandidate
        Push = $true
    }

    $staleLeaseRejected = $false
    try {
        & $gateScript @staleGateArguments | Out-Null
    }
    catch {
        $staleLeaseRejected = $true
    }

    if (-not $staleLeaseRejected) {
        throw 'Expected stale remote lease to be rejected.'
    }

    $baseTree = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', "$baseSha^{tree}") -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    $rawCommitPath = Join-Path $tempRoot 'unsupported-header.commit'
    $rawCommit = @(
        "tree $baseTree",
        "parent $baseSha",
        'author Metadata Fixture <fixture@example.invalid> 1700000000 +0000',
        'committer Metadata Fixture <fixture@example.invalid> 1700000000 +0000',
        'encoding ISO-8859-1',
        '',
        'metadata fixture'
    ) -join [char] 10

    [System.IO.File]::WriteAllText(
        $rawCommitPath,
        $rawCommit,
        [System.Text.UTF8Encoding]::new($false)
    )

    $unsupportedHeaderSha = (
        Invoke-Checked -FilePath 'git' -Arguments @(
            'hash-object',
            '-t',
            'commit',
            '-w',
            $rawCommitPath
        ) -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    $unsupportedHeaderParameters = @{
        RepositoryPath = $workRepo
        BaseSha = $baseSha
        HeadSha = $unsupportedHeaderSha
        BranchName = 'metadata-fixture'
        TrustedPublicKey = "$signingKey.pub"
        SigningKey = $signingKey
    }

    $unsupportedHeaderRejected = $false
    try {
        & $gateScript @unsupportedHeaderParameters | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike "*unsupported header 'encoding'*") {
            throw
        }

        $unsupportedHeaderRejected = $true
    }

    if (-not $unsupportedHeaderRejected) {
        throw 'Expected signing rewrite with an unsupported commit header to fail closed.'
    }

    $duplicateAuthorPath = Join-Path $tempRoot 'duplicate-author.commit'
    $duplicateAuthorCommit = @(
        "tree $baseTree",
        "parent $baseSha",
        'author First Author <first@example.invalid> 1700000000 +0000',
        'author Second Author <second@example.invalid> 1700000001 +0000',
        'committer Metadata Fixture <fixture@example.invalid> 1700000002 +0000',
        '',
        'duplicate author fixture'
    ) -join [char] 10

    [System.IO.File]::WriteAllText(
        $duplicateAuthorPath,
        $duplicateAuthorCommit,
        [System.Text.UTF8Encoding]::new($false)
    )

    $duplicateAuthorSha = (
        Invoke-Checked -FilePath 'git' -Arguments @(
            'hash-object',
            '-t',
            'commit',
            '-w',
            '--literally',
            $duplicateAuthorPath
        ) -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    $duplicateAuthorParameters = @{
        RepositoryPath = $workRepo
        BaseSha = $baseSha
        HeadSha = $duplicateAuthorSha
        BranchName = 'duplicate-author-fixture'
        TrustedPublicKey = "$signingKey.pub"
        SigningKey = $signingKey
    }

    $duplicateAuthorRejected = $false
    try {
        & $gateScript @duplicateAuthorParameters | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike "*exactly one 'author' header*") {
            throw
        }

        $duplicateAuthorRejected = $true
    }

    if (-not $duplicateAuthorRejected) {
        throw 'Expected duplicate author metadata to be rejected before signing rewrite.'
    }

    $nonCanonicalIdentityPath = Join-Path $tempRoot 'noncanonical-identity.commit'
    $nonCanonicalIdentityCommit = @(
        "tree $baseTree",
        "parent $baseSha",
        'author   Spaced  Author <spaced@example.invalid> 01700000000 +0000',
        'committer Metadata Fixture <fixture@example.invalid> 1700000002 +0000',
        '',
        'noncanonical identity fixture'
    ) -join [char] 10

    [System.IO.File]::WriteAllText(
        $nonCanonicalIdentityPath,
        $nonCanonicalIdentityCommit,
        [System.Text.UTF8Encoding]::new($false)
    )

    $nonCanonicalIdentitySha = (
        Invoke-Checked -FilePath 'git' -Arguments @(
            'hash-object',
            '-t',
            'commit',
            '-w',
            '--literally',
            $nonCanonicalIdentityPath
        ) -WorkingDirectory $workRepo |
        Select-Object -First 1
    ).Trim()

    $nonCanonicalIdentityParameters = @{
        RepositoryPath = $workRepo
        BaseSha = $baseSha
        HeadSha = $nonCanonicalIdentitySha
        BranchName = 'noncanonical-identity-fixture'
        TrustedPublicKey = "$signingKey.pub"
        SigningKey = $signingKey
    }

    $nonCanonicalIdentityRejected = $false
    try {
        & $gateScript @nonCanonicalIdentityParameters | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike '*changed the raw author header*') {
            throw
        }

        $nonCanonicalIdentityRejected = $true
    }

    if (-not $nonCanonicalIdentityRejected) {
        throw 'Expected non-canonical raw author metadata to fail closed rather than be normalized.'
    }

    Write-Host '[PASS] preserve mode keeps commit count and commit subjects'
    Write-Host '[PASS] final tree is unchanged'
    Write-Host '[PASS] every rewritten commit verifies with the trusted SSH key'
    Write-Host '[PASS] real remote-head race is rejected before lease-protected update'
    Write-Host '[PASS] unsupported commit headers are rejected instead of being lost during rewrite'
    Write-Host '[PASS] duplicate required commit headers are rejected instead of being collapsed during rewrite'
    Write-Host '[PASS] raw author/committer headers must round-trip byte-for-byte through signing rewrite'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
