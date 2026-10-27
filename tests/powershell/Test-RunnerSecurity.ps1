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
$globalConfig = Join-Path $tempRoot 'global.gitconfig'
$keyPath = Join-Path $tempRoot 'trusted-key'
$fakeSshAdd = Join-Path $fakeBin 'ssh-add.cmd'
$fakeAgy = Join-Path $fakeBin 'agy.cmd'

New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null

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

$oldPath = $env:PATH
$oldGlobalConfig = $env:GIT_CONFIG_GLOBAL
$oldSensitive = @{}
foreach ($name in @('GITHUB_TOKEN', 'GH_TOKEN', 'AGY_REPORTER_TOKEN', 'SSH_AUTH_SOCK', 'SSH_AGENT_PID')) {
    $oldSensitive[$name] = [Environment]::GetEnvironmentVariable($name)
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

    $env:PATH = "$fakeBin;$oldPath"
    $env:GIT_CONFIG_GLOBAL = $globalConfig

    foreach ($name in $oldSensitive.Keys) {
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

    $reviewParameters = @{
        Role = 'Review'
        TrustedPublicKey = "$keyPath.pub"
        AgyExecutable = $fakeAgy
        HomeDirectory = $fakeHome
        MinimumWindowsBuild = 1
    }

    $review = & $preflight @reviewParameters

    if (-not $review.Valid -or $review.TrustedKeyFingerprint -ne $fingerprint) {
        throw 'Clean review fixture did not pass the runner-security preflight.'
    }

    Write-Host '[PASS] isolated review account fixture passes with public key only'

    $publisherParameters = @{
        Role = 'Publisher'
        AgyExecutable = 'publisher-does-not-require-agy'
        HomeDirectory = $fakeHome
        MinimumWindowsBuild = 1
        ForbiddenIdentities = @('OTHER-HOST\OtherUser')
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

    @"
[gpg]
    format = ssh
[commit]
    gpgsign = true
"@ | Set-Content -LiteralPath $globalConfig -Encoding utf8NoBOM

    $signingParameters = @{
        Role = 'Signing'
        TrustedPublicKey = "$keyPath.pub"
        HomeDirectory = $fakeHome
        MinimumWindowsBuild = 1
    }

    $signing = & $preflight @signingParameters

    if (-not $signing.Valid -or
        -not $signing.TrustedKeyLoaded -or
        $signing.TrustedKeyFingerprint -ne $fingerprint) {
        throw 'Signing fixture did not pass expected security checks.'
    }

    Write-Host '[PASS] signing role requires the trusted key in its SSH agent'
}
finally {
    $env:PATH = $oldPath

    if ($null -eq $oldGlobalConfig) {
        Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
    }
    else {
        $env:GIT_CONFIG_GLOBAL = $oldGlobalConfig
    }

    foreach ($name in $oldSensitive.Keys) {
        if ($null -eq $oldSensitive[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -LiteralPath "Env:$name" -Value $oldSensitive[$name]
        }
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
