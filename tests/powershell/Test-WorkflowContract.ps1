#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$workflowPath = Join-Path $repoRoot '.github\workflows\review.yml'
$callerPath = Join-Path $repoRoot 'templates\caller-workflow.yml'

$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$caller = Get-Content -LiteralPath $callerPath -Raw -Encoding utf8

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string] $Text,
        [Parameter(Mandatory)]
        [string] $Needle,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not $Text.Contains($Needle, [StringComparison]::Ordinal)) {
        throw "Workflow contract missing: $Name"
    }

    Write-Host "[PASS] $Name"
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory)]
        [string] $Text,
        [Parameter(Mandatory)]
        [string] $Needle,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Text.Contains($Needle, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Workflow contract contains forbidden text: $Name"
    }

    Write-Host "[PASS] $Name"
}

Assert-Contains -Text $workflow -Needle '  workflow_call:' -Name 'reusable workflow is workflow_call-only'
Assert-NotContains -Text $workflow -Needle 'pull_request_target' -Name 'pull_request_target is forbidden'
Assert-NotContains -Text $workflow -Needle 'secrets: inherit' -Name 'blanket secret inheritance is forbidden'
Assert-NotContains -Text $workflow -Needle 'write-all' -Name 'write-all permission is forbidden'
Assert-NotContains -Text $workflow -Needle '--dangerously-skip-permissions' -Name 'unsafe AGY permission bypass is forbidden'
Assert-NotContains -Text $workflow -Needle 'actions/checkout@v' -Name 'checkout action must be pinned by full commit SHA'

$checkoutMatches = [regex]::Matches($workflow, 'actions/checkout@([0-9a-f]{40})')
if ($checkoutMatches.Count -lt 4) {
    throw 'Expected every checkout use to be pinned by a full 40-character commit SHA.'
}

Write-Host '[PASS] checkout actions are full-SHA pinned'

Assert-Contains -Text $workflow -Needle "needs.sign.outputs.rewritten == 'false'" -Name 'AGY review is blocked in the signing-rewrite run'
Assert-Contains -Text $workflow -Needle 'Signed history was pushed. This run stops before AGY review.' -Name 'signing synchronization barrier is explicit'

$agyPosition = $workflow.IndexOf('- name: Run isolated Antigravity review', [StringComparison]::Ordinal)
$reporterNeedle = 'AGY_REPORTER_TOKEN: $' + '{{ secrets.reporter_token }}'
$reporterTokenPosition = $workflow.IndexOf($reporterNeedle, [StringComparison]::Ordinal)

if ($agyPosition -lt 0 -or $reporterTokenPosition -lt 0 -or $reporterTokenPosition -lt $agyPosition) {
    throw 'Reporter credential must not be materialized before the AGY step.'
}

Write-Host '[PASS] reporter credential is materialized only after AGY review'

Assert-Contains -Text $caller -Needle 'github.event.pull_request.head.repo.full_name == github.repository' -Name 'caller rejects forks before allocating the reusable workflow'
Assert-Contains -Text $caller -Needle 'github.event.pull_request.draft == false' -Name 'caller rejects draft PRs before allocating the reusable workflow'
Assert-Contains -Text $caller -Needle 'types: [opened, reopened, synchronize, ready_for_review]' -Name 'caller event allowlist matches governance'
Assert-Contains -Text $caller -Needle '@REPLACE_WITH_PINNED_COMMIT_SHA' -Name 'caller requires a pinned infrastructure commit'
Assert-NotContains -Text $caller -Needle 'secrets: inherit' -Name 'caller maps secrets explicitly'


Assert-Contains -Text $workflow -Needle 'Enforce deployment capability ceiling' -Name 'trusted project capabilities are checked before AGY'
Assert-Contains -Text $workflow -Needle 'default: false' -Name 'deployment capabilities default to denied'
