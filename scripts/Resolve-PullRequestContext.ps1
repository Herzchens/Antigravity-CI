#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $EventPath,

    [Parameter(Mandatory)]
    [ValidateSet('pull_request')]
    [string] $EventName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $ExpectedRepository,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string] $ExpectedBaseRef,

    [ValidateSet('opened', 'reopened', 'synchronize', 'ready_for_review')]
    [string[]] $AllowedActions = @(
        'opened',
        'reopened',
        'synchronize',
        'ready_for_review'
    ),

    [ValidateRange(1024, 10485760)]
    [int] $MaxBytes = 2097152
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-RequiredString {
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Name,

        [int] $MaxLength = 1024
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "Pull-request event field '$Name' must be a non-empty string."
    }

    if ($Value.Length -gt $MaxLength) {
        throw "Pull-request event field '$Name' exceeds $MaxLength characters."
    }

    [string] $Value
}

function Assert-CommitSha {
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $sha = Assert-RequiredString -Value $Value -Name $Name -MaxLength 40
    if ($sha -cnotmatch '^[0-9a-f]{40}$') {
        throw "Pull-request event field '$Name' must be a lowercase 40-character commit SHA."
    }

    $sha
}

function Assert-SafeRefName {
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $ref = Assert-RequiredString -Value $Value -Name $Name -MaxLength 255

    if ($ref -match '[\x00-\x20\x7f~^:?*\[\\]' -or
        $ref.Contains('..', [StringComparison]::Ordinal) -or
        $ref.Contains('@{', [StringComparison]::Ordinal) -or
        $ref.StartsWith('/', [StringComparison]::Ordinal) -or
        $ref.EndsWith('/', [StringComparison]::Ordinal) -or
        $ref.EndsWith('.', [StringComparison]::Ordinal) -or
        $ref.EndsWith('.lock', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pull-request event field '$Name' is not a safe Git branch ref."
    }

    foreach ($component in $ref.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($component) -or
            $component.StartsWith('.', [StringComparison]::Ordinal)) {
            throw "Pull-request event field '$Name' is not a safe Git branch ref."
        }
    }

    $ref
}

if ($AllowedActions.Count -eq 0) {
    throw 'AllowedActions must contain at least one pull-request action.'
}

$ExpectedBaseRef = Assert-SafeRefName -Value $ExpectedBaseRef -Name 'ExpectedBaseRef'

$resolvedEventPath = (Resolve-Path -LiteralPath $EventPath -ErrorAction Stop).Path
$eventItem = Get-Item -LiteralPath $resolvedEventPath -ErrorAction Stop

if ($eventItem.PSIsContainer) {
    throw 'EventPath must reference a JSON file.'
}

if ($eventItem.Length -gt $MaxBytes) {
    throw "Pull-request event exceeds the maximum allowed size of $MaxBytes bytes."
}

$eventJson = Get-Content -LiteralPath $resolvedEventPath -Raw -Encoding utf8
try {
    $event = ConvertFrom-Json -InputObject $eventJson -Depth 64 -ErrorAction Stop
}
catch {
    throw 'Pull-request event is not valid JSON.'
}

try {
    $pullRequest = $event.pull_request
    $action = [string] $event.action
}
catch {
    throw 'Event payload does not contain the required pull_request structure.'
}

if ($null -eq $pullRequest) {
    throw 'Event payload does not contain pull_request.'
}

if ($AllowedActions -cnotcontains $action) {
    throw "Pull-request action '$action' is not allowed for privileged review."
}

$baseRepository = Assert-RequiredString -Value $pullRequest.base.repo.full_name -Name 'pull_request.base.repo.full_name' -MaxLength 256
$headRepository = Assert-RequiredString -Value $pullRequest.head.repo.full_name -Name 'pull_request.head.repo.full_name' -MaxLength 256

if ($baseRepository -cne $ExpectedRepository) {
    throw "Base repository '$baseRepository' does not match expected repository '$ExpectedRepository'."
}

if ($headRepository -cne $ExpectedRepository) {
    throw 'Fork or cross-repository pull requests are not allowed on the privileged runner.'
}

$baseRepositoryId = [long] $pullRequest.base.repo.id
$headRepositoryId = [long] $pullRequest.head.repo.id

if ($baseRepositoryId -le 0 -or $headRepositoryId -le 0) {
    throw 'Pull-request repository IDs must be positive integers.'
}

if ($baseRepositoryId -ne $headRepositoryId) {
    throw 'Head and base repository IDs differ; privileged review requires a same-repository pull request.'
}

$prNumber = [int] $pullRequest.number
if ($prNumber -le 0) {
    throw 'Pull-request number must be a positive integer.'
}

if ([bool] $pullRequest.draft) {
    throw 'Draft pull requests are not eligible for privileged review.'
}

$baseRef = Assert-SafeRefName -Value $pullRequest.base.ref -Name 'pull_request.base.ref'
$headRef = Assert-SafeRefName -Value $pullRequest.head.ref -Name 'pull_request.head.ref'

if ($baseRef -cne $ExpectedBaseRef) {
    throw "Pull request targets base ref '$baseRef', expected '$ExpectedBaseRef'."
}

$baseSha = Assert-CommitSha -Value $pullRequest.base.sha -Name 'pull_request.base.sha'
$headSha = Assert-CommitSha -Value $pullRequest.head.sha -Name 'pull_request.head.sha'

if ($baseSha -ceq $headSha) {
    throw 'Pull-request base and head SHAs must differ.'
}

[pscustomobject][ordered]@{
    EventName = $EventName
    Action = $action
    Repository = $baseRepository
    RepositoryId = $baseRepositoryId
    PrNumber = $prNumber
    BaseRef = $baseRef
    BaseSha = $baseSha
    HeadRef = $headRef
    HeadSha = $headSha
    HeadRepository = $headRepository
    IsFork = $false
    IsDraft = $false
    TrustedConfigRef = $baseSha
    ReviewCodeRef = $headSha
}
