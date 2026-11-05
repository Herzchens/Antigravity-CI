#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ManifestPath,

    [string] $HomeDirectory = $HOME,

    [ValidateRange(1024, 1048576)]
    [int] $MaxBytes = 65536,

    [ValidateRange(1, 64)]
    [int] $MaxProbes = 16
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NoReparsePointInExistingPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)

    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "$Name does not have a valid path root."
    }

    $current = $root
    $relative = $fullPath.Substring($root.Length)
    $separators = [char[]] @(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    foreach ($component in $relative.Split(
        $separators,
        [System.StringSplitOptions]::RemoveEmptyEntries
    )) {
        $current = Join-Path $current $component

        $pathExists = $false
        try {
            $pathExists = Test-Path -LiteralPath $current -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            break
        }
        catch [System.Security.SecurityException] {
            break
        }

        if (-not $pathExists) {
            break
        }

        $item = $null
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            break
        }
        catch [System.Security.SecurityException] {
            break
        }

        if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name traverses a symbolic link or reparse point."
        }
    }

    $fullPath
}

function Assert-WriteDenied {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $stream = $null
    $denied = $false
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
    }
    catch [System.UnauthorizedAccessException] {
        $denied = $true
    }
    catch [System.Security.SecurityException] {
        $denied = $true
    }
    catch {
        throw "$Name did not prove a write ACL denial; received $($_.Exception.GetType().FullName)."
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    if (-not $denied) {
        throw "$Name is writable by the review account."
    }
}

function Assert-DirectoryCreateDenied {
    param(
        [Parameter(Mandatory)]
        [string] $Directory,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $candidate = Join-Path $Directory (
        '.antigravity-ci-write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $stream = $null
    $denied = $false

    try {
        $stream = [System.IO.File]::Open(
            $candidate,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }
    catch [System.UnauthorizedAccessException] {
        $denied = $true
    }
    catch [System.Security.SecurityException] {
        $denied = $true
    }
    catch {
        throw "$Name parent did not prove a create ACL denial; received $($_.Exception.GetType().FullName)."
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $denied) {
        throw "$Name parent directory is writable by the review account."
    }
}

if (-not $IsWindows) {
    throw 'Review filesystem-boundary verification currently requires Windows.'
}

$homeRoot = [System.IO.Path]::GetFullPath($HomeDirectory)
$resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).Path
$null = Assert-NoReparsePointInExistingPath -Path $resolvedManifest -Name 'ProtectedReadProbeManifest'

$manifestRelativeToHome = [System.IO.Path]::GetRelativePath($homeRoot, $resolvedManifest)
$manifestOutsideHome = [System.IO.Path]::IsPathRooted($manifestRelativeToHome) -or
    $manifestRelativeToHome.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
    $manifestRelativeToHome -eq '..'

if (-not $manifestOutsideHome) {
    throw 'Protected-read probe manifest must be operator-managed outside the review account profile.'
}

$manifestItem = Get-Item -LiteralPath $resolvedManifest -ErrorAction Stop

if ($manifestItem.PSIsContainer) {
    throw 'Protected-read probe manifest must reference a JSON file.'
}

if ($manifestItem.Length -gt $MaxBytes) {
    throw "Protected-read probe manifest exceeds $MaxBytes bytes."
}

Assert-WriteDenied -Path $resolvedManifest -Name 'ProtectedReadProbeManifest'
Assert-DirectoryCreateDenied -Directory (Split-Path -Parent $resolvedManifest) -Name 'ProtectedReadProbeManifest'

$raw = Get-Content -LiteralPath $resolvedManifest -Raw -Encoding utf8
try {
    $manifest = ConvertFrom-Json -InputObject $raw -Depth 16 -ErrorAction Stop
}
catch {
    throw 'Protected-read probe manifest is not valid JSON.'
}

if ($null -eq $manifest -or $manifest -isnot [psobject]) {
    throw 'Protected-read probe manifest must contain a JSON object.'
}

$allowedRootProperties = @('schema_version', 'probes')
foreach ($property in @($manifest.PSObject.Properties.Name)) {
    if ($allowedRootProperties -cnotcontains $property) {
        throw "Protected-read probe manifest contains unsupported property '$property'."
    }
}

if ([int] $manifest.schema_version -ne 1) {
    throw 'Protected-read probe manifest schema_version must be 1.'
}

$probes = @($manifest.probes)
if ($probes.Count -eq 0) {
    throw 'Protected-read probe manifest must contain at least one probe.'
}

if ($probes.Count -gt $MaxProbes) {
    throw "Protected-read probe manifest contains more than $MaxProbes probes."
}

$seenNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$seenPaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$verified = 0

foreach ($probe in $probes) {
    if ($null -eq $probe -or $probe -isnot [psobject]) {
        throw 'Each protected-read probe must be a JSON object.'
    }

    $allowedProbeProperties = @('name', 'path')
    foreach ($property in @($probe.PSObject.Properties.Name)) {
        if ($allowedProbeProperties -cnotcontains $property) {
            throw 'Protected-read probe contains an unsupported property.'
        }
    }

    $name = [string] $probe.name
    if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'Protected-read probe name must be a safe 1-64 character identifier.'
    }

    if (-not $seenNames.Add($name)) {
        throw "Protected-read probe name '$name' is duplicated."
    }

    $pathText = [string] $probe.path
    if ([string]::IsNullOrWhiteSpace($pathText) -or $pathText.Length -gt 4096) {
        throw "Protected-read probe '$name' has an invalid path."
    }

    if (-not [System.IO.Path]::IsPathFullyQualified($pathText)) {
        throw "Protected-read probe '$name' must use an absolute path."
    }

    $fullPath = [System.IO.Path]::GetFullPath($pathText)
    $null = Assert-NoReparsePointInExistingPath -Path $fullPath -Name "Protected-read probe '$name'"

    if (-not $seenPaths.Add($fullPath)) {
        throw "Protected-read probe '$name' duplicates another probe path."
    }

    $relativeToHome = [System.IO.Path]::GetRelativePath($homeRoot, $fullPath)
    $outsideHome = [System.IO.Path]::IsPathRooted($relativeToHome) -or
        $relativeToHome.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -or
        $relativeToHome -eq '..'

    if (-not $outsideHome) {
        throw "Protected-read probe '$name' must target a sentinel outside the review account profile."
    }

    $sentinelParent = Split-Path -Parent $fullPath
    if ([string]::IsNullOrWhiteSpace($sentinelParent)) {
        throw "Protected-read probe '$name' does not have a parent directory."
    }

    Assert-DirectoryCreateDenied -Directory $sentinelParent -Name "Protected-read probe '$name'"

    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $fullPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )

        throw "Protected-read probe '$name' is readable by the review account."
    }
    catch [System.UnauthorizedAccessException] {
        $verified++
    }
    catch [System.Security.SecurityException] {
        $verified++
    }
    catch {
        throw "Protected-read probe '$name' did not prove an ACL denial; received $($_.Exception.GetType().FullName)."
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

if ($verified -ne $probes.Count) {
    throw 'Not every protected-read probe proved an ACL denial.'
}

[pscustomobject][ordered]@{
    ManifestPath = $resolvedManifest
    ProbeCount = $verified
    AllProtected = $true
    Valid = $true
}
