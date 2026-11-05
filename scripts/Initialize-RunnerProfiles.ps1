#requires -Version 7.4

[CmdletBinding()]
param(
    [string[]] $Accounts = @('agci-review', 'agci-publisher')
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
            // 0x800700B7 = ERROR_ALREADY_EXISTS (183)
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

$sandboxSkeletonDirs = @(
    '.cache\ccache',
    '.cargo',
    '.ccache',
    '.config\yarn',
    '.deno',
    '.dotnet\corefx\cryptography',
    '.dzil',
    '.gradle\caches',
    '.local\share\uv',
    '.m2',
    '.nimble',
    '.nuget',
    '.nvm',
    '.volta',
    'AppData\Local\Volta',
    'AppData\Local\Yarn',
    'AppData\Local\ccache',
    'AppData\Local\nvm',
    'AppData\Local\pnpm',
    'AppData\Roaming\npm',
    'AppData\Roaming\nvm',
    'AppData\Roaming\uv\data',
    'AppData\Roaming\yarn',
    'Library\Preferences',
    'scoop'
)

foreach ($acc in $Accounts) {
    $user = Get-LocalUser -Name $acc -ErrorAction Stop
    $sid = $user.SID.Value
    $profile = Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Select-Object -First 1
    $profilePath = $null
    if ($null -ne $profile -and (Test-Path -LiteralPath $profile.LocalPath)) {
        Write-Host "[OK] Profile for $acc already exists: $($profile.LocalPath)"
        $profilePath = $profile.LocalPath
    }
    else {
        Write-Host "Creating Windows profile for $acc ($sid)..."
        $profilePath = [UserProfileHelper]::Create($sid, $acc)
        Write-Host "[OK] Profile for $acc initialized: $profilePath"
    }

    if (-not [string]::IsNullOrWhiteSpace($profilePath) -and (Test-Path -LiteralPath $profilePath)) {
        foreach ($sub in $sandboxSkeletonDirs) {
            $targetDir = Join-Path $profilePath $sub
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
        }
    }
}

Write-Host "All runner profiles initialized successfully."
