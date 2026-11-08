#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $repoRoot 'scripts\Prepare-SigningRepository.ps1'
$scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
$workflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\review.yml') -Raw -Encoding utf8

function Require { param([string]$Text,[string]$Needle,[string]$Name); if(-not $Text.Contains($Needle,[StringComparison]::Ordinal)){throw "Missing: $Name"}; Write-Host "[PASS] $Name" }
function Forbid { param([string]$Text,[string]$Needle,[string]$Name); if($Text.Contains($Needle,[StringComparison]::OrdinalIgnoreCase)){throw "Forbidden: $Name"}; Write-Host "[PASS] $Name" }

Require $scriptText "'init', '--bare'" 'signing repository is bare'
Require $scriptText "'--no-recurse-submodules'" 'signing fetch cannot initialize submodules'
Require $scriptText '"+refs/heads/${BaseRef}:refs/remotes/origin/${BaseRef}"' 'base fetch refspec delimits interpolated branch name'
Require $scriptText '"+refs/heads/${HeadRef}:refs/remotes/origin/${HeadRef}"' 'head fetch refspec delimits interpolated branch name'
Forbid $scriptText '$BaseRef:refs' 'base fetch refspec cannot be parsed as scoped variable syntax'
Forbid $scriptText '$HeadRef:refs' 'head fetch refspec cannot be parsed as scoped variable syntax'
Require $scriptText "`$expectedRemoteUrl = 'https://github.com/' + `$Repository + '.git'" 'signing origin is canonicalized'
Require $scriptText 'remote.origin.pushurl' 'separate pushurl is rejected'
Require $scriptText 'Trusted base moved from event SHA' 'base movement fails closed'
Require $scriptText 'PR head moved from event SHA' 'head movement fails closed'
Require $scriptText "'--is-bare-repository'" 'worktree materialization is checked'
Forbid $scriptText "'--filter=blob:none'" 'signing repository does not depend on promisor demand-fetch'
Require $workflow 'Prepare bare signing target' 'workflow uses bare signing preparation'
Forbid $workflow 'Checkout exact PR head for signing' 'signing runner never checks out PR worktree'

# Contract checks for non-leaking git process invocation and pushurl probe
Require $scriptText 'function Invoke-GitProcess' 'git process helper is declared'
Require $scriptText 'function Assert-NoSeparateOriginPushUrl' 'pushurl policy assertion is modularized'
Forbid $scriptText '& git -C $repositoryRoot config' 'pushurl probe does not use direct native git execution'
Forbid $scriptText '$global:LASTEXITCODE = 0' 'preparation script does not blindly zero LASTEXITCODE'
Forbid $scriptText '$global:LASTEXITCODE = $process.ExitCode' 'process invocation does not couple to PowerShell LASTEXITCODE'

# Parse production functions directly from Prepare-SigningRepository.ps1
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if (@($parseErrors).Count -ne 0) {
    throw "Prepare-SigningRepository.ps1 parse errors: $(@($parseErrors | ForEach-Object { $_.Message }) -join '; ')"
}

$functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($fn in $functions) {
    if ($fn.Name -in @('Invoke-GitProcess', 'Assert-NoSeparateOriginPushUrl')) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}

# --- Runtime Regression and Policy Invariant Tests ---
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'antigravity-ci-signing-repo-contract-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $fixtureRepo = Join-Path $tempRoot 'fixture.git'
    & git init --bare $fixtureRepo | Out-Null
    & git -C $fixtureRepo remote add origin 'https://github.com/Herzchens/Doki-Dango.git' | Out-Null
    $fixtureRepoEscaped = $fixtureRepo.Replace('\', '/')

    # 1. Reproduce exact bug before fix: direct native & git config sets LASTEXITCODE = 1
    # under GitHub Actions runner wrapper semantics (exit $LASTEXITCODE)
    $reproChildScript = Join-Path $tempRoot 'repro-old-leak.ps1'
    Set-Content -LiteralPath $reproChildScript -Value @"
`$ErrorActionPreference = 'Stop'
`$configuredPushUrls = @(& git -C '$fixtureRepoEscaped' config --local --get-all remote.origin.pushurl 2>`$null)
if (`$LASTEXITCODE -eq 0 -and `$configuredPushUrls.Count -gt 0) {
    throw 'Bare signing repository must not configure a separate origin pushurl.'
}
if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) {
    exit `$LASTEXITCODE
}
"@ -Encoding utf8NoBOM

    $reproProc = [System.Diagnostics.Process]::Start([System.Diagnostics.ProcessStartInfo]@{
        FileName = 'pwsh'
        Arguments = "-NoProfile -File `"$reproChildScript`""
        UseShellExecute = $false
        RedirectStandardOutput = $true
        RedirectStandardError = $true
        CreateNoWindow = $true
    })
    $reproProc.WaitForExit()
    if ($reproProc.ExitCode -ne 1) {
        throw "Expected old pushurl probe to exit 1 under runner wrapper, but got $($reproProc.ExitCode)."
    }
    Write-Host '[PASS] reproduced exact bug before fix: old pushurl probe exits 1 under GitHub Actions runner wrapper'

    # 2. Verify fixed probe passes with exit code 0 under runner wrapper semantics
    $fixChildScript = Join-Path $tempRoot 'test-fix-wrapper.ps1'
    $fnDefs = ($functions | Where-Object { $_.Name -in @('Invoke-GitProcess', 'Assert-NoSeparateOriginPushUrl') } | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    Set-Content -LiteralPath $fixChildScript -Value @"
`$ErrorActionPreference = 'Stop'
$fnDefs
Assert-NoSeparateOriginPushUrl -RepositoryPath '$fixtureRepoEscaped'
if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) {
    exit `$LASTEXITCODE
}
"@ -Encoding utf8NoBOM

    $fixProc = [System.Diagnostics.Process]::Start([System.Diagnostics.ProcessStartInfo]@{
        FileName = 'pwsh'
        Arguments = "-NoProfile -File `"$fixChildScript`""
        UseShellExecute = $false
        RedirectStandardOutput = $true
        RedirectStandardError = $true
        CreateNoWindow = $true
    })
    $fixProc.WaitForExit()
    if ($fixProc.ExitCode -ne 0) {
        throw "Expected fixed probe to exit 0 under runner wrapper, but got $($fixProc.ExitCode)."
    }
    Write-Host '[PASS] fixed pushurl probe passes with exit code 0 under GitHub Actions runner wrapper'

    # 3. Verify repository with configured separate pushurl is rejected
    & git -C $fixtureRepo config --local --add remote.origin.pushurl 'https://github.com/attacker/malicious.git' | Out-Null
    $rejected = $false
    try {
        Assert-NoSeparateOriginPushUrl -RepositoryPath $fixtureRepo
    }
    catch {
        if ($_.Exception.Message -match 'Bare signing repository must not configure a separate origin pushurl') {
            $rejected = $true
        }
        else {
            throw "Unexpected error message when pushurl configured: $_"
        }
    }
    if (-not $rejected) {
        throw 'Repository with configured pushurl was not rejected.'
    }
    Write-Host '[PASS] repository with configured separate pushurl is rejected'

    # 4. Verify exit code 1 with unexpected stdout fails closed
    $threwStdoutMismatch = $false
    try {
        Assert-NoSeparateOriginPushUrl -RepositoryPath $fixtureRepo -ProcessInvoker {
            param([string[]] $Arguments)
            [pscustomobject]@{
                ExitCode = 1
                StandardOutput = 'unexpected pushurl output'
                StandardError = ''
            }
        }
    }
    catch {
        if ($_.Exception.Message -match 'returned unexpected stdout') {
            $threwStdoutMismatch = $true
        }
        else {
            throw "Unexpected exception for exit code 1 with stdout: $_"
        }
    }
    if (-not $threwStdoutMismatch) {
        throw 'Failed closed check failed: exit code 1 with stdout did not throw.'
    }
    Write-Host '[PASS] exit code 1 with unexpected stdout fails closed'

    # 5. Verify exit code 0 with empty stdout fails closed
    $threwMalformedZero = $false
    try {
        Assert-NoSeparateOriginPushUrl -RepositoryPath $fixtureRepo -ProcessInvoker {
            param([string[]] $Arguments)
            [pscustomobject]@{
                ExitCode = 0
                StandardOutput = "   `r`n  "
                StandardError = ''
            }
        }
    }
    catch {
        if ($_.Exception.Message -match 'unexpectedly returned exit code 0 without output') {
            $threwMalformedZero = $true
        }
        else {
            throw "Unexpected exception for exit code 0 with empty stdout: $_"
        }
    }
    if (-not $threwMalformedZero) {
        throw 'Failed closed check failed: exit code 0 with empty stdout did not throw.'
    }
    Write-Host '[PASS] exit code 0 with empty stdout fails closed'

    # 6. Verify non-zero exit codes fail closed
    # 6a. Real Git exit code 128 on non-existent path
    $threwNonZeroGit = $false
    $nonExistentPath = Join-Path $tempRoot 'nonexistent'
    try {
        Assert-NoSeparateOriginPushUrl -RepositoryPath $nonExistentPath
    }
    catch {
        if ($_.Exception.Message -match 'failed with exit code') {
            $threwNonZeroGit = $true
        }
        else {
            throw "Unexpected exception for non-existent repo: $_"
        }
    }
    if (-not $threwNonZeroGit) {
        throw 'Failed closed check failed: non-existent repo did not throw unexpected exit code.'
    }
    Write-Host '[PASS] real git non-zero exit code (128) fails closed'

    # 6b. Other non-zero exit code (e.g. exit 2)
    $threwNonZeroMock = $false
    try {
        Assert-NoSeparateOriginPushUrl -RepositoryPath $fixtureRepo -ProcessInvoker {
            param([string[]] $Arguments)
            [pscustomobject]@{
                ExitCode = 2
                StandardOutput = ''
                StandardError = 'git config fatal error'
            }
        }
    }
    catch {
        if ($_.Exception.Message -match 'failed with exit code 2') {
            $threwNonZeroMock = $true
        }
        else {
            throw "Unexpected exception for exit code 2: $_"
        }
    }
    if (-not $threwNonZeroMock) {
        throw 'Failed closed check failed: exit code 2 did not throw.'
    }
    Write-Host '[PASS] any other non-zero exit code fails closed'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
