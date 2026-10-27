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
$verificationScript = Join-Path $repoRoot 'scripts\Test-CommitSignature.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-signature-test-' + [Guid]::NewGuid().ToString('N')
)
$fixtureRepo = Join-Path $tempRoot 'repo'
$signingKey = Join-Path $tempRoot 'signing_key'
$wrongKey = Join-Path $tempRoot 'wrong_key'

New-Item -ItemType Directory -Path $fixtureRepo -Force | Out-Null

try {
    Invoke-Checked -FilePath 'ssh-keygen' -Arguments @('-q', '-t', 'ed25519', '-N', '', '-f', $signingKey)
    Invoke-Checked -FilePath 'ssh-keygen' -Arguments @('-q', '-t', 'ed25519', '-N', '', '-f', $wrongKey)

    Invoke-Checked -FilePath 'git' -Arguments @('init', '--quiet') -WorkingDirectory $fixtureRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.name', 'Antigravity CI Fixture') -WorkingDirectory $fixtureRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.email', 'fixture@example.invalid') -WorkingDirectory $fixtureRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'gpg.format', 'ssh') -WorkingDirectory $fixtureRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'gpg.ssh.program', $sshKeygenProgram) -WorkingDirectory $fixtureRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'user.signingkey', $signingKey) -WorkingDirectory $fixtureRepo
    Invoke-Checked -FilePath 'git' -Arguments @('config', 'commit.gpgsign', 'true') -WorkingDirectory $fixtureRepo

    Set-Content -LiteralPath (Join-Path $fixtureRepo 'fixture.txt') -Value 'signed' -Encoding utf8NoBOM
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'fixture.txt') -WorkingDirectory $fixtureRepo
    Invoke-Checked -FilePath 'git' -Arguments @('commit', '--quiet', '-m', 'signed fixture') -WorkingDirectory $fixtureRepo

    $signedSha = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $fixtureRepo |
        Select-Object -First 1
    ).Trim()

    $result = & $verificationScript -RepositoryPath $fixtureRepo -CommitSha $signedSha -SigningKey "$signingKey.pub"

    if (-not $result.Valid) {
        throw 'Expected signed commit to validate.'
    }

    $wrongKeyRejected = $false
    try {
        & $verificationScript -RepositoryPath $fixtureRepo -CommitSha $signedSha -SigningKey "$wrongKey.pub" | Out-Null
    }
    catch {
        $wrongKeyRejected = $true
    }

    if (-not $wrongKeyRejected) {
        throw 'Expected verification with a different SSH key to fail.'
    }

    Add-Content -LiteralPath (Join-Path $fixtureRepo 'fixture.txt') -Value 'unsigned'
    Invoke-Checked -FilePath 'git' -Arguments @('add', 'fixture.txt') -WorkingDirectory $fixtureRepo
    Invoke-Checked -FilePath 'git' -Arguments @('-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'unsigned fixture') -WorkingDirectory $fixtureRepo

    $unsignedSha = (
        Invoke-Checked -FilePath 'git' -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $fixtureRepo |
        Select-Object -First 1
    ).Trim()

    $unsignedRejected = $false
    try {
        & $verificationScript -RepositoryPath $fixtureRepo -CommitSha $unsignedSha -SigningKey "$signingKey.pub" | Out-Null
    }
    catch {
        $unsignedRejected = $true
    }

    if (-not $unsignedRejected) {
        throw 'Expected unsigned commit verification to fail.'
    }

    Write-Host '[PASS] trusted SSH-signed commit accepted'
    Write-Host '[PASS] commit signed by another SSH key rejected'
    Write-Host '[PASS] unsigned commit rejected'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
