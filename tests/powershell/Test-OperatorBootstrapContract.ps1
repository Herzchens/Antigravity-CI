#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

$profileScriptPath = Join-Path $repoRoot 'scripts\Initialize-RunnerProfiles.ps1'
$verifyScriptPath = Join-Path $repoRoot 'scripts\Verify-OperatorBootstrap.ps1'

if (-not (Test-Path -LiteralPath $profileScriptPath -PathType Leaf)) {
    throw "Required profile initializer script missing: $profileScriptPath"
}
if (-not (Test-Path -LiteralPath $verifyScriptPath -PathType Leaf)) {
    throw "Required verify bootstrap script missing: $verifyScriptPath"
}

$profileScript = Get-Content -LiteralPath $profileScriptPath -Raw -Encoding utf8
$verifyScript = Get-Content -LiteralPath $verifyScriptPath -Raw -Encoding utf8

function Assert-ScriptContains {
    param(
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter(Mandatory)]
        [string] $Needle,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not $Content.Contains($Needle, [StringComparison]::Ordinal)) {
        throw "Contract assertion failed: $Name"
    }

    Write-Host "[PASS] $Name"
}

# Invariants for Initialize-RunnerProfiles.ps1
Assert-ScriptContains -Content $profileScript -Needle 'if (-not $IsWindows)' -Name 'profile initializer enforces Windows host requirement'
Assert-ScriptContains -Content $profileScript -Needle '[string[]] $Accounts' -Name 'profile initializer parameterizes runner accounts'
Assert-ScriptContains -Content $profileScript -Needle 'userenv.dll' -Name 'profile initializer uses Windows userenv API'
Assert-ScriptContains -Content $profileScript -Needle 'CreateProfile' -Name 'profile initializer invokes native CreateProfile'
Assert-ScriptContains -Content $profileScript -Needle '0x800700B7' -Name 'profile initializer handles existing profiles idempotently'
Assert-ScriptContains -Content $profileScript -Needle "(-not ('UserProfileHelper' -as [type]))" -Name 'profile initializer guards Add-Type against duplicate type definition'

# Invariants for Verify-OperatorBootstrap.ps1
Assert-ScriptContains -Content $verifyScript -Needle 'if (-not $IsWindows)' -Name 'bootstrap verification enforces Windows host requirement'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $InstallBase' -Name 'bootstrap verification parameterizes InstallBase'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $ProgramDataBase' -Name 'bootstrap verification parameterizes ProgramDataBase'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $ExpectedFingerprint' -Name 'bootstrap verification parameterizes ExpectedFingerprint'
Assert-ScriptContains -Content $verifyScript -Needle '$reviewIsAdmin -or $pubIsAdmin' -Name 'bootstrap verification checks runner accounts are non-administrative'
Assert-ScriptContains -Content $verifyScript -Needle '$signingSid -eq $reviewSid -or $signingSid -eq $pubSid -or $reviewSid -eq $pubSid' -Name 'bootstrap verification enforces distinct runner SIDs'
Assert-ScriptContains -Content $verifyScript -Needle 'Test-RunnerDirectoryAcl' -Name 'bootstrap verification enforces runner directory ACL isolation'
Assert-ScriptContains -Content $verifyScript -Needle 'S-1-1-0' -Name 'bootstrap verification denies Everyone on protected sentinel'
Assert-ScriptContains -Content $verifyScript -Needle 'S-1-5-11' -Name 'bootstrap verification denies Authenticated Users on protected sentinel'
Assert-ScriptContains -Content $verifyScript -Needle 'S-1-5-32-545' -Name 'bootstrap verification denies Builtin Users on protected sentinel'
Assert-ScriptContains -Content $verifyScript -Needle 'Review can read but cannot modify protected-read-probes.json' -Name 'bootstrap verification enforces manifest read-only policy for review'
Assert-ScriptContains -Content $verifyScript -Needle 'Review can read but cannot modify signing-public.pub' -Name 'bootstrap verification enforces public-key read-only policy for review'
Assert-ScriptContains -Content $verifyScript -Needle 'ssh-keygen -lf $trustedKeyPath' -Name 'bootstrap verification validates copied public key fingerprint'

Write-Host '[PASS] operator bootstrap and profile initialization contracts verified'
