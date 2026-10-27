#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$smokePath = Join-Path $repoRoot 'scripts\Test-AgySandboxSmoke.ps1'
$smoke = Get-Content -LiteralPath $smokePath -Raw -Encoding utf8

function Assert-Contains {
    param(
        [Parameter(Mandatory)]
        [string] $Needle,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not $smoke.Contains($Needle, [StringComparison]::Ordinal)) {
        throw "Sandbox smoke contract missing: $Name"
    }

    Write-Host "[PASS] $Name"
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory)]
        [string] $Needle,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($smoke.Contains($Needle, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Sandbox smoke contract contains forbidden text: $Name"
    }

    Write-Host "[PASS] $Name"
}

Assert-Contains -Needle 'ExpectedAgySha256' -Name 'sandbox smoke pins the AGY executable SHA-256'
Assert-Contains -Needle 'Get-FileHash -LiteralPath $agyPath -Algorithm SHA256' -Name 'sandbox smoke hashes the AGY executable before and after execution'
Assert-Contains -Needle "AGY_CLI_DISABLE_AUTO_UPDATE'] = 'true'" -Name 'sandbox smoke disables AGY self-update'
Assert-Contains -Needle 'Antigravity CLI changed during the sandbox smoke test.' -Name 'sandbox smoke rejects runtime binary mutation'
Assert-Contains -Needle "'--sandbox'" -Name 'sandbox mode is forced'
Assert-Contains -Needle "'stream-json'" -Name 'sandbox smoke uses the typed NDJSON event stream'
Assert-Contains -Needle '$streamEvents.Count -gt 4096' -Name 'sandbox smoke bounds stream event count'
Assert-Contains -Needle "-cnotin @('init', 'step_update', 'result')" -Name 'sandbox smoke rejects unsupported stream event types'
Assert-Contains -Needle "'init'" -Name 'sandbox smoke requires an init event'
Assert-Contains -Needle "'result'" -Name 'sandbox smoke requires a terminal result event'
Assert-Contains -Needle "'always-proceed'" -Name 'sandbox smoke rejects unsafe permission mode'
Assert-Contains -Needle "PSObject.Properties['denied_actions']" -Name 'sandbox smoke inspects headless denied-action evidence'
Assert-Contains -Needle 'requested action(s)' -Name 'sandbox smoke fails on any denied action'
Assert-Contains -Needle '$streamWorkingDirectory.Equals(' -Name 'sandbox smoke binds the observed CLI cwd to the fixture workspace'
Assert-Contains -Needle '@($initPayload.tools) -cnotcontains ''run_command''' -Name 'sandbox smoke requires run_command in the advertised tool set'
Assert-Contains -Needle '$expectedProbeCommand = ''pwsh -NoProfile -File .\sandbox-probe.ps1''' -Name 'sandbox smoke defines the exact expected probe command'
Assert-Contains -Needle '[string] $step.step_type -cne ''tool''' -Name 'sandbox smoke inspects typed tool steps'
Assert-Contains -Needle '[string] $step.tool_name -cne ''run_command''' -Name 'sandbox smoke rejects non-command tool invocation'
Assert-Contains -Needle '[string] $toolInfo.name -cne ''run_command''' -Name 'sandbox smoke verifies canonical tool_info identity'
Assert-Contains -Needle '$toolInfo.parameters.CommandLine' -Name 'sandbox smoke verifies the observed command line'
Assert-Contains -Needle '$matchingProbeDoneEvents -ne 1' -Name 'sandbox smoke requires exactly one completed expected command event'
Assert-Contains -Needle '$toolInfo.error' -Name 'sandbox smoke rejects a completed probe command with a tool error'
Assert-Contains -Needle 'ToolExecutionAttested = $true' -Name 'successful smoke output explicitly records tool-execution attestation'

Assert-Contains -Needle "WindowsProcessJob.ps1" -Name 'sandbox smoke requires the Windows process-job helper'
Assert-Contains -Needle "New-WindowsKillOnCloseJob" -Name 'sandbox smoke creates a kill-on-close Windows Job Object'
Assert-Contains -Needle 'Add-ProcessToWindowsJob -Job $processJob -Process $process' -Name 'sandbox smoke attaches AGY to the process job before trusting execution'
Assert-Contains -Needle 'Close-WindowsProcessJob -Job $processJob' -Name 'sandbox smoke closes the process job during cleanup'
Assert-Contains -Needle "Antigravity sandbox smoke process could not be attached" -Name 'sandbox smoke fails closed if process containment cannot be established'
Assert-Contains -Needle "'--disable-slash-commands'" -Name 'slash command expansion is disabled'
Assert-NotContains -Needle '--dangerously-skip-permissions' -Name 'permission bypass is forbidden'
Assert-Contains -Needle ".ssh" -Name 'outside read probe targets sensitive user-profile content'
Assert-Contains -Needle 'outside_read_succeeded' -Name 'outside read result is asserted'
Assert-Contains -Needle 'outside_write_succeeded' -Name 'outside write result is asserted'
Assert-Contains -Needle 'network_succeeded' -Name 'network result is asserted'
Assert-Contains -Needle 'PROCESS_VM_READ' -Name 'sandbox smoke probes sibling-process memory-read handles'
Assert-Contains -Needle 'PROCESS_TERMINATE' -Name 'sandbox smoke probes sibling-process terminate handles'
Assert-Contains -Needle 'process_handle_probe_completed' -Name 'sibling-process handle probe must execute before acceptance'
Assert-Contains -Needle 'process_vm_read_handle_succeeded' -Name 'sibling-process memory-read outcome is asserted'
Assert-Contains -Needle 'process_terminate_handle_succeeded' -Name 'sibling-process terminate outcome is asserted'
Assert-Contains -Needle 'SiblingProcessReadBlocked = $true' -Name 'sibling-process memory isolation is an explicit acceptance invariant'
Assert-Contains -Needle 'SiblingProcessTerminateBlocked = $true' -Name 'sibling-process termination isolation is an explicit acceptance invariant'
Assert-Contains -Needle '$sentinelProcess.Kill($true)' -Name 'host sibling-process sentinel is terminated during cleanup'
Assert-Contains -Needle "https://example.com/" -Name 'network isolation is probed with a reachable HTTPS origin'
Assert-Contains -Needle 'SentinelLeakedToOutput = $false' -Name 'sentinel leakage is an explicit acceptance invariant'
Assert-Contains -Needle "'AGY_ADC_AUTH'" -Name 'sandbox smoke strips Antigravity ADC auth override'
Assert-Contains -Needle "'GEMINI_API_KEY'" -Name 'sandbox smoke strips Gemini API-key auth override'
Assert-Contains -Needle "'GOOGLE_APPLICATION_CREDENTIALS'" -Name 'sandbox smoke strips Google credential-file override'
Assert-Contains -Needle 'credentials?' -Name 'sandbox smoke strips plural credential-named environment values'

Assert-Contains -Needle 'CredWriteW' -Name 'sandbox smoke creates a session-only Windows Credential Manager sentinel'
Assert-Contains -Needle 'CredReadW' -Name 'sandbox smoke probes Windows Credential Manager access from inside the sandbox'
Assert-Contains -Needle 'credential_probe_completed' -Name 'credential probe must actually execute before acceptance'
Assert-Contains -Needle 'credential_read_succeeded' -Name 'credential read outcome is asserted'
Assert-Contains -Needle 'CredentialManagerReadBlocked = $true' -Name 'Credential Manager isolation is an explicit acceptance invariant'
Assert-Contains -Needle 'credential_write_probe_completed' -Name 'Credential Manager write probe must execute before acceptance'
Assert-Contains -Needle 'credential_write_succeeded' -Name 'Credential Manager write-persistence outcome is asserted'
Assert-Contains -Needle 'CredentialManagerWriteBlocked = $true' -Name 'Credential Manager write isolation is an explicit acceptance invariant'
Assert-Contains -Needle '[AntigravityCiCredentialSentinel]::CanRead($credentialWriteTarget)' -Name 'host verifies the sandbox credential-write target did not persist'
Assert-Contains -Needle '[AntigravityCiCredentialSentinel]::Delete($credentialWriteTarget)' -Name 'sandbox credential-write sentinel is deleted during cleanup'
Assert-Contains -Needle '[AntigravityCiCredentialSentinel]::Delete($credentialTarget)' -Name 'credential sentinel is deleted during cleanup'

Assert-Contains -Needle 'schtasks.exe /Create' -Name 'sandbox smoke probes Windows Task Scheduler registration'
Assert-Contains -Needle '$hostTaskSchedulerRegistrationAllowed = $false' -Name 'Task Scheduler host capability is measured without requiring elevation'
Assert-Contains -Needle 'ScheduledTaskBoundary = if ($hostTaskSchedulerRegistrationAllowed) { ''sandbox'' } else { ''host-account-policy'' }' -Name 'Task Scheduler boundary records whether sandbox or host policy blocked registration'
Assert-Contains -Needle 'scheduled_task_probe_completed' -Name 'Task Scheduler probe must execute before acceptance'
Assert-Contains -Needle 'scheduled_task_create_succeeded' -Name 'Task Scheduler creation outcome is asserted'
Assert-Contains -Needle 'schtasks.exe /Query /TN $taskName' -Name 'host verifies no sandbox task registration persisted'
Assert-Contains -Needle 'ScheduledTaskRegistrationBlocked = $true' -Name 'Task Scheduler isolation is an explicit acceptance invariant'
Assert-Contains -Needle 'schtasks.exe /Delete /TN $cleanupTaskName' -Name 'Task Scheduler sentinels are deleted during cleanup'
Assert-NotContains -Needle 'sandbox scheduler isolation cannot be proven' -Name 'low-privilege host denial is not treated as a smoke-test failure'

Assert-Contains -Needle 'CurrentVersion\Run' -Name 'sandbox smoke probes per-user Run-key persistence'
Assert-Contains -Needle '$hostRegistryRunWriteAllowed = $false' -Name 'HKCU Run host capability is measured without requiring write access'
Assert-Contains -Needle 'RegistryRunBoundary = if ($hostRegistryRunWriteAllowed) { ''sandbox'' } else { ''host-account-policy'' }' -Name 'HKCU Run boundary records sandbox versus host-policy enforcement'
Assert-Contains -Needle 'Antigravity-CI-Sandbox-Control-' -Name 'host control fixture proves persistence primitives are available outside sandbox'
Assert-Contains -Needle 'registry_probe_completed' -Name 'registry persistence probe must execute before acceptance'
Assert-Contains -Needle 'registry_write_succeeded' -Name 'registry write outcome is asserted'
Assert-Contains -Needle 'RegistryRunPersistenceBlocked = $true' -Name 'HKCU Run isolation is an explicit acceptance invariant'
Assert-Contains -Needle 'DeleteValue($runValueName, $false)' -Name 'registry persistence sentinel is deleted during cleanup'
Assert-NotContains -Needle 'Host review account cannot open the HKCU Run key' -Name 'host Run-key denial is not treated as a smoke-test failure'
Assert-NotContains -Needle 'Host review account could not verify the HKCU Run control fixture' -Name 'host Run-key denial remains an acceptable boundary'
Assert-Contains -Needle '[Environment]::SetEnvironmentVariable(' -Name 'sandbox smoke probes persistent user-scoped environment state'
Assert-Contains -Needle '[EnvironmentVariableTarget]::User' -Name 'user environment probe targets the persistent HKCU user scope'
Assert-Contains -Needle 'user_environment_probe_completed' -Name 'user environment persistence probe must execute before acceptance'
Assert-Contains -Needle 'user_environment_write_succeeded' -Name 'user environment persistence outcome is asserted'
Assert-Contains -Needle 'UserEnvironmentPersistenceBlocked = $true' -Name 'user environment persistence isolation is an explicit acceptance invariant'
Assert-Contains -Needle 'UserEnvironmentBoundary = if ($hostUserEnvironmentWriteAllowed) { ''sandbox'' } else { ''host-account-policy'' }' -Name 'user environment boundary records sandbox versus host-policy enforcement'
Assert-Contains -Needle '$userEnvironmentName,' -Name 'user environment sentinel is deleted during cleanup'

# Embedded C# compilation and method-signature regression tests
$idxSentinel = $smoke.IndexOf('public static class AntigravityCiCredentialSentinel')
$idxEndSentinel = $smoke.IndexOf('public static class AntigravityCiProcessBoundary')
if ($idxSentinel -lt 0 -or $idxEndSentinel -le $idxSentinel) {
    throw 'Could not locate AntigravityCiCredentialSentinel definition in smoke script.'
}
$sentinelCode = 'using System; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes; using System.Text; ' +
    $smoke.Substring($idxSentinel, $idxEndSentinel - $idxSentinel)
$sentinelCode = $sentinelCode.Substring(0, $sentinelCode.LastIndexOf('}') + 1)
Add-Type -TypeDefinition $sentinelCode -Language CSharp -ErrorAction Stop

$idxProcess = $smoke.IndexOf('public static class AntigravityCiProcessBoundary')
$idxEndProcess = $smoke.IndexOf('Get-Command schtasks.exe', $idxProcess)
if ($idxProcess -lt 0 -or $idxEndProcess -le $idxProcess) {
    throw 'Could not locate AntigravityCiProcessBoundary definition in smoke script.'
}
$processCode = 'using System; using System.Runtime.InteropServices; ' +
    $smoke.Substring($idxProcess, $idxEndProcess - $idxProcess)
$processCode = $processCode.Substring(0, $processCode.LastIndexOf('}') + 1)
Add-Type -TypeDefinition $processCode -Language CSharp -ErrorAction Stop

$idxProbe = $smoke.IndexOf('public static class AntigravityCiCredentialProbe')
$idxEndProbe = $smoke.IndexOf('$result.credential_read_succeeded', $idxProbe)
if ($idxProbe -lt 0 -or $idxEndProbe -le $idxProbe) {
    throw 'Could not locate AntigravityCiCredentialProbe definition in smoke script.'
}
$probeCode = 'using System; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes; using System.Text; ' +
    $smoke.Substring($idxProbe, $idxEndProbe - $idxProbe)
$probeCode = $probeCode.Substring(0, $probeCode.LastIndexOf('}') + 1)
Add-Type -TypeDefinition $probeCode -Language CSharp -ErrorAction Stop

$sentinelWrite = [AntigravityCiCredentialSentinel].GetMethod('Write', [type[]]@([string], [string], [string]))
$sentinelCanRead = [AntigravityCiCredentialSentinel].GetMethod('CanRead', [type[]]@([string]))
$sentinelDelete = [AntigravityCiCredentialSentinel].GetMethod('Delete', [type[]]@([string]))
if ($null -eq $sentinelWrite -or $sentinelWrite.ReturnType -ne [System.Void]) {
    throw 'AntigravityCiCredentialSentinel.Write must be defined and return void.'
}
if ($null -eq $sentinelCanRead -or $sentinelCanRead.ReturnType -ne [System.Boolean]) {
    throw 'AntigravityCiCredentialSentinel.CanRead must be defined and return bool.'
}
if ($null -eq $sentinelDelete -or $sentinelDelete.ReturnType -ne [System.Void]) {
    throw 'AntigravityCiCredentialSentinel.Delete must be defined and return void.'
}
Write-Host '[PASS] AntigravityCiCredentialSentinel compiles with throwing void Write and host sentinel methods'

$probeWrite = [AntigravityCiCredentialProbe].GetMethod('Write', [type[]]@([string], [string], [string]))
$probeCanRead = [AntigravityCiCredentialProbe].GetMethod('CanRead', [type[]]@([string]))
if ($null -eq $probeWrite -or $probeWrite.ReturnType -ne [System.Boolean]) {
    throw 'AntigravityCiCredentialProbe.Write must be defined and return bool.'
}
if ($null -eq $probeCanRead -or $probeCanRead.ReturnType -ne [System.Boolean]) {
    throw 'AntigravityCiCredentialProbe.CanRead must be defined and return bool.'
}
Write-Host '[PASS] AntigravityCiCredentialProbe compiles with non-throwing bool Write and CanRead probing methods'

$procRead = [AntigravityCiProcessBoundary].GetMethod('CanReadMemory', [type[]]@([int]))
$procTerm = [AntigravityCiProcessBoundary].GetMethod('CanTerminate', [type[]]@([int]))
if ($null -eq $procRead -or $procRead.ReturnType -ne [System.Boolean] -or
    $null -eq $procTerm -or $procTerm.ReturnType -ne [System.Boolean]) {
    throw 'AntigravityCiProcessBoundary methods must be defined and return bool.'
}
Write-Host '[PASS] AntigravityCiProcessBoundary compiles with memory-read and termination probe methods'
