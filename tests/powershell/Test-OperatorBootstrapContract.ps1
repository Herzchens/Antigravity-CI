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
Assert-ScriptContains -Content $profileScript -Needle 'This initialization script must be run elevated as Administrator.' -Name 'profile initializer enforces Administrator elevation'
Assert-ScriptContains -Content $profileScript -Needle '[string[]] $Accounts' -Name 'profile initializer parameterizes runner accounts'
Assert-ScriptContains -Content $profileScript -Needle 'userenv.dll' -Name 'profile initializer uses Windows userenv API'
Assert-ScriptContains -Content $profileScript -Needle 'CreateProfile' -Name 'profile initializer invokes native CreateProfile'
Assert-ScriptContains -Content $profileScript -Needle '0x800700B7' -Name 'profile initializer handles existing profiles idempotently'
Assert-ScriptContains -Content $profileScript -Needle "(-not ('UserProfileHelper' -as [type]))" -Name 'profile initializer guards Add-Type against duplicate type definition'
Assert-ScriptContains -Content $profileScript -Needle 'Win32_UserProfile' -Name 'profile initializer checks existing profiles via Win32_UserProfile'

# Invariants for Verify-OperatorBootstrap.ps1
Assert-ScriptContains -Content $verifyScript -Needle 'if (-not $IsWindows)' -Name 'bootstrap verification enforces Windows host requirement'
Assert-ScriptContains -Content $verifyScript -Needle 'This verification script must be run elevated as Administrator.' -Name 'bootstrap verification enforces Administrator elevation'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $InstallBase' -Name 'bootstrap verification parameterizes InstallBase'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $ProgramDataBase' -Name 'bootstrap verification parameterizes ProgramDataBase'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $ExpectedFingerprint' -Name 'bootstrap verification parameterizes ExpectedFingerprint'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $SigningIdentity' -Name 'bootstrap verification parameterizes SigningIdentity'
Assert-ScriptContains -Content $verifyScript -Needle '$reviewIsAdmin -or $pubIsAdmin' -Name 'bootstrap verification checks runner accounts are non-administrative'
Assert-ScriptContains -Content $verifyScript -Needle '$signingSid -eq $reviewSid -or $signingSid -eq $pubSid -or $reviewSid -eq $pubSid' -Name 'bootstrap verification enforces distinct runner SIDs'
Assert-ScriptContains -Content $verifyScript -Needle 'Test-RunnerDirectoryAcl' -Name 'bootstrap verification enforces runner directory ACL isolation'
Assert-ScriptContains -Content $verifyScript -Needle 'AreAccessRulesProtected' -Name 'bootstrap verification checks runner directory inheritance is disabled'
Assert-ScriptContains -Content $verifyScript -Needle 'S-1-1-0' -Name 'bootstrap verification denies Everyone on protected sentinel'
Assert-ScriptContains -Content $verifyScript -Needle 'S-1-5-11' -Name 'bootstrap verification denies Authenticated Users on protected sentinel'
Assert-ScriptContains -Content $verifyScript -Needle 'S-1-5-32-545' -Name 'bootstrap verification denies Builtin Users on protected sentinel'
Assert-ScriptContains -Content $verifyScript -Needle 'Review can read but cannot modify protected-read-probes.json' -Name 'bootstrap verification enforces manifest read-only policy for review'
Assert-ScriptContains -Content $verifyScript -Needle 'Review can read but cannot modify signing-public.pub' -Name 'bootstrap verification enforces public-key read-only policy for review'
Assert-ScriptContains -Content $verifyScript -Needle 'ssh-keygen -lf $trustedKeyPath' -Name 'bootstrap verification validates copied public key fingerprint'

Assert-ScriptContains -Content $verifyScript -Needle '[string] $ReviewFullName = ''Herzchen Reviewing''' -Name 'bootstrap verification parameterizes ReviewFullName'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $PublisherFullName = ''Herzchen Publisher''' -Name 'bootstrap verification parameterizes PublisherFullName'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $ReviewDescription = ''Antigravity-CI Review Runner''' -Name 'bootstrap verification parameterizes ReviewDescription'
Assert-ScriptContains -Content $verifyScript -Needle '[string] $PublisherDescription = ''Antigravity-CI Publisher Runner''' -Name 'bootstrap verification parameterizes PublisherDescription'
Assert-ScriptContains -Content $verifyScript -Needle 'Review user FullName mismatch' -Name 'bootstrap verification enforces review FullName match'
Assert-ScriptContains -Content $verifyScript -Needle 'Publisher user FullName mismatch' -Name 'bootstrap verification enforces publisher FullName match'
Assert-ScriptContains -Content $verifyScript -Needle 'Review user Description mismatch' -Name 'bootstrap verification enforces review Description match'
Assert-ScriptContains -Content $verifyScript -Needle 'Publisher user Description mismatch' -Name 'bootstrap verification enforces publisher Description match'

# Offline Execution Contract: verify non-elevated execution fails closed
if ($IsWindows) {
    $isCurrentElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isCurrentElevated) {
        $profileErr = & pwsh -NoProfile -File $profileScriptPath 2>&1
        if ($LASTEXITCODE -eq 0 -or -not ($profileErr -match 'This initialization script must be run elevated as Administrator.')) {
            throw "Profile initializer did not fail closed on non-elevated execution: $profileErr"
        }
        Write-Host '[PASS] profile initializer fails closed when executed without Administrator elevation'

        $verifyErr = & pwsh -NoProfile -File $verifyScriptPath 2>&1
        if ($LASTEXITCODE -eq 0 -or -not ($verifyErr -match 'This verification script must be run elevated as Administrator.')) {
            throw "Bootstrap verification did not fail closed on non-elevated execution: $verifyErr"
        }
        Write-Host '[PASS] bootstrap verification fails closed when executed without Administrator elevation'
    }
}

Write-Host '[PASS] operator bootstrap and profile initialization contracts verified'
