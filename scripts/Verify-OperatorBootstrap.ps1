#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $ReviewUserName = 'agci-review',
    [string] $ReviewFullName = 'Herzchen Reviewing',
    [string] $ReviewDescription = 'Antigravity-CI Review Runner',

    [string] $PublisherUserName = 'agci-publisher',
    [string] $PublisherFullName = 'Herzchen Publisher',
    [string] $PublisherDescription = 'Antigravity-CI Publisher Runner',

    [string] $InstallBase = $(if (Test-Path 'D:\Antigravity-CI\runners') { 'D:\Antigravity-CI\runners' } else { 'C:\actions-runner' }),
    [string] $ProgramDataBase = 'C:\ProgramData\Antigravity-CI',
    [string] $ExpectedFingerprint = 'SHA256:20kPITIYb5mzSR9B3stmLoprDRmEGCUFgN0m8BNrJSc',
    [string] $SigningIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This script is intended for Windows host configuration.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This verification script must be run elevated as Administrator.'
    }
}
finally {
    $identity.Dispose()
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

Write-Host "Review user exists: True, Enabled: $($review.Enabled), IsAdmin: $reviewIsAdmin, FullName: '$($review.FullName)'"
Write-Host "Publisher user exists: True, Enabled: $($pub.Enabled), IsAdmin: $pubIsAdmin, FullName: '$($pub.FullName)'"

if ($reviewIsAdmin -or $pubIsAdmin) {
    throw "Security violation: runner account has Administrator rights!"
}

if (-not [string]::IsNullOrWhiteSpace($ReviewFullName) -and $review.FullName -cne $ReviewFullName) {
    throw "Review user FullName mismatch: got '$($review.FullName)', expected '$ReviewFullName'."
}
if (-not [string]::IsNullOrWhiteSpace($PublisherFullName) -and $pub.FullName -cne $PublisherFullName) {
    throw "Publisher user FullName mismatch: got '$($pub.FullName)', expected '$PublisherFullName'."
}
if (-not [string]::IsNullOrWhiteSpace($ReviewDescription) -and $review.Description -cne $ReviewDescription) {
    throw "Review user Description mismatch: got '$($review.Description)', expected '$ReviewDescription'."
}
if (-not [string]::IsNullOrWhiteSpace($PublisherDescription) -and $pub.Description -cne $PublisherDescription) {
    throw "Publisher user Description mismatch: got '$($pub.Description)', expected '$PublisherDescription'."
}
Write-Host "[PASS] Runner accounts exist, enabled, non-admin, with canonical display names and descriptions." -ForegroundColor Green

# 2. Distinct SIDs
$signingSid = ([Security.Principal.NTAccount]::new($SigningIdentity)).Translate([Security.Principal.SecurityIdentifier]).Value
$reviewSid = $review.SID.Value
$pubSid = $pub.SID.Value

Write-Host "Signing SID:   $signingSid ($SigningIdentity)"
Write-Host "Review SID:    $reviewSid ($ReviewUserName)"
Write-Host "Publisher SID: $pubSid ($PublisherUserName)"

if ($signingSid -eq $reviewSid -or $signingSid -eq $pubSid -or $reviewSid -eq $pubSid) {
    throw "Security violation: runner SIDs are not distinct!"
}
Write-Host "[PASS] Signing, Review, and Publisher resolve to three distinct SIDs." -ForegroundColor Green

# 3. Runner directories ACLs
function Test-RunnerDirectoryAcl {
    param([string]$Path, [string]$ExpectedUserSid)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required runner directory does not exist: $Path"
    }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) {
        throw "Inheritance is not disabled on $Path"
    }
    $allowedSids = @(
        'S-1-5-18',        # SYSTEM
        'S-1-5-32-544',    # Administrators
        $ExpectedUserSid
    )
    $expectedFound = $false
    foreach ($rule in $acl.Access) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($allowedSids -notcontains $sid) {
            throw "Unexpected ACL grant on $Path : $($rule.IdentityReference.Value) ($sid)"
        }
        if ($sid -eq $ExpectedUserSid) {
            if ($rule.AccessControlType -ne 'Allow' -or ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Expected user ($ExpectedUserSid) does not have FullControl Allow on $Path"
            }
            $expectedFound = $true
        }
    }
    if (-not $expectedFound) {
        throw "Expected user ($ExpectedUserSid) has no access rule on $Path"
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
if (-not $sentinelAcl.AreAccessRulesProtected) {
    throw "Inheritance is not disabled on $sentinelPath"
}
$allowedSentinelSids = @(
    'S-1-5-18',        # SYSTEM
    'S-1-5-32-544'     # Administrators
)
foreach ($rule in $sentinelAcl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($allowedSentinelSids -notcontains $sid) {
        throw "Security violation: Unexpected ACL grant on operator-sentinel.bin: $($rule.IdentityReference.Value) ($sid)"
    }
    if ($sid -eq $reviewSid -or $sid -eq 'S-1-1-0' -or $sid -eq 'S-1-5-11' -or $sid -eq 'S-1-5-32-545') {
        throw "Security violation: Review or generic users have access to operator-sentinel.bin!"
    }
}
Write-Host "[PASS] Review cannot read operator-sentinel.bin (only SYSTEM and Administrators granted)." -ForegroundColor Green

# Verify Probe Manifest ACL: Review can read, cannot modify
$manifestAcl = Get-Acl -LiteralPath $manifestPath
if (-not $manifestAcl.AreAccessRulesProtected) {
    throw "Inheritance is not disabled on $manifestPath"
}
$forbiddenRights = [Security.AccessControl.FileSystemRights]::Write -bor
                   [Security.AccessControl.FileSystemRights]::Delete -bor
                   [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                   [Security.AccessControl.FileSystemRights]::TakeOwnership
$reviewFound = $false
foreach ($rule in $manifestAcl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -eq $reviewSid) {
        $reviewFound = $true
        if ($rule.AccessControlType -ne 'Allow' -or ($rule.FileSystemRights -band $forbiddenRights) -ne 0) {
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
if (-not $keyAcl.AreAccessRulesProtected) {
    throw "Inheritance is not disabled on $trustedKeyPath"
}
$keyReviewFound = $false
foreach ($rule in $keyAcl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($sid -eq $reviewSid) {
        $keyReviewFound = $true
        if ($rule.AccessControlType -ne 'Allow' -or ($rule.FileSystemRights -band $forbiddenRights) -ne 0) {
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
