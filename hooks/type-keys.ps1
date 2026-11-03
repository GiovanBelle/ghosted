# Types keystrokes into the console Claude Code runs in (Windows).
# Hooks may run without a console, so attach to the console of the nearest ancestor that has one,
# then write key events into its input buffer with WriteConsoleInput (no window focus needed).
# Usage: type-keys.ps1 -Steps <base64 of UTF-8 json [[delaySeconds, text], ...]> -Pids '<ancestor pids, nearest first>' [-Log <events.jsonl>]
# (base64 because Windows command-line quoting mangles the quotes inside JSON)
# -Log appends one line with the outcome (attached pid, records written, errors), so a failed start is visible.
param([string]$Steps, [string]$Pids, [string]$Log)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Keys {
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct KEY_EVENT_RECORD {
        [FieldOffset(0)] public int bKeyDown;
        [FieldOffset(4)] public ushort wRepeatCount;
        [FieldOffset(6)] public ushort wVirtualKeyCode;
        [FieldOffset(8)] public ushort wVirtualScanCode;
        [FieldOffset(10)] public char UnicodeChar;
        [FieldOffset(12)] public uint dwControlKeyState;
    }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] recs, uint n, out uint written);

    static IntPtr input = IntPtr.Zero;
    public static string Errors = "";

    // Returns the pid whose console it attached to, or 0.
    public static uint Attach(string pids) {
        FreeConsole();
        foreach (var p in (pids ?? "").Split(',')) {
            uint pid;
            if (!uint.TryParse(p.Trim(), out pid)) continue;
            if (!AttachConsole(pid)) { Errors += "attach " + pid + ": " + Marshal.GetLastWin32Error() + "; "; continue; }
            // GENERIC_READ|GENERIC_WRITE, FILE_SHARE_READ|FILE_SHARE_WRITE, OPEN_EXISTING
            input = CreateFile("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            // the Ctrl-C it types reaches every process on that console, this one too: ignore it
            if (input != new IntPtr(-1)) { SetConsoleCtrlHandler(IntPtr.Zero, true); return pid; }
            Errors += "CONIN$ " + pid + ": " + Marshal.GetLastWin32Error() + "; ";
            FreeConsole();
        }
        return 0;
    }

    static INPUT_RECORD Key(char c, ushort vk, uint ctrl, bool down) {
        var r = new INPUT_RECORD();
        r.EventType = 1; // KEY_EVENT
        r.KeyEvent.bKeyDown = down ? 1 : 0;
        r.KeyEvent.wRepeatCount = 1;
        r.KeyEvent.wVirtualKeyCode = vk;
        r.KeyEvent.UnicodeChar = c;
        r.KeyEvent.dwControlKeyState = ctrl;
        return r;
    }

    public static uint Type(string text) {
        var recs = new System.Collections.Generic.List<INPUT_RECORD>();
        foreach (char c in text) {
            ushort vk = 0; uint ctrl = 0;
            if (c == '\r') vk = 0x0D;                          // VK_RETURN
            else if (c == '\x03') { vk = 0x43; ctrl = 0x0008; } // Ctrl+C: 'C' with LEFT_CTRL_PRESSED
            recs.Add(Key(c, vk, ctrl, true));
            recs.Add(Key(c, vk, ctrl, false));
        }
        uint written;
        if (!WriteConsoleInput(input, recs.ToArray(), (uint)recs.Count, out written)) Errors += "write: " + Marshal.GetLastWin32Error() + "; ";
        return written;
    }
}
'@

function Write-Log($ok, $attached, $records, $written) {
    if (-not $Log) { return }
    $line = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); kind = 'type'; ok = $ok; method = 'console'; pids = $Pids
        attached = $attached; records = $records; written = $written; ssh = [bool]($env:SSH_CONNECTION -or $env:SSH_CLIENT); errors = [Keys]::Errors }
    # UTF-8 without a BOM: a BOM would hide the line from the JSON-lines readers
    try { [IO.File]::AppendAllText($Log, ($line | ConvertTo-Json -Compress) + "`n", (New-Object Text.UTF8Encoding $false)) } catch {}
}

$attached = [Keys]::Attach($Pids)
if (-not $attached) { Write-Log $false 0 0 0; exit 1 }
$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Steps))
$records = 0; $written = 0
foreach ($step in (ConvertFrom-Json $json)) {
    Start-Sleep -Milliseconds ([int]([double]$step[0] * 1000))
    $text = [string]$step[1]
    $records += 2 * $text.Length
    $written += [Keys]::Type($text)
}
Write-Log ($written -eq $records) $attached $records $written
if ($written -ne $records) { exit 2 }
