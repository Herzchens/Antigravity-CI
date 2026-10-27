#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$resolver = Join-Path $repoRoot 'scripts\Resolve-ProjectConfig.ps1'
$template = Join-Path $repoRoot 'templates\project.toml'
$schema = Join-Path $repoRoot 'schemas\project-config.schema.json'

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

$resolved = & $resolver -ConfigPath $template -SchemaPath $schema

if ($resolved.schema_version -ne 1) {
    throw 'Template schema_version was not parsed correctly.'
}

if ($resolved.project.name -ne 'Example' -or $resolved.project.type -ne 'rust-android') {
    throw 'Template project metadata was not parsed correctly.'
}

if ($resolved.build.windows -ne 'cargo build --workspace') {
    throw 'Template build.windows was not parsed correctly.'
}

if (-not $resolved.features.adb -or $resolved.features.network -or $resolved.features.gui) {
    throw 'Template feature flags were not parsed correctly.'
}

Write-Host '[PASS] canonical template parses and validates'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-project-config-test-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $sentinel = Join-Path $tempRoot 'must-not-exist.txt'
    $sentinelTomlPath = $sentinel.Replace('\', '/')
    $dataOnlyPath = Join-Path $tempRoot 'data-only.toml'

    @"
schema_version = 1 # inline comment

[project]
name = "Example # project"
type = "powershell"

[build]
windows = "Set-Content '$sentinelTomlPath' executed # still data"

[features]
adb = false
network = false
gui = false
"@ | Set-Content -LiteralPath $dataOnlyPath -Encoding utf8NoBOM

    $dataOnly = & $resolver -ConfigPath $dataOnlyPath -SchemaPath $schema

    if (Test-Path -LiteralPath $sentinel) {
        throw 'Project configuration command text was executed during parsing.'
    }

    if ($dataOnly.project.name -ne 'Example # project') {
        throw 'Hash character inside a quoted string was treated as a TOML comment.'
    }

    if ($dataOnly.build.windows -notlike 'Set-Content*') {
        throw 'Command text was not preserved as data.'
    }

    Write-Host '[PASS] command-looking values remain inert data'
    Write-Host '[PASS] inline comments are stripped only outside quoted strings'

    $unknownSection = Join-Path $tempRoot 'unknown-section.toml'
    @"
schema_version = 1
[project]
name = "Example"
type = "powershell"
[features]
adb = false
network = false
gui = false
[secrets]
token = "nope"
"@ | Set-Content -LiteralPath $unknownSection -Encoding utf8NoBOM

    Assert-Throws -Name 'unknown section is rejected' -Action {
        & $resolver -ConfigPath $unknownSection -SchemaPath $schema
    }

    $duplicateKey = Join-Path $tempRoot 'duplicate-key.toml'
    @"
schema_version = 1
[project]
name = "Example"
name = "Duplicate"
type = "powershell"
[features]
adb = false
network = false
gui = false
"@ | Set-Content -LiteralPath $duplicateKey -Encoding utf8NoBOM

    Assert-Throws -Name 'duplicate key is rejected' -Action {
        & $resolver -ConfigPath $duplicateKey -SchemaPath $schema
    }

    $unsupportedValue = Join-Path $tempRoot 'unsupported-value.toml'
    @"
schema_version = 1
[project]
name = "Example"
type = "powershell"
[build]
windows = ["pwsh", "-File", "test.ps1"]
[features]
adb = false
network = false
gui = false
"@ | Set-Content -LiteralPath $unsupportedValue -Encoding utf8NoBOM

    Assert-Throws -Name 'unsupported TOML value type is rejected' -Action {
        & $resolver -ConfigPath $unsupportedValue -SchemaPath $schema
    }

    $unexpectedCapability = Join-Path $tempRoot 'unexpected-capability.toml'
    @"
schema_version = 1
[project]
name = "Example"
type = "powershell"
[features]
adb = false
network = false
gui = false
admin = true
"@ | Set-Content -LiteralPath $unexpectedCapability -Encoding utf8NoBOM

    Assert-Throws -Name 'capability outside the schema is rejected' -Action {
        & $resolver -ConfigPath $unexpectedCapability -SchemaPath $schema
    }

    $duplicateSection = Join-Path $tempRoot 'duplicate-section.toml'
    @"
schema_version = 1
[project]
name = "Example"
type = "powershell"
[features]
adb = false
network = false
gui = false
[features]
adb = false
"@ | Set-Content -LiteralPath $duplicateSection -Encoding utf8NoBOM

    Assert-Throws -Name 'duplicate section is rejected' -Action {
        & $resolver -ConfigPath $duplicateSection -SchemaPath $schema
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
