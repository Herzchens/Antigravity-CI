#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $CommitSha,

    [string] $RepositoryPath = '.',

    [string] $SigningKey,

    [ValidatePattern('^[A-Za-z0-9@._+-]+$')]
    [string] $Principal = 'antigravity-ci'
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

function Get-PublicKeyMaterial {
    param(
        [Parameter(Mandatory)]
        [string] $ConfiguredKey
    )

    if ($ConfiguredKey.StartsWith('key::', [StringComparison]::Ordinal)) {
        $candidate = $ConfiguredKey.Substring(5).Trim()
    }
    else {
        $resolvedKey = Resolve-Path -LiteralPath $ConfiguredKey -ErrorAction Stop
        $firstLine = Get-Content -LiteralPath $resolvedKey.Path -TotalCount 1 -ErrorAction Stop

        if ($firstLine -match 'BEGIN .*PRIVATE KEY') {
            throw 'Signature verification requires a public key, not a private key file.'
        }

        $candidate = $firstLine.Trim()
    }

    $parts = @($candidate -split '\s+')
    if ($parts.Count -lt 2) {
        throw 'Configured SSH signing key is not a valid public key.'
    }

    $keyType = $parts[0]
    $keyBody = $parts[1]

    if ($keyType -notmatch '^(ssh-|ecdsa-|sk-)') {
        throw 'Configured signing key is not an SSH public key.'
    }

    if ($keyBody -notmatch '^[A-Za-z0-9+/=]+$') {
        throw 'Configured SSH public key body is malformed.'
    }

    "$keyType $keyBody"
}

$null = Get-Command git -ErrorAction Stop
$sshKeygenCommand = Get-Command ssh-keygen -ErrorAction Stop

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
$script:RepositoryRoot = $RepositoryRoot

$configuredSshProgram = (Invoke-Git -Arguments @(
    'config',
    '--get',
    'gpg.ssh.program'
) -AllowFailure).Output | Select-Object -First 1

$sshProgram = if ([string]::IsNullOrWhiteSpace($configuredSshProgram)) {
    $sshKeygenCommand.Source
}
else {
    $configuredSshProgram.Trim()
}

$resolvedCommit = (Invoke-Git -Arguments @(
    'rev-parse',
    '--verify',
    "$CommitSha^{commit}"
)).Output | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($resolvedCommit)) {
    throw 'Unable to resolve commit.'
}

$resolvedCommit = $resolvedCommit.Trim().ToLowerInvariant()
if ($resolvedCommit -ne $CommitSha.ToLowerInvariant()) {
    throw 'Resolved commit does not match the expected SHA.'
}

$format = (Invoke-Git -Arguments @(
    'config',
    '--get',
    'gpg.format'
)).Output | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($format) -or $format.Trim() -ne 'ssh') {
    throw 'Git gpg.format must be ssh on the signing runner.'
}

if ([string]::IsNullOrWhiteSpace($SigningKey)) {
    $SigningKey = (Invoke-Git -Arguments @(
        'config',
        '--get',
        'user.signingkey'
    )).Output | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($SigningKey)) {
        throw 'Git user.signingkey is not configured.'
    }

    $SigningKey = $SigningKey.Trim()
}

$publicKey = Get-PublicKeyMaterial -ConfiguredKey $SigningKey

$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-signature-' + [Guid]::NewGuid().ToString('N')
)
$allowedSignersPath = Join-Path $tempDirectory 'allowed_signers'
$publicKeyPath = Join-Path $tempDirectory 'signing_key.pub'

New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null

try {
    Set-Content -LiteralPath $allowedSignersPath -Value "$Principal $publicKey" -Encoding utf8NoBOM -NoNewline
    Set-Content -LiteralPath $publicKeyPath -Value $publicKey -Encoding ascii -NoNewline

    $fingerprintOutput = @(& ssh-keygen -lf $publicKeyPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to fingerprint the configured SSH public key.'
    }

    $fingerprint = ($fingerprintOutput | Select-Object -First 1).Trim()

    $verification = Invoke-Git -Arguments @(
        '-c',
        'gpg.format=ssh',
        '-c',
        "gpg.ssh.program=$sshProgram",
        '-c',
        "gpg.ssh.allowedSignersFile=$allowedSignersPath",
        'verify-commit',
        $resolvedCommit
    ) -AllowFailure

    if ($verification.ExitCode -ne 0) {
        $detail = ($verification.Output | ForEach-Object { [string] $_ }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = 'git verify-commit returned no diagnostic output.'
        }

        throw "Commit $resolvedCommit failed trusted SSH verification.$([Environment]::NewLine)$detail"
    }

    [pscustomobject]@{
        CommitSha = $resolvedCommit
        SigningFormat = 'ssh'
        Principal = $Principal
        KeyFingerprint = $fingerprint
        Valid = $true
    }
}
finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
