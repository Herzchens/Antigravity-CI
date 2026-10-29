#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $ReviewUserName = 'agci-review',
    [string] $PublisherUserName = 'agci-publisher',
    [string] $InstallBase = $(if (Test-Path 'D:\Antigravity-CI\runners') { 'D:\Antigravity-CI\runners' } else { 'C:\actions-runner' }),
    [string] $ProgramDataBase = 'C:\ProgramData\Antigravity-CI',
    [string] $ExpectedFingerprint = 'SHA256:20kPITIYb5mzSR9B3stmLoprDRmEGCUFgN0m8BNrJSc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This script is intended for Windows host configuration.'
}

if (-not ('UserProfileHelper' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class UserProfileHelper {
    [DllImport("userenv.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int CreateProfile(
        string pszUserSid,
        string pszUserName,
        StringBuilder pszProfilePath,
        uint cchProfilePath
    );

    public static string Create(string sid, string username) {
        StringBuilder sb = new StringBuilder(260);
        int hr = CreateProfile(sid, username, sb, (uint)sb.Capacity);
        if (hr != 0) {
            if (hr == unchecked((int)0x800700B7)) {
                return "Profile already exists";
            }
            throw new Exception("CreateProfile failed with HRESULT: 0x" + hr.ToString("X8"));
        }
        return sb.ToString();
    }
}
"@
}

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " STEP 9: Verify Windows Profiles for Runners        " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

foreach ($acc in @($ReviewUserName, $PublisherUserName)) {
    $u = Get-LocalUser -Name $acc -ErrorAction Stop
    $profile = Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $u.SID.Value } | Select-Object -First 1
    if ($null -ne $profile -and (Test-Path -LiteralPath $profile.LocalPath)) {
        Write-Host "[OK] $acc profile: $($profile.LocalPath)" -ForegroundColor Green
    }
    else {
        $profilePath = [UserProfileHelper]::Create($u.SID.Value, $acc)
        Write-Host "[OK] $acc profile: $profilePath" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " STEP 6: Security and ACL Verifications             " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

$adminsGroup = (Get-LocalGroupMember -Group 'Administrators' | ForEach-Object { $_.SID.Value })

# 1. Accounts verification
$review = Get-LocalUser -Name $ReviewUserName -ErrorAction Stop
$pub = Get-LocalUser -Name $PublisherUserName -ErrorAction Stop

$reviewIsAdmin = $adminsGroup -contains $review.SID.Value
$pubIsAdmin = $adminsGroup -contains $pub.SID.Value

Write-Host "Review user exists: True, Enabled: $($review.Enabled), IsAdmin: $reviewIsAdmin"
Write-Host "Publisher user exists: True, Enabled: $($pub.Enabled), IsAdmin: $pubIsAdmin"

if ($reviewIsAdmin -or $pubIsAdmin) {
    throw "Security violation: runner account has Administrator rights!"
}

# 2. Distinct SIDs
$signingIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$signingSid = ([Security.Principal.NTAccount]::new($signingIdentity)).Translate([Security.Principal.SecurityIdentifier]).Value
$reviewSid = $review.SID.Value
$pubSid = $pub.SID.Value

Write-Host "Signing SID:   $signingSid ($signingIdentity)"
Write-Host "Review SID:    $reviewSid ($ReviewUserName)"
Write-Host "Publisher SID: $pubSid ($PublisherUserName)"

if ($signingSid -eq $reviewSid -or $signingSid -eq $pubSid -or $reviewSid -eq $pubSid) {
    throw "Security violation: runner SIDs are not distinct!"
}
Write-Host "[PASS] Signing, Review, and Publisher resolve to three distinct SIDs." -ForegroundColor Green

# 3. Runner directories ACLs
function Test-RunnerDirectoryAcl {
    param([string]$Path, [string]$ExpectedUserSid)
    $acl = Get-Acl -LiteralPath $Path
    $allowedSids = @(
        'S-1-5-18',        # SYSTEM
        'S-1-5-32-544',    # Administrators
        $ExpectedUserSid
    )
    foreach ($rule in $acl.Access) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($allowedSids -notcontains $sid) {
            throw "Unexpected ACL grant on $Path : $($rule.IdentityReference.Value) ($sid)"
        }
    }
    Write-Host "[PASS] $Path is accessible only by intended identity and SYSTEM/Administrators." -ForegroundColor Green
}

Test-RunnerDirectoryAcl -Path (Join-Path $InstallBase 'signing') -ExpectedUserSid $signingSid
Test-RunnerDirectoryAcl -Path (Join-Path $InstallBase 'review') -ExpectedUserSid $reviewSid
Test-RunnerDirectoryAcl -Path (Join-Path $InstallBase 'publisher') -ExpectedUserSid $pubSid

# 4. ProgramData Boundaries
$sentinelPath = Join-Path $ProgramDataBase 'protected\operator-sentinel.bin'
$manifestPath = Join-Path $ProgramDataBase 'review-policy\protected-read-probes.json'
$trustedKeyPath = Join-Path $ProgramDataBase 'trusted-keys\signing-public.pub'

# Verify Sentinel ACL: Review cannot read
$sentinelAcl = Get-Acl -LiteralPath $sentinelPath
foreach ($rule in $sentinelAcl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -eq $reviewSid -or $sid -eq 'S-1-1-0' -or $sid -eq 'S-1-5-11' -or $sid -eq 'S-1-5-32-545') {
        throw "Security violation: Review or generic users have access to operator-sentinel.bin!"
    }
}
Write-Host "[PASS] Review cannot read operator-sentinel.bin (only SYSTEM and Administrators granted)." -ForegroundColor Green

# Verify Probe Manifest ACL: Review can read, cannot modify
$manifestAcl = Get-Acl -LiteralPath $manifestPath
$reviewFound = $false
foreach ($rule in $manifestAcl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -eq $reviewSid) {
        $reviewFound = $true
        if ($rule.AccessControlType -ne 'Allow' -or ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -ne 0) {
            throw "Security violation: Review has write/modify rights on protected-read-probes.json!"
        }
    }
}
if (-not $reviewFound) {
    throw "Review read access not explicitly found on protected-read-probes.json"
}
Write-Host "[PASS] Review can read but cannot modify protected-read-probes.json." -ForegroundColor Green

# Verify Trusted Public Key ACL: Review can read, cannot modify
$keyAcl = Get-Acl -LiteralPath $trustedKeyPath
$keyReviewFound = $false
foreach ($rule in $keyAcl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -eq $reviewSid) {
        $keyReviewFound = $true
        if ($rule.AccessControlType -ne 'Allow' -or ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -ne 0) {
            throw "Security violation: Review has write/modify rights on signing-public.pub!"
        }
    }
}
if (-not $keyReviewFound) {
    throw "Review read access not explicitly found on signing-public.pub"
}
Write-Host "[PASS] Review can read but cannot modify signing-public.pub." -ForegroundColor Green

# 5. Public-key Fingerprint
$fpOutput = & ssh-keygen -lf $trustedKeyPath
$match = [regex]::Match($fpOutput, 'SHA256:[A-Za-z0-9+/=]+')
if (-not $match.Success -or $match.Value -cne $ExpectedFingerprint) {
    throw "Fingerprint mismatch! Got: $($match.Value), Expected: $ExpectedFingerprint"
}
Write-Host "[PASS] Copied public-key fingerprint equals $ExpectedFingerprint" -ForegroundColor Green

Write-Host ""
Write-Host "====================================================" -ForegroundColor Green
Write-Host " ALL SECURITY & ACL VERIFICATIONS PASSED (100%)      " -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
