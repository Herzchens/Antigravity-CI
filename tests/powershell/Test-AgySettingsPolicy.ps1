#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$policy = Join-Path $repoRoot 'scripts\Assert-AgySettingsPolicy.ps1'

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $threw = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        throw "Expected failure: $Name"
    }

    Write-Host "[PASS] $Name"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-settings-policy-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $validPath = Join-Path $tempRoot 'valid.json'
    @'
{
  "enableTerminalSandbox": true,
  "toolPermission": "proceed-in-sandbox",
  "allowNonWorkspaceAccess": false,
  "historySize": 0,
  "disableSlashCommands": true,
  "permissions": {
    "allow": [],
    "deny": ["read_url(*)"]
  }
}
'@ | Set-Content -LiteralPath $validPath -Encoding utf8NoBOM

    $valid = & $policy -SettingsPath $validPath
    if (-not $valid.Valid -or $valid.ToolPermission -ne 'proceed-in-sandbox') {
        throw 'Minimal safe settings fixture did not pass.'
    }

    Write-Host '[PASS] minimal review settings policy is accepted'
    Write-Host '[PASS] restrictive permissions.deny rules remain allowed'

    $cases = @(
        @{
            Name = 'always-proceed is rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"always-proceed","historySize":0,"disableSlashCommands":true}'
        },
        @{
            Name = 'non-workspace access is rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"proceed-in-sandbox","allowNonWorkspaceAccess":true,"historySize":0,"disableSlashCommands":true}'
        },
        @{
            Name = 'permission allow rules are rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"proceed-in-sandbox","historySize":0,"disableSlashCommands":true,"permissions":{"allow":["command(git push)"]}}'
        },
        @{
            Name = 'permission ask rules are rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"proceed-in-sandbox","historySize":0,"disableSlashCommands":true,"permissions":{"ask":["command(*)"]}}'
        },
        @{
            Name = 'unknown permission field is rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"proceed-in-sandbox","historySize":0,"disableSlashCommands":true,"permissions":{"futureMode":[]}}'
        },
        @{
            Name = 'unknown top-level setting is rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"proceed-in-sandbox","historySize":0,"disableSlashCommands":true,"futureCapability":true}'
        },
        @{
            Name = 'persistent auto mode is rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"proceed-in-sandbox","agentMode":"auto","historySize":0,"disableSlashCommands":true}'
        },
        @{
            Name = 'history persistence is rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"proceed-in-sandbox","historySize":2000,"disableSlashCommands":true}'
        },
        @{
            Name = 'custom model provider is rejected'
            Json = '{"enableTerminalSandbox":true,"toolPermission":"proceed-in-sandbox","historySize":0,"disableSlashCommands":true,"modelProvider":"gemini"}'
        }
    )

    foreach ($case in $cases) {
        $path = Join-Path $tempRoot (([Guid]::NewGuid().ToString('N')) + '.json')
        Set-Content -LiteralPath $path -Value $case.Json -Encoding utf8NoBOM
        Assert-Throws -Name $case.Name -Action {
            & $policy -SettingsPath $path
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
