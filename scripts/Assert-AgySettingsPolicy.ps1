#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SettingsPath,

    [ValidateRange(1024, 1048576)]
    [int] $MaxBytes = 65536
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Element
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )

        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) {
                throw 'Antigravity host JSON contains a duplicate property.'
            }

            Assert-NoDuplicateJsonProperties -Element $property.Value
        }

        return
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties -Element $item
        }
    }
}

function ConvertFrom-StrictHostJson {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $DisplayName
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

    try {
        $json = $strictUtf8.GetString($bytes)
    }
    catch [System.Text.DecoderFallbackException] {
        throw "$DisplayName is not valid UTF-8."
    }

    $document = $null
    try {
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $document = [System.Text.Json.JsonDocument]::Parse($json, $options)
        Assert-NoDuplicateJsonProperties -Element $document.RootElement
    }
    catch [System.Text.Json.JsonException] {
        throw "$DisplayName is not valid JSON."
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }

    try {
        ConvertFrom-Json -InputObject $json -Depth 64 -ErrorAction Stop
    }
    catch {
        throw "$DisplayName is not valid JSON."
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [psobject] $Object,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    $property.Value
}

$resolvedSettingsPath = (Resolve-Path -LiteralPath $SettingsPath -ErrorAction Stop).Path
$item = Get-Item -LiteralPath $resolvedSettingsPath -ErrorAction Stop

if ($item.PSIsContainer) {
    throw 'Antigravity settings path must reference a file.'
}

if ($item.Length -gt $MaxBytes) {
    throw "Antigravity settings exceed the maximum allowed size of $MaxBytes bytes."
}

$settings = ConvertFrom-StrictHostJson -Path $resolvedSettingsPath -DisplayName 'Antigravity settings.json'

if ($null -eq $settings -or $settings -isnot [psobject]) {
    throw 'Antigravity settings.json must contain a JSON object.'
}

$allowedTopLevel = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
foreach ($name in @(
    '$schema',
    'enableTerminalSandbox',
    'toolPermission',
    'allowNonWorkspaceAccess',
    'historySize',
    'disableSlashCommands',
    'permissions'
)) {
    [void] $allowedTopLevel.Add($name)
}

foreach ($property in $settings.PSObject.Properties) {
    if (-not $allowedTopLevel.Contains($property.Name)) {
        throw "Review account settings contain unsupported key '$($property.Name)'."
    }
}

$toolPermission = [string] (Get-PropertyValue -Object $settings -Name 'toolPermission')
if ($toolPermission -cne 'proceed-in-sandbox') {
    throw 'Review account must configure toolPermission=proceed-in-sandbox.'
}

$terminalSandbox = Get-PropertyValue -Object $settings -Name 'enableTerminalSandbox'
if ($terminalSandbox -isnot [bool] -or -not [bool] $terminalSandbox) {
    throw 'Review account must configure enableTerminalSandbox=true.'
}

$nonWorkspace = Get-PropertyValue -Object $settings -Name 'allowNonWorkspaceAccess'
if ($null -ne $nonWorkspace -and [bool] $nonWorkspace) {
    throw 'Review account must keep allowNonWorkspaceAccess disabled.'
}

$agentMode = Get-PropertyValue -Object $settings -Name 'agentMode'
if ($null -ne $agentMode -and -not [string]::IsNullOrWhiteSpace([string] $agentMode)) {
    throw 'Review account must not persist an agentMode override.'
}

$historySize = Get-PropertyValue -Object $settings -Name 'historySize'
if ($null -eq $historySize -or [int] $historySize -ne 0) {
    throw 'Review account must configure historySize=0.'
}

$disableSlashCommands = Get-PropertyValue -Object $settings -Name 'disableSlashCommands'
if ($disableSlashCommands -isnot [bool] -or -not [bool] $disableSlashCommands) {
    throw 'Review account must configure disableSlashCommands=true.'
}

$permissions = Get-PropertyValue -Object $settings -Name 'permissions'
if ($null -ne $permissions) {
    if ($permissions -isnot [psobject] -or $permissions -is [string]) {
        throw 'Review account permissions must be a JSON object.'
    }

    $allowedPermissionKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in @('allow', 'ask', 'deny')) {
        [void] $allowedPermissionKeys.Add($name)
    }

    foreach ($property in $permissions.PSObject.Properties) {
        if (-not $allowedPermissionKeys.Contains($property.Name)) {
            throw "Review account permissions contain unsupported key '$($property.Name)'."
        }
    }

    foreach ($name in @('allow', 'ask')) {
        $rules = Get-PropertyValue -Object $permissions -Name $name
        if ($null -ne $rules) {
            if ($rules -is [string] -or $rules -isnot [System.Collections.IEnumerable]) {
                throw "Review account permissions.$name must be an array."
            }

            if (@($rules).Count -gt 0) {
                throw "Review account permissions.$name must be empty."
            }
        }
    }

    $deny = Get-PropertyValue -Object $permissions -Name 'deny'
    if ($null -ne $deny -and
        ($deny -is [string] -or $deny -isnot [System.Collections.IEnumerable])) {
        throw 'Review account permissions.deny must be an array when configured.'
    }
}

$hash = (Get-FileHash -LiteralPath $resolvedSettingsPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()

[pscustomobject][ordered]@{
    SettingsPath = $resolvedSettingsPath
    SettingsSha256 = $hash
    ToolPermission = $toolPermission
    TerminalSandbox = $true
    NonWorkspaceAccess = $false
    HistorySize = 0
    SlashCommandsDisabled = $true
    Valid = $true
}
