#requires -Version 7.4

<#
.SYNOPSIS
    Downloads, verifies, installs, and hardens a pinned AGY CLI binary for Antigravity-CI runners.

.DESCRIPTION
    Installs a specific AGY version into a machine-level ProgramData location with hardened
    ACLs suitable for use by the agci-review runner account.

    ACL policy applied:
      - Inheritance disabled
      - SYSTEM: Full Control
      - Administrators: Full Control
      - $ReviewUserName: ReadAndExecute only (no write, modify, or delete)
      - No other principals

    This script must be run elevated as Administrator. It is idempotent: if the target file
    already exists and its SHA-256 matches the expected hash, the install step is skipped.

.PARAMETER Version
    The AGY version string to install (e.g. '1.4.9').

.PARAMETER ExpectedArchiveSha256
    The expected SHA-256 of the downloaded .zip archive (hex string, case-insensitive).

.PARAMETER ExpectedExecutableSha256
    The expected SHA-256 of the extracted agy.exe (hex string, case-insensitive).

.PARAMETER InstallDirectory
    The root installation directory. The binary will be placed in
    "$InstallDirectory\$Version\agy.exe". Defaults to 'C:\ProgramData\Antigravity-CI\bin\agy'.

.PARAMETER ReviewUserName
    The local username of the review runner account. Defaults to 'agci-review'.

.PARAMETER DownloadBaseUrl
    The base URL for the AGY release archive. Defaults to the official GitHub release URL.

.EXAMPLE
    pwsh -NoProfile -File Install-AgyPinnedBinary.ps1 `
        -Version '1.4.9' `
        -ExpectedArchiveSha256 '0581f6f8d473aecf00f7b56e30b5027f23b7b65934091d0e6b91b97c83a9bc08' `
        -ExpectedExecutableSha256 'cffaeb65f38d048747e447632d70660406d8b214ca724c5e240a5cfc724aabcb'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedArchiveSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedExecutableSha256,

    [string] $InstallDirectory = 'C:\ProgramData\Antigravity-CI\bin\agy',

    [string] $ReviewUserName = 'agci-review',

    [string] $DownloadBaseUrl = 'https://github.com/google-antigravity/antigravity-cli/releases/download'
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
        throw 'This script must be run elevated as Administrator.'
    }
} finally {
    $identity.Dispose()
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

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "   Install-AgyPinnedBinary  v$Version" -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$targetDir  = Join-Path $InstallDirectory $Version
$targetExe  = Join-Path $targetDir 'agy.exe'
$archiveUrl = "$DownloadBaseUrl/$Version/agy_cli_windows_x64.zip"
$expectedExeHashLower     = $ExpectedExecutableSha256.ToLowerInvariant()
$expectedArchiveHashLower = $ExpectedArchiveSha256.ToLowerInvariant()

# --- Step 1: Check if already correctly installed (idempotent) ---
Write-Host ''
Write-Host '>>> [Step 1] Idempotency check...'
if (Test-Path -LiteralPath $targetExe) {
    $existingHash = Get-FileSha256 -Path $targetExe
    if ($existingHash -ceq $expectedExeHashLower) {
        Write-Host "[SKIP] $targetExe already exists with correct SHA-256. Skipping download/extract." -ForegroundColor Cyan
        $skipInstall = $true
    } else {
        Write-Host "[WARN] $targetExe exists but SHA-256 mismatch (got $existingHash). Re-installing." -ForegroundColor Yellow
        $skipInstall = $false
    }
} else {
    Write-Host "[INFO] Target not found. Proceeding with install."
    $skipInstall = $false
}

if (-not $skipInstall) {
    # --- Step 2: Download archive ---
    Write-Host ''
    Write-Host '>>> [Step 2] Downloading archive...'
    $tempDir     = [System.IO.Path]::GetTempPath()
    $archivePath = Join-Path $tempDir "agy_cli_windows_x64-$Version.zip"
    $extractDir  = Join-Path $tempDir "agy-extract-$Version"

    Write-Host "    URL:  $archiveUrl"
    Write-Host "    Dest: $archivePath"

    # Remove stale temp files if present
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
    if (Test-Path -LiteralPath $extractDir)  { Remove-Item -LiteralPath $extractDir -Recurse -Force }

    try {
        $webClient = [System.Net.WebClient]::new()
        $webClient.DownloadFile($archiveUrl, $archivePath)
        $webClient.Dispose()
    } catch {
        throw "Download failed: $_"
    }

    # --- Step 3: Verify archive SHA-256 ---
    Write-Host ''
    Write-Host '>>> [Step 3] Verifying archive SHA-256...'
    $archiveHash = Get-FileSha256 -Path $archivePath
    if ($archiveHash -cne $expectedArchiveHashLower) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        throw "Archive SHA-256 mismatch! Expected: $expectedArchiveHashLower  Got: $archiveHash  File deleted."
    }
    Write-Host "[PASS] Archive SHA-256 verified: $archiveHash" -ForegroundColor Green

    # --- Step 4: Extract agy.exe ---
    Write-Host ''
    Write-Host '>>> [Step 4] Extracting agy.exe from archive...'
    $null = New-Item -ItemType Directory -Path $extractDir -Force
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force

    # Archive contains 'antigravity.exe' (the upstream binary name); we install it as 'agy.exe'.
    $extracted = Get-ChildItem -Path $extractDir -Recurse -Include 'antigravity.exe','agy.exe' | Select-Object -First 1
    if ($null -eq $extracted) {
        throw "Neither antigravity.exe nor agy.exe found inside archive $archivePath"
    }
    Write-Host "    Found: $($extracted.FullName)"

    # --- Step 5: Verify extracted executable SHA-256 ---
    Write-Host ''
    Write-Host '>>> [Step 5] Verifying extracted executable SHA-256...'
    $extractedHash = Get-FileSha256 -Path $extracted.FullName
    if ($extractedHash -cne $expectedExeHashLower) {
        throw "Extracted agy.exe SHA-256 mismatch! Expected: $expectedExeHashLower  Got: $extractedHash"
    }
    Write-Host "[PASS] Extracted agy.exe SHA-256 verified: $extractedHash" -ForegroundColor Green

    # --- Step 6: Create destination directory ---
    Write-Host ''
    Write-Host '>>> [Step 6] Creating destination directory...'
    $null = New-Item -ItemType Directory -Path $targetDir -Force
    Write-Host "    Directory: $targetDir"

    # --- Step 7: Copy agy.exe to destination ---
    Write-Host ''
    Write-Host '>>> [Step 7] Copying agy.exe to stable install path...'
    Copy-Item -LiteralPath $extracted.FullName -Destination $targetExe -Force
    Write-Host "    Installed: $targetExe"

    # Cleanup temp files
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Step 8: Apply hardened ACLs ---
Write-Host ''
Write-Host '>>> [Step 8] Applying hardened ACLs...'

# Resolve review user SID dynamically from username
$reviewUser = Get-LocalUser -Name $ReviewUserName -ErrorAction Stop
$reviewSid  = $reviewUser.SID.Value
Write-Host "    Review user '$ReviewUserName' SID: $reviewSid"

# Apply to both directory and file for defense in depth.
# Correct icacls sequence:
#   Step A: Set explicit grants (these will coexist with inherited ACEs temporarily)
#   Step B: /inheritance:r  — promotes any remaining inherited ACEs to explicit, then
#            disables further inheritance (but does NOT wipe our Step A grants)
# This is the documented safe ordering for icacls. We then remove all entries that are
# NOT one of our three intended SIDs using the .NET SetAccessRuleProtection + explicit rebuild.
foreach ($target in @($targetDir, $targetExe)) {
    Write-Host "    Setting ACLs on: $target"

    # Build the ACL entirely via .NET (avoids icacls ordering ambiguity)
    $acl = Get-Acl -LiteralPath $target

    # Disable inheritance and strip all inherited ACEs
    $acl.SetAccessRuleProtection($true, $false)

    # Remove all existing rules
    $acl.Access | ForEach-Object { $acl.RemoveAccessRuleAll($_) }

    # Build a helper to create a FileSystemAccessRule from a SID string
    function New-FsRule {
        param([string]$SidString, [string]$Rights, [string]$Inherit = 'None', [string]$Propagate = 'None')
        $sid   = [Security.Principal.SecurityIdentifier]::new($SidString)
        $acct  = $sid.Translate([Security.Principal.NTAccount])
        $fsRights = [Security.AccessControl.FileSystemRights]$Rights
        $inhFlags  = [Security.AccessControl.InheritanceFlags]$Inherit
        $propFlags = [Security.AccessControl.PropagationFlags]$Propagate
        [Security.AccessControl.FileSystemAccessRule]::new(
            $acct, $fsRights, $inhFlags, $propFlags,
            [Security.AccessControl.AccessControlType]::Allow)
    }

    if (Test-Path -LiteralPath $target -PathType Container) {
        # Directory: also propagate Full/RX to children
        $acl.AddAccessRule((New-FsRule 'S-1-5-18'     'FullControl'       'ContainerInherit,ObjectInherit' 'None'))
        $acl.AddAccessRule((New-FsRule 'S-1-5-32-544' 'FullControl'       'ContainerInherit,ObjectInherit' 'None'))
        $acl.AddAccessRule((New-FsRule $reviewSid      'ReadAndExecute'    'ContainerInherit,ObjectInherit' 'None'))
    } else {
        # File: no inheritance flags
        $acl.AddAccessRule((New-FsRule 'S-1-5-18'     'FullControl'    'None' 'None'))
        $acl.AddAccessRule((New-FsRule 'S-1-5-32-544' 'FullControl'    'None' 'None'))
        $acl.AddAccessRule((New-FsRule $reviewSid      'ReadAndExecute' 'None' 'None'))
    }

    Set-Acl -LiteralPath $target -AclObject $acl
    Write-Host "    ACL set OK: $target"
}

# --- Step 9: Final executable hash verification ---
Write-Host ''
Write-Host '>>> [Step 9] Final hash verification after install...'
$finalHash = Get-FileSha256 -Path $targetExe
if ($finalHash -cne $expectedExeHashLower) {
    throw "Post-install hash mismatch! Expected: $expectedExeHashLower  Got: $finalHash"
}
Write-Host "[PASS] Final agy.exe SHA-256 verified: $finalHash" -ForegroundColor Green

# --- Step 10: Verify ACL structure ---
Write-Host ''
Write-Host '>>> [Step 10] Verifying ACL structure...'

$exeAcl = Get-Acl -LiteralPath $targetExe
if (-not $exeAcl.AreAccessRulesProtected) {
    throw 'Inheritance is NOT disabled on installed binary! ACL setup failed.'
}

$allowedSids = @('S-1-5-18', 'S-1-5-32-544', $reviewSid)
$reviewRxFound = $false

foreach ($rule in $exeAcl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($allowedSids -notcontains $sid) {
        throw "Unexpected ACL principal on $targetExe : $($rule.IdentityReference.Value) ($sid)"
    }
    if ($sid -eq $reviewSid) {
        $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
                     [Security.AccessControl.FileSystemRights]::Delete -bor
                     [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
                     [Security.AccessControl.FileSystemRights]::TakeOwnership
        if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeMask) -ne 0) {
            throw "Review user has write/modify rights on $targetExe — ACL misconfigured!"
        }
        $reviewRxFound = $true
    }
}

if (-not $reviewRxFound) {
    throw "Review user ($reviewSid) has no ACE on $targetExe"
}
Write-Host "[PASS] ACL structure correct: inheritance disabled, SYSTEM/Admins/review(RX) only." -ForegroundColor Green

# --- Step 11: Probe write attempt (should fail for review user) ---
Write-Host ''
Write-Host '>>> [Step 11] Probe: verify agci-review cannot write to installed binary...'
# We verify by checking the access mask directly — a write attempt from admin context would succeed,
# so we validate via the ACL we just verified rather than a live write probe from this elevated session.
Write-Host "[INFO] Write-access probe confirmed via ACL inspection (no write bits for review SID)." -ForegroundColor Cyan
Write-Host "[INFO] To confirm from agci-review context: run Test-AgyPinnedBinaryContract.ps1 as agci-review." -ForegroundColor Cyan

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host "   AGY $Version PINNED BINARY INSTALL COMPLETE" -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "   Path:    $targetExe"
Write-Host "   SHA-256: $finalHash"
Write-Host "   ACLs:    SYSTEM(F) + Administrators(F) + $ReviewUserName(RX) [inheritance disabled]"
Write-Host ''

# Return structured result
[PSCustomObject]@{
    Version              = $Version
    ExecutablePath       = $targetExe
    ExecutableSha256     = $finalHash
    ReviewUserName       = $ReviewUserName
    ReviewUserSid        = $reviewSid
    AclInheritanceDisabled = $exeAcl.AreAccessRulesProtected
    InstallComplete      = $true
}

