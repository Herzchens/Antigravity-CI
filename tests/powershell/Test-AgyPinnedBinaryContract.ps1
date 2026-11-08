#requires -Version 7.4

<#
.SYNOPSIS
    Contract tests for the AGY pinned binary installer, bootstrap verifier, and host isolation.

.DESCRIPTION
    Verifies:
    1. Static contract invariants of scripts\Install-AgyPinnedBinary.ps1:
       - Parameters: Version, ExpectedArchiveSha256, ExpectedExecutableSha256, InstallDirectory, ReviewUserName
       - Archive and executable SHA-256 verification before installation
       - Hardened ACL enforcement via SetAccessRuleProtection($true, $false) on both directory and binary
       - Strict SID allowlist: SYSTEM (S-1-5-18), Administrators (S-1-5-32-544), review SID
       - Review account granted ReadAndExecute only (Write, Delete, ChangePermissions, TakeOwnership denied)
       - Post-install SHA-256 verification and ACL structure verification
    2. Static contract invariants of scripts\Verify-OperatorBootstrap.ps1 Step 10:
       - Parameters: PinnedAgyVersion, PinnedAgyExecutableSha256, PinnedAgyBinBase
       - Version directory and binary existence and SHA-256 verification
       - Inheritance disabled assertion on both directory and binary
       - Allowed SID allowlist assertion
       - Review account write-mask denial assertion on both directory and binary
    3. Offline execution contract:
       - scripts\Install-AgyPinnedBinary.ps1 fails closed when executed without Administrator elevation
    4. Host isolation & runtime boundary:
       - Requires expected production directory and binary to exist; fails closed if missing
       - Pinned binary is readable and SHA-256 matches expected pin
       - Non-administrative caller cannot write to or modify the pinned binary (fails closed with UnauthorizedAccessException)
       - Non-administrative caller cannot create or modify files in the pinned version directory (fails closed with UnauthorizedAccessException)
       - When run as Administrator, verifies structural ACL on both directory and binary
#>

[CmdletBinding()]
param(
    [string] $ExpectedExecutablePath = 'C:\ProgramData\Antigravity-CI\bin\agy\1.4.9\agy.exe',

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedExecutableSha256 = 'cffaeb65f38d048747e447632d70660406d8b214ca724c5e240a5cfc724aabcb',

    [string] $ExpectedVersion = '1.4.9',

    [string] $ReviewUserName = 'agci-review'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This script is intended for Windows host configuration.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$installerScriptPath = Join-Path $repoRoot 'scripts\Install-AgyPinnedBinary.ps1'
$verifyScriptPath    = Join-Path $repoRoot 'scripts\Verify-OperatorBootstrap.ps1'

if (-not (Test-Path -LiteralPath $installerScriptPath -PathType Leaf)) {
    throw "Required installer script missing: $installerScriptPath"
}
if (-not (Test-Path -LiteralPath $verifyScriptPath -PathType Leaf)) {
    throw "Required verify bootstrap script missing: $verifyScriptPath"
}

$installerScript = Get-Content -LiteralPath $installerScriptPath -Raw -Encoding utf8
$verifyScript    = Get-Content -LiteralPath $verifyScriptPath -Raw -Encoding utf8

$pass  = 0
$total = 0

function Assert-Pass { param([string]$Msg)
    $script:pass++; $script:total++
    Write-Host "[PASS] $Msg" -ForegroundColor Green
}
function Assert-Fail { param([string]$Msg)
    $script:total++
    Write-Host "[FAIL] $Msg" -ForegroundColor Red
    throw "Contract test failed: $Msg"
}
function Assert-Skip { param([string]$Msg)
    Write-Host "[SKIP] $Msg" -ForegroundColor Yellow
}

function Assert-ScriptContains {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Needle,
        [Parameter(Mandatory)] [string] $Name
    )
    if (-not $Content.Contains($Needle, [StringComparison]::Ordinal)) {
        Assert-Fail "Contract assertion failed: $Name (missing needle: $Needle)"
    } else {
        Assert-Pass $Name
    }
}

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Test-AgyPinnedBinaryContract' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$isAdmin = ([Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Running as: $currentUser  (Admin: $isAdmin)"
Write-Host "Expected binary: $ExpectedExecutablePath"
Write-Host "Expected SHA-256: $ExpectedExecutableSha256"
Write-Host "Expected version: $ExpectedVersion"
Write-Host ''

# --- Section 1: Invariants for Install-AgyPinnedBinary.ps1 ---
Write-Host '--- Section 1: Invariants for Install-AgyPinnedBinary.ps1 ---'
Assert-ScriptContains -Content $installerScript -Needle 'if (-not $IsWindows)' -Name 'installer enforces Windows host requirement'
Assert-ScriptContains -Content $installerScript -Needle 'This script must be run elevated as Administrator.' -Name 'installer enforces Administrator elevation'
Assert-ScriptContains -Content $installerScript -Needle '[string] $Version' -Name 'installer parameterizes Version'
Assert-ScriptContains -Content $installerScript -Needle '[string] $ExpectedArchiveSha256' -Name 'installer parameterizes ExpectedArchiveSha256'
Assert-ScriptContains -Content $installerScript -Needle '[string] $ExpectedExecutableSha256' -Name 'installer parameterizes ExpectedExecutableSha256'
Assert-ScriptContains -Content $installerScript -Needle "[string] `$InstallDirectory = 'C:\ProgramData\Antigravity-CI\bin\agy'" -Name 'installer parameterizes InstallDirectory'
Assert-ScriptContains -Content $installerScript -Needle "[string] `$ReviewUserName = 'agci-review'" -Name 'installer parameterizes ReviewUserName'
Assert-ScriptContains -Content $installerScript -Needle 'Archive SHA-256 mismatch!' -Name 'installer verifies archive SHA-256 before extraction'
Assert-ScriptContains -Content $installerScript -Needle 'Extracted agy.exe SHA-256 mismatch!' -Name 'installer verifies extracted binary SHA-256'
Assert-ScriptContains -Content $installerScript -Needle 'SetAccessRuleProtection($true, $false)' -Name 'installer disables ACL inheritance'
Assert-ScriptContains -Content $installerScript -Needle "New-FsRule 'S-1-5-18'" -Name 'installer grants SYSTEM FullControl'
Assert-ScriptContains -Content $installerScript -Needle "New-FsRule 'S-1-5-32-544'" -Name 'installer grants Administrators FullControl'
Assert-ScriptContains -Content $installerScript -Needle 'New-FsRule $reviewSid' -Name 'installer grants review user ReadAndExecute'
Assert-ScriptContains -Content $installerScript -Needle '[Security.AccessControl.FileSystemRights]::Write' -Name 'installer checks write mask denial'
Assert-ScriptContains -Content $installerScript -Needle 'Post-install hash mismatch!' -Name 'installer verifies post-install SHA-256'

# --- Section 2: Invariants for Verify-OperatorBootstrap.ps1 Step 10 ---
Write-Host '--- Section 2: Invariants for Verify-OperatorBootstrap.ps1 Step 10 ---'
Assert-ScriptContains -Content $verifyScript -Needle 'STEP 10: Verify Pinned AGY Binary' -Name 'bootstrap verification defines Step 10'
Assert-ScriptContains -Content $verifyScript -Needle "[string] `$PinnedAgyVersion = '1.4.9'" -Name 'bootstrap verification parameterizes PinnedAgyVersion'
Assert-ScriptContains -Content $verifyScript -Needle "[string] `$PinnedAgyExecutableSha256" -Name 'bootstrap verification parameterizes PinnedAgyExecutableSha256'
Assert-ScriptContains -Content $verifyScript -Needle "[string] `$PinnedAgyBinBase = 'C:\ProgramData\Antigravity-CI\bin\agy'" -Name 'bootstrap verification parameterizes PinnedAgyBinBase'
Assert-ScriptContains -Content $verifyScript -Needle 'Pinned AGY version directory not found at' -Name 'bootstrap verification checks version directory existence'
Assert-ScriptContains -Content $verifyScript -Needle 'Pinned AGY binary not found at' -Name 'bootstrap verification checks binary existence'
Assert-ScriptContains -Content $verifyScript -Needle 'Pinned AGY binary SHA-256 mismatch!' -Name 'bootstrap verification checks binary SHA-256'
Assert-ScriptContains -Content $verifyScript -Needle 'Inheritance is not disabled on pinned AGY directory' -Name 'bootstrap verification checks directory inheritance is disabled'
Assert-ScriptContains -Content $verifyScript -Needle 'Inheritance is not disabled on pinned AGY binary' -Name 'bootstrap verification checks binary inheritance is disabled'
Assert-ScriptContains -Content $verifyScript -Needle 'Security violation: review account has write/modify rights on pinned AGY directory!' -Name 'bootstrap verification enforces review account directory write denial'
Assert-ScriptContains -Content $verifyScript -Needle 'Security violation: review account has write/modify rights on pinned AGY binary!' -Name 'bootstrap verification enforces review account binary write denial'

# --- Section 3: Offline Execution Contract ---
Write-Host '--- Section 3: Offline Execution Contract ---'
if (-not $isAdmin) {
    $installErr = & pwsh -NoProfile -File $installerScriptPath -Version '1.4.9' -ExpectedArchiveSha256 ('0'*64) -ExpectedExecutableSha256 ('0'*64) 2>&1
    if ($LASTEXITCODE -eq 0 -or -not ($installErr -match 'This script must be run elevated as Administrator.')) {
        Assert-Fail "Installer did not fail closed on non-elevated execution: $installErr"
    } else {
        Assert-Pass 'installer fails closed when executed without Administrator elevation'
    }
} else {
    Assert-Skip 'installer non-elevation fail-closed check: running in elevated Administrator session'
}

# --- Section 4: Host Isolation & Runtime Boundary ---
Write-Host '--- Section 4: Host Isolation & Runtime Boundary ---'

$expectedVersionDir = Split-Path -Parent $ExpectedExecutablePath
Write-Host "Expected version directory: $expectedVersionDir"
Write-Host "Expected binary path:       $ExpectedExecutablePath"

# The production state MUST exist. Missing state is an immediate failure, not a pass.
if (-not (Test-Path -LiteralPath $expectedVersionDir -PathType Container)) {
    Assert-Fail "Required production version directory missing: $expectedVersionDir"
} else {
    Assert-Pass "production version directory exists: $expectedVersionDir"
}

if (-not (Test-Path -LiteralPath $ExpectedExecutablePath -PathType Leaf)) {
    Assert-Fail "Required production binary missing: $ExpectedExecutablePath"
} else {
    Assert-Pass "production binary exists: $ExpectedExecutablePath"
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hashBytes = $sha.ComputeHash($stream)
            return [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
        } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

$actualHash = Get-FileSha256 -Path $ExpectedExecutablePath
if ($actualHash -ceq $ExpectedExecutableSha256.ToLowerInvariant()) {
    Assert-Pass "pinned binary SHA-256 matches expected pin: $actualHash"
} else {
    Assert-Fail "SHA-256 mismatch! Expected: $ExpectedExecutableSha256  Got: $actualHash"
}

if (-not $isAdmin) {
    # Non-elevated session: live write attempt on binary must be denied with UnauthorizedAccessException only
    $writeDenied = $false
    try {
        $fs = [System.IO.File]::Open($ExpectedExecutablePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        $fs.Dispose()
    } catch [System.UnauthorizedAccessException] {
        $writeDenied = $true
    } catch {
        Assert-Fail "Unexpected exception during binary write probe (expected UnauthorizedAccessException): $_"
    }
    if ($writeDenied) {
        Assert-Pass 'write probe: non-administrative caller write access to pinned binary is denied (UnauthorizedAccessException)'
    } else {
        Assert-Fail 'write probe SUCCEEDED: non-administrative caller was able to open pinned binary for write!'
    }

    # Non-elevated session: live write attempt on version directory must be denied with UnauthorizedAccessException only
    $dirWriteDenied = $false
    $probeFilePath = Join-Path $expectedVersionDir "probe-write-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($probeFilePath, 'probe-content')
    } catch [System.UnauthorizedAccessException] {
        $dirWriteDenied = $true
    } catch {
        Assert-Fail "Unexpected exception during directory write probe (expected UnauthorizedAccessException): $_"
    } finally {
        if (Test-Path -LiteralPath $probeFilePath) {
            Remove-Item -LiteralPath $probeFilePath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($dirWriteDenied) {
        Assert-Pass 'write probe: non-administrative caller cannot create files in pinned version directory (UnauthorizedAccessException)'
    } else {
        Assert-Fail 'write probe SUCCEEDED: non-administrative caller was able to create files in pinned version directory!'
    }
} else {
    Assert-Skip 'write probe: running as Administrator — structural ACL verified'
}

# Structural ACL verification
if ($isAdmin) {
    $dirAcl = Get-Acl -LiteralPath $expectedVersionDir
    if ($dirAcl.AreAccessRulesProtected) {
        Assert-Pass 'pinned version directory ACL inheritance is disabled'
    } else {
        Assert-Fail 'pinned version directory ACL inheritance is NOT disabled'
    }

    $exeAcl = Get-Acl -LiteralPath $ExpectedExecutablePath
    if ($exeAcl.AreAccessRulesProtected) {
        Assert-Pass 'pinned binary ACL inheritance is disabled'
    } else {
        Assert-Fail 'pinned binary ACL inheritance is NOT disabled'
    }

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $reviewUserObj = Get-LocalUser -Name $ReviewUserName -ErrorAction SilentlyContinue
    if ($null -ne $reviewUserObj) {
        $allowedSids += $reviewUserObj.SID.Value
    }

    foreach ($targetObj in @(@{Name='directory'; Acl=$dirAcl}, @{Name='binary'; Acl=$exeAcl})) {
        $name = $targetObj.Name
        $targetAcl = $targetObj.Acl
        foreach ($rule in $targetAcl.Access) {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($allowedSids -notcontains $sid) {
                Assert-Fail "Unexpected principal on pinned $name`: $($rule.IdentityReference.Value) ($sid)"
            }
        }
    }
    Assert-Pass 'structural ACL: both version directory and binary are restricted to SYSTEM, Administrators, and review user'
}

Write-Host ''
Write-Host '============================================================'
Write-Host "   RESULTS: $pass / $total PASS"
Write-Host '============================================================'

if ($pass -eq $total) {
    Write-Host '   ALL CONTRACT TESTS PASSED' -ForegroundColor Green
} else {
    Write-Host "   $($total - $pass) TEST(S) FAILED" -ForegroundColor Red
    exit 1
}
