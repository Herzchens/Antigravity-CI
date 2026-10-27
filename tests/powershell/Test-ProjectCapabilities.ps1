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

    $networkAllowed = & $gate -ProjectConfigPath $networkPath -AllowNetwork $true
    if (-not $networkAllowed.Valid -or -not $networkAllowed.RequestedNetwork) {
        throw 'Explicitly allowed network capability did not validate.'
    }

    Write-Host '[PASS] deployment must explicitly allow a requested capability'

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

    Assert-Throws -Name 'partial deployment allowance cannot satisfy extra capabilities' -Action {
        & $gate -ProjectConfigPath $allPath -AllowAdb $true -AllowNetwork $true
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
