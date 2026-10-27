#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    Write-Host '[SKIP] runner security fixture requires Windows'
    return
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$preflight = Join-Path $repoRoot 'scripts\Assert-RunnerSecurity.ps1'

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,
        [Parameter(Mandatory)]
        [string] $Name
    )

    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        throw "Expected failure: $Name"
    }

    Write-Host "[PASS] $Name"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-runner-security-' + [Guid]::NewGuid().ToString('N')
)
$fakeBin = Join-Path $tempRoot 'bin'
$fakeHome = Join-Path $tempRoot 'review-home'
$gitIsolationRoot = Join-Path $tempRoot 'git-isolation'
$globalConfig = Join-Path $gitIsolationRoot 'global.gitconfig'
$attributesPath = Join-Path $gitIsolationRoot 'empty.gitattributes'
$hooksPath = Join-Path $gitIsolationRoot 'empty-hooks'
$templatePath = Join-Path $gitIsolationRoot 'empty-template'
$keyPath = Join-Path $tempRoot 'trusted-key'
$fakeSshAdd = Join-Path $fakeBin 'ssh-add.cmd'
$fakeAgy = Join-Path $fakeBin 'agy.cmd'
$protectedDirectory = Join-Path $tempRoot 'owner-private'
$protectedSentinel = Join-Path $protectedDirectory 'sentinel.txt'
$policyDirectory = Join-Path $tempRoot 'review-policy'
$probeManifest = Join-Path $policyDirectory 'protected-read-probes.json'
$fixtureIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
New-Item -ItemType Directory -Path $gitIsolationRoot -Force | Out-Null
New-Item -ItemType Directory -Path $hooksPath -Force | Out-Null
New-Item -ItemType Directory -Path $templatePath -Force | Out-Null

$settingsDir = Join-Path $fakeHome '.gemini\antigravity-cli'
$settingsPath = Join-Path $settingsDir 'settings.json'
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
$settingsFixture = [ordered]@{
    enableTerminalSandbox = $true
    toolPermission = 'proceed-in-sandbox'
    allowNonWorkspaceAccess = $false
    historySize = 0
    disableSlashCommands = $true
    permissions = [ordered]@{ allow = @() }
}
$settingsFixture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $settingsPath -Encoding utf8NoBOM

New-Item -ItemType Directory -Path $protectedDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $policyDirectory -Force | Out-Null
Set-Content -LiteralPath $protectedSentinel -Value 'fixture sentinel' -Encoding utf8NoBOM

[ordered]@{
    schema_version = 1
    probes = @(
        [ordered]@{
            name = 'fixture-owner-private'
            path = $protectedSentinel
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $probeManifest -Encoding utf8NoBOM

foreach ($aclTarget in @(
    @{ Path = $protectedSentinel; Rights = 'R' },
    @{ Path = $protectedDirectory; Rights = 'W' },
    @{ Path = $probeManifest; Rights = 'W' },
    @{ Path = $policyDirectory; Rights = 'W' }
)) {
    $denySpec = $fixtureIdentity + ':(' + $aclTarget.Rights + ')'
    & icacls.exe $aclTarget.Path /deny $denySpec | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to create ACL-denied filesystem-boundary fixture.'
    }
}

$oldPath = $env:PATH
$oldEnvironment = @{}
foreach ($name in @(
    'GIT_CONFIG_GLOBAL',
    'GIT_CONFIG_NOSYSTEM',
    'GIT_CONFIG_COUNT',
    'GIT_CONFIG_PARAMETERS',
    'GIT_ATTR_NOSYSTEM',
    'GIT_TEMPLATE_DIR',
    'ANTIGRAVITY_GIT_ISOLATION_ROOT',
    'GITHUB_TOKEN',
    'GH_TOKEN',
    'AGY_REPORTER_TOKEN',
    'SSH_AUTH_SOCK',
    'SSH_AGENT_PID'
)) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    & ssh-keygen -q -t ed25519 -N '' -f $keyPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to create runner-security fixture key.'
    }

    $publicLine = Get-Content -LiteralPath "$keyPath.pub" -TotalCount 1
    $fingerprintLine = @(& ssh-keygen -lf "$keyPath.pub" 2>&1) | Select-Object -First 1
    $fingerprint = [regex]::Match([string] $fingerprintLine, 'SHA256:[A-Za-z0-9+/=]+').Value

    if ([string]::IsNullOrWhiteSpace($fingerprint)) {
        throw 'Unable to resolve fixture key fingerprint.'
    }

    @"
@echo off
echo --output-format
echo --json-schema
echo --print-timeout
echo --sandbox
echo --disable-slash-commands
exit /b 0
"@ | Set-Content -LiteralPath $fakeAgy -Encoding ascii
    $fakeAgyBytes = [System.IO.File]::ReadAllBytes($fakeAgy)
    $fakeAgySha256 = (
        Get-FileHash -LiteralPath $fakeAgy -Algorithm SHA256 -ErrorAction Stop
    ).Hash.ToLowerInvariant()

    $env:PATH = "$fakeBin;$oldPath"
    $env:GIT_CONFIG_GLOBAL = $globalConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_COUNT = '0'
    $env:GIT_CONFIG_PARAMETERS = ''
    $env:GIT_ATTR_NOSYSTEM = '1'
    $env:GIT_TEMPLATE_DIR = $templatePath
    $env:ANTIGRAVITY_GIT_ISOLATION_ROOT = $gitIsolationRoot

    foreach ($name in @('GITHUB_TOKEN', 'GH_TOKEN', 'AGY_REPORTER_TOKEN', 'SSH_AUTH_SOCK', 'SSH_AGENT_PID')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }

    @"
@echo off
echo Error connecting to agent: No such file or directory 1>&2
exit /b 2
"@ | Set-Content -LiteralPath $fakeSshAdd -Encoding ascii

    [System.IO.File]::WriteAllText(
        $globalConfig,
        '',
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $attributesPath,
        '',
        [System.Text.UTF8Encoding]::new($false)
    )

    & git config --file $globalConfig core.hooksPath $hooksPath
    & git config --file $globalConfig core.attributesFile $attributesPath
    & git config --file $globalConfig credential.interactive false
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to initialize Git isolation fixture.'
    }

    $reviewParameters = @{
        Role = 'Review'
        TrustedPublicKey = "$keyPath.pub"
        AgyExecutable = $fakeAgy
        ExpectedAgySha256 = $fakeAgySha256
        HomeDirectory = $fakeHome
        ProtectedReadProbeManifest = $probeManifest
        MinimumWindowsBuild = 1
        RequireGitIsolation = $true
    }

    $review = & $preflight @reviewParameters

    if (-not $review.Valid -or
        $review.TrustedKeyFingerprint -ne $fingerprint -or
        $review.ProtectedReadProbeCount -ne 1) {
        throw 'Clean review fixture did not pass the runner-security preflight.'
    }

    Write-Host '[PASS] isolated review account fixture passes with public key only'

    Add-Content -LiteralPath $fakeAgy -Value 'rem tampered' -Encoding ascii
    Assert-Throws -Name 'review role rejects a modified Antigravity executable' -Action {
        & $preflight @reviewParameters
    }
    [System.IO.File]::WriteAllBytes($fakeAgy, $fakeAgyBytes)

    Write-Host '[PASS] review role pins the Antigravity executable SHA-256 before execution'

    & git config --file $globalConfig filter.evil.smudge 'cmd.exe /c exit 0'
    Assert-Throws -Name 'runner preflight rejects injected global Git filter drivers' -Action {
        & $preflight @reviewParameters
    }
    & git config --file $globalConfig --unset-all filter.evil.smudge

    Write-Host '[PASS] Git host isolation rejects execution-capable global filter configuration'

    $publisherParameters = @{
        Role = 'Publisher'
        AgyExecutable = 'publisher-does-not-require-agy'
        HomeDirectory = $fakeHome
        MinimumWindowsBuild = 1
        ForbiddenIdentities = @('OTHER-HOST\OtherUser')
        RequireGitIsolation = $true
    }

    $publisher = & $preflight @publisherParameters

    if (-not $publisher.Valid -or $publisher.Role -ne 'Publisher') {
        throw 'Clean publisher fixture did not pass the runner-security preflight.'
    }

    Write-Host '[PASS] isolated publisher role requires no AGY executable or signing key'

    $publisherSameIdentity = $publisherParameters.Clone()
    $publisherSameIdentity.ForbiddenIdentities = @($publisher.Identity)

    Assert-Throws -Name 'publisher role rejects reuse of a forbidden runner identity' -Action {
        & $preflight @publisherSameIdentity
    }

    $env:AGY_REPORTER_TOKEN = 'fixture-secret'
    Assert-Throws -Name 'publisher preflight rejects reporter token materialized too early' -Action {
        & $preflight @publisherParameters
    }
    Remove-Item Env:AGY_REPORTER_TOKEN -ErrorAction SilentlyContinue

    $sameIdentityParameters = $reviewParameters.Clone()
    $sameIdentityParameters.ForbiddenIdentity = $review.Identity

    Assert-Throws -Name 'review role rejects the signing runner identity' -Action {
        & $preflight @sameIdentityParameters
    }

    $wrongFingerprintParameters = $reviewParameters.Clone()
    $wrongFingerprintParameters.ExpectedTrustedKeyFingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'

    Assert-Throws -Name 'review role rejects a mismatched trusted-key fingerprint' -Action {
        & $preflight @wrongFingerprintParameters
    }

    New-Item -ItemType Directory -Path (Join-Path $fakeHome '.ssh') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeHome '.ssh\id_ed25519') -Value 'fixture-private-key' -Encoding ascii

    Assert-Throws -Name 'review role rejects default private-key material' -Action {
        & $preflight @reviewParameters
    }

    Remove-Item -LiteralPath (Join-Path $fakeHome '.ssh\id_ed25519') -Force

    @"
@echo off
echo $publicLine
exit /b 0
"@ | Set-Content -LiteralPath $fakeSshAdd -Encoding ascii

    Assert-Throws -Name 'review role rejects an accessible SSH agent identity' -Action {
        & $preflight @reviewParameters
    }

    $signingParameters = @{
        Role = 'Signing'
        TrustedPublicKey = "$keyPath.pub"
        HomeDirectory = $fakeHome
        MinimumWindowsBuild = 1
        RequireGitIsolation = $true
    }

    $signing = & $preflight @signingParameters

    if (-not $signing.Valid -or
        -not $signing.TrustedKeyLoaded -or
        $signing.TrustedKeyFingerprint -ne $fingerprint) {
        throw 'Signing fixture did not pass expected security checks.'
    }

    Write-Host '[PASS] signing role requires the trusted key in its SSH agent without ambient signing config'
}
finally {
    foreach ($aclPath in @($protectedSentinel, $protectedDirectory, $probeManifest, $policyDirectory)) {
        if (Test-Path -LiteralPath $aclPath) {
            & icacls.exe $aclPath /remove:d $fixtureIdentity | Out-Null
        }
    }

    $env:PATH = $oldPath

    foreach ($name in $oldEnvironment.Keys) {
        if ($null -eq $oldEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -LiteralPath "Env:$name" -Value $oldEnvironment[$name]
        }
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
