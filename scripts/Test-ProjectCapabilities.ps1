#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectConfigPath,

    [bool] $AllowAdb = $false,

    [bool] $AllowNetwork = $false,

    [bool] $AllowGui = $false,

    [bool] $RuntimeAdbReady = $false,

    [bool] $RuntimeNetworkReady = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = (Resolve-Path -LiteralPath $ProjectConfigPath -ErrorAction Stop).Path
$configText = Get-Content -LiteralPath $configPath -Raw -Encoding utf8

try {
    $config = ConvertFrom-Json -InputObject $configText -Depth 16 -ErrorAction Stop
}
catch {
    throw 'Normalized project configuration is not valid JSON.'
}

if ($null -eq $config.PSObject.Properties['features']) {
    throw 'Normalized project configuration does not contain features.'
}

$requested = [ordered]@{
    adb = [bool] $config.features.adb
    network = [bool] $config.features.network
    gui = [bool] $config.features.gui
}

$allowed = [ordered]@{
    adb = $AllowAdb
    network = $AllowNetwork
    gui = $AllowGui
}

if ($AllowGui -or $requested.gui) {
    throw 'GUI/computer-use capability is out of scope for Antigravity-CI v1.'
}

foreach ($name in @('adb', 'network')) {
    if ($requested[$name] -and -not $allowed[$name]) {
        throw "Project requests capability '$name', but this runner deployment does not allow it."
    }
}

if ($requested.adb -and -not $RuntimeAdbReady) {
    throw 'ADB was allowed by deployment policy but no verified runtime ADB boundary is active.'
}

if ($requested.network -and -not $RuntimeNetworkReady) {
    throw 'Network was allowed by deployment policy but no verified domain-scoped runtime network boundary is active.'
}

[pscustomobject][ordered]@{
    RequestedAdb = $requested.adb
    RequestedNetwork = $requested.network
    RequestedGui = $requested.gui
    AllowedAdb = $allowed.adb
    AllowedNetwork = $allowed.network
    AllowedGui = $false
    RuntimeAdbReady = $RuntimeAdbReady
    RuntimeNetworkReady = $RuntimeNetworkReady
    Valid = $true
}
