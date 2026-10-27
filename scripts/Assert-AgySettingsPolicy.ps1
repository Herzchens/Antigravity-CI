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

function Test-MeaningfulValue {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return $false
    }

    if ($Value -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [System.Collections.IDictionary] -and
        $Value -isnot [string]) {
        return @($Value).Count -gt 0
    }

    if ($Value -is [bool]) {
        return [bool] $Value
    }

    return $true
}

$resolvedSettingsPath = (Resolve-Path -LiteralPath $SettingsPath -ErrorAction Stop).Path
$item = Get-Item -LiteralPath $resolvedSettingsPath -ErrorAction Stop

if ($item.PSIsContainer) {
    throw 'Antigravity settings path must reference a file.'
}

if ($item.Length -gt $MaxBytes) {
    throw "Antigravity settings exceed the maximum allowed size of $MaxBytes bytes."
}

$raw = Get-Content -LiteralPath $resolvedSettingsPath -Raw -Encoding utf8
try {
    $settings = ConvertFrom-Json -InputObject $raw -Depth 64 -ErrorAction Stop
}
catch {
    throw 'Antigravity settings.json is not valid JSON.'
}

if ($null -eq $settings -or $settings -isnot [psobject]) {
    throw 'Antigravity settings.json must contain a JSON object.'
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
    $allow = Get-PropertyValue -Object $permissions -Name 'allow'
    if ($null -ne $allow -and @($allow).Count -gt 0) {
        throw 'Review account permissions.allow must be empty; privileged allow rules are not permitted.'
    }
}

foreach ($dangerousKey in @(
    'customModelsConfig',
    'gcp',
    'sandboxProxy',
    'statusLine',
    'title',
    'trustedWorkspaces'
)) {
    $value = Get-PropertyValue -Object $settings -Name $dangerousKey
    if (Test-MeaningfulValue -Value $value) {
        throw "Review account setting '$dangerousKey' is not permitted."
    }
}

$modelProvider = Get-PropertyValue -Object $settings -Name 'modelProvider'
if ($null -ne $modelProvider -and -not [string]::IsNullOrWhiteSpace([string] $modelProvider)) {
    throw 'Review account must use cached Antigravity account authentication, not a modelProvider override.'
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
