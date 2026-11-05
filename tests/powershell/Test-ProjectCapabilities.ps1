#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$gate = Join-Path $repoRoot 'scripts\Test-ProjectCapabilities.ps1'

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
    'antigravity-ci-capability-test-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $safePath = Join-Path $tempRoot 'safe.json'
    @{
        schema_version = 1
        project = @{
            name = 'Safe'
            type = 'powershell'
        }
        features = @{
            adb = $false
            network = $false
            gui = $false
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $safePath -Encoding utf8NoBOM

    $safe = & $gate -ProjectConfigPath $safePath
    if (-not $safe.Valid) {
        throw 'Safe capability set did not validate.'
    }

    Write-Host '[PASS] all-disabled project fits the default deployment ceiling'

    $networkPath = Join-Path $tempRoot 'network.json'
    @{
        schema_version = 1
        project = @{
            name = 'Network'
            type = 'powershell'
        }
        features = @{
            adb = $false
            network = $true
            gui = $false
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $networkPath -Encoding utf8NoBOM

    Assert-Throws -Name 'network request is rejected by default' -Action {
        & $gate -ProjectConfigPath $networkPath
    }

    Assert-Throws -Name 'deployment allow alone cannot activate network capability' -Action {
        & $gate -ProjectConfigPath $networkPath -AllowNetwork $true
    }

    $networkParameters = @{
        ProjectConfigPath = $networkPath
        AllowNetwork = $true
        RuntimeNetworkReady = $true
    }
    $networkReady = & $gate @networkParameters

    if (-not $networkReady.Valid -or
        -not $networkReady.RequestedNetwork -or
        -not $networkReady.RuntimeNetworkReady) {
        throw 'Two-key network capability gate did not validate.'
    }

    Write-Host '[PASS] sensitive capability needs deployment approval plus verified runtime readiness'

    $allPath = Join-Path $tempRoot 'all.json'
    @{
        schema_version = 1
        project = @{
            name = 'All'
            type = 'powershell'
        }
        features = @{
            adb = $true
            network = $true
            gui = $true
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $allPath -Encoding utf8NoBOM

    $allParameters = @{
        ProjectConfigPath = $allPath
        AllowAdb = $true
        AllowNetwork = $true
        AllowGui = $true
        RuntimeAdbReady = $true
        RuntimeNetworkReady = $true
    }

    Assert-Throws -Name 'GUI remains out of scope even when deployment flag is enabled' -Action {
        & $gate @allParameters
    }

    $adbOnlyPath = Join-Path $tempRoot 'adb.json'
    @{
        schema_version = 1
        project = @{
            name = 'Adb'
            type = 'android'
        }
        features = @{
            adb = $true
            network = $false
            gui = $false
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $adbOnlyPath -Encoding utf8NoBOM

    Assert-Throws -Name 'deployment allow alone cannot activate ADB capability' -Action {
        & $gate -ProjectConfigPath $adbOnlyPath -AllowAdb $true
    }

    $adbParameters = @{
        ProjectConfigPath = $adbOnlyPath
        AllowAdb = $true
        RuntimeAdbReady = $true
    }
    $adbReady = & $gate @adbParameters

    if (-not $adbReady.Valid -or
        -not $adbReady.RequestedAdb -or
        -not $adbReady.RuntimeAdbReady) {
        throw 'Two-key ADB capability gate did not validate.'
    }

    Write-Host '[PASS] ADB also requires independent runtime readiness'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
