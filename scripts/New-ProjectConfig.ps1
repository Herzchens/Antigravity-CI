#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $OutputPath,

    [Parameter(Mandatory)]
    [ValidateLength(1, 128)]
    [string] $ProjectName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]*$')]
    [string] $ProjectType,

    [hashtable] $Build = @{},

    [hashtable] $Test = @{},

    [hashtable] $Lint = @{},

    [bool] $Adb = $false,

    [bool] $Network = $false,

    [bool] $Gui = $false,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-StrictTomlString {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [string] $Name,

        [int] $MaxLength
    )

    if ($Value.Length -eq 0 -or $Value.Length -gt $MaxLength) {
        throw "$Name must contain between 1 and $MaxLength characters."
    }

    ConvertTo-Json -InputObject $Value -Compress
}

function Add-CommandSection {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]] $Lines,

        [Parameter(Mandatory)]
        [string] $SectionName,

        [Parameter(Mandatory)]
        [hashtable] $Commands
    )

    if ($Commands.Count -eq 0) {
        return
    }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($rawName in $Commands.Keys) {
        $name = [string] $rawName
        if ($name -notmatch '^[a-z][a-z0-9_-]*$') {
            throw "Command name '$name' in [$SectionName] is invalid."
        }

        $names.Add($name)
    }

    $names.Sort([System.StringComparer]::Ordinal)
    $Lines.Add('')
    $Lines.Add("[$SectionName]")

    foreach ($name in $names) {
        $value = [string] $Commands[$name]
        $encoded = ConvertTo-StrictTomlString -Value $value -Name "$SectionName.$name" -MaxLength 4096
        $Lines.Add("$name = $encoded")
    }
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('schema_version = 1')
$lines.Add('')
$lines.Add('[project]')
$lines.Add('name = ' + (ConvertTo-StrictTomlString -Value $ProjectName -Name 'ProjectName' -MaxLength 128))
$lines.Add('type = ' + (ConvertTo-StrictTomlString -Value $ProjectType -Name 'ProjectType' -MaxLength 64))

Add-CommandSection -Lines $lines -SectionName 'build' -Commands $Build
Add-CommandSection -Lines $lines -SectionName 'test' -Commands $Test
Add-CommandSection -Lines $lines -SectionName 'lint' -Commands $Lint

$lines.Add('')
$lines.Add('[features]')
$lines.Add('adb = ' + $Adb.ToString().ToLowerInvariant())
$lines.Add('network = ' + $Network.ToString().ToLowerInvariant())
$lines.Add('gui = ' + $Gui.ToString().ToLowerInvariant())
$lines.Add('')

$fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $fullOutputPath

if ([System.IO.Path]::GetFileName($fullOutputPath) -cne 'project.toml' -or
    [string]::IsNullOrWhiteSpace($parent) -or
    (Split-Path -Leaf $parent) -cne '.agy') {
    throw 'Project configuration output must be the repository .agy/project.toml file.'
}

if ((Test-Path -LiteralPath $fullOutputPath) -and -not $Force) {
    throw "Project configuration already exists: $fullOutputPath"
}

New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
[System.IO.File]::WriteAllText(
    $fullOutputPath,
    ($lines -join [char] 10),
    [System.Text.UTF8Encoding]::new($false)
)

$resolver = Join-Path $PSScriptRoot 'Resolve-ProjectConfig.ps1'
if (-not (Test-Path -LiteralPath $resolver -PathType Leaf)) {
    throw 'Resolve-ProjectConfig.ps1 is required to validate generated project configuration.'
}

$validated = & $resolver -ConfigPath $fullOutputPath

[pscustomobject][ordered]@{
    Path = $fullOutputPath
    ProjectName = [string] $validated.project.name
    ProjectType = [string] $validated.project.type
    Adb = [bool] $validated.features.adb
    Network = [bool] $validated.features.network
    Gui = [bool] $validated.features.gui
}
