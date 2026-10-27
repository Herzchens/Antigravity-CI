#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepositoryPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $BaseSha,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $HeadSha,

    [ValidateRange(1, 100000)]
    [int] $MaxTrackedPaths = 50000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitBytes {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('-C')
    $startInfo.ArgumentList.Add($script:RepositoryRoot)

    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw 'Unable to start git.'
    }

    $memory = [System.IO.MemoryStream]::new()
    try {
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()
        $null = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            throw "git command failed with exit code $($process.ExitCode)."
        }

        $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function ConvertFrom-NullSeparatedUtf8 {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    $decoder = [System.Text.UTF8Encoding]::new($false, $true)
    $items = [System.Collections.Generic.List[string]]::new()
    $start = 0

    for ($index = 0; $index -le $Bytes.Length; $index++) {
        $boundary = $index -eq $Bytes.Length -or $Bytes[$index] -eq 0
        if (-not $boundary) {
            continue
        }

        $length = $index - $start
        if ($length -gt 0) {
            try {
                $items.Add($decoder.GetString($Bytes, $start, $length))
            }
            catch {
                throw 'Git returned a tracked path that is not valid UTF-8.'
            }
        }

        $start = $index + 1
    }

    $items
}

function Test-BlockedCustomizationPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $normalized = $Path.Replace('\', '/')
    foreach ($segment in $normalized.Split('/')) {
        if ($segment.Equals('.agents', [StringComparison]::OrdinalIgnoreCase) -or
            $segment.Equals('.agent', [StringComparison]::OrdinalIgnoreCase) -or
            $segment.Equals('.gemini', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $false
}

function Test-ContextPolicyPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $name = [System.IO.Path]::GetFileName($Path)
    $name.Equals('AGENTS.md', [StringComparison]::OrdinalIgnoreCase) -or
        $name.Equals('GEMINI.md', [StringComparison]::OrdinalIgnoreCase)
}

$null = Get-Command git -ErrorAction Stop

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
$script:RepositoryRoot = $RepositoryRoot

$baseResolved = (
    & git -C $RepositoryRoot rev-parse --verify "$BaseSha^{commit}"
).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $baseResolved -ne $BaseSha) {
    throw 'Unable to resolve the exact trusted base commit.'
}

$headResolved = (
    & git -C $RepositoryRoot rev-parse --verify "$HeadSha^{commit}"
).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $headResolved -ne $HeadSha) {
    throw 'Unable to resolve the exact review head commit.'
}

$treeBytes = Invoke-GitBytes -Arguments @(
    'ls-tree',
    '-r',
    '-z',
    $headResolved
)
$treeRecords = ConvertFrom-NullSeparatedUtf8 -Bytes $treeBytes

if ($treeRecords.Count -gt $MaxTrackedPaths) {
    throw "Review head contains more than $MaxTrackedPaths tracked paths."
}

$trackedPaths = [System.Collections.Generic.List[string]]::new()
$blockedCount = 0
$unsafeTreeEntryCount = 0

foreach ($record in $treeRecords) {
    $tabIndex = $record.IndexOf([char] 9)
    if ($tabIndex -le 0 -or $tabIndex -ge ($record.Length - 1)) {
        throw 'Git returned a malformed tree entry.'
    }

    $metadata = $record.Substring(0, $tabIndex)
    $path = $record.Substring($tabIndex + 1)
    $metadataParts = @($metadata -split ' ')

    if ($metadataParts.Count -ne 3 -or
        $metadataParts[0] -notmatch '^[0-9]{6}$' -or
        $metadataParts[2] -notmatch '^[0-9a-f]+$') {
        throw 'Git returned a malformed tree entry.'
    }

    $mode = $metadataParts[0]
    if ($mode -cnotin @('100644', '100755')) {
        $unsafeTreeEntryCount++
    }

    $trackedPaths.Add($path)
    if (Test-BlockedCustomizationPath -Path $path) {
        $blockedCount++
    }
}

if ($unsafeTreeEntryCount -gt 0) {
    throw "Review head contains $unsafeTreeEntryCount unsafe Git tree entry mode(s); symlinks, gitlinks, and non-file entries are not permitted."
}

if ($blockedCount -gt 0) {
    throw "Review head contains $blockedCount blocked workspace customization path(s) under .agents or .gemini."
}

$diffBytes = Invoke-GitBytes -Arguments @(
    'diff',
    '--name-only',
    '-z',
    $baseResolved,
    $headResolved,
    '--'
)
$changedPaths = ConvertFrom-NullSeparatedUtf8 -Bytes $diffBytes

$contextChangeCount = 0
foreach ($path in $changedPaths) {
    if (Test-ContextPolicyPath -Path $path) {
        $contextChangeCount++
    }
}

if ($contextChangeCount -gt 0) {
    throw "Review head changes $contextChangeCount AGENTS.md/GEMINI.md policy file(s) relative to the trusted base."
}

[pscustomobject][ordered]@{
    BaseSha = $baseResolved
    HeadSha = $headResolved
    TrackedPathCount = $trackedPaths.Count
    UnsafeTreeEntryCount = 0
    BlockedWorkspaceCustomizationCount = 0
    ChangedContextPolicyCount = 0
    Valid = $true
}
