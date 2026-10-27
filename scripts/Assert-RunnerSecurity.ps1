#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Signing', 'Review', 'Publisher')]
    [string] $Role,

    [string] $TrustedPublicKey,

    [string] $AgyExecutable = 'agy',

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedAgySha256,

    [string] $ForbiddenIdentity,

    [string[]] $ForbiddenIdentities = @(),

    [string] $ExpectedTrustedKeyFingerprint,

    [string] $HomeDirectory = $HOME,

    [string] $ProtectedReadProbeManifest,

    [switch] $RequireGitIsolation,

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

function Assert-GitIsolation {
    $globalConfig = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL')
    $noSystem = [Environment]::GetEnvironmentVariable('GIT_CONFIG_NOSYSTEM')
    $configCount = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT')
    $configParameters = [Environment]::GetEnvironmentVariable('GIT_CONFIG_PARAMETERS')
    $attrNoSystem = [Environment]::GetEnvironmentVariable('GIT_ATTR_NOSYSTEM')
    $templateDirectory = [Environment]::GetEnvironmentVariable('GIT_TEMPLATE_DIR')
    $isolationRoot = [Environment]::GetEnvironmentVariable('ANTIGRAVITY_GIT_ISOLATION_ROOT')

    if ($noSystem -cne '1') {
        throw 'Git isolation requires GIT_CONFIG_NOSYSTEM=1.'
    }

    if (-not [string]::IsNullOrWhiteSpace($configCount) -and $configCount -cne '0') {
        throw 'Git isolation requires GIT_CONFIG_COUNT=0 before privileged work.'
    }

    if (-not [string]::IsNullOrWhiteSpace($configParameters)) {
        throw 'Git isolation requires GIT_CONFIG_PARAMETERS to be empty.'
    }

    if ($attrNoSystem -cne '1') {
        throw 'Git isolation requires GIT_ATTR_NOSYSTEM=1.'
    }

    if ([string]::IsNullOrWhiteSpace($isolationRoot) -or
        -not (Test-Path -LiteralPath $isolationRoot -PathType Container)) {
        throw 'Git isolation root is missing.'
    }

    $root = [System.IO.Path]::GetFullPath($isolationRoot)

    function Assert-WithinIsolationRoot {
        param(
            [Parameter(Mandatory)]
            [string] $Path,

            [Parameter(Mandatory)]
            [string] $Name
        )

        $full = [System.IO.Path]::GetFullPath($Path)
        $relative = [System.IO.Path]::GetRelativePath($root, $full)

        if ($relative -eq '.' -or
            [System.IO.Path]::IsPathRooted($relative) -or
            $relative -eq '..' -or
            $relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
            throw "$Name must be a child of the Git isolation root."
        }

        $full
    }

    if ([string]::IsNullOrWhiteSpace($globalConfig) -or
        -not (Test-Path -LiteralPath $globalConfig -PathType Leaf)) {
        throw 'Git isolation requires an explicit global configuration file.'
    }

    $globalConfigPath = Assert-WithinIsolationRoot -Path $globalConfig -Name 'GIT_CONFIG_GLOBAL'

    if ([string]::IsNullOrWhiteSpace($templateDirectory) -or
        -not (Test-Path -LiteralPath $templateDirectory -PathType Container)) {
        throw 'Git isolation requires an explicit template directory.'
    }

    $templatePath = Assert-WithinIsolationRoot -Path $templateDirectory -Name 'GIT_TEMPLATE_DIR'
    if (@(Get-ChildItem -LiteralPath $templatePath -Force -ErrorAction Stop).Count -ne 0) {
        throw 'Git isolation template directory must be empty.'
    }

    $allowedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in @('core.hookspath', 'core.attributesfile', 'credential.interactive')) {
        [void] $allowedNames.Add($name)
    }

    $configuredNames = @(& git config --global --name-only --list 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate isolated global Git configuration.'
    }

    foreach ($nameLine in $configuredNames) {
        $name = ([string] $nameLine).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (-not $allowedNames.Contains($name)) {
            throw "Git isolation contains unexpected global option '$name'."
        }
    }

    $hooks = Invoke-GitConfig -Arguments @('--global', '--get', 'core.hookspath')
    if ($hooks.ExitCode -ne 0 -or $hooks.Output.Count -eq 0) {
        throw 'Git isolation requires an explicit hooks path.'
    }

    $hooksPath = Assert-WithinIsolationRoot -Path ([string] ($hooks.Output | Select-Object -First 1)) -Name 'core.hooksPath'
    if (-not (Test-Path -LiteralPath $hooksPath -PathType Container) -or
        @(Get-ChildItem -LiteralPath $hooksPath -Force -ErrorAction Stop).Count -ne 0) {
        throw 'Git isolation hooks directory must exist and be empty.'
    }

    $attributes = Invoke-GitConfig -Arguments @('--global', '--get', 'core.attributesfile')
    if ($attributes.ExitCode -ne 0 -or $attributes.Output.Count -eq 0) {
        throw 'Git isolation requires an explicit attributes file.'
    }

    $attributesPath = Assert-WithinIsolationRoot -Path ([string] ($attributes.Output | Select-Object -First 1)) -Name 'core.attributesFile'
    if (-not (Test-Path -LiteralPath $attributesPath -PathType Leaf) -or
        (Get-Item -LiteralPath $attributesPath -ErrorAction Stop).Length -ne 0) {
        throw 'Git isolation attributes file must exist and be empty.'
    }

    $interactive = Invoke-GitConfig -Arguments @('--global', '--get', 'credential.interactive')
    if ($interactive.ExitCode -ne 0 -or
        (($interactive.Output | Select-Object -First 1).Trim().ToLowerInvariant() -ne 'false')) {
        throw 'Git isolation must disable interactive credential helpers.'
    }

    [pscustomobject][ordered]@{
        Root = $root
        GlobalConfig = $globalConfigPath
        HooksPath = $hooksPath
        AttributesPath = $attributesPath
        TemplateDirectory = $templatePath
        GitIsolationValid = ($null -ne $gitIsolation -and $gitIsolation.Valid)
        Valid = $true
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

$gitIsolation = $null
if ($RequireGitIsolation) {
    $gitIsolation = Assert-GitIsolation
}

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
        GitIsolationValid = ($null -ne $gitIsolation -and $gitIsolation.Valid)
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
        GitIsolationValid = ($null -ne $gitIsolation -and $gitIsolation.Valid)
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

if ([string]::IsNullOrWhiteSpace($ExpectedAgySha256)) {
    throw 'Review runner security preflight requires ExpectedAgySha256.'
}

$expectedAgyHash = $ExpectedAgySha256.ToLowerInvariant()
$agyCommand = Get-Command $AgyExecutable -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
$agyPath = [System.IO.Path]::GetFullPath($agyCommand.Source)

$agyHashBeforeHelp = (
    Get-FileHash -LiteralPath $agyPath -Algorithm SHA256 -ErrorAction Stop
).Hash.ToLowerInvariant()

if ($agyHashBeforeHelp -cne $expectedAgyHash) {
    throw "Antigravity CLI SHA-256 '$agyHashBeforeHelp' does not match the expected pinned hash."
}

$previousAutoUpdate = [Environment]::GetEnvironmentVariable('AGY_CLI_DISABLE_AUTO_UPDATE')
try {
    $env:AGY_CLI_DISABLE_AUTO_UPDATE = 'true'
    $helpOutput = @(& $agyPath --help 2>&1)
    $helpExitCode = $LASTEXITCODE
}
finally {
    if ($null -eq $previousAutoUpdate) {
        Remove-Item Env:AGY_CLI_DISABLE_AUTO_UPDATE -ErrorAction SilentlyContinue
    }
    else {
        $env:AGY_CLI_DISABLE_AUTO_UPDATE = $previousAutoUpdate
    }
}

if ($helpExitCode -ne 0) {
    throw 'Antigravity CLI --help failed on the review runner.'
}

$agyHashAfterHelp = (
    Get-FileHash -LiteralPath $agyPath -Algorithm SHA256 -ErrorAction Stop
).Hash.ToLowerInvariant()

if ($agyHashAfterHelp -cne $expectedAgyHash) {
    throw 'Antigravity CLI changed while running the security preflight.'
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
    AgySha256 = $agyHashAfterHelp
    TrustedKeyFingerprint = $trustedFingerprint
    SshAgentIdentityCount = $agentKeys.Count
    AgySettingsSha256 = $hostPolicyResult.SettingsSha256
    ProtectedReadProbeCount = $filesystemBoundaryResult.ProbeCount
    Valid = $true
    SandboxRuntimeStillRequiresSmokeTest = $true
}
