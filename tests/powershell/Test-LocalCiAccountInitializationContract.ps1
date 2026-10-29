#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $repoRoot 'scripts\Initialize-LocalCiAccounts.ps1'
$script = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string] $Needle,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not $script.Contains($Needle, [StringComparison]::Ordinal)) {
        throw "Local CI account initialization contract missing: $Name"
    }

    Write-Host "[PASS] $Name"
}

Assert-Contains -Needle '[string] $SigningPublicKeyPath' -Name 'operator setup requires the signing public-key path'
Assert-Contains -Needle "Join-Path `$InstallBase 'signing'" -Name 'operator setup protects the signing runner directory'
Assert-Contains -Needle "Join-Path `$InstallBase 'review'" -Name 'operator setup protects the review runner directory'
Assert-Contains -Needle "Join-Path `$InstallBase 'publisher'" -Name 'operator setup protects the publisher runner directory'
Assert-Contains -Needle "'/inheritance:r'" -Name 'operator setup disables inherited runner and policy ACLs'
Assert-Contains -Needle "'*S-1-1-0'" -Name 'operator setup removes Everyone grants from runner credential domains'
Assert-Contains -Needle "'*S-1-5-11'" -Name 'operator setup removes Authenticated Users grants from runner credential domains'
Assert-Contains -Needle "'*S-1-5-32-545'" -Name 'operator setup removes builtin Users grants from runner credential domains'
Assert-Contains -Needle 'Signing, Review, and Publisher Windows identities must resolve to distinct SIDs.' -Name 'operator setup enforces distinct trust-domain identities'
Assert-Contains -Needle "Join-Path `$ProgramDataBase 'trusted-keys'" -Name 'operator setup provisions a public-only trusted-key directory'
Assert-Contains -Needle "Join-Path `$trustedKeysDir 'signing-public.pub'" -Name 'operator setup provisions the canonical review verification-key path'
Assert-Contains -Needle 'Review verification-key copy does not match the signing public-key fingerprint.' -Name 'operator setup verifies copied public-key identity'
Assert-Contains -Needle 'Protect-File -Path $sentinelPath' -Name 'operator setup denies review access to the protected sentinel'
Assert-Contains -Needle 'Protect-File -Path $manifestPath -ReviewSid $reviewSid -ReviewReadOnly' -Name 'operator setup keeps the probe manifest readable but not writable by review'
Assert-Contains -Needle 'Protect-File -Path $trustedPublicKeyPath -ReviewSid $reviewSid -ReviewReadOnly' -Name 'operator setup keeps the verification key public-only and read-only'
Assert-Contains -Needle 'Assert-NotAdministrator -UserName $ReviewUserName' -Name 'operator setup removes Review from local Administrators'
Assert-Contains -Needle 'Assert-NotAdministrator -UserName $PublisherUserName' -Name 'operator setup removes Publisher from local Administrators'

Write-Host '[PASS] local CI account initialization contract is fail-closed by role'
