Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$projectSchema = Join-Path $repoRoot 'schemas\project-config.schema.json'
$reportSchema = Join-Path $repoRoot 'schemas\agy-report.schema.json'

if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
    throw 'Test-Json is required. Run this test with PowerShell 7.'
}

$cases = @(
    [pscustomobject]@{
        Name = 'valid project config'
        Schema = $projectSchema
        Fixture = Join-Path $repoRoot 'tests\fixtures\project-config.valid.json'
        Expected = $true
    }
    [pscustomobject]@{
        Name = 'invalid project config'
        Schema = $projectSchema
        Fixture = Join-Path $repoRoot 'tests\fixtures\project-config.invalid.json'
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'valid AGY report'
        Schema = $reportSchema
        Fixture = Join-Path $repoRoot 'tests\fixtures\agy-report.valid.json'
        Expected = $true
    }
    [pscustomobject]@{
        Name = 'invalid AGY report'
        Schema = $reportSchema
        Fixture = Join-Path $repoRoot 'tests\fixtures\agy-report.invalid.json'
        Expected = $false
    }
)

foreach ($case in $cases) {
    $actual = [bool](Test-Json -Path $case.Fixture -SchemaFile $case.Schema -ErrorAction SilentlyContinue)

    if ($actual -ne $case.Expected) {
        throw "Contract test failed: $($case.Name). Expected $($case.Expected), got $actual."
    }

    Write-Host "[PASS] $($case.Name)"
}
