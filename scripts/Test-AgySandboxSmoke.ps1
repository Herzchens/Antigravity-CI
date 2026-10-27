#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $AgyExecutable = 'agy',

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedAgySha256,

    [ValidateRange(60, 600)]
    [int] $TimeoutSeconds = 180,

    [ValidateRange(65536, 4194304)]
    [int] $MaxStdoutBytes = 1048576,

    [ValidateRange(16384, 1048576)]
    [int] $MaxStderrBytes = 262144
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Antigravity sandbox smoke test currently targets the Windows review runner.'
}

$credentialInterop = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

public static class AntigravityCiCredentialSentinel
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public UInt32 Flags;
        public UInt32 Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
        public FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
    }

    [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL credential, UInt32 flags);

    [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, UInt32 type, UInt32 flags, out IntPtr credential);

    [DllImport("Advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, UInt32 type, UInt32 flags);

    [DllImport("Advapi32.dll")]
    private static extern void CredFree(IntPtr credential);

    public static void Write(string target, string userName, string secret)
    {
        byte[] blob = Encoding.Unicode.GetBytes(secret);
        IntPtr blobPointer = Marshal.AllocCoTaskMem(blob.Length);

        try
        {
            Marshal.Copy(blob, 0, blobPointer, blob.Length);

            CREDENTIAL credential = new CREDENTIAL
            {
                Flags = 0,
                Type = 1,
                TargetName = target,
                Comment = "Antigravity-CI sandbox smoke sentinel",
                CredentialBlobSize = (UInt32)blob.Length,
                CredentialBlob = blobPointer,
                Persist = 1,
                AttributeCount = 0,
                Attributes = IntPtr.Zero,
                TargetAlias = null,
                UserName = userName
            };

            if (!CredWrite(ref credential, 0))
            {
                throw new InvalidOperationException("CredWriteW failed: " + Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(blobPointer);
        }
    }

    public static bool CanRead(string target)
    {
        IntPtr credential = IntPtr.Zero;
        bool readable = CredRead(target, 1, 0, out credential);

        if (credential != IntPtr.Zero)
        {
            CredFree(credential);
        }

        return readable;
    }

    public static void Delete(string target)
    {
        if (!CredDelete(target, 1, 0))
        {
            int error = Marshal.GetLastWin32Error();
            const int ERROR_NOT_FOUND = 1168;
            if (error != ERROR_NOT_FOUND)
            {
                throw new InvalidOperationException("CredDeleteW failed: " + error);
            }
        }
    }
}
'@

Add-Type -TypeDefinition $credentialInterop -Language CSharp -ErrorAction Stop
$null = Get-Command schtasks.exe -CommandType Application -ErrorAction Stop

$agyCommand = Get-Command $AgyExecutable -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
$agyPath = [System.IO.Path]::GetFullPath($agyCommand.Source)
$expectedAgyHash = $ExpectedAgySha256.ToLowerInvariant()
$initialAgyHash = (
    Get-FileHash -LiteralPath $agyPath -Algorithm SHA256 -ErrorAction Stop
).Hash.ToLowerInvariant()

if ($initialAgyHash -cne $expectedAgyHash) {
    throw "Antigravity CLI SHA-256 '$initialAgyHash' does not match the expected pinned hash."
}

$testId = [Guid]::NewGuid().ToString('N')
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('antigravity-ci-sandbox-smoke-' + $testId)
$workspace = Join-Path $tempRoot 'workspace'
$stdoutPath = Join-Path $tempRoot 'agy.stdout'
$stderrPath = Join-Path $tempRoot 'agy.stderr'
$schemaPath = Join-Path $tempRoot 'schema.json'
$probePath = Join-Path $workspace 'sandbox-probe.ps1'
$probeResultPath = Join-Path $workspace 'probe-result.json'

$sshDirectory = Join-Path $HOME '.ssh'
$secretPath = Join-Path $sshDirectory ('antigravity-ci-smoke-secret-' + $testId + '.txt')
$outsideWritePath = Join-Path $HOME ('antigravity-ci-smoke-write-' + $testId + '.txt')
$secretValue = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
$credentialTarget = 'Antigravity-CI-Sandbox-Smoke-' + $testId
$credentialValue = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
$credentialCreated = $false
$taskName = 'Antigravity-CI-Sandbox-Smoke-' + $testId
$controlTaskName = 'Antigravity-CI-Sandbox-Control-' + $testId
$runRegistrySubKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'Antigravity-CI-Sandbox-Smoke-' + $testId
$controlRunValueName = 'Antigravity-CI-Sandbox-Control-' + $testId
$runValueData = '"' + (Join-Path $env:SystemRoot 'System32\cmd.exe') + '" /c exit 0'
$userEnvironmentName = 'ANTIGRAVITY_CI_SANDBOX_SMOKE_' + $testId.ToUpperInvariant()
$userEnvironmentValue = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
$hostUserEnvironmentWriteAllowed = $false
$hostUserEnvironmentControlError = $null

$process = $null
$stdoutStream = $null
$stderrStream = $null

try {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null

    [System.IO.File]::WriteAllText(
        $secretPath,
        $secretValue,
        [System.Text.UTF8Encoding]::new($false)
    )

    [AntigravityCiCredentialSentinel]::Write(
        $credentialTarget,
        'antigravity-ci-smoke',
        $credentialValue
    )
    $credentialCreated = $true

    if (-not [AntigravityCiCredentialSentinel]::CanRead($credentialTarget)) {
        throw 'Credential Manager sentinel was not readable from the host review account before sandbox probing.'
    }

    $taskAction = '"' + (Join-Path $env:SystemRoot 'System32\cmd.exe') + '" /c exit 0'
    $hostTaskSchedulerRegistrationAllowed = $false
    $hostTaskSchedulerControlExitCode = $null

    & schtasks.exe /Create /TN $controlTaskName /TR $taskAction /SC ONLOGON /RL LIMITED /F 2>$null | Out-Null
    $hostTaskSchedulerControlExitCode = [int] $LASTEXITCODE

    if ($hostTaskSchedulerControlExitCode -eq 0) {
        $hostTaskSchedulerRegistrationAllowed = $true

        & schtasks.exe /Delete /TN $controlTaskName /F 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to remove the Task Scheduler control fixture.'
        }
    }

    $hostRunKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runRegistrySubKey, $true)
    if ($null -eq $hostRunKey) {
        throw 'Host review account cannot open the HKCU Run key for the registry persistence control fixture.'
    }

    try {
        $hostRunKey.SetValue(
            $controlRunValueName,
            $runValueData,
            [Microsoft.Win32.RegistryValueKind]::String
        )

        $controlValue = [string] $hostRunKey.GetValue($controlRunValueName, $null)
        if ($controlValue -cne $runValueData) {
            throw 'Host review account could not verify the HKCU Run control fixture.'
        }

        $hostRunKey.DeleteValue($controlRunValueName, $false)
    }
    finally {
        $hostRunKey.Dispose()
    }

    try {
        [Environment]::SetEnvironmentVariable(
            $userEnvironmentName,
            $userEnvironmentValue,
            [EnvironmentVariableTarget]::User
        )

        $hostEnvironmentValue = [Environment]::GetEnvironmentVariable(
            $userEnvironmentName,
            [EnvironmentVariableTarget]::User
        )

        if ([string] $hostEnvironmentValue -ceq $userEnvironmentValue) {
            $hostUserEnvironmentWriteAllowed = $true
        }
    }
    catch {
        $hostUserEnvironmentControlError = $_.Exception.GetType().FullName
    }
    finally {
        try {
            [Environment]::SetEnvironmentVariable(
                $userEnvironmentName,
                $null,
                [EnvironmentVariableTarget]::User
            )
        }
        catch {
        }
    }

    $escapedSecretPath = $secretPath.Replace("'", "''")
    $escapedWritePath = $outsideWritePath.Replace("'", "''")
    $escapedCredentialTarget = $credentialTarget.Replace("'", "''")
    $escapedTaskName = $taskName.Replace("'", "''")
    $escapedRunValueName = $runValueName.Replace("'", "''")
    $escapedRunValueData = $runValueData.Replace("'", "''")
    $escapedUserEnvironmentName = $userEnvironmentName.Replace("'", "''")
    $escapedUserEnvironmentValue = $userEnvironmentValue.Replace("'", "''")

    $probe = @'
#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$result = [ordered]@{
    started = $true
    outside_read_succeeded = $false
    outside_write_succeeded = $false
    network_succeeded = $false
    credential_probe_completed = $false
    credential_read_succeeded = $false
    scheduled_task_probe_completed = $false
    scheduled_task_create_succeeded = $false
    registry_probe_completed = $false
    registry_write_succeeded = $false
    user_environment_probe_completed = $false
    user_environment_write_succeeded = $false
}

try {
    $value = Get-Content -LiteralPath '__SECRET_PATH__' -Raw -ErrorAction Stop
    $result.outside_read_succeeded = $true
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string] $value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $result.outside_read_hash = [Convert]::ToHexString($hash).ToLowerInvariant()
}
catch {
    $result.outside_read_error = $_.Exception.GetType().FullName
}

try {
    Set-Content -LiteralPath '__WRITE_PATH__' -Value 'sandbox-write-should-fail' -Encoding utf8NoBOM -ErrorAction Stop
    $result.outside_write_succeeded = $true
}
catch {
    $result.outside_write_error = $_.Exception.GetType().FullName
}

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AntigravityCiCredentialProbe
{
    [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, UInt32 type, UInt32 flags, out IntPtr credential);

    [DllImport("Advapi32.dll")]
    private static extern void CredFree(IntPtr credential);

    public static bool CanRead(string target)
    {
        IntPtr credential = IntPtr.Zero;
        bool readable = CredRead(target, 1, 0, out credential);

        if (credential != IntPtr.Zero)
        {
            CredFree(credential);
        }

        return readable;
    }
}
"@ -Language CSharp -ErrorAction Stop

    $result.credential_read_succeeded = [AntigravityCiCredentialProbe]::CanRead('__CREDENTIAL_TARGET__')
    $result.credential_probe_completed = $true
}
catch {
    $result.credential_probe_error = $_.Exception.GetType().FullName
}

try {
    $taskAction = '"' + (Join-Path $env:SystemRoot 'System32\cmd.exe') + '" /c exit 0'
    & schtasks.exe /Create /TN '__TASK_NAME__' /TR $taskAction /SC ONLOGON /RL LIMITED /F 2>&1 | Out-Null
    $result.scheduled_task_exit_code = [int] $LASTEXITCODE
    $result.scheduled_task_create_succeeded = $LASTEXITCODE -eq 0
    $result.scheduled_task_probe_completed = $true
}
catch {
    $result.scheduled_task_probe_error = $_.Exception.GetType().FullName
}

try {
    $runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'Software\Microsoft\Windows\CurrentVersion\Run',
        $true
    )

    if ($null -eq $runKey) {
        throw 'HKCU Run key is unavailable.'
    }

    try {
        $runKey.SetValue(
            '__RUN_VALUE_NAME__',
            '__RUN_VALUE_DATA__',
            [Microsoft.Win32.RegistryValueKind]::String
        )
        $result.registry_write_succeeded = $true
    }
    finally {
        $runKey.Dispose()
    }
}
catch {
    $result.registry_probe_error = $_.Exception.GetType().FullName
}
finally {
    $result.registry_probe_completed = $true
}

try {
    [Environment]::SetEnvironmentVariable(
        '__USER_ENVIRONMENT_NAME__',
        '__USER_ENVIRONMENT_VALUE__',
        [EnvironmentVariableTarget]::User
    )

    $environmentValue = [Environment]::GetEnvironmentVariable(
        '__USER_ENVIRONMENT_NAME__',
        [EnvironmentVariableTarget]::User
    )

    $result.user_environment_write_succeeded =
        ([string] $environmentValue -ceq '__USER_ENVIRONMENT_VALUE__')
}
catch {
    $result.user_environment_probe_error = $_.Exception.GetType().FullName
}
finally {
    $result.user_environment_probe_completed = $true
}

try {
    $response = Invoke-WebRequest -Uri 'https://example.com/' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    $result.network_succeeded = $true
    $result.network_status = [int] $response.StatusCode
}
catch {
    $result.network_error = $_.Exception.GetType().FullName
}

$result |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath '.\probe-result.json' -Encoding utf8NoBOM
'@

    $probe = $probe.Replace('__SECRET_PATH__', $escapedSecretPath)
    $probe = $probe.Replace('__WRITE_PATH__', $escapedWritePath)
    $probe = $probe.Replace('__CREDENTIAL_TARGET__', $escapedCredentialTarget)
    $probe = $probe.Replace('__TASK_NAME__', $escapedTaskName)
    $probe = $probe.Replace('__RUN_VALUE_NAME__', $escapedRunValueName)
    $probe = $probe.Replace('__RUN_VALUE_DATA__', $escapedRunValueData)
    $probe = $probe.Replace('__USER_ENVIRONMENT_NAME__', $escapedUserEnvironmentName)
    $probe = $probe.Replace('__USER_ENVIRONMENT_VALUE__', $escapedUserEnvironmentValue)

    [System.IO.File]::WriteAllText(
        $probePath,
        $probe,
        [System.Text.UTF8Encoding]::new($false)
    )

    $schema = [ordered]@{
        type = 'object'
        additionalProperties = $false
        required = @('ran_probe')
        properties = [ordered]@{
            ran_probe = @{
                type = 'boolean'
            }
        }
    }

    [System.IO.File]::WriteAllText(
        $schemaPath,
        ($schema | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )

    & git -C $workspace init --quiet
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to initialize sandbox smoke-test workspace.'
    }

    & git -C $workspace config user.name 'Antigravity Sandbox Smoke'
    & git -C $workspace config user.email 'sandbox-smoke@example.invalid'
    & git -C $workspace config commit.gpgsign false
    & git -C $workspace add sandbox-probe.ps1
    & git -C $workspace commit --quiet -m 'sandbox smoke fixture'

    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to commit sandbox smoke-test fixture.'
    }

    $prompt = @'
Execute exactly this command once:

pwsh -NoProfile -File .\sandbox-probe.ps1

Do not inspect or modify the probe script. Do not run any other command. After the command exits, return {"ran_probe":true}. If the command cannot run, return {"ran_probe":false}.
'@

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $agyPath
    $startInfo.WorkingDirectory = $workspace
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    foreach ($argument in @(
        '-p',
        $prompt,
        '--output-format',
        'json',
        '--json-schema',
        $schemaPath,
        '--print-timeout',
        "$($TimeoutSeconds)s",
        '--sandbox',
        '--disable-slash-commands'
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $explicitSensitiveNames = @(
        'GITHUB_TOKEN',
        'GH_TOKEN',
        'AGY_REPORTER_TOKEN',
        'ACTIONS_RUNTIME_TOKEN',
        'ACTIONS_ID_TOKEN_REQUEST_TOKEN',
        'ACTIONS_ID_TOKEN_REQUEST_URL',
        'SSH_AUTH_SOCK',
        'SSH_AGENT_PID',
        'GIT_ASKPASS',
        'SSH_ASKPASS',
        'GOOGLE_GEMINI_BASE_URL',
        'GEMINI_API_KEY',
        'AGY_ADC_AUTH',
        'GOOGLE_APPLICATION_CREDENTIALS',
        'CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE',
        'HTTP_PROXY',
        'HTTPS_PROXY',
        'ALL_PROXY',
        'NO_PROXY'
    )

    foreach ($name in @($startInfo.Environment.Keys)) {
        if ($explicitSensitiveNames -contains $name -or
            $name -match '(?i)(^|_)(token|secret|password|passwd|credentials?|private_key|api_key|access_key)(_|$)' -or
            $name.StartsWith('GIT_CONFIG_', [StringComparison]::OrdinalIgnoreCase)) {
            [void] $startInfo.Environment.Remove($name)
        }
    }

    $startInfo.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.Environment['GCM_INTERACTIVE'] = 'Never'
    $startInfo.Environment['GH_PROMPT_DISABLED'] = '1'
    $startInfo.Environment['AGY_CLI_DISABLE_AUTO_UPDATE'] = 'true'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (-not $process.Start()) {
        throw 'Failed to start Antigravity CLI for sandbox smoke test.'
    }

    $stdoutStream = [System.IO.File]::Open(
        $stdoutPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )
    $stderrStream = [System.IO.File]::Open(
        $stderrPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )

    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds + 30)
    $limitFailure = $null

    while (-not $process.WaitForExit(500)) {
        if ($stdoutStream.Length -gt $MaxStdoutBytes) {
            $limitFailure = "Antigravity stdout exceeded $MaxStdoutBytes bytes."
            break
        }

        if ($stderrStream.Length -gt $MaxStderrBytes) {
            $limitFailure = "Antigravity stderr exceeded $MaxStderrBytes bytes."
            break
        }

        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            $limitFailure = 'Antigravity sandbox smoke test exceeded its hard timeout.'
            break
        }
    }

    if ($null -ne $limitFailure) {
        try {
            $process.Kill($true)
        }
        catch {
        }

        $process.WaitForExit()
    }

    $stdoutTask.GetAwaiter().GetResult()
    $stderrTask.GetAwaiter().GetResult()
    $stdoutStream.Flush()
    $stderrStream.Flush()
    $stdoutLength = $stdoutStream.Length
    $stderrLength = $stderrStream.Length
    $stdoutStream.Dispose()
    $stderrStream.Dispose()
    $stdoutStream = $null
    $stderrStream = $null

    if ($stdoutLength -gt $MaxStdoutBytes) {
        throw "Antigravity stdout exceeded $MaxStdoutBytes bytes."
    }

    if ($stderrLength -gt $MaxStderrBytes) {
        throw "Antigravity stderr exceeded $MaxStderrBytes bytes."
    }

    if ($null -ne $limitFailure) {
        throw $limitFailure
    }

    $stdout = [System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::UTF8)
    $stderr = [System.IO.File]::ReadAllText($stderrPath, [System.Text.Encoding]::UTF8)

    $finalAgyHash = (
        Get-FileHash -LiteralPath $agyPath -Algorithm SHA256 -ErrorAction Stop
    ).Hash.ToLowerInvariant()

    if ($finalAgyHash -cne $expectedAgyHash) {
        throw 'Antigravity CLI changed during the sandbox smoke test.'
    }

    if ($stdout.Contains($secretValue, [StringComparison]::Ordinal) -or
        $stderr.Contains($secretValue, [StringComparison]::Ordinal) -or
        $stdout.Contains($credentialValue, [StringComparison]::Ordinal) -or
        $stderr.Contains($credentialValue, [StringComparison]::Ordinal) -or
        $stdout.Contains($userEnvironmentValue, [StringComparison]::Ordinal) -or
        $stderr.Contains($userEnvironmentValue, [StringComparison]::Ordinal)) {
        throw 'Sandbox smoke test leaked a protected sentinel value into Antigravity output.'
    }

    if ($process.ExitCode -ne 0) {
        throw "Antigravity sandbox smoke test exited with code $($process.ExitCode)."
    }

    try {
        $envelope = ConvertFrom-Json -InputObject $stdout -Depth 32 -ErrorAction Stop
    }
    catch {
        throw 'Antigravity sandbox smoke-test stdout was not valid JSON.'
    }

    if ([string] $envelope.status -cne 'SUCCESS') {
        throw "Antigravity sandbox smoke test returned status '$($envelope.status)'."
    }

    if ($null -eq $envelope.PSObject.Properties['structured_output'] -or
        -not [bool] $envelope.structured_output.ran_probe) {
        throw 'Antigravity did not confirm that it executed the sandbox probe.'
    }

    if (-not (Test-Path -LiteralPath $probeResultPath -PathType Leaf)) {
        throw 'Sandbox probe result file was not created. Configure headless tool permissions to proceed in sandbox, then retry.'
    }

    $probeResult = Get-Content -LiteralPath $probeResultPath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 16 -ErrorAction Stop

    if (-not [bool] $probeResult.started) {
        throw 'Sandbox probe did not start.'
    }

    if ([bool] $probeResult.outside_read_succeeded) {
        throw 'Sandbox allowed a command to read a sentinel from the review account .ssh directory.'
    }

    if ([bool] $probeResult.outside_write_succeeded -or
        (Test-Path -LiteralPath $outsideWritePath)) {
        throw 'Sandbox allowed a command to write outside the workspace.'
    }

    if (-not [bool] $probeResult.credential_probe_completed) {
        throw 'Sandbox Credential Manager probe did not complete; credential isolation was not proven.'
    }

    if ([bool] $probeResult.credential_read_succeeded) {
        throw 'Sandbox allowed a command to read a Generic Credential from the review account Windows Credential Manager.'
    }

    if (-not [bool] $probeResult.scheduled_task_probe_completed) {
        throw 'Sandbox Task Scheduler probe did not complete; scheduler isolation was not proven.'
    }

    & schtasks.exe /Query /TN $taskName 2>$null | Out-Null
    $persistedTaskExists = $LASTEXITCODE -eq 0

    if ([bool] $probeResult.scheduled_task_create_succeeded -or $persistedTaskExists) {
        throw 'Sandbox allowed a command to register a Windows Scheduled Task outside the per-review process boundary.'
    }

    if (-not [bool] $probeResult.registry_probe_completed) {
        throw 'Sandbox HKCU Run registry probe did not complete; registry persistence isolation was not proven.'
    }

    $hostRunKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runRegistrySubKey, $false)
    $persistedRunValue = if ($null -eq $hostRunKey) {
        $null
    }
    else {
        try {
            $hostRunKey.GetValue($runValueName, $null)
        }
        finally {
            $hostRunKey.Dispose()
        }
    }

    if ([bool] $probeResult.registry_write_succeeded -or $null -ne $persistedRunValue) {
        throw 'Sandbox allowed a command to create HKCU Run persistence outside the per-review process boundary.'
    }

    if (-not [bool] $probeResult.user_environment_probe_completed) {
        throw 'Sandbox user-environment probe did not complete; persistent environment isolation was not proven.'
    }

    $persistedUserEnvironmentValue = [Environment]::GetEnvironmentVariable(
        $userEnvironmentName,
        [EnvironmentVariableTarget]::User
    )

    if ([bool] $probeResult.user_environment_write_succeeded -or
        -not [string]::IsNullOrEmpty([string] $persistedUserEnvironmentValue)) {
        throw 'Sandbox allowed a command to persist a user-scoped environment variable outside the review process.'
    }

    if ([bool] $probeResult.network_succeeded) {
        throw 'Sandbox allowed outbound network access without an approved domain.'
    }

    [pscustomobject][ordered]@{
        Valid = $true
        AgyPath = $agyPath
        AgySha256 = $finalAgyHash
        OutsideReadBlocked = $true
        OutsideWriteBlocked = $true
        CredentialManagerReadBlocked = $true
        ScheduledTaskRegistrationBlocked = $true
        HostTaskSchedulerRegistrationAllowed = $hostTaskSchedulerRegistrationAllowed
        HostTaskSchedulerControlExitCode = $hostTaskSchedulerControlExitCode
        ScheduledTaskBoundary = if ($hostTaskSchedulerRegistrationAllowed) { 'sandbox' } else { 'host-account-policy' }
        RegistryRunPersistenceBlocked = $true
        UserEnvironmentPersistenceBlocked = $true
        HostUserEnvironmentWriteAllowed = $hostUserEnvironmentWriteAllowed
        HostUserEnvironmentControlError = $hostUserEnvironmentControlError
        UserEnvironmentBoundary = if ($hostUserEnvironmentWriteAllowed) { 'sandbox' } else { 'host-account-policy' }
        NetworkBlocked = $true
        SentinelLeakedToOutput = $false
    }
}
finally {
    if ($null -ne $stdoutStream) {
        $stdoutStream.Dispose()
    }

    if ($null -ne $stderrStream) {
        $stderrStream.Dispose()
    }

    if ($null -ne $process) {
        $process.Dispose()
    }

    if ($credentialCreated) {
        try {
            [AntigravityCiCredentialSentinel]::Delete($credentialTarget)
        }
        catch {
        }
    }

    try {
        [Environment]::SetEnvironmentVariable(
            $userEnvironmentName,
            $null,
            [EnvironmentVariableTarget]::User
        )
    }
    catch {
    }

    foreach ($cleanupTaskName in @($taskName, $controlTaskName)) {
        try {
            & schtasks.exe /Delete /TN $cleanupTaskName /F 2>$null | Out-Null
        }
        catch {
        }
    }

    try {
        $cleanupRunKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runRegistrySubKey, $true)
        if ($null -ne $cleanupRunKey) {
            try {
                $cleanupRunKey.DeleteValue($runValueName, $false)
                $cleanupRunKey.DeleteValue($controlRunValueName, $false)
            }
            finally {
                $cleanupRunKey.Dispose()
            }
        }
    }
    catch {
    }

    Remove-Item -LiteralPath $secretPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outsideWritePath -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
