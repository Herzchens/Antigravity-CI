#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $ReviewUserName = 'agci-review',
    [string] $PublisherUserName = 'agci-publisher',
    [string] $InstallBase = 'C:\actions-runner',
    [string] $ProgramDataBase = 'C:\ProgramData\Antigravity-CI'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This script is intended for Windows host configuration.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This initialization script must be run elevated as Administrator.'
}

function New-SecureLocalUser {
    param(
        [Parameter(Mandatory)][string] $UserName,
        [Parameter(Mandatory)][string] $Description
    )

    $existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Host "[OK] Local user '$UserName' already exists."
        return $existing
    }

    $password = Read-Host -Prompt "Enter password for standard user '$UserName'" -AsSecureString
    $user = New-LocalUser -Name $UserName -Password $password -FullName $UserName -Description $Description -PasswordNeverExpires:$true
    Write-Host "[CREATED] Local standard user '$UserName' successfully created."
    $user
}

Write-Host "=== Phase A: Create Low-Privilege Local Accounts ==="
$reviewUser = New-SecureLocalUser -UserName $ReviewUserName -Description 'Antigravity-CI Dedicated Standard Review Runner'
$publisherUser = New-SecureLocalUser -UserName $PublisherUserName -Description 'Antigravity-CI Dedicated Standard Publisher Runner'

$adminGroup = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
$adminGroupName = (Get-LocalGroup | Where-Object { $_.SID -eq $adminGroup }).Name

foreach ($u in @($ReviewUserName, $PublisherUserName)) {
    $members = Get-LocalGroupMember -Group $adminGroupName -ErrorAction SilentlyContinue
    if ($members.Name -contains "$env:COMPUTERNAME\$u" -or $members.Name -contains $u) {
        Remove-LocalGroupMember -Group $adminGroupName -Member $u
        Write-Host "[RESTRICTED] Removed '$u' from Administrators group."
    }
}

Write-Host "=== Phase B: Setup Protected Filesystem Boundary ==="
$policyDir = Join-Path $ProgramDataBase 'review-policy'
$protectedDir = Join-Path $ProgramDataBase 'protected'
$null = New-Item -ItemType Directory -Path $policyDir -Force
$null = New-Item -ItemType Directory -Path $protectedDir -Force

$sentinelPath = Join-Path $protectedDir 'operator-sentinel.bin'
if (-not (Test-Path -LiteralPath $sentinelPath)) {
    Set-Content -LiteralPath $sentinelPath -Value 'operator-sentinel-payload-deadbeef' -Encoding utf8NoBOM
}

$manifestPath = Join-Path $policyDir 'protected-read-probes.json'
$manifestContent = @'
{
  "schema_version": 1,
  "probes": [
    {
      "name": "operator-sentinel",
      "path": "C:\\ProgramData\\Antigravity-CI\\protected\\operator-sentinel.bin"
    }
  ]
}
'@
Set-Content -LiteralPath $manifestPath -Value $manifestContent -Encoding utf8NoBOM

Write-Host "=== Phase C: Apply Boundary ACLs ==="
& icacls.exe $sentinelPath /deny "${ReviewUserName}:(R)" | Out-Null
& icacls.exe $protectedDir /deny "${ReviewUserName}:(WD,AD,WA,WEA)" | Out-Null
& icacls.exe $manifestPath /grant "${ReviewUserName}:(R)" | Out-Null
& icacls.exe $manifestPath /deny "${ReviewUserName}:(WD,AD,WA,WEA)" | Out-Null
& icacls.exe $policyDir /deny "${ReviewUserName}:(WD,AD,WA,WEA)" | Out-Null

Write-Host "[OK] Filesystem boundary ACLs configured."

Write-Host "=== Phase D: Runner Directory Permissions ==="
$reviewRunnerDir = Join-Path $InstallBase 'review'
$publisherRunnerDir = Join-Path $InstallBase 'publisher'

if (Test-Path -LiteralPath $reviewRunnerDir) {
    & icacls.exe $reviewRunnerDir /grant "${ReviewUserName}:(OI)(CI)(F)" /T | Out-Null
    Write-Host "[OK] Granted $ReviewUserName access to $reviewRunnerDir"
}

if (Test-Path -LiteralPath $publisherRunnerDir) {
    & icacls.exe $publisherRunnerDir /grant "${PublisherUserName}:(OI)(CI)(F)" /T | Out-Null
    Write-Host "[OK] Granted $PublisherUserName access to $publisherRunnerDir"
}

Write-Host "Initialization completed successfully."
