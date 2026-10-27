#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\Prepare-SigningRepository.ps1') -Raw -Encoding utf8
$workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\review.yml') -Raw -Encoding utf8

function Require { param([string]$Text,[string]$Needle,[string]$Name); if(-not $Text.Contains($Needle,[StringComparison]::Ordinal)){throw "Missing: $Name"}; Write-Host "[PASS] $Name" }
function Forbid { param([string]$Text,[string]$Needle,[string]$Name); if($Text.Contains($Needle,[StringComparison]::OrdinalIgnoreCase)){throw "Forbidden: $Name"}; Write-Host "[PASS] $Name" }

Require $scriptText "'init', '--bare'" 'signing repository is bare'
Require $scriptText "'--no-recurse-submodules'" 'signing fetch cannot initialize submodules'
Require $scriptText "`$expectedRemoteUrl = 'https://github.com/' + `$Repository + '.git'" 'signing origin is canonicalized'
Require $scriptText 'remote.origin.pushurl' 'separate pushurl is rejected'
Require $scriptText 'Trusted base moved from event SHA' 'base movement fails closed'
Require $scriptText 'PR head moved from event SHA' 'head movement fails closed'
Require $scriptText "'--is-bare-repository'" 'worktree materialization is checked'
Forbid $scriptText "'--filter=blob:none'" 'signing repository does not depend on promisor demand-fetch'
Require $workflow 'Prepare bare signing target' 'workflow uses bare signing preparation'
Forbid $workflow 'Checkout exact PR head for signing' 'signing runner never checks out PR worktree'
