#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$smokePath = Join-Path $repoRoot 'scripts\Test-AgySandboxSmoke.ps1'
$smoke = Get-Content -LiteralPath $smokePath -Raw -Encoding utf8

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string] $Needle,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not $smoke.Contains($Needle, [StringComparison]::Ordinal)) {
        throw "Sandbox smoke contract missing: $Name"
    }

    Write-Host "[PASS] $Name"
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory)]
        [string] $Needle,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($smoke.Contains($Needle, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Sandbox smoke contract contains forbidden text: $Name"
    }

    Write-Host "[PASS] $Name"
}

Assert-Contains -Needle 'ExpectedAgySha256' -Name 'sandbox smoke pins the AGY executable SHA-256'
Assert-Contains -Needle 'Get-FileHash -LiteralPath $agyPath -Algorithm SHA256' -Name 'sandbox smoke hashes the AGY executable before and after execution'
Assert-Contains -Needle "AGY_CLI_DISABLE_AUTO_UPDATE'] = 'true'" -Name 'sandbox smoke disables AGY self-update'
Assert-Contains -Needle 'Antigravity CLI changed during the sandbox smoke test.' -Name 'sandbox smoke rejects runtime binary mutation'
Assert-Contains -Needle "'--sandbox'" -Name 'sandbox mode is forced'
Assert-Contains -Needle "'--disable-slash-commands'" -Name 'slash command expansion is disabled'
Assert-NotContains -Needle '--dangerously-skip-permissions' -Name 'permission bypass is forbidden'
Assert-Contains -Needle ".ssh" -Name 'outside read probe targets sensitive user-profile content'
Assert-Contains -Needle 'outside_read_succeeded' -Name 'outside read result is asserted'
Assert-Contains -Needle 'outside_write_succeeded' -Name 'outside write result is asserted'
Assert-Contains -Needle 'network_succeeded' -Name 'network result is asserted'
Assert-Contains -Needle "https://example.com/" -Name 'network isolation is probed with a reachable HTTPS origin'
Assert-Contains -Needle 'SentinelLeakedToOutput = $false' -Name 'sentinel leakage is an explicit acceptance invariant'
Assert-Contains -Needle "'AGY_ADC_AUTH'" -Name 'sandbox smoke strips Antigravity ADC auth override'
Assert-Contains -Needle "'GEMINI_API_KEY'" -Name 'sandbox smoke strips Gemini API-key auth override'
Assert-Contains -Needle "'GOOGLE_APPLICATION_CREDENTIALS'" -Name 'sandbox smoke strips Google credential-file override'
Assert-Contains -Needle 'credentials?' -Name 'sandbox smoke strips plural credential-named environment values'
