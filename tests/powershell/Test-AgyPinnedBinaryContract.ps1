#requires -Version 7.4

<#
.SYNOPSIS
    Contract tests for the AGY pinned binary install at the ProgramData stable location.

.DESCRIPTION
    Verifies:
    1. The pinned binary exists at the expected stable path.
    2. The binary SHA-256 matches the pinned expected hash.
    3. The ACL structure is correct (inheritance disabled; only SYSTEM, Administrators, and
       agci-review with ReadAndExecute are granted).
    4. The AGY version string matches the expected version.
    5. Write access is correctly denied when invoked from a non-Administrator review-account context.
       (Probe 5 is advisory when run as Administrator; it validates via ACL rather than live attempt.)

    Designed to run from non-elevated agci-review context for the write-probe check.
    When run as Administrator, all checks except the live write-probe pass.

.PARAMETER ExpectedExecutablePath
    The expected stable path to the pinned agy.exe.

.PARAMETER ExpectedExecutableSha256
    The expected SHA-256 of the binary (hex, case-insensitive).

.PARAMETER ExpectedVersion
    The expected AGY version string (e.g. '1.4.9').

.PARAMETER ReviewUserName
    The review runner local username. Defaults to 'agci-review'.

.EXAMPLE
    # Run from non-elevated agci-review session:
    pwsh -NoProfile -File Test-AgyPinnedBinaryContract.ps1
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

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hashBytes = $sha.ComputeHash($stream)
            return [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

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

# --- Test 1: Binary exists ---
Write-Host '--- Test 1: Binary exists at stable path ---'
if (-not (Test-Path -LiteralPath $ExpectedExecutablePath)) {
    Assert-Fail "Binary not found: $ExpectedExecutablePath"
} else {
    Assert-Pass "Binary exists: $ExpectedExecutablePath"
}

# --- Test 2: SHA-256 matches ---
Write-Host '--- Test 2: SHA-256 matches expected pin ---'
$actualHash = Get-FileSha256 -Path $ExpectedExecutablePath
if ($actualHash -cne $ExpectedExecutableSha256.ToLowerInvariant()) {
    Assert-Fail "SHA-256 mismatch! Expected: $ExpectedExecutableSha256  Got: $actualHash"
} else {
    Assert-Pass "SHA-256 matches pin: $actualHash"
}

# --- Test 3: ACL structure (requires elevation to inspect ACL via .NET) ---
Write-Host '--- Test 3: ACL structure ---'
if ($isAdmin) {
    $reviewUser = Get-LocalUser -Name $ReviewUserName -ErrorAction Stop
    $reviewSid  = $reviewUser.SID.Value
    $allowedSids = @('S-1-5-18', 'S-1-5-32-544', $reviewSid)

    $exeAcl = Get-Acl -LiteralPath $ExpectedExecutablePath
    if (-not $exeAcl.AreAccessRulesProtected) {
        Assert-Fail 'ACL inheritance is NOT disabled on binary'
    }

    $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
                 [Security.AccessControl.FileSystemRights]::Delete -bor
                 [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                 [Security.AccessControl.FileSystemRights]::TakeOwnership
    $reviewAceFound = $false

    foreach ($rule in $exeAcl.Access) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($allowedSids -notcontains $sid) {
            Assert-Fail "Unexpected ACL principal: $($rule.IdentityReference.Value) ($sid)"
        }
        if ($sid -eq $reviewSid -and $rule.AccessControlType -eq 'Allow') {
            if (($rule.FileSystemRights -band $writeMask) -ne 0) {
                Assert-Fail "Review account has write/modify rights on binary — ACL misconfigured!"
            }
            $reviewAceFound = $true
        }
    }
    if (-not $reviewAceFound) {
        Assert-Fail "Review account ($reviewSid) has no ACE on binary"
    }
    Assert-Pass "ACL: inheritance disabled, principals = SYSTEM(F)/Administrators(F)/$ReviewUserName(RX)"
} else {
    # Non-elevated: use icacls for a best-effort check
    $icaclsOut = & icacls.exe $ExpectedExecutablePath 2>&1 | Out-String
    if ($icaclsOut -match [regex]::Escape($ReviewUserName)) {
        Assert-Pass "ACL (icacls): $ReviewUserName entry found (full ACL verification requires elevation)"
    } else {
        Assert-Skip "ACL (icacls): Cannot resolve ACL from non-elevated session — run as Administrator to fully verify"
    }
}

# --- Test 4: AGY version ---
Write-Host '--- Test 4: AGY version string ---'
try {
    $env:AGY_CLI_DISABLE_AUTO_UPDATE = 'true'
    $versionOutput = & $ExpectedExecutablePath --version 2>&1 | Out-String
    if ($versionOutput -match [regex]::Escape($ExpectedVersion)) {
        Assert-Pass "AGY version matches: $ExpectedVersion"
    } else {
        Assert-Fail "AGY version mismatch! Expected $ExpectedVersion in output: $versionOutput"
    }
} catch {
    Assert-Fail "Failed to invoke agy.exe --version: $_"
} finally {
    Remove-Item Env:AGY_CLI_DISABLE_AUTO_UPDATE -ErrorAction SilentlyContinue
}

# --- Test 5: Write probe ---
Write-Host '--- Test 5: Write probe (review account cannot modify binary) ---'
if (-not $isAdmin) {
    # Genuine non-elevated probe: attempt file open for write
    $writeProbeResult = $false
    try {
        $fs = [System.IO.File]::Open($ExpectedExecutablePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        $fs.Dispose()
        $writeProbeResult = $true  # Should NOT reach here
    } catch [System.UnauthorizedAccessException] {
        $writeProbeResult = $false
    } catch [System.IO.IOException] {
        $writeProbeResult = $false  # File in use — also acceptable, we can't write
    }
    if ($writeProbeResult) {
        Assert-Fail 'Write probe SUCCEEDED — review account can write to binary! ACL misconfigured.'
    } else {
        Assert-Pass 'Write probe correctly denied: review account cannot write to binary.'
    }
} else {
    Assert-Skip 'Write probe: running as Administrator — ACL verified structurally in Test 3. Re-run as agci-review for live probe.'
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

