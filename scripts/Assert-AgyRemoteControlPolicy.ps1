#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AgyExecutable,

    [string] $HomeDirectory = $HOME,

    [ValidateRange(1024, 1048576)]
    [int] $MaxConfigBytes = 65536
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object] $Object,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $Object) {
        return $null
    }

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

    if ($Value -is [bool]) {
        return [bool] $Value
    }

    if ($Value -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string] -and
        $Value -isnot [System.Collections.IDictionary]) {
        return @($Value).Count -gt 0
    }

    $true
}

function Assert-NoReparsePointInExistingPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $relative = [System.IO.Path]::GetRelativePath($root, $fullPath)

    $current = $root
    foreach ($segment in $relative.Split(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.StringSplitOptions]::RemoveEmptyEntries
    )) {
        $current = Join-Path $current $segment

        if (-not (Test-Path -LiteralPath $current)) {
            break
        }

        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name traverses a reparse point: $current"
        }
    }

    $fullPath
}

function Test-AntigravityMarkerText {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return $false
    }

    $text = [string] $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    $text -match '(?i)(antigravity|(?:^|[^a-z0-9])agy(?:\.exe)?(?:[^a-z0-9]|$)|run_agy_remote_control)'
}

function Test-RemoteControlMarkerText {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return $false
    }

    $text = [string] $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    $text -match '(?i)(remote[-_ ]control|run_agy_remote_control)'
}

if (-not $IsWindows) {
    throw 'Antigravity Remote Control policy currently targets the Windows review runner.'
}

$null = Get-Command Get-ScheduledTask -ErrorAction Stop
$null = Get-Command Get-CimInstance -ErrorAction Stop

$agyCommand = Get-Command $AgyExecutable -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
$agyPath = [System.IO.Path]::GetFullPath($agyCommand.Source)
$agyFileName = [System.IO.Path]::GetFileName($agyPath)

$homeRoot = [System.IO.Path]::GetFullPath($HomeDirectory)
$configPath = Join-Path $homeRoot '.gemini\config\config.json'
$configMarkerCount = 0

if (Test-Path -LiteralPath $configPath) {
    $resolvedConfigPath = Assert-NoReparsePointInExistingPath -Path $configPath -Name 'Antigravity config.json'
    $configItem = Get-Item -LiteralPath $resolvedConfigPath -Force -ErrorAction Stop

    if ($configItem.PSIsContainer) {
        throw 'Antigravity config.json path must reference a file.'
    }

    if ($configItem.Length -gt $MaxConfigBytes) {
        throw "Antigravity config.json exceeds the maximum allowed size of $MaxConfigBytes bytes."
    }

    $configText = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding utf8
    try {
        $config = ConvertFrom-Json -InputObject $configText -Depth 64 -ErrorAction Stop
    }
    catch {
        throw 'Antigravity config.json is not valid JSON.'
    }

    $settingsScopes = @(
        $config,
        (Get-PropertyValue -Object $config -Name 'userSettings')
    )

    foreach ($scope in $settingsScopes) {
        if ($null -eq $scope) {
            continue
        }

        foreach ($propertyName in @(
            'cliRemoteControlHostname',
            'remoteControlHostname',
            'remoteControlEnabled'
        )) {
            if (Test-MeaningfulValue -Value (Get-PropertyValue -Object $scope -Name $propertyName)) {
                $configMarkerCount++
            }
        }
    }

    if ($configMarkerCount -gt 0) {
        throw 'Review account Antigravity config contains Remote Control state. Disable/unregister Remote Control and remove persisted Remote Control settings before privileged review.'
    }
}

try {
    $scheduledTasks = @(Get-ScheduledTask -ErrorAction Stop)
}
catch {
    throw 'Unable to enumerate Windows Scheduled Tasks while checking the Antigravity Remote Control boundary.'
}

$taskMarkerCount = 0
foreach ($task in $scheduledTasks) {
    $taskIdentity = ([string] $task.TaskPath) + ([string] $task.TaskName)
    $taskAgyMarker = Test-AntigravityMarkerText -Value $taskIdentity
    $taskRemoteControlMarker = Test-RemoteControlMarkerText -Value $taskIdentity

    foreach ($action in @($task.Actions)) {
        $execute = [string] $action.Execute
        $arguments = [string] $action.Arguments
        $actionText = $execute + ' ' + $arguments
        $actionAgyMarker = Test-AntigravityMarkerText -Value $actionText
        $actionRemoteControlMarker = Test-RemoteControlMarkerText -Value $actionText

        $executeMatchesAgy = $false
        if (-not [string]::IsNullOrWhiteSpace($execute)) {
            try {
                $executeMatchesAgy = [System.IO.Path]::GetFileName($execute).Equals(
                    $agyFileName,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
            catch {
                $executeMatchesAgy = $false
            }
        }

        if ($taskAgyMarker -or
            $executeMatchesAgy -or
            $actionAgyMarker -or
            ($taskRemoteControlMarker -and $actionRemoteControlMarker)) {
            $taskMarkerCount++
            break
        }
    }
}

if ($taskMarkerCount -gt 0) {
    throw "Review runner exposes $taskMarkerCount Antigravity/Remote Control Scheduled Task marker(s). Run 'agy remote-control stop' from the review account and remove any legacy daemon registration before privileged review."
}

try {
    $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
}
catch {
    throw 'Unable to enumerate Windows processes while checking the Antigravity Remote Control boundary.'
}

$processMarkerCount = 0
foreach ($process in $processes) {
    if ([int] $process.ProcessId -eq $PID) {
        continue
    }

    $name = [string] $process.Name
    $commandLine = [string] $process.CommandLine
    $executablePath = [string] $process.ExecutablePath

    $nameMatchesAgy = $name.Equals($agyFileName, [StringComparison]::OrdinalIgnoreCase)
    $pathMatchesAgy = -not [string]::IsNullOrWhiteSpace($executablePath) -and
        $executablePath.Equals($agyPath, [StringComparison]::OrdinalIgnoreCase)

    if ($nameMatchesAgy -or
        $pathMatchesAgy -or
        (Test-AntigravityMarkerText -Value $commandLine)) {
        $processMarkerCount++
    }
}

if ($processMarkerCount -gt 0) {
    throw "Review runner exposes $processMarkerCount concurrent Antigravity/Remote Control process marker(s). Dedicated review execution requires no other Antigravity process."
}

[pscustomobject][ordered]@{
    AgyPath = $agyPath
    ConfigPath = $configPath
    ConfigRemoteControlMarkerCount = 0
    ScheduledTaskMarkerCount = 0
    ProcessMarkerCount = 0
    ScheduledTaskCountScanned = $scheduledTasks.Count
    ProcessCountScanned = $processes.Count
    Valid = $true
}
