#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ConfigPath,

    [string] $SchemaPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-TomlComment {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Line
    )

    $inString = $false
    $escaped = $false

    for ($index = 0; $index -lt $Line.Length; $index++) {
        $character = $Line[$index]

        if ($inString) {
            if ($escaped) {
                $escaped = $false
                continue
            }

            if ($character -eq '\') {
                $escaped = $true
                continue
            }

            if ($character -eq '"') {
                $inString = $false
            }

            continue
        }

        if ($character -eq '"') {
            $inString = $true
            continue
        }

        if ($character -eq '#') {
            return $Line.Substring(0, $index)
        }
    }

    $Line
}

function ConvertFrom-StrictTomlValue {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [int] $LineNumber
    )

    if ($Value -eq 'true') {
        return $true
    }

    if ($Value -eq 'false') {
        return $false
    }

    if ($Value -match '^-?(0|[1-9][0-9]*)$') {
        $parsedInteger = 0L
        if (-not [long]::TryParse(
            $Value,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref] $parsedInteger
        )) {
            throw "Integer value is out of range at line $LineNumber."
        }

        return $parsedInteger
    }

    if ($Value.StartsWith('"', [StringComparison]::Ordinal) -and
        $Value.EndsWith('"', [StringComparison]::Ordinal)) {
        try {
            $parsedString = ConvertFrom-Json -InputObject $Value -ErrorAction Stop
        }
        catch {
            throw "Invalid quoted string at line $LineNumber."
        }

        if ($parsedString -isnot [string]) {
            throw "Expected a quoted string at line $LineNumber."
        }

        return $parsedString
    }

    throw "Unsupported TOML value at line $LineNumber. Only booleans, integers, and JSON-compatible double-quoted strings are allowed."
}

$null = Get-Command Test-Json -ErrorAction Stop

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path

if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path $PSScriptRoot '..\schemas\project-config.schema.json'
}

$resolvedSchemaPath = (Resolve-Path -LiteralPath $SchemaPath -ErrorAction Stop).Path

$allowedSections = @(
    'project',
    'build',
    'test',
    'lint',
    'features'
)

$document = [ordered]@{}
$currentSection = $null
$seenSections = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)

$lineNumber = 0
foreach ($rawLine in Get-Content -LiteralPath $resolvedConfigPath -Encoding utf8) {
    $lineNumber++
    $line = (Remove-TomlComment -Line $rawLine).Trim()

    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    if ($line -match '^\[([a-z]+)\]$') {
        $sectionName = $Matches[1]

        if ($allowedSections -notcontains $sectionName) {
            throw "Unsupported TOML section [$sectionName] at line $lineNumber."
        }

        if (-not $seenSections.Add($sectionName)) {
            throw "Duplicate TOML section [$sectionName] at line $lineNumber."
        }

        $document[$sectionName] = [ordered]@{}
        $currentSection = $sectionName
        continue
    }

    if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(.+)$') {
        throw "Unsupported TOML syntax at line $lineNumber."
    }

    $key = $Matches[1]
    $rawValue = $Matches[2].Trim()
    $value = ConvertFrom-StrictTomlValue -Value $rawValue -LineNumber $lineNumber

    if ($null -eq $currentSection) {
        if ($key -ne 'schema_version') {
            throw "Unsupported top-level key '$key' at line $lineNumber."
        }

        if ($document.Contains($key)) {
            throw "Duplicate key '$key' at line $lineNumber."
        }

        $document[$key] = $value
        continue
    }

    $section = $document[$currentSection]

    if ($section.Contains($key)) {
        throw "Duplicate key '$currentSection.$key' at line $lineNumber."
    }

    $section[$key] = $value
}

$json = $document | ConvertTo-Json -Depth 16 -Compress

$matchesSchema = [bool](
    Test-Json -Json $json -SchemaFile $resolvedSchemaPath -ErrorAction SilentlyContinue
)

if (-not $matchesSchema) {
    throw 'Project configuration does not match schemas/project-config.schema.json.'
}

ConvertFrom-Json -InputObject $json -Depth 16
