#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$policy = Join-Path $repoRoot 'scripts\Assert-AgyHostPolicy.ps1'

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
    'antigravity-ci-host-policy-' + [Guid]::NewGuid().ToString('N')
)
$home = Join-Path $tempRoot 'home'
$settingsDir = Join-Path $home '.gemini\antigravity-cli'
$settingsPath = Join-Path $settingsDir 'settings.json'

New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null

try {
    @'
{
  "enableTerminalSandbox": true,
  "toolPermission": "proceed-in-sandbox",
  "allowNonWorkspaceAccess": false,
  "historySize": 0,
  "disableSlashCommands": true,
  "permissions": { "allow": [] }
}
'@ | Set-Content -LiteralPath $settingsPath -Encoding utf8NoBOM

    $result = & $policy -HomeDirectory $home
    if (-not $result.Valid) {
        throw 'Clean dedicated review home did not pass.'
    }

    Write-Host '[PASS] dedicated review home without global customizations is accepted'

    $hooks = Join-Path $home '.gemini\config\hooks.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $hooks) -Force | Out-Null
    Set-Content -LiteralPath $hooks -Value '{}' -Encoding utf8NoBOM

    Assert-Throws -Name 'global hooks are rejected' -Action {
        & $policy -HomeDirectory $home
    }

    Remove-Item -LiteralPath $hooks -Force

    $skill = Join-Path $home '.gemini\antigravity-cli\skills\evil\SKILL.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $skill) -Force | Out-Null
    Set-Content -LiteralPath $skill -Value 'fixture' -Encoding utf8NoBOM

    Assert-Throws -Name 'global skills are rejected' -Action {
        & $policy -HomeDirectory $home
    }

    Remove-Item -LiteralPath (Join-Path $home '.gemini\antigravity-cli\skills') -Recurse -Force

    $projectOverride = Join-Path $home '.gemini\config\projects\fixture.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $projectOverride) -Force | Out-Null
    Set-Content -LiteralPath $projectOverride -Value '{"permissionPreset":"turbo"}' -Encoding utf8NoBOM

    Assert-Throws -Name 'saved project-specific overrides are rejected' -Action {
        & $policy -HomeDirectory $home
    }

    Remove-Item -LiteralPath (Join-Path $home '.gemini\config\projects') -Recurse -Force

    $legacyGlobalRule = Join-Path $home '.gemini\antigravity-cli\rules\legacy.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyGlobalRule) -Force | Out-Null
    Set-Content -LiteralPath $legacyGlobalRule -Value 'global injected rule' -Encoding utf8NoBOM

    Assert-Throws -Name 'global CLI rules are rejected' -Action {
        & $policy -HomeDirectory $home
    }

    Remove-Item -LiteralPath (Join-Path $home '.gemini\antigravity-cli\rules') -Recurse -Force

    $registry = Join-Path $home '.gemini\config\plugins.json'
    Set-Content -LiteralPath $registry -Value '{}' -Encoding utf8NoBOM

    Assert-Throws -Name 'global customization registries are rejected' -Action {
        & $policy -HomeDirectory $home
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
