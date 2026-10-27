#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$gate = Join-Path $repoRoot 'scripts\Resolve-PullRequestContext.ps1'

function Write-EventFixture {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [hashtable] $Overrides
    )

    $event = [ordered]@{
        action = 'synchronize'
        pull_request = [ordered]@{
            number = 17
            draft = $false
            base = [ordered]@{
                ref = 'main'
                sha = '1111111111111111111111111111111111111111'
                repo = [ordered]@{
                    id = 1435102796
                    full_name = 'Herzchens/Antigravity-CI'
                }
            }
            head = [ordered]@{
                ref = 'feat/example'
                sha = '2222222222222222222222222222222222222222'
                repo = [ordered]@{
                    id = 1435102796
                    full_name = 'Herzchens/Antigravity-CI'
                }
            }
        }
    }

    foreach ($key in $Overrides.Keys) {
        switch ($key) {
            'action' { $event.action = $Overrides[$key] }
            'draft' { $event.pull_request.draft = $Overrides[$key] }
            'base_ref' { $event.pull_request.base.ref = $Overrides[$key] }
            'base_sha' { $event.pull_request.base.sha = $Overrides[$key] }
            'base_repo' { $event.pull_request.base.repo.full_name = $Overrides[$key] }
            'base_repo_id' { $event.pull_request.base.repo.id = $Overrides[$key] }
            'head_ref' { $event.pull_request.head.ref = $Overrides[$key] }
            'head_sha' { $event.pull_request.head.sha = $Overrides[$key] }
            'head_repo' { $event.pull_request.head.repo.full_name = $Overrides[$key] }
            'head_repo_id' { $event.pull_request.head.repo.id = $Overrides[$key] }
            default { throw "Unknown test override '$key'." }
        }
    }

    $event |
        ConvertTo-Json -Depth 16 |
        Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

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
    'antigravity-ci-pr-context-test-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$common = @{
    EventName = 'pull_request'
    ExpectedRepository = 'Herzchens/Antigravity-CI'
    ExpectedBaseRef = 'main'
}

try {
    $validPath = Join-Path $tempRoot 'valid.json'
    Write-EventFixture -Path $validPath -Overrides @{}

    $validParameters = $common.Clone()
    $validParameters.EventPath = $validPath
    $resolved = & $gate @validParameters

    if ($resolved.Repository -ne 'Herzchens/Antigravity-CI' -or
        $resolved.PrNumber -ne 17 -or
        $resolved.Action -ne 'synchronize') {
        throw 'Valid pull-request context was not resolved correctly.'
    }

    if ($resolved.TrustedConfigRef -ne '1111111111111111111111111111111111111111') {
        throw 'Trusted config ref must be the base SHA.'
    }

    if ($resolved.ReviewCodeRef -ne '2222222222222222222222222222222222222222') {
        throw 'Review code ref must be the exact PR head SHA.'
    }

    Write-Host '[PASS] same-repository ready PR resolves to trusted base config and exact head code refs'

    $forkPath = Join-Path $tempRoot 'fork.json'
    Write-EventFixture -Path $forkPath -Overrides @{
        head_repo = 'attacker/Antigravity-CI'
        head_repo_id = 999999
    }

    $forkParameters = $common.Clone()
    $forkParameters.EventPath = $forkPath
    Assert-Throws -Name 'fork PR is rejected' -Action {
        & $gate @forkParameters
    }

    $sameNameDifferentIdPath = Join-Path $tempRoot 'different-id.json'
    Write-EventFixture -Path $sameNameDifferentIdPath -Overrides @{
        head_repo_id = 999999
    }

    $differentIdParameters = $common.Clone()
    $differentIdParameters.EventPath = $sameNameDifferentIdPath
    Assert-Throws -Name 'repository ID mismatch is rejected' -Action {
        & $gate @differentIdParameters
    }

    $draftPath = Join-Path $tempRoot 'draft.json'
    Write-EventFixture -Path $draftPath -Overrides @{
        action = 'opened'
        draft = $true
    }

    $draftParameters = $common.Clone()
    $draftParameters.EventPath = $draftPath
    Assert-Throws -Name 'draft PR is rejected' -Action {
        & $gate @draftParameters
    }

    $closedPath = Join-Path $tempRoot 'closed.json'
    Write-EventFixture -Path $closedPath -Overrides @{
        action = 'closed'
    }

    $closedParameters = $common.Clone()
    $closedParameters.EventPath = $closedPath
    Assert-Throws -Name 'non-allowlisted PR action is rejected' -Action {
        & $gate @closedParameters
    }

    $wrongBasePath = Join-Path $tempRoot 'wrong-base.json'
    Write-EventFixture -Path $wrongBasePath -Overrides @{
        base_ref = 'release'
    }

    $wrongBaseParameters = $common.Clone()
    $wrongBaseParameters.EventPath = $wrongBasePath
    Assert-Throws -Name 'unexpected base branch is rejected' -Action {
        & $gate @wrongBaseParameters
    }

    $unsafeRefPath = Join-Path $tempRoot 'unsafe-ref.json'
    Write-EventFixture -Path $unsafeRefPath -Overrides @{
        head_ref = ('feat/ok' + [char] 10 + 'injected')
    }

    $unsafeRefParameters = $common.Clone()
    $unsafeRefParameters.EventPath = $unsafeRefPath
    Assert-Throws -Name 'control characters in head ref are rejected' -Action {
        & $gate @unsafeRefParameters
    }

    foreach ($unsafeBranch in @(
        '@',
        '-danger',
        'feat/component.lock'
    )) {
        $gitRulePath = Join-Path $tempRoot ('git-rule-' + [Guid]::NewGuid().ToString('N') + '.json')
        Write-EventFixture -Path $gitRulePath -Overrides @{
            head_ref = $unsafeBranch
        }

        $gitRuleParameters = $common.Clone()
        $gitRuleParameters.EventPath = $gitRulePath
        Assert-Throws -Name "Git-invalid branch ref '$unsafeBranch' is rejected" -Action {
            & $gate @gitRuleParameters
        }
    }

    $sameShaPath = Join-Path $tempRoot 'same-sha.json'
    Write-EventFixture -Path $sameShaPath -Overrides @{
        head_sha = '1111111111111111111111111111111111111111'
    }

    $sameShaParameters = $common.Clone()
    $sameShaParameters.EventPath = $sameShaPath
    Assert-Throws -Name 'identical base and head SHAs are rejected' -Action {
        & $gate @sameShaParameters
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
