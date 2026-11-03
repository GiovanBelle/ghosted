# Runs a command inside a pseudo console (ConPTY), the way Windows OpenSSH's sshd hosts a session:
# a headless conhost whose input arrives through a pipe instead of a console window. Waits for it and returns its exit code.
param([string]$Command, [int]$TimeoutSeconds = 60)

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class ConPty {
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern int CreatePseudoConsole(COORD size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr pc);
    [DllImport("kernel32.dll", SetLastError = true)] static extern void ClosePseudoConsole(IntPtr pc);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr retSize);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);

    public static int Run(string command, int timeoutMs) {
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0);
        CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0);
        IntPtr pc;
        int hr = CreatePseudoConsole(new COORD { X = 120, Y = 30 }, inRead, outWrite, 0, out pc);
        if (hr != 0) throw new Exception("CreatePseudoConsole " + hr);
        inRead.Dispose(); outWrite.Dispose();
        // Drain the output, or the pseudo console blocks once its pipe is full; echo it for the CI log.
        var reader = new Thread(() => {
            using (var s = new FileStream(outRead, FileAccess.Read)) {
                var buf = new byte[4096]; int n;
                try { while ((n = s.Read(buf, 0, buf.Length)) > 0) Console.Out.Write(System.Text.Encoding.UTF8.GetString(buf, 0, n)); } catch {}
            }
        });
        reader.IsBackground = true; reader.Start();

        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(si);
        // STARTF_USESTDHANDLES with null handles: otherwise the child inherits this script's redirected pipes, not the pseudo console
        si.StartupInfo.dwFlags = 0x00000100;
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        si.lpAttributeList = Marshal.AllocHGlobal(size);
        if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, ref size)) throw new Exception("attr list " + Marshal.GetLastWin32Error());
        // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, (IntPtr)0x00020016, pc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new Exception("attr " + Marshal.GetLastWin32Error());
        PROCESS_INFORMATION pi;
        // EXTENDED_STARTUPINFO_PRESENT
        if (!CreateProcess(null, command, IntPtr.Zero, IntPtr.Zero, false, 0x00080000, IntPtr.Zero, null, ref si, out pi))
            throw new Exception("CreateProcess " + Marshal.GetLastWin32Error());
        uint code = 259;
        if (WaitForSingleObject(pi.hProcess, (uint)timeoutMs) == 0) GetExitCodeProcess(pi.hProcess, out code);
        ClosePseudoConsole(pc);
        inWrite.Dispose();
        return (int)code;
    }
}
'@

exit [ConPty]::Run($Command, $TimeoutSeconds * 1000)
