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

foreach ($acc in $Accounts) {
    $user = Get-LocalUser -Name $acc -ErrorAction Stop
    $sid = $user.SID.Value
    Write-Host "Creating Windows profile for $acc ($sid)..."
    $path = [UserProfileHelper]::Create($sid, $acc)
    Write-Host "[OK] Profile for $acc initialized: $path"
}

Write-Host "All runner profiles initialized successfully."
