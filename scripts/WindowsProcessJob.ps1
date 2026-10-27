#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'Windows process-job containment is only available on Windows.'
}

if ($null -eq ('AntigravityCi.ProcessJobNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AntigravityCi
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    public static class ProcessJobNative
    {
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int jobObjectInformationClass,
            ref JobObjectExtendedLimitInformation jobObjectInformation,
            uint jobObjectInformationLength
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static IntPtr CreateKillOnCloseJob()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");
            }

            var information = new JobObjectExtendedLimitInformation();
            information.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;

            uint size = (uint)Marshal.SizeOf<JobObjectExtendedLimitInformation>();
            if (!SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformationClass,
                ref information,
                size))
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(job);
                throw new Win32Exception(error, "SetInformationJobObject failed.");
            }

            return job;
        }

        public static void Assign(IntPtr job, IntPtr process)
        {
            if (job == IntPtr.Zero)
            {
                throw new ArgumentException("Job handle is invalid.", nameof(job));
            }

            if (process == IntPtr.Zero)
            {
                throw new ArgumentException("Process handle is invalid.", nameof(process));
            }

            if (!AssignProcessToJobObject(job, process))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "AssignProcessToJobObject failed."
                );
            }

            bool assigned;
            if (!IsProcessInJob(process, job, out assigned))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "IsProcessInJob failed."
                );
            }

            if (!assigned)
            {
                throw new InvalidOperationException("Process was not associated with the containment job.");
            }
        }

        public static void Close(IntPtr job)
        {
            if (job == IntPtr.Zero)
            {
                return;
            }

            if (!CloseHandle(job))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CloseHandle failed for process job.");
            }
        }
    }
}
'@ -ErrorAction Stop
}

function New-WindowsKillOnCloseJob {
    [CmdletBinding()]
    param()

    [AntigravityCi.ProcessJobNative]::CreateKillOnCloseJob()
}

function Add-ProcessToWindowsJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [IntPtr] $Job,

        [Parameter(Mandatory)]
        [System.Diagnostics.Process] $Process
    )

    if ($Process.HasExited) {
        throw 'Process exited before it could be attached to the containment job.'
    }

    [AntigravityCi.ProcessJobNative]::Assign($Job, $Process.Handle)
}

function Close-WindowsProcessJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [IntPtr] $Job
    )

    [AntigravityCi.ProcessJobNative]::Close($Job)
}
