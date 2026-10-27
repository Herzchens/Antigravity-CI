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

$reviewJobPosition = $workflow.IndexOf('  review:', [StringComparison]::Ordinal)
$publisherJobPosition = $workflow.IndexOf('  publisher:', [StringComparison]::Ordinal)

if ($reviewJobPosition -lt 0 -or $publisherJobPosition -le $reviewJobPosition) {
    throw 'Expected separate review and publisher jobs.'
}

$reviewJobText = $workflow.Substring(
    $reviewJobPosition,
    $publisherJobPosition - $reviewJobPosition
)
$publisherJobText = $workflow.Substring($publisherJobPosition)
$reporterNeedle = 'AGY_REPORTER_TOKEN: $' + '{{ secrets.reporter_token }}'

Assert-NotContains -Text $reviewJobText -Needle $reporterNeedle -Name 'review job never materializes reporter credential'
Assert-Contains -Text $publisherJobText -Needle $reporterNeedle -Name 'reporter credential exists only in publisher job'
Assert-Contains -Text $publisherJobText -Needle 'runs-on: [self-hosted, Windows, "${{ inputs.publisher_runner_label }}"]' -Name 'publisher uses a deployment-specific isolated runner'
Assert-Contains -Text $reviewJobText -Needle 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' -Name 'validated report upload action is full-SHA pinned'
Assert-Contains -Text $publisherJobText -Needle 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093' -Name 'validated report download action is full-SHA pinned'
Assert-NotContains -Text $publisherJobText -Needle 'Checkout exact signed PR head' -Name 'publisher never checks out reviewed PR code'
Assert-Contains -Text $workflow -Needle 'retention-days: 1' -Name 'report handoff artifact has minimal retention'

Assert-Contains -Text $caller -Needle 'github.event.pull_request.head.repo.full_name == github.repository' -Name 'caller rejects forks before allocating the reusable workflow'
Assert-Contains -Text $caller -Needle 'github.event.pull_request.draft == false' -Name 'caller rejects draft PRs before allocating the reusable workflow'
Assert-Contains -Text $caller -Needle 'types: [opened, reopened, synchronize, ready_for_review]' -Name 'caller event allowlist matches governance'
Assert-Contains -Text $caller -Needle '@REPLACE_WITH_PINNED_COMMIT_SHA' -Name 'caller requires a pinned infrastructure commit'
Assert-NotContains -Text $caller -Needle 'secrets: inherit' -Name 'caller maps secrets explicitly'


Assert-Contains -Text $workflow -Needle 'Enforce deployment capability ceiling' -Name 'trusted project capabilities are checked before AGY'
Assert-Contains -Text $workflow -Needle 'default: false' -Name 'deployment capabilities default to denied'


Assert-Contains -Text $workflow -Needle 'Verify signing runner security boundary' -Name 'signing runner security preflight is required'
Assert-Contains -Text $workflow -Needle 'Verify isolated review runner security boundary' -Name 'review runner security preflight is required'
Assert-Contains -Text $workflow -Needle 'inputs.signing_public_key_path' -Name 'signing key path is role-specific'
Assert-Contains -Text $workflow -Needle 'inputs.review_trusted_public_key_path' -Name 'review verification key path is role-specific'
Assert-NotContains -Text $workflow -Needle 'inputs.trusted_public_key_path' -Name 'shared signing/review key path is forbidden'
Assert-Contains -Text $caller -Needle "review_trusted_public_key_path: 'REPLACE_WITH_REVIEW_PUBLIC_KEY_PATH'" -Name 'caller requires a deployment-specific public-only review key location'


Assert-Contains -Text $workflow -Needle 'signing_runner_identity:' -Name 'signing runner identity is exported for review isolation'
Assert-Contains -Text $workflow -Needle 'signing_key_fingerprint:' -Name 'signing key fingerprint is exported for review verification'
Assert-Contains -Text $workflow -Needle '-ForbiddenIdentity $env:SIGNING_RUNNER_IDENTITY' -Name 'review runner cannot reuse signing OS identity'
Assert-Contains -Text $workflow -Needle '-ExpectedTrustedKeyFingerprint $env:SIGNING_KEY_FINGERPRINT' -Name 'review public-key copy must match signing key fingerprint'


Assert-Contains -Text $workflow -Needle 'contains(fromJSON(' -Name 'reusable workflow enforces an event-action allowlist before runner allocation'
Assert-Contains -Text $workflow -Needle 'github.event.pull_request.draft == false' -Name 'reusable workflow rejects draft PRs before signing runner allocation'
Assert-Contains -Text $workflow -Needle 'github.event.pull_request.head.repo.id == github.event.pull_request.base.repo.id' -Name 'reusable workflow rejects repository-ID mismatches before signing runner allocation'
Assert-Contains -Text $workflow -Needle 'github.event.pull_request.head.repo.full_name == github.repository' -Name 'reusable workflow rejects cross-repository heads before signing runner allocation'
Assert-Contains -Text $workflow -Needle 'publisher_runner_label:' -Name 'publisher runner label is a required deployment input'
Assert-Contains -Text $caller -Needle 'publisher_runner_label: antigravity-publisher' -Name 'caller maps an isolated publisher runner'
Assert-Contains -Text $workflow -Needle 'review_runner_identity:' -Name 'review runner identity is exported for publisher isolation'
Assert-Contains -Text $workflow -Needle "Role = 'Publisher'" -Name 'publisher runner security preflight is required'
Assert-Contains -Text $workflow -Needle 'ForbiddenIdentities = @($env:REVIEW_RUNNER_IDENTITY)' -Name 'publisher cannot reuse review runner identity'
Assert-Contains -Text $workflow -Needle 'Clean persistent runner workspace' -Name 'persistent runner workspaces are cleaned before checkout'
Assert-NotContains -Text $workflow -Needle 'actions/upload-artifact@v' -Name 'upload artifact action must not use a floating tag'
Assert-NotContains -Text $workflow -Needle 'actions/download-artifact@v' -Name 'download artifact action must not use a floating tag'

Assert-Contains -Text $workflow -Needle 'github.event.pull_request.base.ref == github.event.repository.default_branch' -Name 'reusable workflow rejects non-default-base PRs before signing runner allocation'
Assert-Contains -Text $workflow -Needle 'Path still exists after removal' -Name 'persistent runner cleanup fails closed when removal does not complete'

Assert-Contains -Text $workflow -Needle 'report_sha256:' -Name 'review exports the validated report digest'
Assert-Contains -Text $workflow -Needle 'Hash validated report' -Name 'review hashes the validated report before artifact upload'
Assert-Contains -Text $workflow -Needle 'Verify downloaded report digest' -Name 'publisher verifies report bytes before publication'
Assert-Contains -Text $workflow -Needle 'needs.review.outputs.report_sha256' -Name 'publisher digest check is bound to review-job output'

Assert-NotContains -Text $workflow -Needle 'persist-credentials: true' -Name 'self-hosted checkouts never persist credentials'
Assert-NotContains -Text $workflow -Needle ('token: $' + '{{ secrets.signing_push_token }}') -Name 'signing write token is not materialized by checkout'
Assert-Contains -Text $workflow -Needle ('SIGNING_PUSH_TOKEN: $' + '{{ secrets.signing_push_token }}') -Name 'signing write token is scoped to the signing step'
Assert-Contains -Text $workflow -Needle 'http.https://github.com/.extraheader' -Name 'signing push credential is process-scoped through Git config environment'
Assert-Contains -Text $workflow -Needle '::add-mask::$encodedCredential' -Name 'derived signing credential is masked before use'
Assert-Contains -Text $workflow -Needle '$env:SIGNING_PUSH_TOKEN = $null' -Name 'signing write token is cleared after the signing push attempt'

Assert-Contains -Text $publisherJobText -Needle 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' -Name 'GitHub App token action is full-SHA pinned'
Assert-NotContains -Text $workflow -Needle 'actions/create-github-app-token@v' -Name 'GitHub App token action must not use a floating tag'
Assert-NotContains -Text $reviewJobText -Needle 'reporter_app_private_key' -Name 'review job never materializes GitHub App private key'
Assert-Contains -Text $publisherJobText -Needle ('private-key: $' + '{{ secrets.reporter_app_private_key }}') -Name 'GitHub App private key is scoped to publisher token creation'
Assert-Contains -Text $publisherJobText -Needle ('AGY_REPORTER_TOKEN: $' + '{{ steps.reporter_app.outputs.token }}') -Name 'GitHub App installation token feeds only the publisher script'
Assert-Contains -Text $publisherJobText -Needle "if: inputs.reporter_app_client_id != ''" -Name 'GitHub App publisher path is explicit'
Assert-Contains -Text $publisherJobText -Needle "if: inputs.reporter_app_client_id == ''" -Name 'fallback token publisher path is mutually exclusive'
Assert-Contains -Text $caller -Needle 'reporter_app_client_id:' -Name 'caller exposes GitHub App reporter client ID'
Assert-Contains -Text $caller -Needle 'reporter_app_private_key:' -Name 'caller maps GitHub App reporter private key explicitly'

Assert-Contains -Text $caller -Needle 'REPLACE_WITH_INFRASTRUCTURE_REPOSITORY/.github/workflows/review.yml@REPLACE_WITH_PINNED_COMMIT_SHA' -Name 'caller template requires explicit infrastructure repository and immutable commit'
Assert-Contains -Text $caller -Needle 'signing_runner_label: REPLACE_WITH_SIGNING_RUNNER_LABEL' -Name 'caller template requires a deployment-specific signing runner'
Assert-Contains -Text $caller -Needle 'review_runner_label: REPLACE_WITH_REVIEW_RUNNER_LABEL' -Name 'caller template requires a deployment-specific review runner'
Assert-Contains -Text $caller -Needle 'publisher_runner_label: REPLACE_WITH_PUBLISHER_RUNNER_LABEL' -Name 'caller template requires a deployment-specific publisher runner'
Assert-Contains -Text $caller -Needle "expected_reporter_login: 'REPLACE_WITH_REPORTER_LOGIN'" -Name 'caller template requires a deployment-specific reporter identity'
