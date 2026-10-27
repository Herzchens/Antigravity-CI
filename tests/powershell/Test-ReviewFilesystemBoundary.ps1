#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    Write-Host '[SKIP] filesystem-boundary fixture requires Windows'
    return
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$boundary = Join-Path $repoRoot 'scripts\Test-ReviewFilesystemBoundary.ps1'

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
    'antigravity-ci-filesystem-boundary-' + [Guid]::NewGuid().ToString('N')
)
$fakeHome = Join-Path $tempRoot 'review-home'
$outside = Join-Path $tempRoot 'outside'
$manifestRoot = Join-Path $tempRoot 'policy'
$manifest = Join-Path $manifestRoot 'protected-read-probes.json'

New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
New-Item -ItemType Directory -Path $manifestRoot -Force | Out-Null
New-Item -ItemType Directory -Path $outside -Force | Out-Null

try {
    $readableSentinel = Join-Path $outside 'readable.txt'
    Set-Content -LiteralPath $readableSentinel -Value 'must be denied in production' -Encoding utf8NoBOM

    [ordered]@{
        schema_version = 1
        probes = @(
            [ordered]@{
                name = 'owner-private'
                path = $readableSentinel
            }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM

    Assert-Throws -Name 'readable outside-profile sentinel is rejected' -Action {
        & $boundary -ManifestPath $manifest -HomeDirectory $fakeHome
    }

    $insideSentinel = Join-Path $fakeHome 'inside.txt'
    Set-Content -LiteralPath $insideSentinel -Value 'inside home' -Encoding utf8NoBOM

    [ordered]@{
        schema_version = 1
        probes = @(
            [ordered]@{
                name = 'inside-home'
                path = $insideSentinel
            }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM

    Assert-Throws -Name 'sentinel inside review profile is rejected' -Action {
        & $boundary -ManifestPath $manifest -HomeDirectory $fakeHome
    }

    [ordered]@{
        schema_version = 1
        probes = @(
            [ordered]@{
                name = 'missing'
                path = (Join-Path $outside 'missing.txt')
            }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM

    Assert-Throws -Name 'missing sentinel does not count as ACL isolation' -Action {
        & $boundary -ManifestPath $manifest -HomeDirectory $fakeHome
    }

    [ordered]@{
        schema_version = 1
        probes = @(
            [ordered]@{
                name = 'owner-private'
                path = $readableSentinel
                command = 'ignored'
            }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM

    Assert-Throws -Name 'unknown manifest properties are rejected' -Action {
        & $boundary -ManifestPath $manifest -HomeDirectory $fakeHome
    }

    Write-Host '[PASS] positive ACL-denial verification is intentionally reserved for the real review account setup'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
