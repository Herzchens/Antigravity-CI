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

    [Parameter(Mandatory)]
    [string] $SigningPublicKeyPath,

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
        throw 'This initialization script must be run elevated as Administrator.'
    }
}
finally {
    $identity.Dispose()
}

$null = Get-Command icacls.exe -ErrorAction Stop
$null = Get-Command ssh-keygen -ErrorAction Stop

function Invoke-Icacls {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $Operation
    )

    & icacls.exe @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed while $Operation (exit code $LASTEXITCODE)."
    }
}

function Convert-IdentityToSid {
    param(
        [Parameter(Mandatory)]
        [string] $Identity
    )

    try {
        $account = [Security.Principal.NTAccount]::new($Identity)
        $sid = $account.Translate([Security.Principal.SecurityIdentifier])
        return $sid.Value
    }
    catch {
        throw "Unable to resolve Windows identity '$Identity' to a SID."
    }
}

function New-SecureLocalUser {
    param(
        [Parameter(Mandatory)]
        [string] $UserName,

        [Parameter(Mandatory)]
        [string] $FullName,

        [Parameter(Mandatory)]
        [ValidateLength(1, 48)]
        [string] $Description
    )

    $existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if (-not $existing.Enabled) {
            throw "Existing local user '$UserName' is disabled."
        }

        $needsUpdate = $false
        $updateParams = @{
            Name = $UserName
        }

        if ($existing.FullName -cne $FullName) {
            $updateParams['FullName'] = $FullName
            $needsUpdate = $true
        }

        if ($existing.Description -cne $Description) {
            $updateParams['Description'] = $Description
            $needsUpdate = $true
        }

        if ($needsUpdate) {
            Set-LocalUser @updateParams -ErrorAction Stop
            Write-Host "[UPDATED] Local user '$UserName' display name/description updated."
            $existing = Get-LocalUser -Name $UserName -ErrorAction Stop
        }
        else {
            Write-Host "[OK] Local user '$UserName' already exists with canonical metadata."
        }

        return $existing
    }

    $password = Read-Host -Prompt "Enter password for standard user '$UserName'" -AsSecureString
    $user = New-LocalUser -Name $UserName -Password $password -FullName $FullName -Description $Description -PasswordNeverExpires:$true

    Write-Host "[CREATED] Local standard user '$UserName' successfully created."
    $user
}

function Assert-NotAdministrator {
    param(
        [Parameter(Mandatory)]
        [string] $UserName,

        [Parameter(Mandatory)]
        [string] $AdministratorsGroupName
    )

    $members = @(Get-LocalGroupMember -Group $AdministratorsGroupName -ErrorAction Stop)
    $memberNames = @($members | ForEach-Object { [string] $_.Name })

    if ($memberNames -contains "$env:COMPUTERNAME\$UserName" -or
        $memberNames -contains $UserName) {
        Remove-LocalGroupMember -Group $AdministratorsGroupName -Member $UserName -ErrorAction Stop
        Write-Host "[RESTRICTED] Removed '$UserName' from Administrators group."
    }

    $remaining = @(Get-LocalGroupMember -Group $AdministratorsGroupName -ErrorAction Stop)
    $remainingNames = @($remaining | ForEach-Object { [string] $_.Name })
    if ($remainingNames -contains "$env:COMPUTERNAME\$UserName" -or
        $remainingNames -contains $UserName) {
        throw "Local user '$UserName' remains in Administrators after restriction."
    }
}

function Protect-DirectoryForIdentity {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $AllowedSid,

        [Parameter(Mandatory)]
        [string[]] $RoleSids
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required runner directory does not exist: $Path"
    }

    $genericReadSids = @(
        '*S-1-1-0',
        '*S-1-5-11',
        '*S-1-5-32-545'
    )

    $roleSidArguments = @($RoleSids | ForEach-Object { '*' + $_ })

    Invoke-Icacls -Arguments @($Path, '/inheritance:r', '/T', '/C', '/Q') -Operation "disabling inherited ACLs on '$Path'"
    Invoke-Icacls -Arguments (@($Path, '/remove:g') + $genericReadSids + $roleSidArguments + @('/T', '/C', '/Q')) -Operation "removing broad and cross-role grants from '$Path'"

    $allowedRule = '*' + $AllowedSid + ':(OI)(CI)(F)'
    $grants = @(
        $Path,
        '/grant:r',
        '*S-1-5-18:(OI)(CI)(F)',
        '*S-1-5-32-544:(OI)(CI)(F)',
        $allowedRule,
        '/T',
        '/C',
        '/Q'
    )
    Invoke-Icacls -Arguments $grants -Operation "granting the intended runner identity on '$Path'"
}

function Protect-Directory {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $ReviewSid,

        [switch] $ReviewReadOnly
    )

    Invoke-Icacls -Arguments @($Path, '/inheritance:r') -Operation "disabling inherited ACLs on '$Path'"

    $grants = @(
        '*S-1-5-18:(OI)(CI)(F)',
        '*S-1-5-32-544:(OI)(CI)(F)'
    )

    if ($ReviewReadOnly) {
        if ([string]::IsNullOrWhiteSpace($ReviewSid)) {
            throw 'ReviewSid is required for a review-readable protected directory.'
        }

        $grants += ('*' + $ReviewSid + ':(OI)(CI)(RX)')
    }

    Invoke-Icacls -Arguments (@($Path, '/grant:r') + $grants) -Operation "setting protected directory ACLs on '$Path'"
}

function Protect-File {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $ReviewSid,

        [switch] $ReviewReadOnly
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required protected file does not exist: $Path"
    }

    Invoke-Icacls -Arguments @($Path, '/inheritance:r') -Operation "disabling inherited ACLs on '$Path'"

    $grants = @(
        '*S-1-5-18:(F)',
        '*S-1-5-32-544:(F)'
    )

    if ($ReviewReadOnly) {
        if ([string]::IsNullOrWhiteSpace($ReviewSid)) {
            throw 'ReviewSid is required for a review-readable protected file.'
        }

        $grants += ('*' + $ReviewSid + ':(R)')
    }

    Invoke-Icacls -Arguments (@($Path, '/grant:r') + $grants) -Operation "setting protected file ACLs on '$Path'"
}

$resolvedSigningPublicKey = (Resolve-Path -LiteralPath $SigningPublicKeyPath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedSigningPublicKey -PathType Leaf)) {
    throw 'SigningPublicKeyPath must reference an existing SSH public key.'
}

$fingerprintOutput = @(& ssh-keygen -lf $resolvedSigningPublicKey 2>&1)
if ($LASTEXITCODE -ne 0 -or $fingerprintOutput.Count -eq 0) {
    throw 'Unable to fingerprint the signing public key.'
}

$fingerprintMatch = [regex]::Match(
    [string] ($fingerprintOutput | Select-Object -First 1),
    'SHA256:[A-Za-z0-9+/=]+'
)
if (-not $fingerprintMatch.Success) {
    throw 'Unable to parse the signing public-key fingerprint.'
}
$signingFingerprint = $fingerprintMatch.Value

Write-Host '=== Phase A: Create Low-Privilege Local Accounts ==='
$reviewUser = New-SecureLocalUser -UserName $ReviewUserName -FullName $ReviewFullName -Description $ReviewDescription
$publisherUser = New-SecureLocalUser -UserName $PublisherUserName -FullName $PublisherFullName -Description $PublisherDescription

$administratorsSid = [Security.Principal.SecurityIdentifier]::new(
    [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
    $null
)
$administratorsGroupName = (
    Get-LocalGroup -ErrorAction Stop |
    Where-Object { $_.SID -eq $administratorsSid } |
    Select-Object -First 1
).Name

if ([string]::IsNullOrWhiteSpace($administratorsGroupName)) {
    throw 'Unable to resolve the local Administrators group.'
}

Assert-NotAdministrator -UserName $ReviewUserName -AdministratorsGroupName $administratorsGroupName
Assert-NotAdministrator -UserName $PublisherUserName -AdministratorsGroupName $administratorsGroupName

$reviewSid = $reviewUser.SID.Value
$publisherSid = $publisherUser.SID.Value
$signingSid = Convert-IdentityToSid -Identity $SigningIdentity

if ($reviewSid -eq $publisherSid -or
    $reviewSid -eq $signingSid -or
    $publisherSid -eq $signingSid) {
    throw 'Signing, Review, and Publisher Windows identities must resolve to distinct SIDs.'
}

Write-Host '=== Phase B: Protect Runner Credential Domains ==='
$signingRunnerDir = Join-Path $InstallBase 'signing'
$reviewRunnerDir = Join-Path $InstallBase 'review'
$publisherRunnerDir = Join-Path $InstallBase 'publisher'
$roleSids = @($signingSid, $reviewSid, $publisherSid)

Protect-DirectoryForIdentity -Path $signingRunnerDir -AllowedSid $signingSid -RoleSids $roleSids
Protect-DirectoryForIdentity -Path $reviewRunnerDir -AllowedSid $reviewSid -RoleSids $roleSids
Protect-DirectoryForIdentity -Path $publisherRunnerDir -AllowedSid $publisherSid -RoleSids $roleSids

Write-Host '=== Phase C: Setup Protected Review Boundary ==='
$null = New-Item -ItemType Directory -Path $ProgramDataBase -Force
$policyDir = Join-Path $ProgramDataBase 'review-policy'
$protectedDir = Join-Path $ProgramDataBase 'protected'
$trustedKeysDir = Join-Path $ProgramDataBase 'trusted-keys'

$null = New-Item -ItemType Directory -Path $policyDir -Force
$null = New-Item -ItemType Directory -Path $protectedDir -Force
$null = New-Item -ItemType Directory -Path $trustedKeysDir -Force

Protect-Directory -Path $ProgramDataBase -ReviewSid $reviewSid -ReviewReadOnly
Protect-Directory -Path $policyDir -ReviewSid $reviewSid -ReviewReadOnly
Protect-Directory -Path $protectedDir
Protect-Directory -Path $trustedKeysDir -ReviewSid $reviewSid -ReviewReadOnly

$sentinelPath = Join-Path $protectedDir 'operator-sentinel.bin'
if (-not (Test-Path -LiteralPath $sentinelPath)) {
    Set-Content -LiteralPath $sentinelPath -Value 'operator-sentinel-payload-deadbeef' -Encoding utf8NoBOM
}

$manifestPath = Join-Path $policyDir 'protected-read-probes.json'
$manifestContent = [ordered]@{
    schema_version = 1
    probes = @(
        [ordered]@{
            name = 'operator-sentinel'
            path = $sentinelPath
        }
    )
} | ConvertTo-Json -Depth 8
Set-Content -LiteralPath $manifestPath -Value $manifestContent -Encoding utf8NoBOM

$trustedPublicKeyPath = Join-Path $trustedKeysDir 'signing-public.pub'
Copy-Item -LiteralPath $resolvedSigningPublicKey -Destination $trustedPublicKeyPath -Force

Protect-File -Path $sentinelPath
Protect-File -Path $manifestPath -ReviewSid $reviewSid -ReviewReadOnly
Protect-File -Path $trustedPublicKeyPath -ReviewSid $reviewSid -ReviewReadOnly

$trustedFingerprintOutput = @(& ssh-keygen -lf $trustedPublicKeyPath 2>&1)
if ($LASTEXITCODE -ne 0 -or $trustedFingerprintOutput.Count -eq 0) {
    throw 'Unable to fingerprint the review verification-key copy.'
}

$trustedFingerprintMatch = [regex]::Match(
    [string] ($trustedFingerprintOutput | Select-Object -First 1),
    'SHA256:[A-Za-z0-9+/=]+'
)
if (-not $trustedFingerprintMatch.Success -or
    $trustedFingerprintMatch.Value -cne $signingFingerprint) {
    throw 'Review verification-key copy does not match the signing public-key fingerprint.'
}

Write-Host '[OK] Runner credentials are isolated by role.'
Write-Host '[OK] Review protected-read boundary and public verification key are configured.'
Write-Host 'Initialization completed successfully.'

[pscustomobject][ordered]@{
    SigningIdentity = $SigningIdentity
    SigningSid = $signingSid
    ReviewIdentity = "$env:COMPUTERNAME\$ReviewUserName"
    ReviewSid = $reviewSid
    PublisherIdentity = "$env:COMPUTERNAME\$PublisherUserName"
    PublisherSid = $publisherSid
    SigningRunnerDirectory = $signingRunnerDir
    ReviewRunnerDirectory = $reviewRunnerDir
    PublisherRunnerDirectory = $publisherRunnerDir
    ProtectedReadProbeManifest = $manifestPath
    ReviewTrustedPublicKeyPath = $trustedPublicKeyPath
    TrustedKeyFingerprint = $signingFingerprint
    Valid = $true
}
