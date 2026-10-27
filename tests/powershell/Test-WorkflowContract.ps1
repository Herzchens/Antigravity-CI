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
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Needle,
        [Parameter(Mandatory)][string] $Name
    )

    if (-not $Text.Contains($Needle, [StringComparison]::Ordinal)) {
        throw "Workflow contract missing: $Name"
    }

    Write-Host "[PASS] $Name"
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Needle,
        [Parameter(Mandatory)][string] $Name
    )

    if ($Text.Contains($Needle, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Workflow contract contains forbidden text: $Name"
    }

    Write-Host "[PASS] $Name"
}

function Assert-Matches {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Name
    )

    if ($Text -notmatch $Pattern) {
        throw "Workflow contract pattern missing: $Name"
    }

    Write-Host "[PASS] $Name"
}

function Assert-NotMatches {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Name
    )

    if ($Text -match $Pattern) {
        throw "Workflow contract contains forbidden pattern: $Name"
    }

    Write-Host "[PASS] $Name"
}

function Get-JobText {
    param(
        [Parameter(Mandatory)][string] $Start,
        [string] $End
    )

    $startPosition = $workflow.IndexOf($Start, [StringComparison]::Ordinal)
    if ($startPosition -lt 0) {
        throw "Workflow job marker is missing: $Start"
    }

    $endPosition = if ([string]::IsNullOrWhiteSpace($End)) {
        $workflow.Length
    }
    else {
        $candidate = $workflow.IndexOf($End, $startPosition + $Start.Length, [StringComparison]::Ordinal)
        if ($candidate -lt 0) {
            throw "Workflow job marker is missing: $End"
        }
        $candidate
    }

    $workflow.Substring($startPosition, $endPosition - $startPosition)
}

Assert-Contains -Text $workflow -Needle '  workflow_call:' -Name 'infrastructure workflow is reusable-only'
Assert-NotMatches -Text $workflow -Pattern '(?m)^  pull_request_target:\s*$' -Name 'infrastructure workflow does not directly trigger privileged PR events'
Assert-NotContains -Text $workflow -Needle 'secrets: inherit' -Name 'blanket secret inheritance is forbidden'
Assert-NotContains -Text $workflow -Needle 'write-all' -Name 'write-all permission is forbidden'
Assert-NotContains -Text $workflow -Needle '--dangerously-skip-permissions' -Name 'unsafe AGY permission bypass is forbidden'
Assert-NotContains -Text $workflow -Needle 'persist-credentials: true' -Name 'self-hosted checkouts never persist credentials'

Assert-Matches -Text $caller -Pattern '(?m)^  pull_request_target:\s*$' -Name 'caller executes from the trusted default-branch PR context'
Assert-NotMatches -Text $caller -Pattern '(?m)^  pull_request:\s*$' -Name 'caller never executes from a PR-controlled workflow ref'
Assert-Contains -Text $caller -Needle 'types: [opened, reopened, synchronize, ready_for_review]' -Name 'caller event allowlist matches governance'
Assert-Contains -Text $caller -Needle 'github.event.pull_request.draft == false' -Name 'caller rejects drafts before reusable workflow allocation'
Assert-Contains -Text $caller -Needle 'github.event.pull_request.base.ref == github.event.repository.default_branch' -Name 'caller rejects non-default base branches'
Assert-Contains -Text $caller -Needle 'github.event.pull_request.base.repo.full_name == github.repository' -Name 'caller requires the trusted base repository'
Assert-Contains -Text $caller -Needle 'github.event.pull_request.head.repo.full_name == github.repository' -Name 'caller rejects fork or cross-repository heads'
Assert-Contains -Text $caller -Needle 'github.event.pull_request.head.repo.id == github.event.pull_request.base.repo.id' -Name 'caller binds repository identity by immutable ID'
Assert-Contains -Text $caller -Needle 'REPLACE_WITH_INFRASTRUCTURE_REPOSITORY/.github/workflows/review.yml@REPLACE_WITH_PINNED_COMMIT_SHA' -Name 'caller pins the reusable workflow by exact infrastructure commit'
Assert-NotContains -Text $caller -Needle 'secrets: inherit' -Name 'caller maps secrets explicitly'

Assert-Contains -Text $workflow -Needle "github.event_name == 'pull_request_target'" -Name 'reusable workflow independently requires the trusted-base event'
Assert-Contains -Text $workflow -Needle 'contains(fromJSON(' -Name 'reusable workflow repeats the action allowlist before runner allocation'
Assert-Contains -Text $workflow -Needle 'github.event.pull_request.draft == false' -Name 'reusable workflow repeats draft rejection'
Assert-Contains -Text $workflow -Needle 'github.event.pull_request.base.ref == github.event.repository.default_branch' -Name 'reusable workflow repeats base-branch validation'
Assert-Contains -Text $workflow -Needle 'github.event.pull_request.head.repo.full_name == github.repository' -Name 'reusable workflow repeats same-repository validation'
Assert-Contains -Text $workflow -Needle 'github.event.pull_request.head.repo.id == github.event.pull_request.base.repo.id' -Name 'reusable workflow repeats repository-ID validation'

$signJobText = Get-JobText -Start '  sign:' -End '  review:'
$reviewJobText = Get-JobText -Start '  review:' -End '  publisher:'
$publisherJobText = Get-JobText -Start '  publisher:'

$signInfra = $signJobText.IndexOf('- name: Checkout trusted Antigravity-CI implementation', [StringComparison]::Ordinal)
$signSecurity = $signJobText.IndexOf('- name: Verify signing runner security boundary', [StringComparison]::Ordinal)
$signTarget = $signJobText.IndexOf('- name: Checkout exact PR head for signing', [StringComparison]::Ordinal)
if ($signInfra -lt 0 -or $signSecurity -le $signInfra -or $signTarget -le $signSecurity) {
    throw 'Signing runner must verify trusted infrastructure and host policy before checking out PR code.'
}
Write-Host '[PASS] signing runner preflight precedes untrusted PR checkout'

$reviewInfra = $reviewJobText.IndexOf('- name: Checkout trusted Antigravity-CI implementation', [StringComparison]::Ordinal)
$reviewSecurity = $reviewJobText.IndexOf('- name: Verify isolated review runner security boundary', [StringComparison]::Ordinal)
$reviewTarget = $reviewJobText.IndexOf('- name: Checkout exact signed PR head without credentials', [StringComparison]::Ordinal)
if ($reviewInfra -lt 0 -or $reviewSecurity -le $reviewInfra -or $reviewTarget -le $reviewSecurity) {
    throw 'Review runner must verify trusted infrastructure and host policy before checking out PR code.'
}
Write-Host '[PASS] review runner preflight precedes untrusted PR checkout'

$checkoutMatches = [regex]::Matches($workflow, 'actions/checkout@([0-9a-f]{40})')
if ($checkoutMatches.Count -ne 5) {
    throw "Expected five immutable checkout uses, found $($checkoutMatches.Count)."
}
Write-Host '[PASS] all checkout actions are full-SHA pinned'

$safeDirectoryMatches = [regex]::Matches($workflow, '(?m)^\s*set-safe-directory:\s*false\s*$')
if ($safeDirectoryMatches.Count -ne $checkoutMatches.Count) {
    throw 'Every checkout must disable persistent global safe.directory mutation.'
}
Write-Host '[PASS] every checkout disables persistent safe.directory mutation'

if ([regex]::Matches($workflow, '(?m)^\s*lfs:\s*false\s*$').Count -lt 2 -or
    [regex]::Matches($workflow, '(?m)^\s*submodules:\s*false\s*$').Count -lt 2) {
    throw 'Both untrusted target checkouts must explicitly disable LFS and submodules.'
}
Write-Host '[PASS] target checkouts explicitly disable LFS and submodules'

$usesMatches = [regex]::Matches(
    $workflow,
    '(?m)^\s*uses:\s*(?<target>[^\s#]+)\s*$',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
)
foreach ($match in $usesMatches) {
    $target = $match.Groups['target'].Value
    if ($target.StartsWith('./', [StringComparison]::Ordinal)) {
        continue
    }

    if ($target -notmatch '@[0-9a-f]{40}$') {
        throw "External action or reusable workflow is not pinned by an immutable SHA: $target"
    }
}
Write-Host '[PASS] every external action use is immutable-SHA pinned'

Assert-Contains -Text $workflow -Needle "needs.sign.outputs.rewritten == 'false'" -Name 'AGY review is blocked in the signing-rewrite run'
Assert-Contains -Text $workflow -Needle 'Signed history was pushed. This run stops before AGY review.' -Name 'fresh synchronize barrier is explicit'
Assert-Contains -Text $workflow -Needle ('SIGNING_PUSH_TOKEN: $' + '{{ secrets.signing_push_token }}') -Name 'signing write credential is scoped to the signing step'
Assert-NotContains -Text $workflow -Needle ('token: $' + '{{ secrets.signing_push_token }}') -Name 'signing write credential is never persisted by checkout'
Assert-Contains -Text $workflow -Needle 'http.https://github.com/.extraheader' -Name 'signing push authentication is process-scoped'
Assert-Contains -Text $workflow -Needle '$env:SIGNING_PUSH_TOKEN = $null' -Name 'signing token variable is cleared after use'

Assert-Contains -Text $workflow -Needle 'Enforce capability ceiling and runtime readiness' -Name 'capability policy is enforced before AGY'
Assert-Contains -Text $workflow -Needle 'default: false' -Name 'sensitive capability deployment ceilings default to denied'
Assert-Contains -Text $reviewJobText -Needle '-ExpectedBaseSha $env:TARGET_BASE' -Name 'review binds live state to the trusted base SHA'
Assert-Contains -Text $reviewJobText -Needle '-ExpectedBaseRef $env:TARGET_BASE_REF' -Name 'review binds live state to the trusted base ref'
Assert-Contains -Text $publisherJobText -Needle '-ExpectedBaseSha $env:TARGET_BASE' -Name 'publisher refuses reports after trusted base movement'
Assert-Contains -Text $publisherJobText -Needle '-ExpectedBaseRef $env:TARGET_BASE_REF' -Name 'publisher binds publication to the trusted base ref'

Assert-Contains -Text $workflow -Needle 'report_sha256:' -Name 'review exports the validated report digest'
Assert-Contains -Text $workflow -Needle 'Hash validated report' -Name 'review hashes the report before artifact upload'
Assert-Contains -Text $publisherJobText -Needle 'Verify downloaded report digest' -Name 'publisher verifies report bytes before publication'
Assert-Contains -Text $publisherJobText -Needle 'needs.review.outputs.report_sha256' -Name 'publisher digest is bound to review output'
Assert-NotContains -Text $publisherJobText -Needle 'Checkout exact signed PR head' -Name 'publisher never checks out reviewed PR code'

Assert-Contains -Text $publisherJobText -Needle 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1' -Name 'GitHub App token action is full-SHA pinned'
Assert-NotContains -Text $reviewJobText -Needle 'reporter_app_private_key' -Name 'review job never materializes GitHub App private key'
Assert-Contains -Text $publisherJobText -Needle ('private-key: $' + '{{ secrets.reporter_app_private_key }}') -Name 'GitHub App private key exists only at publisher token creation'
Assert-Contains -Text $publisherJobText -Needle ('AGY_REPORTER_TOKEN: $' + '{{ steps.reporter_app.outputs.token }}') -Name 'GitHub App installation token feeds only the publisher script'
Assert-Contains -Text $publisherJobText -Needle ('AGY_REPORTER_TOKEN: $' + '{{ secrets.reporter_token }}') -Name 'fallback reporter token exists only in publisher job'
Assert-Contains -Text $publisherJobText -Needle 'permission-pull-requests: write' -Name 'GitHub App token requests only pull-request write permission'
Assert-Contains -Text $publisherJobText -Needle ('repositories: $' + '{{ github.event.repository.name }}') -Name 'GitHub App token is scoped to the current repository'
Assert-Contains -Text $publisherJobText -Needle ('owner: $' + '{{ github.repository_owner }}') -Name 'GitHub App token owner is explicit'

Assert-Contains -Text $workflow -Needle 'signing_runner_identity:' -Name 'signing runner identity is exported for isolation'
Assert-Contains -Text $workflow -Needle 'review_runner_identity:' -Name 'review runner identity is exported for publisher isolation'
Assert-Contains -Text $workflow -Needle '-ForbiddenIdentity $env:SIGNING_RUNNER_IDENTITY' -Name 'review runner cannot reuse the signing identity'
Assert-Contains -Text $workflow -Needle 'ForbiddenIdentities = @($env:REVIEW_RUNNER_IDENTITY)' -Name 'publisher cannot reuse the review identity'
Assert-Contains -Text $workflow -Needle 'Path still exists after removal' -Name 'persistent workspace cleanup fails closed'

$gitIsolationStepCount = [regex]::Matches(
    $workflow,
    '(?m)^\s*- name: Isolate Git host configuration\s*$'
).Count
if ($gitIsolationStepCount -ne 3) {
    throw "Expected Git host isolation in all three privileged jobs, found $gitIsolationStepCount."
}
Write-Host '[PASS] every privileged job isolates host Git configuration before checkout'

foreach ($requiredIsolation in @(
    'GIT_CONFIG_NOSYSTEM=1',
    'GIT_CONFIG_COUNT=0',
    'GIT_CONFIG_PARAMETERS=',
    'GIT_ATTR_NOSYSTEM=1',
    'GIT_TEMPLATE_DIR=',
    'core.hooksPath',
    'core.attributesFile',
    'credential.interactive'
)) {
    Assert-Contains -Text $workflow -Needle $requiredIsolation -Name "Git isolation configures $requiredIsolation"
}

if ([regex]::Matches($workflow, '-RequireGitIsolation').Count -ne 3) {
    throw 'Every privileged runner preflight must require Git isolation.'
}
Write-Host '[PASS] every privileged runner preflight requires Git isolation'

Assert-Contains -Text $signJobText -Needle '-SigningKey $env:TRUSTED_PUBLIC_KEY_PATH' -Name 'signing key selection is explicit and independent of ambient Git config'

Assert-Contains -Text $caller -Needle "agy_sha256: 'REPLACE_WITH_AGY_SHA256'" -Name 'caller template requires a pinned AGY executable hash'
Assert-Contains -Text $workflow -Needle '      agy_sha256:' -Name 'reusable workflow requires the AGY executable hash input'

$agyHashBindings = [regex]::Matches(
    $workflow,
    '-ExpectedAgySha256 \$env:AGY_SHA256'
).Count
if ($agyHashBindings -ne 2) {
    throw "Expected AGY SHA-256 pin at review preflight and execution; found $agyHashBindings."
}
Write-Host '[PASS] AGY binary hash is enforced before preflight execution and review execution'

Write-Host '[PASS] workflow contract is internally consistent'
