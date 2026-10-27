#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $HomeDirectory = $HOME,

    [string] $SettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$homeRoot = [System.IO.Path]::GetFullPath($HomeDirectory)

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $homeRoot '.gemini\antigravity-cli\settings.json'
}

$settingsPolicy = Join-Path $PSScriptRoot 'Assert-AgySettingsPolicy.ps1'
if (-not (Test-Path -LiteralPath $settingsPolicy -PathType Leaf)) {
    throw 'Assert-AgySettingsPolicy.ps1 is required next to Assert-AgyHostPolicy.ps1.'
}

$blockedFiles = @(
    (Join-Path $homeRoot '.gemini\AGENTS.md'),
    (Join-Path $homeRoot '.gemini\GEMINI.md'),
    (Join-Path $homeRoot '.gemini\config\AGENTS.md'),
    (Join-Path $homeRoot '.gemini\config\GEMINI.md'),
    (Join-Path $homeRoot '.gemini\config\hooks.json'),
    (Join-Path $homeRoot '.gemini\config\mcp_config.json'),
    (Join-Path $homeRoot '.gemini\config\skills.json'),
    (Join-Path $homeRoot '.gemini\config\rules.json'),
    (Join-Path $homeRoot '.gemini\config\plugins.json'),
    (Join-Path $homeRoot '.gemini\config\agents.json'),
    (Join-Path $homeRoot '.gemini\antigravity-cli\hooks.json'),
    (Join-Path $homeRoot '.gemini\antigravity-cli\mcp_config.json')
)

foreach ($path in $blockedFiles) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        throw 'Review account exposes a global Antigravity customization file.'
    }
}

$blockedDirectories = @(
    (Join-Path $homeRoot '.gemini\config\plugins'),
    (Join-Path $homeRoot '.gemini\config\skills'),
    (Join-Path $homeRoot '.gemini\config\agents'),
    (Join-Path $homeRoot '.gemini\config\rules'),
    (Join-Path $homeRoot '.gemini\config\projects'),
    (Join-Path $homeRoot '.gemini\antigravity-cli\plugins'),
    (Join-Path $homeRoot '.gemini\antigravity-cli\skills'),
    (Join-Path $homeRoot '.gemini\antigravity-cli\agents'),
    (Join-Path $homeRoot '.gemini\antigravity-cli\rules')
)

foreach ($path in $blockedDirectories) {
    if (Test-Path -LiteralPath $path) {
        throw 'Review account exposes a global Antigravity customization directory.'
    }
}

$settings = & $settingsPolicy -SettingsPath $SettingsPath

[pscustomobject][ordered]@{
    HomeDirectory = $homeRoot
    SettingsPath = $settings.SettingsPath
    SettingsSha256 = $settings.SettingsSha256
    GlobalCustomizationsPresent = $false
    Valid = $true
}
