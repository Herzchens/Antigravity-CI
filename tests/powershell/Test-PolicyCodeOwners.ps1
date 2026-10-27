#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$generator = Join-Path $repoRoot 'scripts\New-PolicyCodeOwners.ps1'

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
    'antigravity-ci-codeowners-' + [Guid]::NewGuid().ToString('N')
)
$codeOwnersPath = Join-Path $tempRoot '.github\CODEOWNERS'
New-Item -ItemType Directory -Path (Split-Path -Parent $codeOwnersPath) -Force | Out-Null

try {
    @(
        '# existing broad ownership',
        '* @global-owner',
        '.agy/project.toml @old-owner',
        ''
    ) | Set-Content -LiteralPath $codeOwnersPath -Encoding utf8NoBOM

    $parameters = @{
        OutputPath = $codeOwnersPath
        CodeOwner = '@Herzchens'
        CallerWorkflowPath = '.github/workflows/antigravity-review.yml'
    }

    Assert-Throws -Name 'conflicting exact policy owner requires explicit force' -Action {
        & $generator @parameters
    }

    $parameters.Force = $true
    $result = & $generator @parameters

    if ($result.PolicyEntryCount -ne 2) {
        throw 'Generator did not report the two privileged policy entries.'
    }

    $lines = @(Get-Content -LiteralPath $codeOwnersPath -Encoding utf8)
    if ($lines -notcontains '* @global-owner') {
        throw 'Existing unrelated CODEOWNERS rules were not preserved.'
    }

    $callerMatches = @($lines | Where-Object {
        $_ -ceq '.github/workflows/antigravity-review.yml @Herzchens'
    })
    $configMatches = @($lines | Where-Object {
        $_ -ceq '.agy/project.toml @Herzchens'
    })

    if ($callerMatches.Count -ne 1 -or $configMatches.Count -ne 1) {
        throw 'Privileged CODEOWNERS entries were not rendered exactly once.'
    }

    $nonBlank = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonBlank[-2] -cne '.github/workflows/antigravity-review.yml @Herzchens' -or
        $nonBlank[-1] -cne '.agy/project.toml @Herzchens') {
        throw 'Privileged CODEOWNERS entries must be the final matching rules.'
    }

    $before = Get-Content -LiteralPath $codeOwnersPath -Raw -Encoding utf8
    $parameters.Remove('Force')
    $null = & $generator @parameters
    $after = Get-Content -LiteralPath $codeOwnersPath -Raw -Encoding utf8

    if ($before -cne $after) {
        throw 'CODEOWNERS generation is not idempotent for an already-correct policy.'
    }

    $unsafeParameters = @{
        OutputPath = $codeOwnersPath
        CodeOwner = '@Herzchens'
        CallerWorkflowPath = '../outside.yml'
        Force = $true
    }

    Assert-Throws -Name 'unsafe caller workflow path is rejected' -Action {
        & $generator @unsafeParameters
    }

    Write-Host '[PASS] existing broad CODEOWNERS rules are preserved'
    Write-Host '[PASS] exact privileged rules are last and therefore override broader patterns'
    Write-Host '[PASS] CODEOWNERS policy generation is idempotent'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
