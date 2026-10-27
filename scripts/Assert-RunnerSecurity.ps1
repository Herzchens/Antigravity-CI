#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Signing', 'Review', 'Publisher')]
    [string] $Role,

    [string] $TrustedPublicKey,

    [string] $AgyExecutable = 'agy',

    [string] $ForbiddenIdentity,

    [string[]] $ForbiddenIdentities = @(),

    [string] $ExpectedTrustedKeyFingerprint,

    [string] $HomeDirectory = $HOME,

    [string] $ProtectedReadProbeManifest,

    [ValidateRange(1, 99999)]
    [int] $MinimumWindowsBuild = 26100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitConfig {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = @(& git config @Arguments 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Get-PublicKeyFingerprint {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $output = @(& ssh-keygen -lf $Path 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
        throw 'Unable to fingerprint TrustedPublicKey.'
    }

    $line = [string] ($output | Select-Object -First 1)
    $match = [regex]::Match($line, 'SHA256:[A-Za-z0-9+/=]+')
    if (-not $match.Success) {
        throw 'Unable to parse TrustedPublicKey fingerprint.'
    }

    $match.Value
}

function Get-PublicKeyMaterial {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $line = Get-Content -LiteralPath $resolved -TotalCount 1 -ErrorAction Stop
    $parts = @($line.Trim() -split '\s+')

    if ($parts.Count -lt 2 -or
        $parts[0] -notmatch '^(ssh-|ecdsa-|sk-)' -or
        $parts[1] -notmatch '^[A-Za-z0-9+/=]+$') {
        throw 'TrustedPublicKey is not a valid SSH public key.'
    }

    "$($parts[0]) $($parts[1])"
}

if (-not $IsWindows) {
    throw 'Antigravity-CI self-hosted runner roles currently require Windows.'
}

if ([Environment]::OSVersion.Version.Build -lt $MinimumWindowsBuild) {
    throw "Windows build $([Environment]::OSVersion.Version.Build) is below the configured sandbox baseline $MinimumWindowsBuild."
}

$null = Get-Command git -ErrorAction Stop
$null = Get-Command ssh-keygen -ErrorAction Stop

$trustedKey = $null
$trustedFingerprint = $null

if ($Role -in @('Signing', 'Review')) {
    if ([string]::IsNullOrWhiteSpace($TrustedPublicKey)) {
        throw "TrustedPublicKey is required for runner role '$Role'."
    }

    $trustedKey = Get-PublicKeyMaterial -Path $TrustedPublicKey
    $trustedKeyPath = (Resolve-Path -LiteralPath $TrustedPublicKey -ErrorAction Stop).Path
    $trustedFingerprint = Get-PublicKeyFingerprint -Path $trustedKeyPath

    if (-not [string]::IsNullOrWhiteSpace($ExpectedTrustedKeyFingerprint) -and
        $trustedFingerprint -cne $ExpectedTrustedKeyFingerprint) {
        throw "Trusted public-key fingerprint '$trustedFingerprint' does not match expected fingerprint '$ExpectedTrustedKeyFingerprint'."
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($ExpectedTrustedKeyFingerprint)) {
    throw 'ExpectedTrustedKeyFingerprint is not valid for the Publisher role.'
}

$runnerIdentity = [Environment]::MachineName + '\' + [Environment]::UserName
$forbidden = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

if (-not [string]::IsNullOrWhiteSpace($ForbiddenIdentity)) {
    [void] $forbidden.Add($ForbiddenIdentity)
}

foreach ($identity in @($ForbiddenIdentities)) {
    if (-not [string]::IsNullOrWhiteSpace($identity)) {
        [void] $forbidden.Add($identity)
    }
}

if ($forbidden.Contains($runnerIdentity)) {
    throw "Runner identity '$runnerIdentity' is forbidden for role '$Role'."
}

if ($Role -eq 'Signing') {

    $format = Invoke-GitConfig -Arguments @('--global', '--get', 'gpg.format')
    if ($format.ExitCode -ne 0 -or
        (($format.Output | Select-Object -First 1).Trim() -cne 'ssh')) {
        throw 'Signing runner must configure global gpg.format=ssh.'
    }

    $commitSigning = Invoke-GitConfig -Arguments @('--global', '--get', 'commit.gpgsign')
    if ($commitSigning.ExitCode -ne 0 -or
        (($commitSigning.Output | Select-Object -First 1).Trim().ToLowerInvariant() -ne 'true')) {
        throw 'Signing runner must configure global commit.gpgsign=true.'
    }

    $agentOutput = @(& ssh-add -L 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Signing runner cannot read an SSH agent identity.'
    }

    $agentKeys = @(
        $agentOutput |
        ForEach-Object { [string] $_ } |
        Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' } |
        ForEach-Object {
            $parts = @($_.Trim() -split '\s+')
            if ($parts.Count -ge 2) {
                "$($parts[0]) $($parts[1])"
            }
        }
    )

    if ($agentKeys -cnotcontains $trustedKey) {
        throw 'Trusted signing key is not loaded in the signing runner SSH agent.'
    }

    [pscustomobject][ordered]@{
        Role = 'Signing'
        WindowsBuild = [Environment]::OSVersion.Version.Build
        User = [Environment]::UserName
        Identity = $runnerIdentity
        TrustedKeyFingerprint = $trustedFingerprint
        TrustedKeyLoaded = $true
        Valid = $true
    }

    return
}

$agentOutput = @(& ssh-add -L 2>&1)
$agentExitCode = $LASTEXITCODE
$agentKeys = @(
    $agentOutput |
    ForEach-Object { [string] $_ } |
    Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' }
)

if ($agentExitCode -eq 0 -and $agentKeys.Count -gt 0) {
    throw "Non-signing runner role '$Role' exposes SSH agent identities. Use a separate Windows account without signing-agent access."
}

$globalSigningKey = Invoke-GitConfig -Arguments @('--global', '--get', 'user.signingkey')
if ($globalSigningKey.ExitCode -eq 0 -and
    -not [string]::IsNullOrWhiteSpace(($globalSigningKey.Output | Select-Object -First 1))) {
    throw "Non-signing runner role '$Role' must not have a global Git signing key configured."
}

$globalCommitSigning = Invoke-GitConfig -Arguments @('--global', '--get', 'commit.gpgsign')
if ($globalCommitSigning.ExitCode -eq 0 -and
    (($globalCommitSigning.Output | Select-Object -First 1).Trim().ToLowerInvariant() -eq 'true')) {
    throw "Non-signing runner role '$Role' must not enable global commit signing."
}

$resolvedHomeDirectory = [System.IO.Path]::GetFullPath($HomeDirectory)

$defaultPrivateKeyCandidates = @(
    (Join-Path $resolvedHomeDirectory '.ssh\id_ed25519'),
    (Join-Path $resolvedHomeDirectory '.ssh\id_rsa'),
    (Join-Path $resolvedHomeDirectory '.ssh\id_ecdsa'),
    (Join-Path $resolvedHomeDirectory '.ssh\id_dsa')
)

foreach ($candidate in $defaultPrivateKeyCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        throw "Non-signing runner role '$Role' exposes a default SSH private-key path: $candidate"
    }
}

foreach ($name in @(
    'GITHUB_TOKEN',
    'GH_TOKEN',
    'AGY_REPORTER_TOKEN',
    'SSH_AUTH_SOCK',
    'SSH_AGENT_PID'
)) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Non-signing runner role '$Role' found unexpected sensitive environment variable '$name'."
    }
}

if ($Role -eq 'Publisher') {
    [pscustomobject][ordered]@{
        Role = 'Publisher'
        WindowsBuild = [Environment]::OSVersion.Version.Build
        User = [Environment]::UserName
        Identity = $runnerIdentity
        SshAgentIdentityCount = $agentKeys.Count
        Valid = $true
    }

    return
}

$hostPolicy = Join-Path $PSScriptRoot 'Assert-AgyHostPolicy.ps1'
if (-not (Test-Path -LiteralPath $hostPolicy -PathType Leaf)) {
    throw 'Assert-AgyHostPolicy.ps1 is required next to Assert-RunnerSecurity.ps1.'
}
$hostPolicyResult = & $hostPolicy -HomeDirectory $resolvedHomeDirectory

$filesystemBoundary = Join-Path $PSScriptRoot 'Test-ReviewFilesystemBoundary.ps1'
if (-not (Test-Path -LiteralPath $filesystemBoundary -PathType Leaf)) {
    throw 'Test-ReviewFilesystemBoundary.ps1 is required next to Assert-RunnerSecurity.ps1.'
}

if ([string]::IsNullOrWhiteSpace($ProtectedReadProbeManifest)) {
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw 'Unable to resolve ProgramData for the protected-read probe manifest.'
    }

    $ProtectedReadProbeManifest = Join-Path $programData 'Antigravity-CI\review-policy\protected-read-probes.json'
}

$filesystemBoundaryResult = & $filesystemBoundary `
    -ManifestPath $ProtectedReadProbeManifest `
    -HomeDirectory $resolvedHomeDirectory

$agyCommand = Get-Command $AgyExecutable -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
$agyPath = [System.IO.Path]::GetFullPath($agyCommand.Source)

$helpOutput = @(& $agyPath --help 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw 'Antigravity CLI --help failed on the review runner.'
}

$helpText = $helpOutput -join [Environment]::NewLine
foreach ($requiredFlag in @(
    '--output-format',
    '--json-schema',
    '--print-timeout',
    '--sandbox',
    '--disable-slash-commands'
)) {
    if (-not $helpText.Contains($requiredFlag, [StringComparison]::Ordinal)) {
        throw "Antigravity CLI does not advertise required flag '$requiredFlag'."
    }
}

[pscustomobject][ordered]@{
    Role = 'Review'
    WindowsBuild = [Environment]::OSVersion.Version.Build
    User = [Environment]::UserName
    Identity = $runnerIdentity
    AgyPath = $agyPath
    TrustedKeyFingerprint = $trustedFingerprint
    SshAgentIdentityCount = $agentKeys.Count
    AgySettingsSha256 = $hostPolicyResult.SettingsSha256
    ProtectedReadProbeCount = $filesystemBoundaryResult.ProbeCount
    Valid = $true
    SandboxRuntimeStillRequiresSmokeTest = $true
}
