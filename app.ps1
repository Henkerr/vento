# =====================================================================
#  Vento - lightweight fan monitoring & control for Windows
#  PowerShell 5.1 + WPF + LibreHardwareMonitor. Admin rights required
#  for SuperIO sensor access.
# =====================================================================

[CmdletBinding()]
param(
    # Register/remove the logon task and exit, without loading the UI or
    # touching the hardware. Used by the installer's "start with Windows"
    # task; also handy for scripting the setting by hand.
    [switch]$RegisterAutostart,
    [switch]$UnregisterAutostart
)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'Vento'
$script:AppVersion = '1.8.2'

# App folder ($PSScriptRoot can be empty in exotic hosts)
$script:AppRoot = $PSScriptRoot
if (-not $script:AppRoot) { $script:AppRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$script:icoPath = Join-Path $script:AppRoot 'assets\vento.ico'

# --- Autostart via scheduled task (RunLevel Highest = no UAC at logon).
# ScheduledTasks cmdlets, not schtasks.exe: native stderr under
# ErrorActionPreference=Stop throws in PS 5.1, and /TR quoting mangles
# paths with spaces (C:\Program Files\...).
# Defined up here so -RegisterAutostart can run before the admin/STA
# guards and the sensor library.
$script:taskName = 'Vento'

# What the task should launch out of this folder: the exe when it is next
# to us (installed copy), otherwise powershell.exe on app.ps1 (source copy).
function Get-AutoStartTarget {
    $exe = Join-Path $script:AppRoot 'Vento.exe'
    if (Test-Path $exe) { return @{ Execute = $exe; Argument = '' } }
    return @{
        Execute  = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        Argument = ('-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f (Join-Path $script:AppRoot 'app.ps1'))
    }
}
function Get-AutoStartTask {
    try { return Get-ScheduledTask -TaskName $script:taskName -ErrorAction Stop } catch { return $null }
}
function Test-AutoStart { return [bool](Get-AutoStartTask) }

# Returns $null on success or the error text: a checkbox that silently
# fails to stick is worse than no checkbox at all.
function Set-AutoStart([bool]$on) {
    try {
        if ($on) {
            $t = Get-AutoStartTarget
            if ($t.Argument) {
                $action = New-ScheduledTaskAction -Execute $t.Execute -Argument $t.Argument -WorkingDirectory $script:AppRoot
            } else {
                $action = New-ScheduledTaskAction -Execute $t.Execute -WorkingDirectory $script:AppRoot
            }
            $user      = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
            $trigger.Delay = 'PT15S'   # let the shell and the SuperIO driver settle first
            $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
                            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                            -StartWhenAvailable -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $script:taskName -Force `
                -Description "Starts $script:AppName at logon so the fan curve is applied without signing in to the app." `
                -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        } else {
            Unregister-ScheduledTask -TaskName $script:taskName -Confirm:$false -ErrorAction Stop
        }
        return $null
    } catch { return $_.Exception.Message }
}

# A task registered from a folder that later moved or was deleted keeps
# pointing at a path that is gone, so nothing comes up at logon. Repoint it
# at whoever is running - but only then: another copy that still exists on
# disk may well be the one the user meant to start with Windows.
function Sync-AutoStartTarget {
    $task = Get-AutoStartTask
    if (-not $task) { return }
    try {
        $have = @($task.Actions)[0]
        # For the powershell.exe fallback the path that can go missing is the
        # script, not the host - powershell.exe is always there.
        $path = [string]$have.Execute
        $m = [regex]::Match([string]$have.Arguments, '-File\s+"([^"]+)"')
        if ($m.Success) { $path = $m.Groups[1].Value }
        if (-not $path -or (Test-Path -LiteralPath $path)) { return }
        [void](Set-AutoStart $true)
    } catch { }
}

if ($RegisterAutostart -or $UnregisterAutostart) {
    $err = Set-AutoStart (-not $UnregisterAutostart)
    if ($err) { Write-Error $err; exit 1 }
    exit 0
}

# --- Admin & STA guards ----------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File', ('"{0}"' -f $PSCommandPath))
    exit
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File', ('"{0}"' -f $PSCommandPath))
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# Swaps a ResourceDictionary brush from pure CLR code. Doing the same through
# the PowerShell indexer stores a PSObject wrapper that the WPF renderer later
# fails to cast to Brush, and the XAML-declared resource brushes arrive frozen
# so they cannot be mutated in place either.
Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml -TypeDefinition @'
namespace VentoNative {
    public static class Res {
        public static void SetBrush(System.Windows.ResourceDictionary dict, string key, System.Windows.Media.Color color) {
            var b = new System.Windows.Media.SolidColorBrush(color);
            b.Freeze();
            dict[key] = b;
        }
    }
}
'@

# DDC/CI monitor control (brightness / contrast / color preset) through the
# dxva2.dll high-level API. HMONITOR enumeration is done in C# because
# scriptblock->delegate marshaling is unreliable inside a background runspace.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace VentoNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct DRECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO { public int cbSize; public DRECT rcMonitor; public DRECT rcWork; public uint dwFlags; }
    public static class Ddc {
        private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr rc, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfoW(IntPtr hMonitor, ref MONITORINFO lpmi);
        // Desktop rectangle of a display, so the panel's map matches the desk.
        public static int[] GetBounds(IntPtr hMonitor) {
            MONITORINFO mi = new MONITORINFO();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfoW(hMonitor, ref mi)) return null;
            return new int[] { mi.rcMonitor.left, mi.rcMonitor.top,
                               mi.rcMonitor.right - mi.rcMonitor.left,
                               mi.rcMonitor.bottom - mi.rcMonitor.top,
                               (int)(mi.dwFlags & 1) };
        }
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool DestroyPhysicalMonitors(uint count, PHYSICAL_MONITOR[] monitors);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetMonitorBrightness(IntPtr h, uint v);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetMonitorContrast(IntPtr h, out uint min, out uint cur, out uint max);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetMonitorContrast(IntPtr h, uint v);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetVCPFeature(IntPtr h, byte code, uint v);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetCapabilitiesStringLength(IntPtr h, out uint len);
        [DllImport("dxva2.dll", SetLastError = true)] public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, System.Text.StringBuilder caps, uint len);
        public static System.Collections.Generic.List<IntPtr> GetHMonitors() {
            var list = new System.Collections.Generic.List<IntPtr>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hm, hdc, rc, d) => { list.Add(hm); return true; }, IntPtr.Zero);
            return list;
        }
    }
}
'@
} catch { }

# Own taskbar identity: without this the window is grouped under
# powershell.exe and the taskbar shows the PowerShell icon.
try {
    Add-Type -Namespace VentoNative -Name Shell -MemberDefinition '[DllImport("shell32.dll", SetLastError=true)] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID); [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string msg); [DllImport("user32.dll")] public static extern bool ChangeWindowMessageFilter(uint msg, uint action);'
    [void][VentoNative.Shell]::SetCurrentProcessExplicitAppUserModelID('Blakfy.Vento')
    # Vento runs elevated, so Explorer's TaskbarCreated broadcast is blocked
    # by UIPI and the tray icon would never come back after an Explorer
    # restart. Let the message through (1 = MSGFLT_ADD) so WinForms'
    # NotifyIcon can re-register itself.
    $tbMsg = [VentoNative.Shell]::RegisterWindowMessage('TaskbarCreated')
    if ($tbMsg) { [void][VentoNative.Shell]::ChangeWindowMessageFilter($tbMsg, 1) }
} catch { }

# OSD overlay: extended window styles (click-through, no activation, hidden
# from Alt-Tab) plus a periodic topmost re-assert - borderless games like to
# reorder the z stack.
try {
    Add-Type -Namespace VentoNative -Name Osd -MemberDefinition '[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW", SetLastError=true)] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex); [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW", SetLastError=true)] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong); [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags); [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);'
} catch { }

# Global hotkeys: system-wide keys that fire even while a game has focus.
# RegisterHotKey posts WM_HOTKEY to the main window; a HwndSource hook routes it.
try {
    Add-Type -Namespace VentoNative -Name Hotkey -MemberDefinition '[DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk); [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);'
} catch { }

# Per-process frame rate, the way PresentMon does it: a real-time ETW session
# on the DXGI / D3D9 / DxgKrnl providers, counting Present events per process.
# No bundled binaries, no vendor SDK, works on any GPU. Needs admin (Vento is
# elevated). The struct layout here is exact - EVENT_TRACE_LOGFILEW is 448
# bytes on x64; the callback offsets are why a naive definition sees nothing.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
namespace VentoNative {
public static class Fps {
  const uint WNODE_FLAG_TRACED_GUID = 0x00020000, EVENT_TRACE_REAL_TIME_MODE = 0x00000100;
  const uint EVENT_TRACE_CONTROL_STOP = 1, EVENT_CONTROL_CODE_ENABLE_PROVIDER = 1;
  const uint PROCESS_TRACE_MODE_REAL_TIME = 0x100, PROCESS_TRACE_MODE_RAW_TIMESTAMP = 0x1000, PROCESS_TRACE_MODE_EVENT_RECORD = 0x10000000;
  const uint EVENT_FILTER_TYPE_EVENT_ID = 0x80000200, ENABLE_TRACE_PARAMETERS_VERSION_2 = 2;
  const byte TRACE_LEVEL_VERBOSE = 5; const ushort EVENT_HEADER_FLAG_32_BIT_HEADER = 0x0020;
  static readonly ulong INVALID = IntPtr.Size == 8 ? 0xFFFFFFFFFFFFFFFFUL : 0xFFFFFFFFUL;
  static readonly Guid DXGI = new Guid("CA11C036-0102-4A2D-A6AD-F03CFED5D3C9");
  static readonly Guid D3D9 = new Guid("783ACA0A-790E-4D7F-8451-AA850511C6B9");
  static readonly Guid DXGK = new Guid("802EC45A-1E99-4B83-9920-87C98277BA9D");
  static readonly long DXGI0 = BitConverter.ToInt64(DXGI.ToByteArray(),0), DXGI1 = BitConverter.ToInt64(DXGI.ToByteArray(),8);
  static readonly long D3D90 = BitConverter.ToInt64(D3D9.ToByteArray(),0), D3D91 = BitConverter.ToInt64(D3D9.ToByteArray(),8);
  static readonly long DXGK0 = BitConverter.ToInt64(DXGK.ToByteArray(),0), DXGK1 = BitConverter.ToInt64(DXGK.ToByteArray(),8);

  [StructLayout(LayoutKind.Sequential)] struct WNODE_HEADER { public uint BufferSize, ProviderId; public ulong HistoricalContext, TimeStamp; public Guid Guid; public uint ClientContext, Flags; }
  [StructLayout(LayoutKind.Sequential)] struct EVENT_TRACE_PROPERTIES { public WNODE_HEADER Wnode; public uint BufferSize, MinimumBuffers, MaximumBuffers, MaximumFileSize, LogFileMode, FlushTimer, EnableFlags; public int AgeLimit; public uint NumberOfBuffers, FreeBuffers, EventsLost, BuffersWritten, LogBuffersLost, RealTimeBuffersLost; public IntPtr LoggerThreadId; public uint LogFileNameOffset, LoggerNameOffset; }
  [StructLayout(LayoutKind.Sequential)] struct EVENT_FILTER_DESCRIPTOR { public ulong Ptr; public uint Size, Type; }
  [StructLayout(LayoutKind.Sequential)] struct ENABLE_TRACE_PARAMETERS { public uint Version, EnableProperty, ControlFlags; public Guid SourceId; public IntPtr EnableFilterDesc; public uint FilterDescCount; }
  [StructLayout(LayoutKind.Sequential)] struct SYSTEMTIME { public ushort Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct TIME_ZONE_INFORMATION { public int Bias; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string StandardName; public SYSTEMTIME StandardDate; public int StandardBias; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DaylightName; public SYSTEMTIME DaylightDate; public int DaylightBias; }
  [StructLayout(LayoutKind.Sequential)] struct TRACE_LOGFILE_HEADER { public uint BufferSize, Version, ProviderVersion, NumberOfProcessors; public long EndTime; public uint TimerResolution, MaximumFileSize, LogFileMode, BuffersWritten; public Guid LogInstanceGuid; public IntPtr LoggerName, LogFileName; public TIME_ZONE_INFORMATION TimeZone; public long BootTime, PerfFreq, StartTime; public uint ReservedFlags, BuffersLost; }
  [StructLayout(LayoutKind.Sequential)] struct EVENT_TRACE_HEADER { public ushort Size, FieldTypeFlags; public uint Version, ThreadId, ProcessId; public long TimeStamp; public Guid Guid; public ulong ProcessorTime; }
  [StructLayout(LayoutKind.Sequential)] struct EVENT_TRACE { public EVENT_TRACE_HEADER Header; public uint InstanceId, ParentInstanceId; public Guid ParentGuid; public IntPtr MofData; public uint MofLength, ClientContext; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct EVENT_TRACE_LOGFILEW {
    [MarshalAs(UnmanagedType.LPWStr)] public string LogFileName; [MarshalAs(UnmanagedType.LPWStr)] public string LoggerName;
    public long CurrentTime; public uint BuffersRead, ProcessTraceMode; public EVENT_TRACE CurrentEvent; public TRACE_LOGFILE_HEADER LogfileHeader;
    public IntPtr BufferCallback; public uint BufferSize, Filled, EventsLost; public IntPtr EventRecordCallback; public uint IsKernelTrace; public IntPtr Context; }

  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] static extern uint StartTraceW(out ulong h, string name, IntPtr props);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] static extern uint ControlTraceW(ulong h, string name, IntPtr props, uint code);
  [DllImport("advapi32.dll", ExactSpelling = true)] static extern uint EnableTraceEx2(ulong h, ref Guid prov, uint code, byte lvl, ulong any, ulong all, uint timeout, ref ENABLE_TRACE_PARAMETERS p);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)] static extern ulong OpenTraceW(ref EVENT_TRACE_LOGFILEW lf);
  [DllImport("advapi32.dll", ExactSpelling = true)] static extern uint ProcessTrace(ulong[] h, uint n, IntPtr s, IntPtr e);
  [DllImport("advapi32.dll", ExactSpelling = true)] static extern uint CloseTrace(ulong h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate void EventCb(IntPtr rec);

  static ulong s_session, s_trace = 0; static IntPtr s_props = IntPtr.Zero; static Thread s_thread;
  static EventCb s_cb; static long s_freq = System.Diagnostics.Stopwatch.Frequency;
  class St { public long Bucket, LastTs; public int Cur, Last; }
  static readonly object s_lk = new object();
  static readonly Dictionary<int, St> s_rt = new Dictionary<int, St>();
  static readonly Dictionary<int, St> s_kr = new Dictionary<int, St>();
  public static string Status = "off";

  static IntPtr NewProps(string name, out int total) {
    int size = Marshal.SizeOf(typeof(EVENT_TRACE_PROPERTIES)); total = size + 2 * 1024 * 2;
    IntPtr p = Marshal.AllocHGlobal(total); for (int i = 0; i < total; i++) Marshal.WriteByte(p, i, 0);
    var s = new EVENT_TRACE_PROPERTIES();
    s.Wnode.BufferSize = (uint)total; s.Wnode.Flags = WNODE_FLAG_TRACED_GUID; s.Wnode.ClientContext = 1;
    s.LogFileMode = EVENT_TRACE_REAL_TIME_MODE; s.FlushTimer = 1; s.BufferSize = 16; s.MinimumBuffers = 4; s.MaximumBuffers = 32;
    s.LoggerNameOffset = (uint)size; s.LogFileNameOffset = 0;
    Marshal.StructureToPtr(s, p, false); return p;
  }
  static void Enable(Guid prov, ulong anyKw, ushort[] ids) {
    int n = 4 + 2 * ids.Length; IntPtr blob = Marshal.AllocHGlobal(n);
    Marshal.WriteByte(blob, 0, 1); Marshal.WriteByte(blob, 1, 0); Marshal.WriteInt16(blob, 2, (short)ids.Length);
    for (int i = 0; i < ids.Length; i++) Marshal.WriteInt16(blob, 4 + 2 * i, (short)ids[i]);
    var fd = new EVENT_FILTER_DESCRIPTOR { Ptr = (ulong)blob.ToInt64(), Size = (uint)n, Type = EVENT_FILTER_TYPE_EVENT_ID };
    IntPtr pfd = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(EVENT_FILTER_DESCRIPTOR))); Marshal.StructureToPtr(fd, pfd, false);
    var ep = new ENABLE_TRACE_PARAMETERS { Version = ENABLE_TRACE_PARAMETERS_VERSION_2, EnableFilterDesc = pfd, FilterDescCount = 1 };
    EnableTraceEx2(s_session, ref prov, EVENT_CONTROL_CODE_ENABLE_PROVIDER, TRACE_LEVEL_VERBOSE, anyKw, 0, 0, ref ep);
    Marshal.FreeHGlobal(pfd); Marshal.FreeHGlobal(blob);
  }
  public static uint Start(string name) {
    try {
      int total; s_props = NewProps(name, out total);
      ControlTraceW(0, name, s_props, EVENT_TRACE_CONTROL_STOP);
      Marshal.FreeHGlobal(s_props); s_props = NewProps(name, out total);
      uint st = StartTraceW(out s_session, name, s_props);
      if (st != 0) { Status = "start=" + st; return st; }
      Enable(DXGI, 0x8000000000000002UL, new ushort[] { 42, 55 });
      Enable(D3D9, 0x8000000000000002UL, new ushort[] { 1 });
      Enable(DXGK, 0x4000000008000001UL, new ushort[] { 184 });
      var lf = new EVENT_TRACE_LOGFILEW(); lf.LoggerName = name;
      lf.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD | PROCESS_TRACE_MODE_RAW_TIMESTAMP;
      s_cb = OnEvent; lf.EventRecordCallback = Marshal.GetFunctionPointerForDelegate(s_cb);
      s_trace = OpenTraceW(ref lf);
      if (s_trace == INVALID) { Status = "open=" + Marshal.GetLastWin32Error(); return 1; }
      if (lf.LogfileHeader.PerfFreq > 0) s_freq = lf.LogfileHeader.PerfFreq;
      s_thread = new Thread(Loop); s_thread.IsBackground = true; s_thread.Start();
      Status = "on"; return 0;
    } catch (Exception e) { Status = "exc:" + e.Message; return 2; }
  }
  static void Loop() { try { ProcessTrace(new ulong[] { s_trace }, 1, IntPtr.Zero, IntPtr.Zero); } catch { } }
  static void OnEvent(IntPtr rec) {
    ushort hflags = (ushort)Marshal.ReadInt16(rec, 4); int pid = Marshal.ReadInt32(rec, 12); long ts = Marshal.ReadInt64(rec, 16);
    long g0 = Marshal.ReadInt64(rec, 24), g1 = Marshal.ReadInt64(rec, 32); ushort id = (ushort)Marshal.ReadInt16(rec, 40);
    if (g0 == DXGI0 && g1 == DXGI1) {
      if (id != 42 && id != 55) return;
      IntPtr ud = Marshal.ReadIntPtr(rec, 96);
      if (ud != IntPtr.Zero) { int off = (hflags & EVENT_HEADER_FLAG_32_BIT_HEADER) != 0 ? 4 : 8; try { if ((Marshal.ReadInt32(ud, off) & 1) != 0) return; } catch { } }
      Count(s_rt, pid, ts);
    } else if (g0 == D3D90 && g1 == D3D91) { if (id == 1) Count(s_rt, pid, ts); }
    else if (g0 == DXGK0 && g1 == DXGK1) { if (id == 184) Count(s_kr, pid, ts); }
  }
  static void Count(Dictionary<int, St> m, int pid, long ts) {
    long b = ts / s_freq;
    lock (s_lk) { St s; if (!m.TryGetValue(pid, out s)) { s = new St(); s.Bucket = b; m[pid] = s; }
      if (b != s.Bucket) { s.Last = (b == s.Bucket + 1) ? s.Cur : 0; s.Bucket = b; s.Cur = 0; } s.Cur++; s.LastTs = ts; }
  }
  static int GetFps(int pid) {
    long now = System.Diagnostics.Stopwatch.GetTimestamp();
    lock (s_lk) { St s;
      if (s_rt.TryGetValue(pid, out s) && now - s.LastTs < 2 * s_freq) return s.Last;
      if (s_kr.TryGetValue(pid, out s) && now - s.LastTs < 2 * s_freq) return s.Last; return 0; }
  }
  static int TopPid(int excludeSelf) {
    long now = System.Diagnostics.Stopwatch.GetTimestamp(); int best = 0, bestPid = 0;
    lock (s_lk) {
      foreach (var kv in s_rt) { if (kv.Key == excludeSelf) continue; if (now - kv.Value.LastTs > 2 * s_freq) continue; if (kv.Value.Last > best) { best = kv.Value.Last; bestPid = kv.Key; } }
      if (bestPid == 0) foreach (var kv in s_kr) { if (kv.Key == excludeSelf) continue; if (now - kv.Value.LastTs > 2 * s_freq) continue; if (kv.Value.Last > best) { best = kv.Value.Last; bestPid = kv.Key; } }
    }
    return bestPid;
  }
  // The number Vento shows: the focused window's rate, or the busiest
  // presenter (the game behind a borderless overlay), never Vento itself.
  public static int Current(int selfPid) {
    uint fpid; GetWindowThreadProcessId(GetForegroundWindow(), out fpid);
    int f = 0;
    if (fpid != 0 && (int)fpid != selfPid) f = GetFps((int)fpid);
    if (f == 0) { int tp = TopPid(selfPid); if (tp != 0) f = GetFps(tp); }
    return f;
  }
  public static void Stop() {
    try { if (s_trace != 0 && s_trace != INVALID) { CloseTrace(s_trace); s_trace = 0; } } catch { }
    try { if (s_session != 0) { ControlTraceW(s_session, null, s_props, EVENT_TRACE_CONTROL_STOP); s_session = 0; } } catch { }
    if (s_thread != null) { s_thread.Join(5000); s_thread = null; }
    if (s_props != IntPtr.Zero) { Marshal.FreeHGlobal(s_props); s_props = IntPtr.Zero; }
    Status = "off";
  }
}}
'@
} catch { }

# --- Single instance -------------------------------------------------
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Global\VentoSingleInstance', [ref]$created)
# Launching Vento while it is already running should surface the running
# window (the tray icon may be hidden or lost), not show a dead modal.
# The second instance signals this event and exits; the first instance
# polls it in the UI tick and calls Show-Main.
$script:showMe = New-Object System.Threading.EventWaitHandle($false, ([System.Threading.EventResetMode]::AutoReset), 'Global\VentoShowMe')
if (-not $created) {
    [void]$script:showMe.Set()
    exit
}

try {

# --- Sensor library --------------------------------------------------
$libDir = Join-Path $script:AppRoot 'lib'
foreach ($dll in (Get-ChildItem -Path $libDir -Filter '*.dll')) {
    try { [void][Reflection.Assembly]::LoadFrom($dll.FullName) } catch { }
}
if (-not ('LibreHardwareMonitor.Hardware.Computer' -as [type])) {
    [void][System.Windows.MessageBox]::Show("Could not load the sensor library. Check the 'lib' folder.", 'Vento', 'OK', 'Error')
    exit
}

# --- Conflicting fan software ----------------------------------------
if (Get-Process -Name FanControl -ErrorAction SilentlyContinue) {
    $answer = [System.Windows.MessageBox]::Show("FanControl is currently running. Two programs cannot drive the fans at the same time.`n`nClose FanControl now?", 'Vento', 'YesNo', 'Warning')
    if ($answer -eq 'Yes') { Stop-Process -Name FanControl -Force; Start-Sleep -Seconds 1 } else { exit }
}

# Keep an existing logon task pointing at this copy (see Sync-AutoStartTarget).
Sync-AutoStartTarget

# --- Settings --------------------------------------------------------
$script:settingsPath = Join-Path $script:AppRoot 'settings.json'

function Get-DefaultSettings {
    @{
        startMinimized   = $false      # start hidden in the tray
        closeToTray      = $true       # X button hides instead of exiting
        lastMode         = 'auto'      # last user-chosen mode, restored at launch
        updateIntervalMs = 2000        # sensor poll interval
        accentColor      = '#4C8DFF'
        cpuFanChannel    = 'Fan #1'    # SuperIO channel driving the CPU cooler
        caseFanChannel   = 'Fan #2'    # SuperIO channel driving the case fan hub
        mbTempSensor     = 'auto'      # SuperIO temp sensor for the BOARD card ('auto' = best guess)
        quietCase        = 30          # case fan % per mode
        normalCase       = 50
        perfCase         = 100
        perfCpu          = 100         # CPU fan % in Performance mode
        boostEnabled     = $true       # Quiet mode: temporarily raise fans when hot
        boostHigh        = 75          # boost above this temp (deg C)
        boostLow         = 65          # drop back to Quiet below this temp
        boostCase        = 80          # case fan % while boosting
        cpuMaxTemp       = 85          # safety guard: force Auto above these temps
        gpuMaxTemp       = 83
        warnCpu          = 65          # comfort targets: per-sensor threshold that
        warnGpu          = 65          # drives the thermal palette, the hero copy
        warnSsd          = 60          # and the per-card warning chips
        warnMb           = 62
        checkUpdates     = $true       # notify when a new GitHub release exists
        updateRepo       = 'Henkerr/vento'
        gameAction       = 'performance' # what to do when a game is detected: performance | curve | off
        gameOnLoad       = 80          # % GPU load that counts as gaming
        gameCooldownSec  = 15          # extra full-speed seconds after a game ends (0 = off)
        curve40          = 25          # Curve mode: case fan % at 40/55/70/80 deg C
        curve55          = 40
        curve70          = 65
        curve80          = 100
        osdMode          = 'auto'      # in-game overlay: auto (while gaming) | on | off
        osdLayout        = 'blade'     # blade | strip | hero | pills | ghost | micro | thermo
        osdTheme         = 'sirocco'   # sirocco | ember | venom | violet | crimson | mono
        windowMaterial   = 'mica'      # mica | acrylic | micaalt: the main window's Windows 11 backdrop
        heroSensor       = 'auto'      # auto (hottest vs its target) | cpu | gpu | ssd | board: the Home hero
        devCheckMin      = 30          # Bluetooth device battery check, minutes (0 = only on Refresh)
        devLowOn         = $true       # low-battery notification for connected devices (threshold: podsWarn)
        toastsOn         = $true       # Windows notifications at all (off: nothing is shown, not even a balloon)
        # Lights: a BLE LED strip (MR Star protocol). The page shows only where
        # HKCU\Software\Vento\Lights = 1, so these are inert everywhere else.
        ledAddr          = '4142C00A9E32' # the strip's Bluetooth address, hex
        ledAutoConn      = $false      # connect when Vento starts (and keep the link)
        ledOn            = $true       # last power state Vento sent
        ledBri           = 100         # brightness %
        ledHue           = 240         # static color, HSV hue 0-359
        ledSat           = 100         # and saturation %
        ledSpeed         = 50          # built-in effect speed 1-100
        ledFx            = 91          # built-in effect number (the 71 the strip's app offers)
        ledKind          = 'color'     # what the strip shows: color | effect | loop
        ledLoop          = ''          # the color loop playing (kind = loop)
        ledLoops         = @(
            @{ Name = 'Ocean';  Colors = @('#0040FF', '#00C8FF', '#7A3CFF'); Trans = 'fade'; Half = 8 },
            @{ Name = 'Sunset'; Colors = @('#FF2D55', '#FF7A00', '#FFC400'); Trans = 'fade'; Half = 6 },
            @{ Name = 'Police'; Colors = @('#FF0000', '#0030FF');            Trans = 'jump'; Half = 1 }
        )
        osdCorner        = 'tr'        # overlay corner: tr | tl | bl | br
        osdScale         = 100         # overlay scale %
        osdOnSecondary   = $false      # place the overlay on the secondary monitor
        osdOpacity       = 100         # overlay opacity %
        osdFree          = $false      # overlay parked where the user dragged it
        osdX             = 0           # free position, DIPs
        osdY             = 0
        osdCapSafe       = $false      # hide the overlay from screen capture / recording / share
        # Global hotkeys - '' is unbound. Stored as 'Ctrl+Alt+<Key>', the last
        # token being a System.Windows.Input.Key enum name so it round-trips.
        hkOsd            = ''          # toggle the overlay
        hkQuiet          = ''          # switch to Quiet
        hkNormal         = ''          # switch to Normal
        hkPerf           = ''          # switch to Performance
        hkAuto           = ''          # switch to Auto
        hkProfile        = ''          # cycle to the next Vento profile
        osdCpu           = $true       # overlay metrics
        osdGpu           = $true
        osdGpuLoad       = $true
        osdFps           = $false      # per-process frame rate (ETW)
        osdRam           = $false      # memory usage %
        osdFans          = $true
        osdSsd           = $false
        osdMb            = $false
        osdColFps        = ''          # per-metric color overrides ('' = theme decides)
        osdColCpu        = ''
        osdColGpu        = ''
        osdColLoad       = ''
        osdColRam        = ''
        osdColSsd        = ''
        osdColMb         = ''
        osdColFan        = ''
        osdPods          = $false      # AirPods battery in the overlay
        osdColPods       = ''
        # AirPods battery over Apple's BLE proximity advertisements. Wire
        # format from public research (INRIA hal-02394619, furiousMAC) -
        # passive listening only, nothing is ever written to the buds.
        podsEnabled      = $true       # scan for AirPods battery broadcasts
        podsModel        = 0           # learned model id (0 = learn from the first strong packet)
        podsRssiMin      = -80         # ignore advertisements weaker than this (dBm)
        podsWarn         = 20          # low-battery notification threshold (%)
        monSync          = $false      # monitor panel: one set of sliders drives all displays
        monProfile       = 'DAY'       # display profile currently applied
        monAdvOpen       = $true       # the ALL CONTROLS section starts expanded
        monProfileScope  = 'all'       # a profile drives every display, or only the selected one
        monProfileByMon  = @()         # per-display profile names, used when the scope is 'one'
        monNight         = $false      # dim every display inside a nightly window
        monNightFrom     = 1380        # minutes past midnight (23:00)
        monNightTo       = 420         # 07:00
        monNightProfile  = 'NIGHT'     # profile the schedule applies
        # Built-in display profiles. Each carries its own identity colour, which
        # tints the panel while it is the active one; users add their own with
        # any colour they like.
        #
        # The numbers are not invented. Brightness tracks the room, because
        # that is the only lever that should: ~120-150 cd/m2 for a lit room
        # (ISO 9241-303 / TFTCentral), 80-100 cd/m2 in the dark (ISO 3664),
        # and 100 cd/m2 for film, which is the ITU-R BT.2035 reference
        # viewing environment. Contrast stays at the factory 70 in all of
        # them: on an LCD it is a signal-gain control, and pushing it past
        # default clips highlight detail (Lagom white-saturation test).
        # 6500K is D65, the white point sRGB, Rec.709, DCI-P3-D65 and Rec.2100
        # all master to, so it is the accurate choice everywhere; NIGHT's
        # 5000K is a deliberate comfort deviation, since warm white suppresses
        # melatonin far less than cool white.
        monProfiles      = @(
            @{ Name = 'DAY';    Color = '#FFC46F'; Bri = 45; Con = 70; Preset = 5; Builtin = $true },
            @{ Name = 'NIGHT';  Color = '#8F86FF'; Bri = 15; Con = 70; Preset = 4; Builtin = $true },
            @{ Name = 'CINEMA'; Color = '#FF7A8A'; Bri = 25; Con = 70; Preset = 5; Builtin = $true },
            @{ Name = 'GAME';   Color = '#7FE0A0'; Bri = 50; Con = 70; Preset = 5; Builtin = $true }
        )
        # Vento profiles - the whole machine in one name. Each sets a fan mode,
        # the overlay, and a display profile (by name, so they ride on the same
        # display scenes above). Switched from the tray and a hotkey. Colours
        # echo the matching display profile so the two systems read as one.
        ventoProfile     = ''          # active Vento profile ('' = none picked)
        ventoProfiles    = @(
            @{ Name = 'GAMING'; Color = '#7FE0A0'; Fan = 'performance'; Overlay = 'on';  Display = 'GAME';   Builtin = $true },
            @{ Name = 'MOVIE';  Color = '#FF7A8A'; Fan = 'quiet';       Overlay = 'off'; Display = 'CINEMA'; Builtin = $true },
            @{ Name = 'WORK';   Color = '#FFC46F'; Fan = 'normal';      Overlay = 'off'; Display = 'DAY';    Builtin = $true }
        )
    }
}

function Limit([double]$v, [double]$lo, [double]$hi) {
    if ($v -lt $lo) { return $lo }
    if ($v -gt $hi) { return $hi }
    return $v
}

function Import-Settings {
    $s = Get-DefaultSettings
    if (Test-Path $script:settingsPath) {
        try {
            $json = Get-Content -Raw -Path $script:settingsPath | ConvertFrom-Json
            foreach ($k in @($s.Keys)) {
                $p = $json.PSObject.Properties[$k]
                if ($null -ne $p -and $null -ne $p.Value) { $s[$k] = $p.Value }
            }
            # 1.4.x stored the game reaction as a bool - map it onto the tri-state action.
            $pOld = $json.PSObject.Properties['gameBoost']
            if ($null -ne $pOld -and $null -eq $json.PSObject.Properties['gameAction']) {
                $s.gameAction = $(if ([bool]$pOld.Value) { 'performance' } else { 'off' })
            }
        } catch { }
    }
    # Validation + hardware safety floors (case hub never below 20%, CPU never
    # below 30%). Any unusable value (e.g. hand-edited text) resets to defaults
    # instead of crashing every launch until the file is deleted.
    try {
        $s.startMinimized   = [bool]$s.startMinimized
        $s.closeToTray      = [bool]$s.closeToTray
        $s.boostEnabled     = [bool]$s.boostEnabled
        $s.updateIntervalMs = [int](Limit $s.updateIntervalMs 1000 10000)
        $s.quietCase        = [int](Limit $s.quietCase  20 100)
        $s.normalCase       = [int](Limit $s.normalCase 20 100)
        $s.perfCase         = [int](Limit $s.perfCase   20 100)
        $s.perfCpu          = [int](Limit $s.perfCpu    30 100)
        $s.boostHigh        = [int](Limit $s.boostHigh  60 90)
        $s.boostLow         = [int](Limit $s.boostLow   40 ($s.boostHigh - 3))
        $s.boostCase        = [int](Limit $s.boostCase  30 100)
        $s.cpuMaxTemp       = [int](Limit $s.cpuMaxTemp 70 95)
        $s.gpuMaxTemp       = [int](Limit $s.gpuMaxTemp 70 95)
        $s.warnCpu          = [int](Limit $s.warnCpu 50 80)
        $s.warnGpu          = [int](Limit $s.warnGpu 50 80)
        $s.warnSsd          = [int](Limit $s.warnSsd 45 75)
        $s.warnMb           = [int](Limit $s.warnMb  45 75)
        $s.cpuFanChannel    = [string]$s.cpuFanChannel
        $s.caseFanChannel   = [string]$s.caseFanChannel
        $s.mbTempSensor     = [string]$s.mbTempSensor
        $s.checkUpdates     = [bool]$s.checkUpdates
        $s.updateRepo       = [string]$s.updateRepo
        $s.gameOnLoad       = [int](Limit $s.gameOnLoad 50 100)
        $s.gameCooldownSec  = [int](Limit $s.gameCooldownSec 0 60)
        $s.curve40          = [int](Limit $s.curve40 20 100)
        $s.curve55          = [int](Limit $s.curve55 20 100)
        $s.curve70          = [int](Limit $s.curve70 20 100)
        $s.curve80          = [int](Limit $s.curve80 20 100)
        $s.osdScale         = [int](Limit $s.osdScale 75 200)
        $s.osdOnSecondary   = [bool]$s.osdOnSecondary
        $s.osdOpacity       = [int](Limit $s.osdOpacity 30 100)
        $s.osdFree          = [bool]$s.osdFree
        $s.osdCapSafe       = [bool]$s.osdCapSafe
        # Kept as plain strings; a junk value simply fails to register later.
        foreach ($k in 'hkOsd','hkQuiet','hkNormal','hkPerf','hkAuto','hkProfile') { $s[$k] = [string]$s[$k] }
        $s.osdX             = [double](Limit $s.osdX -20000 20000)
        $s.osdY             = [double](Limit $s.osdY -20000 20000)
        foreach ($k in 'osdCpu','osdGpu','osdGpuLoad','osdRam','osdFans','osdSsd','osdMb','osdFps') { $s[$k] = [bool]$s[$k] }
        $s.monSync          = [bool]$s.monSync
        $s.monNight         = [bool]$s.monNight
        $s.monAdvOpen       = [bool]$s.monAdvOpen
        $s.monNightFrom     = [int](Limit $s.monNightFrom 0 1439)
        $s.monNightTo       = [int](Limit $s.monNightTo   0 1439)
        $s.osdPods          = [bool]$s.osdPods
        $s.podsEnabled      = [bool]$s.podsEnabled
        $s.podsModel        = [int](Limit $s.podsModel 0 65535)
        $s.podsRssiMin      = [int](Limit $s.podsRssiMin -100 -40)
        $s.podsWarn         = [int](Limit $s.podsWarn 5 50)
    } catch {
        $s = Get-DefaultSettings
    }
    # Profiles come back from JSON as objects; normalise them to hashtables and
    # keep the built-ins present so the panel always has something to apply.
    # Kept out of the block above so one bad profile can't wipe every setting.
    try {
        $def = (Get-DefaultSettings).monProfiles
        $norm = @()
        foreach ($p in @($s.monProfiles)) {
            if ($null -eq $p) { continue }
            $h = @{}
            if ($p -is [hashtable]) { foreach ($k in $p.Keys) { $h[$k] = $p[$k] } }
            else { foreach ($pp in $p.PSObject.Properties) { $h[$pp.Name] = $pp.Value } }
            $nm = ([string]$h.Name).Trim()
            if (-not $nm) { continue }
            $col = [string]$h.Color
            try { [void][System.Windows.Media.ColorConverter]::ConvertFromString($col) } catch { $col = '#6FB1FF' }
            # Parsed per field: a hand-edited value salvages that one number
            # instead of throwing the whole profile list away.
            $bri = 0; $con = 0; $pre = 0
            [void][int]::TryParse([string]$h.Bri, [ref]$bri)
            [void][int]::TryParse([string]$h.Con, [ref]$con)
            [void][int]::TryParse([string]$h.Preset, [ref]$pre)
            $norm += ,@{ Name = $nm; Color = $col
                         Bri = [int](Limit $bri 0 100); Con = [int](Limit $con 0 100)
                         Preset = $pre; Builtin = [bool]$h.Builtin }
        }
        foreach ($d in $def) {
            $hit = $false
            foreach ($p in $norm) { if ($p.Name -eq $d.Name) { $hit = $true; break } }
            if (-not $hit) { $norm += ,$d }
        }
        $s.monProfiles = @($norm)
    } catch { $s.monProfiles = (Get-DefaultSettings).monProfiles }
    # Vento profiles - normalised the same way, in their own guard.
    try {
        $vdef = (Get-DefaultSettings).ventoProfiles
        $vnorm = @()
        foreach ($p in @($s.ventoProfiles)) {
            if ($null -eq $p) { continue }
            $h = @{}
            if ($p -is [hashtable]) { foreach ($k in $p.Keys) { $h[$k] = $p[$k] } }
            else { foreach ($pp in $p.PSObject.Properties) { $h[$pp.Name] = $pp.Value } }
            $nm = ([string]$h.Name).Trim()
            if (-not $nm) { continue }
            $col = [string]$h.Color
            try { [void][System.Windows.Media.ColorConverter]::ConvertFromString($col) } catch { $col = '#6FB1FF' }
            $fan = [string]$h.Fan
            if (@('quiet','normal','performance','curve','auto') -notcontains $fan) { $fan = 'normal' }
            $ov = [string]$h.Overlay
            if (@('on','off','auto') -notcontains $ov) { $ov = 'auto' }
            $vnorm += ,@{ Name = $nm; Color = $col; Fan = $fan; Overlay = $ov; Display = [string]$h.Display; Builtin = [bool]$h.Builtin }
        }
        foreach ($d in $vdef) {
            $hit = $false
            foreach ($p in $vnorm) { if ($p.Name -eq $d.Name) { $hit = $true; break } }
            if (-not $hit) { $vnorm += ,$d }
        }
        $s.ventoProfiles = @($vnorm)
    } catch { $s.ventoProfiles = (Get-DefaultSettings).ventoProfiles }
    $s.ventoProfile      = [string]$s.ventoProfile
    $s.monProfile        = [string]$s.monProfile
    $s.monNightProfile   = [string]$s.monNightProfile
    if (@('all', 'one') -notcontains [string]$s.monProfileScope) { $s.monProfileScope = 'all' }
    $s.monProfileByMon   = @(@($s.monProfileByMon) | ForEach-Object { [string]$_ })
    if (@('quiet','normal','performance','curve','auto') -notcontains [string]$s.lastMode) { $s.lastMode = 'auto' }
    if (@('performance','curve','off') -notcontains [string]$s.gameAction) { $s.gameAction = 'performance' }
    if (@('auto','on','off') -notcontains [string]$s.osdMode) { $s.osdMode = 'auto' }
    if (@('tr','tl','bl','br') -notcontains [string]$s.osdCorner) { $s.osdCorner = 'tr' }
    if (@('blade','strip','hero','pills','ghost','micro','thermo') -notcontains [string]$s.osdLayout) { $s.osdLayout = 'blade' }
    if (@('sirocco','ember','venom','violet','crimson','mono') -notcontains [string]$s.osdTheme) { $s.osdTheme = 'sirocco' }
    if (@('mica','acrylic','micaalt') -notcontains [string]$s.windowMaterial) { $s.windowMaterial = 'mica' }
    if (@('auto','cpu','gpu','ssd','board') -notcontains [string]$s.heroSensor) { $s.heroSensor = 'auto' }
    if (@(0, 15, 30, 60) -notcontains [int]$s.devCheckMin) { $s.devCheckMin = 30 }
    $s.devLowOn = [bool]$s.devLowOn
    $s.toastsOn = [bool]$s.toastsOn
    $s.ledAddr = ([string]$s.ledAddr).ToUpperInvariant() -replace '[^0-9A-F]', ''
    if ($s.ledAddr.Length -ne 12) { $s.ledAddr = '4142C00A9E32' }
    $s.ledAutoConn = [bool]$s.ledAutoConn
    $s.ledOn       = [bool]$s.ledOn
    try {
        $s.ledBri   = [int](Limit $s.ledBri 1 100)
        $s.ledHue   = [int](Limit $s.ledHue 0 359)
        $s.ledSat   = [int](Limit $s.ledSat 0 100)
        $s.ledSpeed = [int](Limit $s.ledSpeed 1 100)
        $s.ledFx    = [int](Limit $s.ledFx 1 93)
        if (@(5, 6, 8, 9, 28, 33, 34) -contains $s.ledFx -or ($s.ledFx -ge 11 -and $s.ledFx -le 25)) { $s.ledFx = 91 }
    } catch { $s.ledBri = 100; $s.ledHue = 240; $s.ledSat = 100; $s.ledSpeed = 50; $s.ledFx = 91 }
    if (@('color', 'effect', 'loop') -notcontains [string]$s.ledKind) { $s.ledKind = 'color' }
    $s.ledLoop = [string]$s.ledLoop
    try {
        $lnorm = @()
        foreach ($p in @($s.ledLoops)) {
            if ($null -eq $p) { continue }
            $h = @{}
            if ($p -is [hashtable]) { foreach ($k in $p.Keys) { $h[$k] = $p[$k] } }
            else { foreach ($pp in $p.PSObject.Properties) { $h[$pp.Name] = $pp.Value } }
            $nm = ([string]$h.Name).Trim()
            if (-not $nm) { continue }
            $cols = @(@($h.Colors) | Where-Object { [string]$_ -match '^#[0-9A-Fa-f]{6}$' } | ForEach-Object { ([string]$_).ToUpperInvariant() })
            if ($cols.Count -lt 1) { continue }
            $tr = [string]$h.Trans
            if (@('fade', 'jump', 'breathe') -notcontains $tr) { $tr = 'fade' }
            $half = 6; try { $half = [int](Limit $h.Half 1 60) } catch { }
            $lnorm += , @{ Name = $nm; Colors = @($cols); Trans = $tr; Half = $half }
        }
        $s.ledLoops = @($lnorm)
    } catch { $s.ledLoops = (Get-DefaultSettings).ledLoops }
    foreach ($k in 'osdColFps','osdColCpu','osdColGpu','osdColLoad','osdColRam','osdColSsd','osdColMb','osdColFan','osdColPods') {
        $v = [string]$s[$k]
        if ($v) { try { [void][System.Windows.Media.ColorConverter]::ConvertFromString($v) } catch { $v = '' } }
        $s[$k] = $v
    }
    # Settings files written before the GitHub username was final point the
    # updater at a repo that never existed - migrate them.
    if ([string]$s.updateRepo -eq 'blakfy/vento') { $s.updateRepo = 'Henkerr/vento' }
    try { [void][System.Windows.Media.ColorConverter]::ConvertFromString([string]$s.accentColor) }
    catch { $s.accentColor = '#4C8DFF' }
    return $s
}

function Export-Settings($s) {
    # Depth 6: display profiles are a list of objects, and the default depth of
    # 2 would serialise them as type names instead of values.
    $s | ConvertTo-Json -Depth 6 | Out-File -FilePath $script:settingsPath -Encoding utf8
}

$script:settings = Import-Settings

# --- Shared state ----------------------------------------------------
$sync = [hashtable]::Synchronized(@{
    Data            = [hashtable]::Synchronized(@{ ActiveMode = 'auto'; BoostActive = $false })
    Settings        = [hashtable]::Synchronized(@{})
    SettingsChanged = $false
    PendingMode     = $null
    Exit            = $false
    Stopped         = $false
    Status          = 'loading'
    Error           = $null
    DdcQueue        = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    Ddc             = [hashtable]::Synchronized(@{ Gen = 0; WGen = 0; Busy = $false; Monitors = @(); LastWrite = $null })
})
foreach ($k in $script:settings.Keys) { $sync.Settings[$k] = $script:settings[$k] }

# --- Worker: only this runspace touches LibreHardwareMonitor ---------
$worker = {
    param($sync)
    $pc = $null
    $controls = @()
    try {
        $pc = New-Object LibreHardwareMonitor.Hardware.Computer
        $pc.IsMotherboardEnabled = $true
        $pc.IsCpuEnabled = $true
        $pc.IsGpuEnabled = $true
        $pc.IsStorageEnabled = $true
        $pc.IsMemoryEnabled = $true    # RAM usage % for the overlay
        $pc.Open()

        # Storage is skipped here: SSD units are updated per-pass anyway, and
        # warming up every drive would SMART-poll HDDs at each launch.
        foreach ($round in 1..2) {
            foreach ($hw in $pc.Hardware) {
                if ($hw.HardwareType.ToString() -eq 'Storage') { continue }
                $hw.Update()
                foreach ($sub in $hw.SubHardware) { $sub.Update() }
            }
            Start-Sleep -Milliseconds 500
        }

        # Resolve sensor references once, reuse them afterwards.
        # Channel names come from settings so other boards can remap them;
        # if a named channel is missing we fall back to first/second found.
        $cpuChan  = [string]$sync.Settings.cpuFanChannel
        $caseChan = [string]$sync.Settings.caseFanChannel

        $mb  = $pc.Hardware | Where-Object { $_.HardwareType.ToString() -eq 'Motherboard' } | Select-Object -First 1
        $sio = $null
        if ($mb) { $sio = $mb.SubHardware | Select-Object -First 1; $sync.Data.MbName = $mb.Name }

        $fanCpu = $null; $fanCase = $null; $ctlCpu = $null; $ctlCase = $null
        $spares = @()
        if ($sio) {
            $allFans = @($sio.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Fan' }     | Sort-Object Name)
            $allCtls = @($sio.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Control' } | Sort-Object Name)
            $fanCpu  = $allFans | Where-Object { $_.Name -eq $cpuChan }  | Select-Object -First 1
            $fanCase = $allFans | Where-Object { $_.Name -eq $caseChan } | Select-Object -First 1
            $ctlCpu  = $allCtls | Where-Object { $_.Name -eq $cpuChan }  | Select-Object -First 1
            $ctlCase = $allCtls | Where-Object { $_.Name -eq $caseChan } | Select-Object -First 1
            if (-not $fanCpu)  { $fanCpu  = $allFans | Where-Object { $_ -ne $fanCase } | Select-Object -First 1 }
            if (-not $fanCase) { $fanCase = $allFans | Where-Object { $_ -ne $fanCpu }  | Select-Object -First 1 }
            if (-not $ctlCpu)  { $ctlCpu  = $allCtls | Where-Object { $_ -ne $ctlCase } | Select-Object -First 1 }
            if (-not $ctlCase) { $ctlCase = $allCtls | Where-Object { $_ -ne $ctlCpu }  | Select-Object -First 1 }
            $spares = @($allCtls | Where-Object { $_ -ne $ctlCpu -and $_ -ne $ctlCase })
        }
        $controls = @(@($ctlCpu, $ctlCase) + $spares | Where-Object { $_ })

        # Board temp: SuperIO temp sensor names are chip-specific and often
        # unlabeled, so settings override -> known names -> first plausible.
        $mbTempSensor = $null
        if ($sio) {
            $allTemps = @($sio.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Temperature' })
            $sel = [string]$sync.Settings.mbTempSensor
            if ($sel -and $sel -ne 'auto') { $mbTempSensor = $allTemps | Where-Object { $_.Name -eq $sel } | Select-Object -First 1 }
            if (-not $mbTempSensor) { $mbTempSensor = $allTemps | Where-Object { $_.Name -match '^(System|Motherboard|System Temperature)$' } | Select-Object -First 1 }
            if (-not $mbTempSensor) { $mbTempSensor = $allTemps | Where-Object { $_.Name -notmatch 'CPU|AUX|Peripheral' -and $null -ne $_.Value -and $_.Value -gt 0 -and $_.Value -lt 120 } | Select-Object -First 1 }
            if (-not $mbTempSensor) { $mbTempSensor = $allTemps | Where-Object { $null -ne $_.Value -and $_.Value -gt 0 -and $_.Value -lt 120 } | Select-Object -First 1 }
        }

        $cpuHw = $pc.Hardware | Where-Object { $_.HardwareType.ToString() -eq 'Cpu' } | Select-Object -First 1
        $cpuTemp = $null
        if ($cpuHw) {
            $cpuTemp = $cpuHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Temperature' -and $_.Name -eq 'Core (Tctl/Tdie)' } | Select-Object -First 1
            if (-not $cpuTemp) { $cpuTemp = $cpuHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Temperature' } | Select-Object -First 1 }
            $sync.Data.CpuName = $cpuHw.Name
        }

        # Pick the GPU that matters: on hybrid laptops and iGPU-first desktops
        # the integrated GPU often enumerates first but has no real temp/load,
        # which would leave the GPU card blank and break game detection. Score
        # each candidate by whether it reports a GPU Core temperature and load,
        # preferring a discrete NVIDIA/AMD part, and take the best.
        $gpuCands = @($pc.Hardware | Where-Object { $_.HardwareType.ToString() -like 'Gpu*' })
        $gpuHw = $null
        if ($gpuCands.Count -eq 1) { $gpuHw = $gpuCands[0] }
        elseif ($gpuCands.Count -gt 1) {
            $best = -1
            foreach ($cand in $gpuCands) {
                $sc = 0
                $sens = @($cand.Sensors)
                if ($sens | Where-Object { $_.SensorType.ToString() -eq 'Temperature' -and $_.Name -eq 'GPU Core' -and $null -ne $_.Value }) { $sc += 4 }
                if ($sens | Where-Object { $_.SensorType.ToString() -eq 'Load' -and $_.Name -eq 'GPU Core' -and $null -ne $_.Value }) { $sc += 2 }
                if ($cand.HardwareType.ToString() -match 'Nvidia|AmdGpu|Amd') { $sc += 1 }
                if ($cand.Name -match 'GeForce|RTX|GTX|Radeon|RX ') { $sc += 1 }
                if ($sc -gt $best) { $best = $sc; $gpuHw = $cand }
            }
            if (-not $gpuHw) { $gpuHw = $gpuCands[0] }
        }
        $gpuTemp = $null; $gpuFans = @()
        if ($gpuHw) {
            $gpuTemp = $gpuHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Temperature' -and $_.Name -eq 'GPU Core' } | Select-Object -First 1
            if (-not $gpuTemp) { $gpuTemp = $gpuHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Temperature' } | Select-Object -First 1 }
            $gpuFans = @($gpuHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Fan' } | Sort-Object Name)
            $sync.Data.GpuName = $gpuHw.Name
        }
        $gpuLoad = $null
        if ($gpuHw) {
            $gpuLoad = $gpuHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Load' -and $_.Name -eq 'GPU Core' } | Select-Object -First 1
            if (-not $gpuLoad) { $gpuLoad = $gpuHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Load' } | Select-Object -First 1 }
        }

        # RAM usage % for the overlay. This LHM build splits memory into
        # 'Virtual Memory' (commit charge) and 'Total Memory' (physical), in
        # that order - taking the first would overstate usage, so anything
        # named Virtual is skipped when a physical entry exists.
        $memHw = $pc.Hardware | Where-Object { $_.HardwareType.ToString() -eq 'Memory' -and $_.Name -notmatch 'Virtual' } | Select-Object -First 1
        if (-not $memHw) { $memHw = $pc.Hardware | Where-Object { $_.HardwareType.ToString() -eq 'Memory' } | Select-Object -First 1 }
        $ramLoad = $null
        if ($memHw) {
            $ramLoad = $memHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Load' -and $_.Name -eq 'Memory' } | Select-Object -First 1
            if (-not $ramLoad) { $ramLoad = $memHw.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Load' } | Select-Object -First 1 }
        }
        # DIMM thermal sensors, read over SPD. DDR5 modules always carry one,
        # many DDR4 sticks do not - on those this list is simply empty and the
        # readout never appears.
        $ramTempSensors = @()
        $ramTempHw = @()
        foreach ($hw0 in $pc.Hardware) {
            if ($hw0.HardwareType.ToString() -ne 'Memory') { continue }
            $hit = $false
            foreach ($sn0 in $hw0.Sensors) {
                if ($sn0.SensorType.ToString() -eq 'Temperature') { $ramTempSensors += $sn0; $hit = $true }
            }
            foreach ($sub0 in $hw0.SubHardware) {
                foreach ($sn0 in $sub0.Sensors) {
                    if ($sn0.SensorType.ToString() -eq 'Temperature') { $ramTempSensors += $sn0; $hit = $true }
                }
            }
            # Only modules that actually carry a sensor get polled each pass.
            if ($hit) { $ramTempHw += $hw0 }
        }

        # SSD card shows the hottest solid-state drive. HDDs are excluded from
        # the recurring poll so steady-state SMART reads can't keep a sleeping
        # disk awake (drive enumeration at Open() still touches each once).
        # Every drive is a generic StorageDevice in this LHM build, so NVMe is
        # detected by its 'Composite Temperature' sensor (NVMe health log;
        # 'Temperature #n' are controller diodes that read 10-20 deg C hot),
        # SATA SSDs by model name - 'SSD' plus the common families that omit
        # it (Kingston SA400/SUV, WD Blue/Green WDS...).
        $ssdUnits = @()
        foreach ($st in @($pc.Hardware | Where-Object { $_.HardwareType.ToString() -eq 'Storage' })) {
            $temps = @($st.Sensors | Where-Object { $_.SensorType.ToString() -eq 'Temperature' })
            $ts = $temps | Where-Object { $_.Name -eq 'Composite Temperature' } | Select-Object -First 1
            $isNvme = [bool]$ts
            if (-not $isNvme -and $st.Name -notmatch 'SSD|WDS\d|SA400|SUV\d') { continue }
            if (-not $ts) { $ts = $temps | Where-Object { $_.Name -eq 'Temperature' } | Select-Object -First 1 }
            if (-not $ts) { $ts = $temps | Where-Object { $_.Name -notmatch 'Warning|Critical' } | Select-Object -First 1 }
            if ($ts) { $ssdUnits += ,@{ Hw = $st; Sensor = $ts; Nvme = $isNvme; Dead = $false } }
        }
        if (@($ssdUnits | Where-Object { $_.Nvme }).Count -gt 0) { $ssdUnits = @($ssdUnits | Where-Object { $_.Nvme }) }

        function Get-CurveTarget([double]$t, $s) {
            # piecewise-linear case fan curve over 40/55/70/80 deg C
            $pts = @(@(40, [int]$s.curve40), @(55, [int]$s.curve55), @(70, [int]$s.curve70), @(80, [int]$s.curve80))
            if ($t -le $pts[0][0]) { return $pts[0][1] }
            if ($t -ge $pts[3][0]) { return $pts[3][1] }
            for ($i = 0; $i -lt 3; $i++) {
                if ($t -le $pts[$i + 1][0]) {
                    $f = ($t - $pts[$i][0]) / ($pts[$i + 1][0] - $pts[$i][0])
                    return [int][math]::Round($pts[$i][1] + ($pts[$i + 1][1] - $pts[$i][1]) * $f)
                }
            }
            return $pts[3][1]
        }

        function Set-CaseSpeed([int]$pct) {
            if ($ctlCase) { $ctlCase.Control.SetSoftware([math]::Max(20, $pct)) }
        }

        function Reset-FanControls {
            # LHM's Control setters are change-gated and nothing in its update
            # loop ever re-writes control registers: after sleep the SuperIO
            # forgets our duty while LHM still caches it, so re-applying the
            # same mode used to write NOTHING to the chip (the 1.6.1 and 1.7.2
            # wake fixes were silent no-ops; the manual mode toggle worked only
            # because its values actually changed). Dropping to Default first
            # makes the next SetSoftware a real mode change, whose handler
            # writes the value to the chip (verified in LHM 0.9.6 source:
            # Control.cs setters + SuperIOHardware.cs ControlModeChanged).
            if ($ctlCpu)  { $ctlCpu.Control.SetDefault() }
            if ($ctlCase) { $ctlCase.Control.SetDefault() }
        }

        function Set-Mode([string]$mode) {
            $s = $sync.Settings
            switch ($mode) {
                'quiet'       { if ($ctlCpu) { $ctlCpu.Control.SetDefault() }
                                Set-CaseSpeed $s.quietCase }
                'normal'      { if ($ctlCpu) { $ctlCpu.Control.SetDefault() }
                                Set-CaseSpeed $s.normalCase }
                'performance' { if ($ctlCpu) { $ctlCpu.Control.SetSoftware([math]::Max(30, [int]$s.perfCpu)) }
                                Set-CaseSpeed $s.perfCase }
                'curve'       { if ($ctlCpu) { $ctlCpu.Control.SetDefault() } }   # case speed applied by the loop
                'auto'        { if ($ctlCpu) { $ctlCpu.Control.SetDefault() }
                                if ($ctlCase) { $ctlCase.Control.SetDefault() } }
            }
            foreach ($sp in $spares) { $sp.Control.SetDefault() }
            $sync.Data.ActiveMode = $mode
        }

        # restore the last user-chosen mode ('auto' = BIOS control, nothing to apply)
        $initMode = [string]$sync.Settings.lastMode
        if (@('quiet','normal','performance','curve') -contains $initMode) { Set-Mode $initMode }

        $sync.Status = 'ready'
        $boostOn = $false
        $gameOn = $false; $gameHot = 0; $gameIdle = 0; $preGame = 'auto'
        $gameEngaged = 'performance'   # mode the game action actually switched to
        $detOn = $false; $detHot = 0; $detIdle = 0
        $sync.Data.GameDetected = $false
        $coolMs = 0; $coolHot = 0
        $lastCurve = -100
        $sinceUpdate = 999999
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $lastLoopMs = [long]0
        $lastPassMs = [long](-1)
        $lastWall = [DateTime]::UtcNow
        $reapplyAt = @()   # pending post-resume re-apply marks (stopwatch ms)
        $tickErr = 0
        while (-not $sync.Exit) {
          # A transient fault in a single tick (a sensor read, a fan write)
          # must not end the worker - the outer catch would quit the app,
          # which is exactly what should not happen mid-game. Keep looping;
          # log the first of a burst so a real, persistent fault is still
          # visible in error.log.
          try {
            # real elapsed time this iteration - Start-Sleep overshoots, so
            # fixed increments would drift
            $nowMs = $clock.ElapsedMilliseconds
            $tickMs = [int][math]::Max(0, [math]::Min(5000, $nowMs - $lastLoopMs))
            $lastLoopMs = $nowMs
            $s = $sync.Settings
            # Resume from sleep/hibernate: the SuperIO drops our software fan
            # control back to its BIOS default (often full speed), and nothing
            # re-applies a fixed mode until the mode changes. A wall-clock jump
            # between ticks is the tell - re-apply the active mode, exactly what
            # a manual mode re-select does. Wall clock, not the stopwatch, since
            # QPC can pause across S3.
            $wallNow = [DateTime]::UtcNow
            if (($wallNow - $lastWall).TotalSeconds -gt 25) {
                # Reset-FanControls is what makes this re-apply actually reach
                # the chip - see its comment. The staged repeats below cover a
                # board whose EC settles late and re-arms its own defaults.
                Reset-FanControls
                Set-Mode $sync.Data.ActiveMode
                if ($boostOn -and $sync.Data.ActiveMode -eq 'quiet' -and $s.boostEnabled) { Set-CaseSpeed $s.boostCase }
                $lastCurve = -100
                $sinceUpdate = 999999
                $reapplyAt = @(($nowMs + 5000), ($nowMs + 15000), ($nowMs + 45000))
            }
            $lastWall = $wallNow
            if ($reapplyAt.Count -gt 0 -and $nowMs -ge $reapplyAt[0]) {
                $reapplyAt = @($reapplyAt | Select-Object -Skip 1)
                Reset-FanControls
                Set-Mode $sync.Data.ActiveMode
                if ($boostOn -and $sync.Data.ActiveMode -eq 'quiet' -and $s.boostEnabled) { Set-CaseSpeed $s.boostCase }
                $lastCurve = -100
            }
            $pending = $sync.PendingMode
            if ($pending) {
                # Clear only if unchanged so a click landing mid-cycle isn't lost
                if ($sync.PendingMode -eq $pending) { $sync.PendingMode = $null }
                Set-Mode $pending
                $boostOn = $false
                $sync.Data.BoostActive = $false
                $gameOn = $false; $gameHot = 0
                $sync.Data.GameBoost = $false
                $coolMs = 0; $coolHot = 0
                $sync.Data.CoolDown = $false
                $lastCurve = -100
                $sinceUpdate = 999999   # apply curve/read sensors promptly
                $sync.Data.Warning = $null
            }
            if ($sync.SettingsChanged) {
                $sync.SettingsChanged = $false
                $lastCurve = -100
                Set-Mode $sync.Data.ActiveMode
                # Keep an active Quiet boost alive across live tweaks from the
                # mode panel - Set-Mode just dropped the case fans to quietCase.
                if ($boostOn) {
                    if ($sync.Data.ActiveMode -eq 'quiet' -and $s.boostEnabled) { Set-CaseSpeed $s.boostCase }
                    else { $boostOn = $false; $sync.Data.BoostActive = $false }
                }
                $sinceUpdate = 999999   # re-evaluate curve/boost with the new values promptly
            }
            # Post-game cooldown countdown runs on the fast loop so the
            # remaining time and the hand-back stay accurate even when the
            # sensor interval is long.
            if ($coolMs -gt 0) {
                if ($sync.Data.ActiveMode -ne $gameEngaged) {
                    # user changed mode manually - drop the cooldown
                    $coolMs = 0; $coolHot = 0
                    $sync.Data.CoolDown = $false
                } else {
                    $coolMs -= $tickMs
                    if ($coolMs -le 0) {
                        $coolMs = 0; $coolHot = 0
                        $sync.Data.CoolDown = $false
                        Set-Mode $preGame
                        $lastCurve = -100
                        $sinceUpdate = 999999   # apply the returned mode's curve promptly
                    } else {
                        $sync.Data.CoolLeft = $coolMs
                    }
                }
            }
            if ($sinceUpdate -ge [int]$s.updateIntervalMs) {
                $sinceUpdate = 0
                # Each device is updated on its own: a GPU driver reset (TDR) or
                # an SMBus clash with another tool can make one Update() throw,
                # and that must degrade just that card for a tick, not take the
                # whole app down (the outer catch used to exit on it).
                if ($sio)   { try { $sio.Update() }   catch { } }
                if ($cpuHw) { try { $cpuHw.Update() } catch { } }
                if ($gpuHw) { try { $gpuHw.Update() } catch { } }
                if ($memHw) { try { $memHw.Update() } catch { } }
                foreach ($hw0 in $ramTempHw) { try { $hw0.Update() } catch { } }
                # A drive whose Update() throws (USB enclosure unplugged) is
                # retired: LHM never nulls Sensor.Value, so without this the
                # card would keep showing the last reading as if it were live.
                foreach ($u in $ssdUnits) {
                    if ($u.Dead) { continue }
                    try { $u.Hw.Update() } catch { $u.Dead = $true }
                }

                $d = $sync.Data
                $d.CpuFan  = if ($fanCpu  -and $null -ne $fanCpu.Value)  { [int]$fanCpu.Value }  else { $null }
                $d.CaseFan = if ($fanCase -and $null -ne $fanCase.Value) { [int]$fanCase.Value } else { $null }
                $d.CpuTemp = if ($cpuTemp -and $null -ne $cpuTemp.Value) { [math]::Round($cpuTemp.Value, 1) } else { $null }
                $d.GpuTemp = if ($gpuTemp -and $null -ne $gpuTemp.Value) { [math]::Round($gpuTemp.Value, 1) } else { $null }
                $d.GpuFan1 = if ($gpuFans.Count -ge 1 -and $null -ne $gpuFans[0].Value) { [int]$gpuFans[0].Value } else { $null }
                $d.GpuFan2 = if ($gpuFans.Count -ge 2 -and $null -ne $gpuFans[1].Value) { [int]$gpuFans[1].Value } else { $null }
                $d.RamLoad = if ($ramLoad -and $null -ne $ramLoad.Value) { [math]::Round($ramLoad.Value) } else { $null }
                # Hottest DIMM, when the sticks report one at all.
                $ramT = $null
                foreach ($sn0 in $ramTempSensors) {
                    $v0 = $sn0.Value
                    if ($null -ne $v0 -and $v0 -gt 0 -and $v0 -lt 120 -and ($null -eq $ramT -or $v0 -gt $ramT)) { $ramT = $v0 }
                }
                $d.RamTemp = if ($null -ne $ramT) { [math]::Round($ramT, 1) } else { $null }

                # Plausibility re-checked every pass: SuperIO chips report
                # -55 / 127 deg C on disconnected diodes.
                $d.MbTemp = if ($mbTempSensor -and $null -ne $mbTempSensor.Value -and $mbTempSensor.Value -gt 0 -and $mbTempSensor.Value -lt 120) { [math]::Round($mbTempSensor.Value, 1) } else { $null }

                $best = $null; $bestName = $null
                foreach ($u in $ssdUnits) {
                    if ($u.Dead) { continue }
                    if ($null -ne $u.Sensor.Value -and (($null -eq $best) -or ($u.Sensor.Value -gt $best))) { $best = [double]$u.Sensor.Value; $bestName = $u.Hw.Name }
                }
                $d.SsdTemp = if ($null -ne $best) { [math]::Round($best, 1) } else { $null }
                $d.SsdName = $bestName

                # Quiet-mode cooling boost with hysteresis: raise the case
                # fans above boostHigh, fall back to Quiet speed below boostLow.
                if ($d.ActiveMode -eq 'quiet' -and $s.boostEnabled) {
                    $hot  = (($null -ne $d.CpuTemp) -and ($d.CpuTemp -ge $s.boostHigh)) -or
                            (($null -ne $d.GpuTemp) -and ($d.GpuTemp -ge $s.boostHigh))
                    $cool = (($null -eq $d.CpuTemp) -or ($d.CpuTemp -le $s.boostLow)) -and
                            (($null -eq $d.GpuTemp) -or ($d.GpuTemp -le $s.boostLow))
                    if (-not $boostOn -and $hot)  { Set-CaseSpeed $s.boostCase;  $boostOn = $true }
                    elseif ($boostOn -and $cool)  { Set-CaseSpeed $s.quietCase;  $boostOn = $false }
                } elseif ($boostOn) {
                    $boostOn = $false
                }
                $d.BoostActive = $boostOn

                # Curve mode: case fans follow the temperature curve (max of CPU/GPU)
                if ($d.ActiveMode -eq 'curve') {
                    $tMax = $null
                    if ($null -ne $d.CpuTemp) { $tMax = [double]$d.CpuTemp }
                    if (($null -ne $d.GpuTemp) -and (($null -eq $tMax) -or ($d.GpuTemp -gt $tMax))) { $tMax = [double]$d.GpuTemp }
                    if ($null -ne $tMax) {
                        $target = Get-CurveTarget $tMax $s
                        if ([math]::Abs($target - $lastCurve) -ge 3) { Set-CaseSpeed $target; $lastCurve = $target }
                        $d.CurveTarget = $lastCurve   # show what was actually applied
                    }
                } else {
                    $d.CurveTarget = $null
                }

                # Auto game boost: sustained GPU load switches to Performance,
                # sustained idle switches back to the previous mode.
                $load = if ($gpuLoad -and $null -ne $gpuLoad.Value) { [double]$gpuLoad.Value } else { $null }
                $d.GpuLoad = $load
                # Real elapsed time since the previous sensor pass: forced
                # prompt passes (SettingsChanged, cooldown expiry) must not
                # inflate the game-boost / cooldown accumulators.
                $passMs = if ($lastPassMs -lt 0) { [int]$s.updateIntervalMs } else { [int][math]::Min(60000, $nowMs - $lastPassMs) }
                $lastPassMs = $nowMs
                # Game detection (signal only): feeds the OSD overlay's auto
                # mode and stays live even when the game action is 'off'.
                # Faster on (10s) than the action's 30s ramp so the overlay
                # appears promptly; 60s idle release so loading screens and
                # menus don't flicker it.
                if ($null -ne $load) {
                    if ($detOn) {
                        if ($load -le 30) { $detIdle += $passMs } else { $detIdle = 0 }
                        if ($detIdle -ge 60000) { $detOn = $false; $detIdle = 0 }
                    } else {
                        if ($load -ge $s.gameOnLoad) { $detHot += $passMs } else { $detHot = 0 }
                        if ($detHot -ge 10000) { $detOn = $true; $detHot = 0; $detIdle = 0 }
                    }
                } elseif ($detOn) {
                    # A null sample is a sensor hiccup (transient read fault, TDR),
                    # not proof the game ended: let the same 60s idle release decide
                    # instead of blanking the overlay mid-game on one bad read.
                    $detIdle += $passMs
                    if ($detIdle -ge 60000) { $detOn = $false; $detHot = 0; $detIdle = 0 }
                }
                $d.GameDetected = $detOn
                # Near the safety limits, never (re)arm game boost - otherwise
                # the guard's forced Auto and the boost would fight in a loop.
                $tooHot = ((($null -ne $d.CpuTemp) -and ($d.CpuTemp -gt ($s.cpuMaxTemp - 4))) -or
                           (($null -ne $d.GpuTemp) -and ($d.GpuTemp -gt ($s.gpuMaxTemp - 4))))
                $act = [string]$s.gameAction
                $gameMode = if ($act -eq 'curve') { 'curve' } else { 'performance' }
                if ($act -ne 'off' -and $null -ne $load) {
                    if ($gameOn) {
                        if ($d.ActiveMode -ne $gameEngaged) {
                            # user changed mode manually - stop tracking
                            $gameOn = $false; $d.GameBoost = $false
                        } else {
                            if ($load -le 30) { $gameIdle += $passMs } else { $gameIdle = 0 }
                            if ($gameIdle -ge 120000) {
                                $gameOn = $false; $d.GameBoost = $false
                                if ([int]$s.gameCooldownSec -gt 0) {
                                    # post-game cooldown: hold Performance a little
                                    # longer, then hand back to the pre-game mode
                                    $coolMs = [int]$s.gameCooldownSec * 1000
                                    $coolHot = 0
                                    $d.CoolLeft = $coolMs; $d.CoolTo = $preGame
                                    $d.CoolDown = $true
                                } else {
                                    Set-Mode $preGame
                                    $lastCurve = -100
                                }
                            }
                        }
                    } elseif ($coolMs -gt 0) {
                        # game came back mid-cooldown: a few sustained samples
                        # resume the boost without the full 30s ramp (a single
                        # spike - e.g. a video burst - should not re-arm it)
                        if (($load -ge $s.gameOnLoad) -and (-not $tooHot)) { $coolHot += $passMs } else { $coolHot = 0 }
                        if ($coolHot -ge 6000) {
                            $coolMs = 0; $coolHot = 0; $d.CoolDown = $false
                            $gameOn = $true; $d.GameBoost = $true; $gameIdle = 0
                        }
                    } else {
                        if (($load -ge $s.gameOnLoad) -and ($d.ActiveMode -ne $gameMode) -and (-not $tooHot)) { $gameHot += $passMs } else { $gameHot = 0 }
                        if ($gameHot -ge 30000) {
                            $preGame = $d.ActiveMode
                            $gameEngaged = $gameMode
                            Set-Mode $gameMode
                            $lastCurve = -100   # entering curve: apply the curve target promptly
                            $gameOn = $true; $d.GameBoost = $true; $d.GameMode = $gameEngaged
                            $d.GameDetected = $true; $detOn = $true
                            $gameHot = 0; $gameIdle = 0
                            $boostOn = $false; $d.BoostActive = $false
                        }
                    }
                } elseif ($gameOn -or $coolMs -gt 0) {
                    # tracking lost (sensor vanished or action set to off) -
                    # don't strand the fans in the game mode
                    $gameOn = $false; $d.GameBoost = $false
                    $coolMs = 0; $coolHot = 0; $d.CoolDown = $false
                    if ($d.ActiveMode -eq $gameEngaged) { Set-Mode $preGame; $lastCurve = -100 }
                }

                # Safety guard: in any manual mode, runaway temps force Auto.
                if ($d.ActiveMode -ne 'auto') {
                    if ((($null -ne $d.CpuTemp) -and ($d.CpuTemp -gt $s.cpuMaxTemp)) -or
                        (($null -ne $d.GpuTemp) -and ($d.GpuTemp -gt $s.gpuMaxTemp))) {
                        Set-Mode 'auto'
                        $boostOn = $false
                        $d.BoostActive = $false
                        $gameOn = $false; $gameHot = 0; $gameIdle = 0
                        $d.GameBoost = $false
                        $coolMs = 0; $coolHot = 0; $d.CoolDown = $false
                        $d.Warning = 'High temperature - fans switched back to Auto'
                    }
                }
            }
            $tickErr = 0
          } catch {
            # This runspace has no file access to the app folder; hand the
            # throttled fault to the UI thread, which logs it. The loop lives.
            $tickErr++
            if ($tickErr -eq 1 -or ($tickErr % 100) -eq 0) {
                $sync.TickError = "worker tick error #$tickErr`: " + ($_ | Out-String)
            }
          }
            Start-Sleep -Milliseconds 200
            $sinceUpdate += 200
        }
    }
    catch {
        $sync.Error = $_ | Out-String
        $sync.Status = 'error'
    }
    finally {
        foreach ($c in $controls) { try { $c.Control.SetDefault() } catch { } }
        if ($pc) { try { $pc.Close() } catch { } }
        $sync.Stopped = $true
    }
}

$script:runspace = [runspacefactory]::CreateRunspace()
$script:runspace.ApartmentState = 'MTA'
$script:runspace.Open()
$script:psWorker = [powershell]::Create()
$script:psWorker.Runspace = $script:runspace
[void]$script:psWorker.AddScript($worker.ToString()).AddArgument($sync)
[void]$script:psWorker.BeginInvoke()

# --- UI --------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Vento" Width="720" Height="966"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="__FONTS__#Sora, Segoe UI">
  <Window.Resources>
    <!-- Sirocco thermal palette: every color below is rewritten each tick by
         Apply-Thermal, lerped between the cool/warm/hot anchor palettes. -->
    <SolidColorBrush x:Key="AccentBrush" Color="#6FB1FF"/>
    <SolidColorBrush x:Key="AccentSoftBrush" Color="#266FB1FF"/>
    <SolidColorBrush x:Key="ThInkBrush" Color="#EDF1F8"/>
    <SolidColorBrush x:Key="ThDimBrush" Color="#8FA3BC"/>
    <SolidColorBrush x:Key="ThFaintBrush" Color="#5A6B84"/>
    <SolidColorBrush x:Key="ThTileBrush" Color="#10151D"/>
    <SolidColorBrush x:Key="ThTrackBrush" Color="#16202E"/>
    <SolidColorBrush x:Key="ThGridBrush" Color="#151D2A"/>
    <SolidColorBrush x:Key="ThChartABrush" Color="#D8E4F2"/>
    <DrawingBrush x:Key="BarSegmentBrush" TileMode="Tile" Viewport="0,0,9,6" ViewportUnits="Absolute" Viewbox="0,0,9,6" ViewboxUnits="Absolute" Stretch="None">
      <DrawingBrush.Drawing>
        <GeometryDrawing Brush="#0A0E16">
          <GeometryDrawing.Geometry>
            <RectangleGeometry Rect="7,0,2,6"/>
          </GeometryDrawing.Geometry>
        </GeometryDrawing>
      </DrawingBrush.Drawing>
    </DrawingBrush>
    <Style x:Key="TitleBtn" TargetType="Button">
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#8A93A6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="8">
              <TextBlock Text="{TemplateBinding Content}" FontFamily="Segoe MDL2 Assets" FontSize="10"
                         Foreground="{TemplateBinding Foreground}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1A2233"/>
                <Setter Property="Foreground" Value="#ECF0F7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#233048"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Title-bar chip: the displays button carries a label so it reads as a
         destination, not a decoration. -->
    <Style x:Key="ChipTitleBtn" TargetType="Button">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#1A6FB1FF" BorderBrush="{DynamicResource AccentSoftBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="11,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#2E6FB1FF"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#456FB1FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TitleBtnClose" TargetType="Button" BasedOn="{StaticResource TitleBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="8">
              <TextBlock Text="{TemplateBinding Content}" FontFamily="Segoe MDL2 Assets" FontSize="10"
                         Foreground="{TemplateBinding Foreground}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#E5484D"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#C13F45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="{DynamicResource ThTileBrush}"/>
    </Style>
    <Style x:Key="CardInner" TargetType="Border">
      <Setter Property="CornerRadius" Value="11"/>
      <Setter Property="BorderThickness" Value="0,1,0,0"/>
      <Setter Property="BorderBrush" Value="#0DFFFFFF"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="16,12"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThDimBrush}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="AccentTick" TargetType="Rectangle">
      <Setter Property="Width" Value="3"/>
      <Setter Property="Height" Value="10"/>
      <Setter Property="RadiusX" Value="1.5"/>
      <Setter Property="RadiusY" Value="1.5"/>
      <Setter Property="Fill" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="BigValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThInkBrush}"/>
      <Setter Property="FontSize" Value="30"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="MinWidth" Value="40"/>
      <Setter Property="Typography.NumeralAlignment" Value="Tabular"/>
    </Style>
    <Style x:Key="MidValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThInkBrush}"/>
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Typography.NumeralAlignment" Value="Tabular"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
    </Style>
    <Style x:Key="UnitLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThFaintBrush}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
      <Setter Property="Margin" Value="5,0,0,4"/>
    </Style>
    <Style x:Key="CardSub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThDimBrush}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="Kbd" TargetType="Border">
      <Setter Property="CornerRadius" Value="5"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#3A5573"/>
      <Setter Property="Background" Value="#182534"/>
      <Setter Property="Padding" Value="8,2,8,3"/>
      <Setter Property="Margin" Value="0,0,5,0"/>
      <Setter Property="MinWidth" Value="24"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="KbdText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#D2DBEA"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="TextAlignment" Value="Center"/>
    </Style>
    <Style x:Key="IconChip" TargetType="Border">
      <Setter Property="Width" Value="24"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="CornerRadius" Value="7"/>
      <Setter Property="Background" Value="#141B2A"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
    </Style>
    <Style x:Key="IconChipAccent" TargetType="Border" BasedOn="{StaticResource IconChip}">
      <Setter Property="Background" Value="{DynamicResource AccentSoftBrush}"/>
    </Style>
    <Style x:Key="ChipGlyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#AAB6CC"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="ChipGlyphAccent" TargetType="TextBlock" BasedOn="{StaticResource ChipGlyph}">
      <Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/>
    </Style>
    <Style x:Key="SegBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource ThDimBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="7"/>
              <Border x:Name="hov" Background="#12FFFFFF" CornerRadius="7" Opacity="0"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,10"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="hov" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="hov" Property="Opacity" Value="1"/>
                <Setter TargetName="hov" Property="Background" Value="#1CFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#0B0E14"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="bg" Background="{DynamicResource AccentBrush}" CornerRadius="9"/>
              <Border x:Name="sheen" CornerRadius="9" Opacity="0.35" IsHitTestVisible="False">
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#40FFFFFF" Offset="0"/>
                    <GradientStop Color="#00FFFFFF" Offset="0.55"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Border x:Name="dim" CornerRadius="9" Background="#000000" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="sheen" Property="Opacity" Value="0.55"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="dim" Property="Opacity" Value="0.18"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#8A93A6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" BorderBrush="#232C3E" BorderThickness="1" CornerRadius="9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#151C2A"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="#303A50"/>
                <Setter Property="Foreground" Value="#ECF0F7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1B2334"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- A context menu opens in its own popup, so it inherits neither the
         window's font nor its dark surfaces - both are set here. -->
    <Style x:Key="DarkMenu" TargetType="ContextMenu">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="FontFamily" Value="__FONTS__#Sora, Segoe UI"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="#141A24" BorderBrush="#26FFFFFF" BorderThickness="1" CornerRadius="8" Padding="4">
              <StackPanel IsItemsHost="True"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkMenuItem" TargetType="MenuItem">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Foreground" Value="#EDF1F8"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="bg" Background="Transparent" CornerRadius="5" Padding="10,6">
              <ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1FFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SubtleBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#8A93A6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" BorderBrush="#232C3E" BorderThickness="1" CornerRadius="7" Padding="12,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1B2232"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="#303A50"/>
                <Setter Property="Foreground" Value="#ECF0F7"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#151C2A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SetLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThDimBrush}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="SetValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThInkBrush}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Typography.NumeralAlignment" Value="Tabular"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
    </Style>
    <!-- Mode-panel slider tiles: setting name + big value up top, the
         slider full-width beneath, on its own inset surface. -->
    <Style x:Key="TileLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThDimBrush}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="TileValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThInkBrush}"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Typography.NumeralAlignment" Value="Tabular"/>
    </Style>
    <Style x:Key="TileUnit" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource ThDimBrush}"/>
      <Setter Property="FontSize" Value="9"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="2,0,0,2"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
    </Style>
    <Style x:Key="SetCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C9D2E2"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,10,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="18" Height="18" VerticalAlignment="Center">
                <Border x:Name="box" CornerRadius="5" Background="#0C1119" BorderBrush="#2B3447" BorderThickness="1.5"/>
                <Border x:Name="fill" CornerRadius="5" Background="{DynamicResource AccentBrush}" Opacity="0"/>
                <Path x:Name="check" Data="M 4.5 9.5 L 7.5 12.5 L 13.5 5.5" Stroke="#07090D" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Opacity="0"/>
              </Grid>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="fill" Property="Opacity" Value="1"/>
                <Setter TargetName="check" Property="Opacity" Value="1"/>
                <Setter TargetName="box" Property="BorderThickness" Value="0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="BorderBrush" Value="#41506C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Pill switch: the monitor panel's schedule toggle. Track lights up in
         the accent, knob slides right - reads as hardware, not a form field. -->
    <Style x:Key="PillSwitch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="42" Height="23" Background="Transparent">
              <Border x:Name="track" CornerRadius="11" Background="#0C1119" BorderBrush="#2B3447" BorderThickness="1.5"/>
              <Border x:Name="lit" CornerRadius="11" Background="{DynamicResource AccentBrush}" Opacity="0"/>
              <Ellipse x:Name="knob" Width="15" Height="15" Fill="#6B7789" HorizontalAlignment="Left" Margin="4,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="lit" Property="Opacity" Value="1"/>
                <Setter TargetName="track" Property="BorderThickness" Value="0"/>
                <Setter TargetName="knob" Property="Fill" Value="#FFFFFF"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Margin" Value="0,0,4,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="track" Property="BorderBrush" Value="#41506C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Small glyph/label chip used across the monitor panel's action row. -->
    <Style x:Key="ChipBtn" TargetType="Button" BasedOn="{StaticResource SubtleBtn}">
      <Setter Property="Height" Value="30"/>
    </Style>
    <Style x:Key="SetSlider" TargetType="Slider">
      <Setter Property="Foreground" Value="#4C8DFF"/>
      <Setter Property="IsSnapToTickEnabled" Value="True"/>
      <Setter Property="TickFrequency" Value="1"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="12,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <!-- The Sirocco board's thermo-bar language: a groove recessed into
               the tile (dark inner top shadow + 1px bottom light edge), the
               gradient fill inside it, and a white light-blade handle that
               stands proud of the track - the halo dot's slider sibling. -->
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center" Height="24">
              <Border Height="8" CornerRadius="4" VerticalAlignment="Center" Background="#52000000"
                      BorderBrush="#0DFFFFFF" BorderThickness="0,0,0,1">
                <Rectangle Height="3" VerticalAlignment="Top" RadiusX="4" RadiusY="2" Margin="1,0.5,1,0">
                  <Rectangle.Fill>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#59000000" Offset="0"/>
                      <GradientStop Color="#00000000" Offset="1"/>
                    </LinearGradientBrush>
                  </Rectangle.Fill>
                </Rectangle>
              </Border>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton IsTabStop="False" Command="Slider.DecreaseLarge">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Grid Height="6" Margin="1,0,0,0">
                          <Border CornerRadius="3"
                                  Background="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Slider}}"/>
                          <!-- 1px specular meniscus on the lit fill -->
                          <Rectangle Height="1" VerticalAlignment="Top" Margin="3,1,3,0" Fill="#30FFFFFF" RadiusX="0.5" RadiusY="0.5"/>
                        </Grid>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton IsTabStop="False" Command="Slider.IncreaseLarge">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="8" Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="11" Height="22">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid Background="Transparent">
                          <Rectangle x:Name="blade" Width="3.5" Height="16" RadiusX="1.75" RadiusY="1.75" Fill="#FFFFFF">
                            <Rectangle.Effect>
                              <DropShadowEffect ShadowDepth="0" BlurRadius="8" Opacity="0.65" Color="#FFFFFF"/>
                            </Rectangle.Effect>
                          </Rectangle>
                        </Grid>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="blade" Property="Width" Value="4.5"/>
                            <Setter TargetName="blade" Property="Height" Value="18"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Border CornerRadius="4" Background="#0C1119" Opacity="0.6"/>
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False" IsTabStop="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False" IsTabStop="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Focusable="False">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="tb" CornerRadius="4" Background="#2B3346" MinHeight="24" Margin="1,0"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="tb" Property="Background" Value="#3E4A66"/>
                          </Trigger>
                          <Trigger Property="IsDragging" Value="True">
                            <Setter TargetName="tb" Property="Background" Value="#4C5A7C"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="8"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Foreground" Value="#C9D2E2"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="#171E2D" BorderBrush="#2B3447" BorderThickness="1" CornerRadius="8" Padding="10,6">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="10">
    <Border x:Name="WinBase" CornerRadius="18" Background="#0A0D13">
      <Border.Effect>
        <DropShadowEffect ShadowDepth="0" BlurRadius="18" Opacity="0.55" Color="#000000"/>
      </Border.Effect>
    </Border>
    <Border x:Name="WinFrame" CornerRadius="18" BorderThickness="1">
      <Border.BorderBrush>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#2E3850" Offset="0"/>
          <GradientStop Color="#161C2A" Offset="1"/>
        </LinearGradientBrush>
      </Border.BorderBrush>
      <Border.Background>
        <RadialGradientBrush Center="0.5,0" GradientOrigin="0.5,0" RadiusX="0.9" RadiusY="0.55">
          <GradientStop Color="#14202E" Offset="0"/>
          <GradientStop Color="#0A0D13" Offset="1"/>
        </RadialGradientBrush>
      </Border.Background>
      <Border CornerRadius="17" BorderThickness="0,1,0,0" BorderBrush="#0FFFFFFF">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="48"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <!-- Title bar -->
          <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
            <StackPanel Orientation="Horizontal" Margin="18,0,0,0" VerticalAlignment="Center">
              <Grid Width="18" Height="18">
                <Path x:Name="LogoOuter" Fill="#4C8DFF" Stretch="Uniform"
                      Data="M12,12 C12,5.6 16.4,2.6 20.2,4.8 C17.6,9.2 14.6,11.2 12,12 Z M12,12 C17.54,15.2 17.94,20.51 14.14,22.7 C11.63,18.25 11.39,14.65 12,12 Z M12,12 C6.46,15.2 1.66,12.89 1.67,8.5 C6.78,8.55 10.01,10.15 12,12 Z"/>
                <Ellipse Width="4" Height="4" Fill="#07090D"/>
              </Grid>
              <TextBlock Text="V&#x200A;E&#x200A;N&#x200A;T&#x200A;O" FontSize="13" FontWeight="Bold" Foreground="{DynamicResource ThInkBrush}" Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0">
              <!-- Update pill: shown when a newer release exists; click = download
                   and silently install. The tray balloon is easy to miss - this is
                   the in-window indicator. -->
              <Border x:Name="UpdatePill" CornerRadius="8" BorderThickness="1" Padding="10,4" Margin="0,0,10,0" VerticalAlignment="Center"
                      Background="#1A6FB1FF" BorderBrush="#406FB1FF" Cursor="Hand" Visibility="Collapsed"
                      ToolTip="Download and install the new version">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Foreground="{DynamicResource AccentBrush}" FontFamily="Segoe MDL2 Assets" FontSize="10" Text="&#xE896;" VerticalAlignment="Center"/>
                  <TextBlock x:Name="UpdatePillText" Foreground="{DynamicResource AccentBrush}" FontSize="10" FontWeight="Bold"
                             Margin="7,0,0,0" VerticalAlignment="Center" Text="UPDATE"/>
                </StackPanel>
              </Border>
              <Border x:Name="StateBadge" CornerRadius="8" BorderThickness="1" Padding="10,4" Margin="0,0,10,0" VerticalAlignment="Center"
                      Background="#1A6FB1FF" BorderBrush="#406FB1FF">
                <StackPanel Orientation="Horizontal">
                  <Ellipse Width="7" Height="7" Fill="{DynamicResource AccentBrush}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="StateBadgeText" Foreground="{DynamicResource AccentBrush}" FontSize="10" FontWeight="Bold"
                             Margin="7,0,0,0" VerticalAlignment="Center" Text="STARTING"/>
                </StackPanel>
              </Border>
              <Button x:Name="BtnPods" Style="{StaticResource ChipTitleBtn}" ToolTip="AirPods battery" Margin="0,0,8,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE7F6;" VerticalAlignment="Center"/>
                  <TextBlock Text="PODS" FontSize="10" FontWeight="Bold" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnMonitors" Style="{StaticResource ChipTitleBtn}" ToolTip="Displays: brightness, color, profiles" Margin="0,0,8,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE7F4;" VerticalAlignment="Center"/>
                  <TextBlock Text="DISPLAYS" FontSize="10" FontWeight="Bold" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnSettings" Style="{StaticResource ChipTitleBtn}" ToolTip="Settings" Margin="0,0,8,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="15" Text="&#xE713;" VerticalAlignment="Center"/>
                  <TextBlock Text="SETTINGS" FontSize="10" FontWeight="Bold" Margin="8,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnMin" Style="{StaticResource TitleBtn}" Content="&#xE921;" ToolTip="Minimize to tray"/>
              <Button x:Name="BtnClose" Style="{StaticResource TitleBtnClose}" Content="&#xE8BB;" ToolTip="Close"/>
            </StackPanel>
            <Border Height="1" VerticalAlignment="Bottom" Margin="18,0">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0.5" EndPoint="1,0.5">
                  <GradientStop Color="#001E2736" Offset="0"/>
                  <GradientStop Color="#1E2736" Offset="0.5"/>
                  <GradientStop Color="#001E2736" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
            </Border>
          </Grid>

          <!-- Main content -->
          <Grid Grid.Row="1" Margin="16,4,16,0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Hero: thermal core + halo + mode selector -->
            <Grid Grid.Row="0" Height="212" Margin="2,0,2,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="216"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid Width="206" Height="206" HorizontalAlignment="Center" VerticalAlignment="Center">
                <!-- BitmapCache: the breathing opacity animation composites a cached
                     bitmap instead of re-rendering the gradient every frame -->
                <Ellipse x:Name="OrbGlow" Width="204" Height="204" Opacity="0.55" CacheMode="BitmapCache"/>
                <Canvas Width="206" Height="206">
                  <Path x:Name="HaloTrack" Stroke="{DynamicResource ThTrackBrush}" StrokeThickness="7"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                        Data="M 23.3,149 A 92,92 0 1 1 182.7,149"/>
                  <Path x:Name="HaloFill" StrokeThickness="7" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  <Ellipse x:Name="HaloDot" Width="9" Height="9" Fill="#FFFFFF" Visibility="Collapsed"/>
                </Canvas>
                <Ellipse x:Name="OrbCore" Width="150" Height="150" StrokeThickness="1.5"/>
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                  <TextBlock x:Name="OrbVal" FontSize="42" FontWeight="Bold" HorizontalAlignment="Center"
                             Typography.NumeralAlignment="Tabular" Foreground="#0A1A33" Text="--"/>
                  <TextBlock x:Name="OrbLabel" FontSize="10" FontWeight="Bold" HorizontalAlignment="Center"
                             Foreground="#9E0A1A33" Margin="0,1,0,0" Text=""/>
                </StackPanel>
              </Grid>
              <StackPanel Grid.Column="1" Margin="22,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="HeroTitle" FontSize="23" FontWeight="Bold" Foreground="{DynamicResource ThInkBrush}" Text="Starting sensors"/>
                <TextBlock x:Name="HeroSub" FontSize="12" Foreground="{DynamicResource ThDimBrush}" Margin="0,4,0,0" Text="waiting for the first readings"/>
                <StackPanel Orientation="Horizontal" Margin="1,12,0,0">
                  <TextBlock x:Name="LabCool" FontSize="9" FontWeight="Bold" Foreground="{DynamicResource ThFaintBrush}" Text="C O O L"/>
                  <TextBlock x:Name="LabWarm" FontSize="9" FontWeight="Bold" Foreground="{DynamicResource ThFaintBrush}" Margin="18,0,0,0" Text="W A R M"/>
                  <TextBlock x:Name="LabHot" FontSize="9" FontWeight="Bold" Foreground="{DynamicResource ThFaintBrush}" Margin="18,0,0,0" Text="H O T"/>
                </StackPanel>
                <Border x:Name="ModeShell" Background="{DynamicResource ThTileBrush}" BorderThickness="1" BorderBrush="#246FB1FF" CornerRadius="12" Padding="3" Margin="0,14,0,0" HorizontalAlignment="Left">
                  <UniformGrid Columns="5" Width="426">
                    <Button x:Name="BtnQuiet"  Style="{StaticResource SegBtn}" Content="Quiet"/>
                    <Button x:Name="BtnNormal" Style="{StaticResource SegBtn}" Content="Normal"/>
                    <Button x:Name="BtnPerf"   Style="{StaticResource SegBtn}" Content="Perf"/>
                    <Button x:Name="BtnCurve"  Style="{StaticResource SegBtn}" Content="Curve"/>
                    <Button x:Name="BtnAuto"   Style="{StaticResource SegBtn}" Content="Auto"/>
                  </UniformGrid>
                </Border>
              </StackPanel>
            </Grid>

            <!-- section: temperatures -->
            <Grid Grid.Row="1" Margin="2,10,2,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Style="{StaticResource CardTitle}" Foreground="{DynamicResource ThFaintBrush}" Text="T E M P E R A T U R E S"/>
              <Border Grid.Column="1" x:Name="SectLine1" Height="1" Margin="10,0,0,0" VerticalAlignment="Center" Background="#226FB1FF"/>
            </Grid>

            <!-- Temperatures: four tiles -->
            <Grid Grid.Row="2" Margin="0,6,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,8,0">
                <Grid>
                  <Border x:Name="CpuHair" Height="1.5" VerticalAlignment="Top" Margin="10,0" CornerRadius="1"/>
                  <Border Style="{StaticResource CardInner}" Padding="12,10">
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <Border Style="{StaticResource IconChip}" Width="20" Height="20" CornerRadius="6" Background="{DynamicResource AccentSoftBrush}" VerticalAlignment="Center">
                          <TextBlock Style="{StaticResource ChipGlyph}" FontSize="11" Foreground="{DynamicResource AccentBrush}" Text="&#xE950;"/>
                        </Border>
                        <TextBlock Style="{StaticResource CardTitle}" Text="CPU" Margin="7,0,0,0" VerticalAlignment="Center"/>
                        <Border x:Name="CpuWarnFlag" CornerRadius="4" Padding="5,1" Margin="7,0,0,0" VerticalAlignment="Center"
                                Background="{DynamicResource AccentSoftBrush}" Visibility="Collapsed">
                          <TextBlock x:Name="CpuWarnText" FontSize="8" FontWeight="Bold" Foreground="{DynamicResource AccentBrush}" Text=""/>
                        </Border>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                        <TextBlock x:Name="CpuTempVal" Style="{StaticResource BigValue}" Text="--"/>
                        <TextBlock Text="&#176;" Foreground="{DynamicResource ThFaintBrush}" FontSize="15" FontWeight="SemiBold" Margin="2,2,0,0"/>
                      </StackPanel>
                      <TextBlock x:Name="CpuNameText" Style="{StaticResource CardSub}" Text="Processor" Margin="0,1,0,0"/>
                      <Grid x:Name="CpuSparkHost" Height="18" Margin="0,7,0,0" ClipToBounds="True">
                        <Polygon x:Name="CpuSparkFill"/>
                        <Polyline x:Name="CpuSpark" StrokeThickness="1.5" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                      </Grid>
                    </StackPanel>
                  </Border>
                </Grid>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,8,0">
                <Grid>
                  <Border x:Name="GpuHair" Height="1.5" VerticalAlignment="Top" Margin="10,0" CornerRadius="1"/>
                  <Border Style="{StaticResource CardInner}" Padding="12,10">
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <Border Style="{StaticResource IconChip}" Width="20" Height="20" CornerRadius="6" Background="{DynamicResource AccentSoftBrush}" VerticalAlignment="Center">
                          <TextBlock Style="{StaticResource ChipGlyph}" FontSize="11" Foreground="{DynamicResource AccentBrush}" Text="&#xE7F4;"/>
                        </Border>
                        <TextBlock Style="{StaticResource CardTitle}" Text="GPU" Margin="7,0,0,0" VerticalAlignment="Center"/>
                        <Border x:Name="GpuWarnFlag" CornerRadius="4" Padding="5,1" Margin="7,0,0,0" VerticalAlignment="Center"
                                Background="{DynamicResource AccentSoftBrush}" Visibility="Collapsed">
                          <TextBlock x:Name="GpuWarnText" FontSize="8" FontWeight="Bold" Foreground="{DynamicResource AccentBrush}" Text=""/>
                        </Border>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                        <TextBlock x:Name="GpuTempVal" Style="{StaticResource BigValue}" Text="--"/>
                        <TextBlock Text="&#176;" Foreground="{DynamicResource ThFaintBrush}" FontSize="15" FontWeight="SemiBold" Margin="2,2,0,0"/>
                      </StackPanel>
                      <TextBlock x:Name="GpuNameText" Style="{StaticResource CardSub}" Text="Graphics card" Margin="0,1,0,0"/>
                      <Grid x:Name="GpuSparkHost" Height="18" Margin="0,7,0,0" ClipToBounds="True">
                        <Polygon x:Name="GpuSparkFill"/>
                        <Polyline x:Name="GpuSpark" StrokeThickness="1.5" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                      </Grid>
                    </StackPanel>
                  </Border>
                </Grid>
              </Border>
              <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0,0,8,0">
                <Grid>
                  <Border x:Name="SsdHair" Height="1.5" VerticalAlignment="Top" Margin="10,0" CornerRadius="1"/>
                  <Border Style="{StaticResource CardInner}" Padding="12,10">
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <Border Style="{StaticResource IconChip}" Width="20" Height="20" CornerRadius="6" Background="{DynamicResource AccentSoftBrush}" VerticalAlignment="Center">
                          <TextBlock Style="{StaticResource ChipGlyph}" FontSize="11" Foreground="{DynamicResource AccentBrush}" Text="&#xEDA2;"/>
                        </Border>
                        <TextBlock Style="{StaticResource CardTitle}" Text="SSD" Margin="7,0,0,0" VerticalAlignment="Center"/>
                        <Border x:Name="SsdWarnFlag" CornerRadius="4" Padding="5,1" Margin="7,0,0,0" VerticalAlignment="Center"
                                Background="{DynamicResource AccentSoftBrush}" Visibility="Collapsed">
                          <TextBlock x:Name="SsdWarnText" FontSize="8" FontWeight="Bold" Foreground="{DynamicResource AccentBrush}" Text=""/>
                        </Border>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                        <TextBlock x:Name="SsdTempVal" Style="{StaticResource BigValue}" Text="--"/>
                        <TextBlock Text="&#176;" Foreground="{DynamicResource ThFaintBrush}" FontSize="15" FontWeight="SemiBold" Margin="2,2,0,0"/>
                      </StackPanel>
                      <TextBlock x:Name="SsdNameText" Style="{StaticResource CardSub}" Text="Drive" Margin="0,1,0,0"/>
                      <Grid x:Name="SsdSparkHost" Height="18" Margin="0,7,0,0" ClipToBounds="True">
                        <Polygon x:Name="SsdSparkFill"/>
                        <Polyline x:Name="SsdSpark" StrokeThickness="1.5" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                      </Grid>
                    </StackPanel>
                  </Border>
                </Grid>
              </Border>
              <Border Grid.Column="3" Style="{StaticResource Card}">
                <Grid>
                  <Border x:Name="MbHair" Height="1.5" VerticalAlignment="Top" Margin="10,0" CornerRadius="1"/>
                  <Border Style="{StaticResource CardInner}" Padding="12,10">
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <Border Style="{StaticResource IconChip}" Width="20" Height="20" CornerRadius="6" Background="{DynamicResource AccentSoftBrush}" VerticalAlignment="Center">
                          <TextBlock Style="{StaticResource ChipGlyph}" FontSize="11" Foreground="{DynamicResource AccentBrush}" Text="&#xE977;"/>
                        </Border>
                        <TextBlock Style="{StaticResource CardTitle}" Text="BOARD" Margin="7,0,0,0" VerticalAlignment="Center"/>
                        <Border x:Name="MbWarnFlag" CornerRadius="4" Padding="5,1" Margin="7,0,0,0" VerticalAlignment="Center"
                                Background="{DynamicResource AccentSoftBrush}" Visibility="Collapsed">
                          <TextBlock x:Name="MbWarnText" FontSize="8" FontWeight="Bold" Foreground="{DynamicResource AccentBrush}" Text=""/>
                        </Border>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" Margin="0,3,0,0">
                        <TextBlock x:Name="MbTempVal" Style="{StaticResource BigValue}" Text="--"/>
                        <TextBlock Text="&#176;" Foreground="{DynamicResource ThFaintBrush}" FontSize="15" FontWeight="SemiBold" Margin="2,2,0,0"/>
                      </StackPanel>
                      <TextBlock x:Name="MbNameText" Style="{StaticResource CardSub}" Text="Motherboard" Margin="0,1,0,0"/>
                      <Grid x:Name="MbSparkHost" Height="18" Margin="0,7,0,0" ClipToBounds="True">
                        <Polygon x:Name="MbSparkFill"/>
                        <Polyline x:Name="MbSpark" StrokeThickness="1.5" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                      </Grid>
                    </StackPanel>
                  </Border>
                </Grid>
              </Border>
            </Grid>


            <!-- section: fans -->
            <Grid Grid.Row="3" Margin="2,10,2,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Style="{StaticResource CardTitle}" Foreground="{DynamicResource ThFaintBrush}" Text="F A N S"/>
              <Border Grid.Column="1" x:Name="SectLine2" Height="1" Margin="10,0,0,0" VerticalAlignment="Center" Background="#226FB1FF"/>
            </Grid>

            <!-- Fans -->
            <Grid Grid.Row="4" Margin="0,6,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,8,0">
                <Border Style="{StaticResource CardInner}" Padding="12,10">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Border Style="{StaticResource IconChip}" Width="20" Height="20" CornerRadius="6" Background="{DynamicResource AccentSoftBrush}" VerticalAlignment="Center">
                        <Grid Width="14" Height="14">
                          <Ellipse Stroke="{DynamicResource AccentBrush}" StrokeThickness="1" Opacity="0.55"/>
                          <!-- BitmapCache: the spin rotates a cached bitmap on the render
                               thread; without it every frame re-renders the card subtree -->
                          <Path x:Name="RotorCpu" Fill="{DynamicResource AccentBrush}" Stretch="Uniform" Margin="1.5" RenderTransformOrigin="0.5,0.5"
                                Data="M 12,10.8 Q 14.4,5.6 17.6,8.6 Q 15,11 12,10.8 Z M 13.04,12.6 Q 16.34,17.28 12.14,18.55 Q 11.37,15.1 13.04,12.6 Z M 10.96,12.6 Q 5.26,13.12 6.26,8.85 Q 9.63,9.9 10.96,12.6 Z">
                            <Path.CacheMode><BitmapCache RenderAtScale="2"/></Path.CacheMode>
                          </Path>
                        </Grid>
                      </Border>
                      <TextBlock Style="{StaticResource CardTitle}" Text="CPU FAN" Margin="7,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock x:Name="CpuFanVal" Style="{StaticResource MidValue}" Text="--"/>
                      <TextBlock Style="{StaticResource UnitLabel}" Text="RPM"/>
                    </StackPanel>
                    <Border x:Name="CpuFanRailTrack" Height="3" CornerRadius="2" Background="{DynamicResource ThTrackBrush}" Margin="0,8,0,2">
                      <Border x:Name="CpuFanRail" Height="3" CornerRadius="2" HorizontalAlignment="Left" Width="0" Background="{DynamicResource AccentBrush}"/>
                    </Border>
                  </StackPanel>
                </Border>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,8,0">
                <Border Style="{StaticResource CardInner}" Padding="12,10">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Border Style="{StaticResource IconChip}" Width="20" Height="20" CornerRadius="6" Background="{DynamicResource AccentSoftBrush}" VerticalAlignment="Center">
                        <Grid Width="14" Height="14">
                          <Ellipse Stroke="{DynamicResource AccentBrush}" StrokeThickness="1" Opacity="0.55"/>
                          <Path x:Name="RotorCase" Fill="{DynamicResource AccentBrush}" Stretch="Uniform" Margin="1.5" RenderTransformOrigin="0.5,0.5"
                                Data="M 12,10.8 Q 14.4,5.6 17.6,8.6 Q 15,11 12,10.8 Z M 13.04,12.6 Q 16.34,17.28 12.14,18.55 Q 11.37,15.1 13.04,12.6 Z M 10.96,12.6 Q 5.26,13.12 6.26,8.85 Q 9.63,9.9 10.96,12.6 Z">
                            <Path.CacheMode><BitmapCache RenderAtScale="2"/></Path.CacheMode>
                          </Path>
                        </Grid>
                      </Border>
                      <TextBlock Style="{StaticResource CardTitle}" Text="CASE FANS" Margin="7,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock x:Name="CaseFanVal" Style="{StaticResource MidValue}" Text="--"/>
                      <TextBlock Style="{StaticResource UnitLabel}" Text="RPM"/>
                    </StackPanel>
                    <Border x:Name="CaseFanRailTrack" Height="3" CornerRadius="2" Background="{DynamicResource ThTrackBrush}" Margin="0,8,0,2">
                      <Border x:Name="CaseFanRail" Height="3" CornerRadius="2" HorizontalAlignment="Left" Width="0" Background="{DynamicResource AccentBrush}"/>
                    </Border>
                  </StackPanel>
                </Border>
              </Border>
              <Border Grid.Column="2" Style="{StaticResource Card}">
                <Border Style="{StaticResource CardInner}" Padding="12,10">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Border Style="{StaticResource IconChip}" Width="20" Height="20" CornerRadius="6" Background="{DynamicResource AccentSoftBrush}" VerticalAlignment="Center">
                        <Grid Width="14" Height="14">
                          <Ellipse Stroke="{DynamicResource AccentBrush}" StrokeThickness="1" Opacity="0.55"/>
                          <Path x:Name="RotorGpu" Fill="{DynamicResource AccentBrush}" Stretch="Uniform" Margin="1.5" RenderTransformOrigin="0.5,0.5"
                                Data="M 12,10.8 Q 14.4,5.6 17.6,8.6 Q 15,11 12,10.8 Z M 13.04,12.6 Q 16.34,17.28 12.14,18.55 Q 11.37,15.1 13.04,12.6 Z M 10.96,12.6 Q 5.26,13.12 6.26,8.85 Q 9.63,9.9 10.96,12.6 Z">
                            <Path.CacheMode><BitmapCache RenderAtScale="2"/></Path.CacheMode>
                          </Path>
                        </Grid>
                      </Border>
                      <TextBlock Style="{StaticResource CardTitle}" Text="GPU FANS" Margin="7,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock x:Name="GpuFanVal" Style="{StaticResource MidValue}" Text="--"/>
                      <TextBlock Style="{StaticResource UnitLabel}" Text="RPM"/>
                    </StackPanel>
                    <Border x:Name="GpuFanRailTrack" Height="3" CornerRadius="2" Background="{DynamicResource ThTrackBrush}" Margin="0,8,0,2">
                      <Border x:Name="GpuFanRail" Height="3" CornerRadius="2" HorizontalAlignment="Left" Width="0" Background="{DynamicResource AccentBrush}"/>
                    </Border>
                  </StackPanel>
                </Border>
              </Border>
            </Grid>

            <!-- Mode panel: live settings for the active mode + fan activity -->
            <Border Grid.Row="5" Style="{StaticResource Card}" Margin="0,10,0,2">
              <Border Style="{StaticResource CardInner}">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                  </Grid.RowDefinitions>
                  <Grid Grid.Row="0">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                      <Rectangle Style="{StaticResource AccentTick}"/>
                      <TextBlock x:Name="ModeSetTitle" Style="{StaticResource CardTitle}" Text="MODE" Margin="7,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <Button x:Name="BtnModeReset" Style="{StaticResource SubtleBtn}" Content="Reset" Width="64"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,-8,0,-8"
                            ToolTip="Restore this mode's default settings"/>
                  </Grid>
                  <TextBlock Grid.Row="1" x:Name="ModeSetHint" Style="{StaticResource CardSub}" Text="" TextWrapping="Wrap" Visibility="Collapsed"/>
                  <Grid Grid.Row="2" x:Name="ModeSlots" Margin="0,10,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="8"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Border x:Name="Slot1" Grid.Row="0" Grid.Column="0" CornerRadius="10" Padding="11,7,11,9"
                            Background="{DynamicResource ThTrackBrush}" BorderThickness="1" Visibility="Collapsed">
                      <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid Grid.Row="0">
                          <TextBlock x:Name="ML1" Style="{StaticResource TileLabel}"/>
                          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <TextBlock x:Name="MV1" Style="{StaticResource TileValue}"/>
                            <TextBlock x:Name="MU1" Style="{StaticResource TileUnit}"/>
                          </StackPanel>
                        </Grid>
                        <Slider Grid.Row="1" x:Name="MS1" Style="{StaticResource SetSlider}" Margin="0,5,0,0" Minimum="20" Maximum="100"/>
                      </Grid>
                    </Border>
                    <Border x:Name="Slot2" Grid.Row="0" Grid.Column="2" CornerRadius="10" Padding="11,7,11,9"
                            Background="{DynamicResource ThTrackBrush}" BorderThickness="1" Visibility="Collapsed">
                      <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid Grid.Row="0">
                          <TextBlock x:Name="ML2" Style="{StaticResource TileLabel}"/>
                          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <TextBlock x:Name="MV2" Style="{StaticResource TileValue}"/>
                            <TextBlock x:Name="MU2" Style="{StaticResource TileUnit}"/>
                          </StackPanel>
                        </Grid>
                        <Slider Grid.Row="1" x:Name="MS2" Style="{StaticResource SetSlider}" Margin="0,5,0,0" Minimum="20" Maximum="100"/>
                      </Grid>
                    </Border>
                    <Border x:Name="Slot3" Grid.Row="1" Grid.Column="0" CornerRadius="10" Padding="11,7,11,9" Margin="0,8,0,0"
                            Background="{DynamicResource ThTrackBrush}" BorderThickness="1" Visibility="Collapsed">
                      <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid Grid.Row="0">
                          <TextBlock x:Name="ML3" Style="{StaticResource TileLabel}"/>
                          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <TextBlock x:Name="MV3" Style="{StaticResource TileValue}"/>
                            <TextBlock x:Name="MU3" Style="{StaticResource TileUnit}"/>
                          </StackPanel>
                        </Grid>
                        <Slider Grid.Row="1" x:Name="MS3" Style="{StaticResource SetSlider}" Margin="0,5,0,0" Minimum="20" Maximum="100"/>
                      </Grid>
                    </Border>
                    <Border x:Name="Slot4" Grid.Row="1" Grid.Column="2" CornerRadius="10" Padding="11,7,11,9" Margin="0,8,0,0"
                            Background="{DynamicResource ThTrackBrush}" BorderThickness="1" Visibility="Collapsed">
                      <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid Grid.Row="0">
                          <TextBlock x:Name="ML4" Style="{StaticResource TileLabel}"/>
                          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                            <TextBlock x:Name="MV4" Style="{StaticResource TileValue}"/>
                            <TextBlock x:Name="MU4" Style="{StaticResource TileUnit}"/>
                          </StackPanel>
                        </Grid>
                        <Slider Grid.Row="1" x:Name="MS4" Style="{StaticResource SetSlider}" Margin="0,5,0,0" Minimum="20" Maximum="100"/>
                      </Grid>
                    </Border>
                  </Grid>
                  <Grid Grid.Row="3" Margin="0,10,0,0">
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid>
                      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="FAN ACTIVITY" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Ellipse x:Name="LegCpuDot" Width="7" Height="7" Fill="#D8E4F2" VerticalAlignment="Center"/>
                        <TextBlock Text="CPU fan" Foreground="{DynamicResource ThDimBrush}" FontSize="10" Margin="6,0,14,0" VerticalAlignment="Center"/>
                        <Ellipse x:Name="LegCaseDot" Width="7" Height="7" Fill="#6FB1FF" VerticalAlignment="Center"/>
                        <TextBlock Text="Case fans" Foreground="{DynamicResource ThDimBrush}" FontSize="10" Margin="6,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Grid>
                    <Grid Grid.Row="1" Margin="0,8,0,0">
                      <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                      </Grid.RowDefinitions>
                      <Grid MinHeight="36">
                        <Grid>
                          <Grid.RowDefinitions>
                            <RowDefinition/>
                            <RowDefinition/>
                            <RowDefinition/>
                            <RowDefinition/>
                          </Grid.RowDefinitions>
                          <Border Grid.Row="0" BorderBrush="{DynamicResource ThGridBrush}" BorderThickness="0,0,0,1"/>
                          <Border Grid.Row="1" BorderBrush="{DynamicResource ThGridBrush}" BorderThickness="0,0,0,1"/>
                          <Border Grid.Row="2" BorderBrush="{DynamicResource ThGridBrush}" BorderThickness="0,0,0,1"/>
                          <Border Grid.Row="3" BorderBrush="{DynamicResource ThGridBrush}" BorderThickness="0,0,0,1"/>
                          <TextBlock Grid.Row="0" x:Name="AxR0" FontSize="8" Foreground="{DynamicResource ThFaintBrush}" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,2,1" Typography.NumeralAlignment="Tabular" Text=""/>
                          <TextBlock Grid.Row="1" x:Name="AxR1" FontSize="8" Foreground="{DynamicResource ThFaintBrush}" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,2,1" Typography.NumeralAlignment="Tabular" Text=""/>
                          <TextBlock Grid.Row="2" x:Name="AxR2" FontSize="8" Foreground="{DynamicResource ThFaintBrush}" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,2,1" Typography.NumeralAlignment="Tabular" Text=""/>
                        </Grid>
                        <Grid x:Name="FanSparkHost" Background="Transparent" ClipToBounds="True" Margin="0,3,0,0">
                          <Polygon x:Name="CpuFanSparkFill"/>
                          <Polygon x:Name="CaseFanSparkFill"/>
                          <Polyline x:Name="CaseFanSpark" StrokeThickness="1.5" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                          <Polyline x:Name="CpuFanSpark" StrokeThickness="1.5" StrokeLineJoin="Round" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                        </Grid>
                      </Grid>
                      <Grid Grid.Row="1" Margin="0,4,0,0">
                        <TextBlock FontSize="8" Foreground="{DynamicResource ThFaintBrush}" Text="10 min ago"/>
                        <TextBlock FontSize="8" Foreground="{DynamicResource ThFaintBrush}" HorizontalAlignment="Right" Text="now"/>
                      </Grid>
                    </Grid>
                  </Grid>
                </Grid>
              </Border>
            </Border>
          </Grid>

          <!-- Footer -->
          <Grid Grid.Row="2" Margin="18,10,18,12">
            <Border x:Name="FooterPill" Background="{DynamicResource ThTileBrush}" BorderBrush="#246FB1FF" BorderThickness="1" CornerRadius="999" Padding="11,5" HorizontalAlignment="Left" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="StatusDot" Width="7" Height="7" Fill="#566073" VerticalAlignment="Center"/>
                <TextBlock x:Name="StatusText" Foreground="#8A93A6" FontSize="11" Margin="7,0,0,0" MinWidth="150"
                           Typography.NumeralAlignment="Tabular" Text="Starting sensors..."/>
              </StackPanel>
            </Border>
            <TextBlock x:Name="WarnText" Foreground="#F26D78" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center" Text=""/>
          </Grid>

          <!-- Settings overlay -->
          <!-- Update banner: drops in from the top when a newer release exists.
               Later tucks it away; the title-bar pill remains as the anchor. -->
          <Border x:Name="UpdateBanner" Grid.Row="1" Grid.RowSpan="2" VerticalAlignment="Top" HorizontalAlignment="Center"
                  Margin="0,10,0,0" CornerRadius="12" BorderThickness="1" Padding="16,10" Visibility="Collapsed" Opacity="0"
                  Background="{DynamicResource ThTileBrush}" BorderBrush="{DynamicResource AccentBrush}">
            <Border.Effect>
              <DropShadowEffect ShadowDepth="6" Direction="270" BlurRadius="18" Opacity="0.5" Color="#000000"/>
            </Border.Effect>
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="{DynamicResource AccentBrush}" Text="&#xE896;" VerticalAlignment="Center"/>
              <TextBlock x:Name="UpdateBannerText" Foreground="{DynamicResource ThInkBrush}" FontSize="13" FontWeight="SemiBold"
                         Margin="10,0,16,0" VerticalAlignment="Center" Text="Update available"/>
              <Button x:Name="BtnUpdateNow" Style="{StaticResource PrimaryBtn}" Content="Install now" Width="104" Height="30"/>
              <Button x:Name="BtnUpdateLater" Style="{StaticResource GhostBtn}" Content="Later" Width="64" Height="30" Margin="6,0,0,0"/>
            </StackPanel>
          </Border>
          <Border x:Name="SettingsOverlay" Grid.Row="1" Grid.RowSpan="2" Background="#E607090D" Visibility="Collapsed">
            <Border Style="{StaticResource Card}" Margin="16,8,16,14">
              <Border Style="{StaticResource CardInner}" Padding="20,16">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <StackPanel Orientation="Horizontal">
                    <Rectangle Style="{StaticResource AccentTick}"/>
                    <TextBlock Style="{StaticResource CardTitle}" Text="SETTINGS" Margin="7,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,6,0,0">
                    <StackPanel Margin="0,0,6,0">
                      <StackPanel Orientation="Horizontal" Margin="0,6,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="FAN SPEEDS" Foreground="#4C8DFF" x:Name="SecFans" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Quiet - case fans"/>
                        <Slider Grid.Column="1" x:Name="S_QuietCase" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_QuietCase" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Normal - case fans"/>
                        <Slider Grid.Column="1" x:Name="S_NormalCase" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_NormalCase" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Performance - case fans"/>
                        <Slider Grid.Column="1" x:Name="S_PerfCase" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_PerfCase" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Performance - CPU fan"/>
                        <Slider Grid.Column="1" x:Name="S_PerfCpu" Style="{StaticResource SetSlider}" Minimum="30" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_PerfCpu" Style="{StaticResource SetValue}"/>
                      </Grid>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="COOLING BOOST" Foreground="#4C8DFF" x:Name="SecBoost" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <CheckBox x:Name="S_BoostEnabled" Style="{StaticResource SetCheck}" Content="In Quiet mode: raise fans when hot, return when cool"/>
                      <Grid Margin="0,9,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Boost above (CPU/GPU)"/>
                        <Slider Grid.Column="1" x:Name="S_BoostHigh" Style="{StaticResource SetSlider}" Minimum="60" Maximum="90"/>
                        <TextBlock Grid.Column="2" x:Name="V_BoostHigh" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Resume below"/>
                        <Slider Grid.Column="1" x:Name="S_BoostLow" Style="{StaticResource SetSlider}" Minimum="40" Maximum="85"/>
                        <TextBlock Grid.Column="2" x:Name="V_BoostLow" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Boost - case fans"/>
                        <Slider Grid.Column="1" x:Name="S_BoostCase" Style="{StaticResource SetSlider}" Minimum="30" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_BoostCase" Style="{StaticResource SetValue}"/>
                      </Grid>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="CURVE MODE" Foreground="#4C8DFF" x:Name="SecCurve" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Case fans at 40&#176;C"/>
                        <Slider Grid.Column="1" x:Name="S_C40" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_C40" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Case fans at 55&#176;C"/>
                        <Slider Grid.Column="1" x:Name="S_C55" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_C55" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Case fans at 70&#176;C"/>
                        <Slider Grid.Column="1" x:Name="S_C70" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_C70" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Case fans at 80&#176;C"/>
                        <Slider Grid.Column="1" x:Name="S_C80" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_C80" Style="{StaticResource SetValue}"/>
                      </Grid>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="GAME BOOST" Foreground="#4C8DFF" x:Name="SecGame" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <TextBlock Style="{StaticResource SetLabel}" Text="When a game is detected (GPU load based)" Margin="0,8,0,0"/>
                      <Border x:Name="GameActShell" Background="{DynamicResource ThTileBrush}" BorderThickness="1" BorderBrush="#246FB1FF" CornerRadius="10" Padding="3" Margin="0,6,0,0" HorizontalAlignment="Left">
                        <UniformGrid Columns="3" Width="336">
                          <Button x:Name="S_GameActPerf"  Style="{StaticResource SegBtn}" Content="Performance"/>
                          <Button x:Name="S_GameActCurve" Style="{StaticResource SegBtn}" Content="Curve"/>
                          <Button x:Name="S_GameActOff"   Style="{StaticResource SegBtn}" Content="Do nothing"/>
                        </UniformGrid>
                      </Border>
                      <StackPanel x:Name="GameSliders">
                        <Grid Margin="0,9,0,0">
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                          </Grid.ColumnDefinitions>
                          <TextBlock Style="{StaticResource SetLabel}" Text="Trigger - GPU load above"/>
                          <Slider Grid.Column="1" x:Name="S_GameLoad" Style="{StaticResource SetSlider}" Minimum="50" Maximum="100"/>
                          <TextBlock Grid.Column="2" x:Name="V_GameLoad" Style="{StaticResource SetValue}"/>
                        </Grid>
                        <Grid Margin="0,7,0,0">
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                          </Grid.ColumnDefinitions>
                          <TextBlock Style="{StaticResource SetLabel}" Text="Post-game cooldown"/>
                          <Slider Grid.Column="1" x:Name="S_GameCool" Style="{StaticResource SetSlider}" Minimum="0" Maximum="60"/>
                          <TextBlock Grid.Column="2" x:Name="V_GameCool" Style="{StaticResource SetValue}"/>
                        </Grid>
                      </StackPanel>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="OVERLAY (OSD)" Foreground="#4C8DFF" x:Name="SecOsd" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <TextBlock Style="{StaticResource CardSub}" Text="A small always-on-top readout for games. Works over borderless and windowed games; true exclusive fullscreen hides it." Margin="0,2,0,0" TextWrapping="Wrap"/>
                      <Grid Margin="0,8,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Show overlay"/>
                        <Border Grid.Column="1" x:Name="OsdModeShell" Background="{DynamicResource ThTileBrush}" BorderThickness="1" BorderBrush="#246FB1FF" CornerRadius="10" Padding="3" HorizontalAlignment="Left">
                          <UniformGrid Columns="3" Width="300">
                            <Button x:Name="O_ModeAuto" Style="{StaticResource SegBtn}" Content="While gaming"/>
                            <Button x:Name="O_ModeOn"   Style="{StaticResource SegBtn}" Content="Always"/>
                            <Button x:Name="O_ModeOff"  Style="{StaticResource SegBtn}" Content="Off"/>
                          </UniformGrid>
                        </Border>
                      </Grid>
                      <TextBlock Style="{StaticResource SetLabel}" Text="Layout" Margin="0,10,0,0"/>
                      <Border x:Name="OsdLayoutShell" Background="{DynamicResource ThTileBrush}" BorderThickness="1" BorderBrush="#246FB1FF" CornerRadius="10" Padding="3" Margin="0,4,0,0" HorizontalAlignment="Left">
                        <UniformGrid Columns="7" Width="595">
                          <Button x:Name="O_LayBlade"  Style="{StaticResource SegBtn}" Content="Blade"/>
                          <Button x:Name="O_LayStrip"  Style="{StaticResource SegBtn}" Content="Strip"/>
                          <Button x:Name="O_LayHero"   Style="{StaticResource SegBtn}" Content="Hero"/>
                          <Button x:Name="O_LayPills"  Style="{StaticResource SegBtn}" Content="Pills"/>
                          <Button x:Name="O_LayGhost"  Style="{StaticResource SegBtn}" Content="Ghost"/>
                          <Button x:Name="O_LayMicro"  Style="{StaticResource SegBtn}" Content="Micro"/>
                          <Button x:Name="O_LayThermo" Style="{StaticResource SegBtn}" Content="Thermo"/>
                        </UniformGrid>
                      </Border>
                      <TextBlock Style="{StaticResource SetLabel}" Text="Theme" Margin="0,10,0,0"/>
                      <Border x:Name="OsdThemeShell" Background="{DynamicResource ThTileBrush}" BorderThickness="1" BorderBrush="#246FB1FF" CornerRadius="10" Padding="3" Margin="0,4,0,0" HorizontalAlignment="Left">
                        <UniformGrid Columns="6" Width="510">
                          <Button x:Name="O_ThSirocco" Style="{StaticResource SegBtn}" Content="Ice"/>
                          <Button x:Name="O_ThEmber"   Style="{StaticResource SegBtn}" Content="Ember"/>
                          <Button x:Name="O_ThVenom"   Style="{StaticResource SegBtn}" Content="Venom"/>
                          <Button x:Name="O_ThViolet"  Style="{StaticResource SegBtn}" Content="Violet"/>
                          <Button x:Name="O_ThCrimson" Style="{StaticResource SegBtn}" Content="Crimson"/>
                          <Button x:Name="O_ThMono"    Style="{StaticResource SegBtn}" Content="Mono"/>
                        </UniformGrid>
                      </Border>
                      <TextBlock Style="{StaticResource SetLabel}" Text="Preview" Margin="0,10,0,0"/>
                      <Border x:Name="OsdPreviewFrame" CornerRadius="10" Margin="0,4,0,0" Height="150" ClipToBounds="True" BorderThickness="1" BorderBrush="#1AFFFFFF">
                        <Border.Background>
                          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                            <GradientStop Color="#131A25" Offset="0"/>
                            <GradientStop Color="#0B0F16" Offset="0.6"/>
                            <GradientStop Color="#121722" Offset="1"/>
                          </LinearGradientBrush>
                        </Border.Background>
                        <Grid x:Name="OsdPreviewHost">
                          <TextBlock Text="( game )" Foreground="#1FFFFFFF" FontSize="18" FontWeight="Light" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                      </Border>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Corner"/>
                        <Border Grid.Column="1" x:Name="OsdCornerShell" Background="{DynamicResource ThTileBrush}" BorderThickness="1" BorderBrush="#246FB1FF" CornerRadius="10" Padding="3" HorizontalAlignment="Left">
                          <UniformGrid Columns="4" Width="300">
                            <Button x:Name="O_CorTL" Style="{StaticResource SegBtn}" Content="Top L"/>
                            <Button x:Name="O_CorTR" Style="{StaticResource SegBtn}" Content="Top R"/>
                            <Button x:Name="O_CorBL" Style="{StaticResource SegBtn}" Content="Bot L"/>
                            <Button x:Name="O_CorBR" Style="{StaticResource SegBtn}" Content="Bot R"/>
                          </UniformGrid>
                        </Border>
                      </Grid>
                      <Grid Margin="0,9,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Size"/>
                        <Slider Grid.Column="1" x:Name="S_OsdScale" Style="{StaticResource SetSlider}" Minimum="75" Maximum="200"/>
                        <TextBlock Grid.Column="2" x:Name="V_OsdScale" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Opacity"/>
                        <Slider Grid.Column="1" x:Name="S_OsdOpacity" Style="{StaticResource SetSlider}" Minimum="30" Maximum="100"/>
                        <TextBlock Grid.Column="2" x:Name="V_OsdOpacity" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,9,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Position"/>
                        <StackPanel Grid.Column="1" Orientation="Horizontal">
                          <Button x:Name="BtnOsdMove" Style="{StaticResource SubtleBtn}" Content="MOVE FREELY"/>
                          <Button x:Name="BtnOsdResetPos" Style="{StaticResource SubtleBtn}" Content="BACK TO CORNER" Margin="8,0,0,0" Visibility="Collapsed"/>
                          <TextBlock x:Name="OsdPosNote" Style="{StaticResource CardSub}" Text="" Margin="12,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                      </Grid>
                      <CheckBox x:Name="S_OsdSecond" Style="{StaticResource SetCheck}" Content="Show on the secondary monitor"/>
                      <CheckBox x:Name="S_OsdCapSafe" Style="{StaticResource SetCheck}" Content="Hide from screen capture (streams, recordings, share)"/>
                      <TextBlock Style="{StaticResource SetLabel}" Text="Show in the overlay" Margin="0,10,0,0"/>
                      <WrapPanel Margin="0,2,0,0">
                        <CheckBox x:Name="S_OsdFps"  Style="{StaticResource SetCheck}" Content="Frame rate (FPS)" Width="220"/>
                        <CheckBox x:Name="S_OsdCpu"  Style="{StaticResource SetCheck}" Content="CPU temperature" Width="220"/>
                        <CheckBox x:Name="S_OsdGpu"  Style="{StaticResource SetCheck}" Content="GPU temperature" Width="220"/>
                        <CheckBox x:Name="S_OsdLoad" Style="{StaticResource SetCheck}" Content="GPU load" Width="220"/>
                        <CheckBox x:Name="S_OsdRam"  Style="{StaticResource SetCheck}" Content="RAM usage" Width="220"/>
                        <CheckBox x:Name="S_OsdFans" Style="{StaticResource SetCheck}" Content="Fan speeds (CPU + case)" Width="220"/>
                        <CheckBox x:Name="S_OsdSsd"  Style="{StaticResource SetCheck}" Content="SSD temperature" Width="220"/>
                        <CheckBox x:Name="S_OsdMb"   Style="{StaticResource SetCheck}" Content="Board temperature" Width="220"/>
                        <CheckBox x:Name="S_OsdPods" Style="{StaticResource SetCheck}" Content="AirPods battery" Width="220"/>
                      </WrapPanel>
                      <TextBlock Style="{StaticResource SetLabel}" Text="Metric colors - click to pick one; unpainted metrics follow the theme" Margin="0,10,0,0"/>
                      <WrapPanel Margin="0,4,0,0">
                        <Button x:Name="O_ColFps"   Style="{StaticResource SegBtn}" Content="FPS"   MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColCpu"   Style="{StaticResource SegBtn}" Content="CPU"   MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColGpu"   Style="{StaticResource SegBtn}" Content="GPU"   MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColLoad"  Style="{StaticResource SegBtn}" Content="LOAD"  MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColRam"   Style="{StaticResource SegBtn}" Content="RAM"   MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColSsd"   Style="{StaticResource SegBtn}" Content="SSD"   MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColMb"    Style="{StaticResource SegBtn}" Content="BOARD" MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColFan"   Style="{StaticResource SegBtn}" Content="FAN"   MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColPods"  Style="{StaticResource SegBtn}" Content="PODS"  MinWidth="58" Margin="0,2,4,2"/>
                        <Button x:Name="O_ColReset" Style="{StaticResource SegBtn}" Content="Reset" MinWidth="58" Margin="8,2,0,2"/>
                      </WrapPanel>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="SAFETY" Foreground="#4C8DFF" x:Name="SecSafety" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Force Auto above - CPU"/>
                        <Slider Grid.Column="1" x:Name="S_CpuMax" Style="{StaticResource SetSlider}" Minimum="70" Maximum="95"/>
                        <TextBlock Grid.Column="2" x:Name="V_CpuMax" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Force Auto above - GPU"/>
                        <Slider Grid.Column="1" x:Name="S_GpuMax" Style="{StaticResource SetSlider}" Minimum="70" Maximum="95"/>
                        <TextBlock Grid.Column="2" x:Name="V_GpuMax" Style="{StaticResource SetValue}"/>
                      </Grid>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="COMFORT TARGETS" Foreground="#4C8DFF" x:Name="SecTargets" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <TextBlock Style="{StaticResource CardSub}" Text="Where the thermal palette and the per-card warnings consider each sensor warm." Margin="0,2,0,0" TextWrapping="Wrap"/>
                      <Grid Margin="0,8,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Comfort target - CPU"/>
                        <Slider Grid.Column="1" x:Name="S_WarnCpu" Style="{StaticResource SetSlider}" Minimum="50" Maximum="80"/>
                        <TextBlock Grid.Column="2" x:Name="V_WarnCpu" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Comfort target - GPU"/>
                        <Slider Grid.Column="1" x:Name="S_WarnGpu" Style="{StaticResource SetSlider}" Minimum="50" Maximum="80"/>
                        <TextBlock Grid.Column="2" x:Name="V_WarnGpu" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Comfort target - SSD"/>
                        <Slider Grid.Column="1" x:Name="S_WarnSsd" Style="{StaticResource SetSlider}" Minimum="45" Maximum="75"/>
                        <TextBlock Grid.Column="2" x:Name="V_WarnSsd" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <Grid Margin="0,7,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Comfort target - board"/>
                        <Slider Grid.Column="1" x:Name="S_WarnMb" Style="{StaticResource SetSlider}" Minimum="45" Maximum="75"/>
                        <TextBlock Grid.Column="2" x:Name="V_WarnMb" Style="{StaticResource SetValue}"/>
                      </Grid>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="GENERAL" Foreground="#4C8DFF" x:Name="SecGeneral" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Update interval"/>
                        <Slider Grid.Column="1" x:Name="S_Interval" Style="{StaticResource SetSlider}" Minimum="1" Maximum="10"/>
                        <TextBlock Grid.Column="2" x:Name="V_Interval" Style="{StaticResource SetValue}"/>
                      </Grid>
                      <CheckBox x:Name="S_StartMin" Style="{StaticResource SetCheck}" Content="Start minimized to tray"/>
                      <CheckBox x:Name="S_CloseTray" Style="{StaticResource SetCheck}" Content="Close button hides to tray"/>
                      <CheckBox x:Name="S_Updates" Style="{StaticResource SetCheck}" Content="Notify me when a new version is available"/>
                      <CheckBox x:Name="S_AutoStart" Style="{StaticResource SetCheck}" Content="Start with Windows (scheduled task, no UAC prompt)"/>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="SHORTCUTS" Foreground="#4C8DFF" x:Name="SecShortcuts" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <TextBlock Style="{StaticResource CardSub}" Text="Global keys that work anywhere, even in a game. Click a field, then press your combination:" Margin="0,2,0,0" TextWrapping="Wrap"/>
                      <WrapPanel Margin="0,8,0,2">
                        <Border Style="{StaticResource Kbd}"><TextBlock Style="{StaticResource KbdText}" Text="Ctrl"/></Border>
                        <Border Style="{StaticResource Kbd}"><TextBlock Style="{StaticResource KbdText}" Text="Alt"/></Border>
                        <Border Style="{StaticResource Kbd}"><TextBlock Style="{StaticResource KbdText}" Text="Shift"/></Border>
                        <Border Style="{StaticResource Kbd}"><TextBlock Style="{StaticResource KbdText}" Text="Win"/></Border>
                        <TextBlock Style="{StaticResource CardSub}" Text="one of these, plus a key" VerticalAlignment="Center" Margin="3,0,18,0"/>
                        <Border Style="{StaticResource Kbd}"><TextBlock Style="{StaticResource KbdText}" Text="Esc"/></Border>
                        <TextBlock Style="{StaticResource CardSub}" Text="cancel" VerticalAlignment="Center" Margin="3,0,18,0"/>
                        <Border Style="{StaticResource Kbd}"><TextBlock Style="{StaticResource KbdText}" Text="Del"/></Border>
                        <TextBlock Style="{StaticResource CardSub}" Text="clear" VerticalAlignment="Center" Margin="3,0,0,0"/>
                      </WrapPanel>
                      <TextBlock x:Name="HkConflict" Style="{StaticResource CardSub}" Foreground="#F26D78" Text="" Margin="0,5,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
                      <Grid Margin="0,8,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Toggle overlay"/>
                        <Button Grid.Column="1" x:Name="H_Osd" Style="{StaticResource SubtleBtn}" Content="Not set" HorizontalAlignment="Left" MinWidth="184"/>
                      </Grid>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Quiet mode"/>
                        <Button Grid.Column="1" x:Name="H_Quiet" Style="{StaticResource SubtleBtn}" Content="Not set" HorizontalAlignment="Left" MinWidth="184"/>
                      </Grid>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Normal mode"/>
                        <Button Grid.Column="1" x:Name="H_Normal" Style="{StaticResource SubtleBtn}" Content="Not set" HorizontalAlignment="Left" MinWidth="184"/>
                      </Grid>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Performance mode"/>
                        <Button Grid.Column="1" x:Name="H_Perf" Style="{StaticResource SubtleBtn}" Content="Not set" HorizontalAlignment="Left" MinWidth="184"/>
                      </Grid>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Auto mode"/>
                        <Button Grid.Column="1" x:Name="H_Auto" Style="{StaticResource SubtleBtn}" Content="Not set" HorizontalAlignment="Left" MinWidth="184"/>
                      </Grid>
                      <Grid Margin="0,6,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Style="{StaticResource SetLabel}" Text="Cycle Vento profile"/>
                        <Button Grid.Column="1" x:Name="H_Profile" Style="{StaticResource SubtleBtn}" Content="Not set" HorizontalAlignment="Left" MinWidth="184"/>
                      </Grid>

                      <StackPanel Orientation="Horizontal" Margin="0,18,0,4">
                        <Rectangle Style="{StaticResource AccentTick}"/>
                        <TextBlock Style="{StaticResource CardTitle}" Text="PROFILES" Foreground="#4C8DFF" x:Name="SecProfiles" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                      <TextBlock Style="{StaticResource CardSub}" Text="One name for the whole machine - a fan mode, the overlay, and a display scene together. Click to apply; right-click to edit. Switch anytime from the tray or the cycle shortcut." Margin="0,2,0,0" TextWrapping="Wrap"/>
                      <WrapPanel x:Name="VentoSceneHost" Margin="0,10,0,0"/>
                      <Border x:Name="VentoEditLayer" Visibility="Collapsed" Background="#0A0F17" BorderBrush="#243247" BorderThickness="1" CornerRadius="12" Padding="14" Margin="0,4,0,2">
                        <StackPanel>
                          <TextBlock x:Name="VentoEditTitle" Style="{StaticResource CardTitle}" Text="NEW PROFILE" Foreground="#EDF1F8"/>
                          <Grid Margin="0,10,0,0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <TextBlock Style="{StaticResource SetLabel}" Text="Name" VerticalAlignment="Center"/>
                            <Border Grid.Column="1" Background="#0C1119" CornerRadius="8" BorderBrush="#2B3447" BorderThickness="1">
                              <TextBox x:Name="VP_Name" Background="Transparent" BorderThickness="0" Foreground="#EDF1F8" FontSize="14" FontWeight="SemiBold" Padding="12,8" CaretBrush="#6FB1FF" MaxLength="22"/>
                            </Border>
                          </Grid>
                          <TextBlock Style="{StaticResource SetLabel}" Text="Colour" Margin="0,10,0,0"/>
                          <WrapPanel x:Name="VP_Swatches" Margin="0,6,0,0"/>
                          <TextBlock Style="{StaticResource SetLabel}" Text="Fans" Margin="0,4,0,0"/>
                          <WrapPanel x:Name="VP_FanHost" Margin="0,6,0,0"/>
                          <TextBlock Style="{StaticResource SetLabel}" Text="Overlay" Margin="0,4,0,0"/>
                          <WrapPanel x:Name="VP_OvHost" Margin="0,6,0,0"/>
                          <TextBlock Style="{StaticResource SetLabel}" Text="Display scene" Margin="0,4,0,0"/>
                          <WrapPanel x:Name="VP_DispHost" Margin="0,6,0,0"/>
                          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
                            <Button x:Name="BtnVpDelete" Style="{StaticResource GhostBtn}" Content="Delete" Width="96"/>
                            <Button x:Name="BtnVpCancel" Style="{StaticResource GhostBtn}" Content="Cancel" Width="96" Margin="8,0,0,0"/>
                            <Button x:Name="BtnVpSave" Style="{StaticResource PrimaryBtn}" Content="Save" Width="96" Margin="8,0,0,0"/>
                          </StackPanel>
                        </StackPanel>
                      </Border>
                    </StackPanel>
                  </ScrollViewer>
                  <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
                    <Button x:Name="BtnSetCancel" Style="{StaticResource GhostBtn}" Content="Cancel" Width="96"/>
                    <Button x:Name="BtnSetSave" Style="{StaticResource PrimaryBtn}" Content="Save" Width="96" Margin="8,0,0,0"/>
                  </StackPanel>
                </Grid>
              </Border>
            </Border>
          </Border>
          <!-- MONITORS panel: desk map (brightness lives on the screens),
               the selected display's controls, profile scenes, the night
               schedule band, and an ADVANCED sheet for the deep DDC codes. -->
          <Border x:Name="MonitorOverlay" Grid.Row="1" Grid.RowSpan="2" Background="#E607090D" Visibility="Collapsed">
            <Border Style="{StaticResource Card}" Margin="16,8,16,14">
              <Border Style="{StaticResource CardInner}" Padding="20,16">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <Grid Grid.Row="0">
                    <StackPanel Orientation="Horizontal">
                      <Rectangle Style="{StaticResource AccentTick}"/>
                      <TextBlock Style="{StaticResource CardTitle}" Text="MONITORS" Margin="7,0,0,0" VerticalAlignment="Center"/>
                      <TextBlock x:Name="MonStatus" Style="{StaticResource CardSub}" Text="" Margin="12,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                      <Ellipse x:Name="MonSceneDot" Width="7" Height="7" Fill="#5A6B84" VerticalAlignment="Center"/>
                      <TextBlock x:Name="MonSceneText" Style="{StaticResource CardTitle}" Text="" Margin="8,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Grid>

                  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0">
                    <StackPanel Margin="0,0,6,0">
                      <!-- Desk map: screens drawn to scale from the Windows
                           desktop layout; each carries its own brightness. -->
                      <Border Background="#0A0F17" CornerRadius="10" Height="286" ClipToBounds="True">
                        <Grid>
                          <Canvas x:Name="MonMapCanvas"/>
                          <TextBlock x:Name="MonMapTag" Text="DESK" FontSize="9" FontWeight="SemiBold"
                                     Foreground="#3C4A5E" Margin="14,10,0,0" HorizontalAlignment="Left" VerticalAlignment="Top"/>
                          <TextBlock x:Name="MonMapHint" Text="DRAG A BLADE " FontSize="9" FontWeight="SemiBold"
                                     Foreground="#3C4A5E" Margin="0,0,14,10" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
                        </Grid>
                      </Border>

                      <!-- Selected display + actions -->
                      <Grid Margin="0,14,0,0">
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                          <Rectangle Style="{StaticResource AccentTick}"/>
                          <TextBlock Style="{StaticResource CardTitle}" Text="SELECTED" Margin="7,0,0,0" VerticalAlignment="Center"/>
                          <TextBlock x:Name="MonSelName" Style="{StaticResource CardTitle}" Foreground="#6FB1FF" Text="" Margin="9,0,0,0" VerticalAlignment="Center"/>
                          <TextBlock x:Name="MonSelMeta" Style="{StaticResource CardSub}" Text="" Margin="9,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                          <Button x:Name="BtnMonSync" Style="{StaticResource ChipBtn}" Content="SYNC"/>
                          <Button x:Name="BtnMonIdentify" Style="{StaticResource ChipBtn}" Content="IDENTIFY" Margin="6,0,0,0"/>
                        </StackPanel>
                      </Grid>

                      <!-- Contrast + preset + input, one compact row -->
                      <Grid Margin="0,12,0,0">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="196"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel x:Name="MonConRow" Grid.Column="0" Margin="0,0,16,0">
                          <Grid>
                            <StackPanel Orientation="Horizontal">
                              <Rectangle Style="{StaticResource AccentTick}"/>
                              <TextBlock Style="{StaticResource CardTitle}" Text="CONTRAST" Margin="7,0,0,0" VerticalAlignment="Center"/>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                              <TextBlock x:Name="V_MonCon" Style="{StaticResource TileValue}" Text="--"/>
                              <TextBlock Style="{StaticResource TileUnit}" Text="%"/>
                            </StackPanel>
                          </Grid>
                          <Slider x:Name="S_MonCon" Style="{StaticResource SetSlider}" Minimum="0" Maximum="100" Margin="0,4,0,0"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Margin="0,0,12,0">
                          <StackPanel Orientation="Horizontal">
                            <Rectangle Style="{StaticResource AccentTick}"/>
                            <TextBlock Style="{StaticResource CardTitle}" Text="COLOR PRESET" Margin="7,0,0,0" VerticalAlignment="Center"/>
                          </StackPanel>
                          <WrapPanel x:Name="MonPreHost" Margin="0,4,0,0"/>
                        </StackPanel>
                        <StackPanel Grid.Column="2">
                          <StackPanel Orientation="Horizontal">
                            <Rectangle Style="{StaticResource AccentTick}"/>
                            <TextBlock Style="{StaticResource CardTitle}" Text="INPUT" Margin="7,0,0,0" VerticalAlignment="Center"/>
                          </StackPanel>
                          <WrapPanel x:Name="MonInHost" Margin="0,4,0,0"/>
                        </StackPanel>
                      </Grid>

                      <!-- Everything else the selected display exposes, in
                           plain sight rather than behind a dialog. -->
                      <Border x:Name="MonAdvCard" Background="#0C121C" CornerRadius="10" Margin="0,14,0,0" Padding="16,12">
                        <StackPanel>
                          <Grid>
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                              <Rectangle Style="{StaticResource AccentTick}"/>
                              <TextBlock Style="{StaticResource CardTitle}" Text="ALL CONTROLS" Margin="7,0,0,0" VerticalAlignment="Center"/>
                              <TextBlock x:Name="MonAdvTitle" Style="{StaticResource CardSub}" Text="" Margin="10,0,0,0" VerticalAlignment="Center"/>
                            </StackPanel>
                            <Button x:Name="BtnMonAdv" Style="{StaticResource ChipBtn}" Content="HIDE" Height="26" HorizontalAlignment="Right"/>
                          </Grid>
                          <StackPanel x:Name="MonAdvBody">
                            <StackPanel x:Name="MonModeRow" Margin="0,12,0,0">
                              <TextBlock Style="{StaticResource CardTitle}" Text="PICTURE MODE"/>
                              <WrapPanel x:Name="MonModeHost" Margin="0,6,0,0"/>
                              <TextBlock x:Name="MonModeHint" Style="{StaticResource CardSub}" Foreground="#4A5970" Text="" Margin="0,2,0,0" Visibility="Collapsed"/>
                            </StackPanel>
                            <!-- Response time is not a DDC/CI feature on any consumer
                                 display; the honest thing is to say so where the user
                                 will look for it. -->
                            <Border Background="#0E1622" CornerRadius="8" Padding="12,8" Margin="0,12,0,0">
                              <StackPanel>
                                <TextBlock Style="{StaticResource CardTitle}" Text="ONLY IN THE DISPLAY'S OWN MENU"/>
                                <TextBlock x:Name="MonRtText" Style="{StaticResource CardSub}" Foreground="#8FA3BC" TextWrapping="Wrap" Margin="0,4,0,0" Text=""/>
                              </StackPanel>
                            </Border>
                            <Grid Margin="0,12,0,0">
                              <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                              </Grid.ColumnDefinitions>
                              <StackPanel x:Name="MonRgbGroup" Grid.Column="0" Margin="0,0,14,0">
                                <TextBlock Style="{StaticResource CardTitle}" Text="RGB GAIN"/>
                                <Grid Margin="0,8,0,0">
                                  <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="16"/><ColumnDefinition Width="*"/><ColumnDefinition Width="38"/>
                                  </Grid.ColumnDefinitions>
                                  <TextBlock Text="R" FontSize="10" FontWeight="SemiBold" Foreground="#FF7A7A" VerticalAlignment="Center"/>
                                  <Slider Grid.Column="1" x:Name="S_MonR" Style="{StaticResource SetSlider}" Minimum="0" Maximum="100" Margin="4,0"/>
                                  <TextBlock Grid.Column="2" x:Name="V_MonR" Style="{StaticResource SetValue}" Text="--"/>
                                </Grid>
                                <Grid Margin="0,6,0,0">
                                  <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="16"/><ColumnDefinition Width="*"/><ColumnDefinition Width="38"/>
                                  </Grid.ColumnDefinitions>
                                  <TextBlock Text="G" FontSize="10" FontWeight="SemiBold" Foreground="#7FE0A0" VerticalAlignment="Center"/>
                                  <Slider Grid.Column="1" x:Name="S_MonG" Style="{StaticResource SetSlider}" Minimum="0" Maximum="100" Margin="4,0"/>
                                  <TextBlock Grid.Column="2" x:Name="V_MonG" Style="{StaticResource SetValue}" Text="--"/>
                                </Grid>
                                <Grid Margin="0,6,0,0">
                                  <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="16"/><ColumnDefinition Width="*"/><ColumnDefinition Width="38"/>
                                  </Grid.ColumnDefinitions>
                                  <TextBlock Text="B" FontSize="10" FontWeight="SemiBold" Foreground="#6FB1FF" VerticalAlignment="Center"/>
                                  <Slider Grid.Column="1" x:Name="S_MonB" Style="{StaticResource SetSlider}" Minimum="0" Maximum="100" Margin="4,0"/>
                                  <TextBlock Grid.Column="2" x:Name="V_MonB" Style="{StaticResource SetValue}" Text="--"/>
                                </Grid>
                              </StackPanel>
                              <StackPanel Grid.Column="1">
                                <StackPanel x:Name="MonSharpRow">
                                  <Grid>
                                    <TextBlock Style="{StaticResource CardTitle}" Text="SHARPNESS"/>
                                    <TextBlock x:Name="V_MonSharp" Style="{StaticResource SetValue}" Text="--" HorizontalAlignment="Right"/>
                                  </Grid>
                                  <Slider x:Name="S_MonSharp" Style="{StaticResource SetSlider}" Minimum="0" Maximum="100" Margin="0,6,0,0"/>
                                </StackPanel>
                                <StackPanel x:Name="MonVolRow" Margin="0,10,0,0">
                                  <Grid>
                                    <TextBlock Style="{StaticResource CardTitle}" Text="VOLUME"/>
                                    <TextBlock x:Name="V_MonVol" Style="{StaticResource SetValue}" Text="--" HorizontalAlignment="Right"/>
                                  </Grid>
                                  <Grid Margin="0,6,0,0">
                                    <Grid.ColumnDefinitions>
                                      <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Button x:Name="BtnMonMute" Style="{StaticResource ChipBtn}" FontFamily="Segoe MDL2 Assets"
                                            FontSize="12" Content="&#xE767;" Width="38" Height="26"/>
                                    <Slider Grid.Column="1" x:Name="S_MonVol" Style="{StaticResource SetSlider}" Minimum="0" Maximum="100" Margin="8,0,0,0"/>
                                  </Grid>
                                </StackPanel>
                              </StackPanel>
                            </Grid>
                            <!-- Named so the user can tell "this display can't"
                                 apart from "Vento can't". -->
                            <TextBlock x:Name="MonAdvNa" Style="{StaticResource CardSub}" Foreground="#4A5970"
                                       Text="" Margin="0,10,0,0" TextWrapping="Wrap"/>
                            <TextBlock x:Name="MonWriteNote" Style="{StaticResource CardSub}" Foreground="#FFC46F"
                                       Text="" Margin="0,8,0,0" TextWrapping="Wrap" Visibility="Collapsed"/>
                            <Grid Margin="0,12,0,0">
                              <Border x:Name="MonAdvHzChip" Background="#0E1622" CornerRadius="8" Padding="12,6" HorizontalAlignment="Left">
                                <StackPanel Orientation="Horizontal">
                                  <Ellipse Width="6" Height="6" Fill="#7FE0A0" VerticalAlignment="Center"/>
                                  <TextBlock x:Name="MonAdvHz" Style="{StaticResource CardTitle}" Foreground="#C9D2E2" Text="" Margin="8,0,0,0" VerticalAlignment="Center"/>
                                </StackPanel>
                              </Border>
                              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                <Button x:Name="BtnMonResetColor" Style="{StaticResource ChipBtn}" Content="RESET COLOR"/>
                                <Button x:Name="BtnMonResetLevels" Style="{StaticResource ChipBtn}" Content="RESET LEVELS" Margin="8,0,0,0"/>
                                <Button x:Name="BtnMonSoftOff" Style="{StaticResource ChipBtn}" Content="SOFT OFF" Foreground="#FF8A8A" Margin="8,0,0,0"/>
                              </StackPanel>
                            </Grid>
                            <!-- Factory reset is irreversible from software, so it
                                 asks before it fires. -->
                            <Grid Margin="0,8,0,0">
                              <Button x:Name="BtnMonFactory" Style="{StaticResource ChipBtn}" Content="FACTORY RESET" Foreground="#FF8A8A" HorizontalAlignment="Left"/>
                              <StackPanel x:Name="MonFactoryConfirm" Orientation="Horizontal" HorizontalAlignment="Left" Visibility="Collapsed">
                                <TextBlock Style="{StaticResource CardSub}" Text="Reset every setting on this display?" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                <Button x:Name="BtnMonFactoryYes" Style="{StaticResource ChipBtn}" Content="RESET" Foreground="#FF8A8A"/>
                                <Button x:Name="BtnMonFactoryNo" Style="{StaticResource ChipBtn}" Content="CANCEL" Margin="6,0,0,0"/>
                              </StackPanel>
                            </Grid>
                          </StackPanel>
                        </StackPanel>
                      </Border>

                      <!-- Switching input can leave a display dark with no way
                           back, so the change reverts itself unless kept. -->
                      <Border x:Name="MonRevertBar" Background="#2A1A0E" BorderBrush="#5A4020" BorderThickness="1"
                              CornerRadius="9" Padding="14,9" Margin="0,12,0,0" Visibility="Collapsed">
                        <Grid>
                          <TextBlock x:Name="MonRevertText" Style="{StaticResource CardSub}" Foreground="#FFC46F"
                                     Text="" Margin="0" VerticalAlignment="Center"/>
                          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button x:Name="BtnMonRevertKeep" Style="{StaticResource ChipBtn}" Content="KEEP"/>
                            <Button x:Name="BtnMonRevertNow" Style="{StaticResource ChipBtn}" Content="REVERT NOW" Margin="6,0,0,0"/>
                          </StackPanel>
                        </Grid>
                      </Border>

                      <!-- Profiles: one tap applies brightness + contrast +
                           color preset to every display. -->
                      <Grid Margin="0,16,0,0">
                        <StackPanel Orientation="Horizontal">
                          <Rectangle Style="{StaticResource AccentTick}"/>
                          <TextBlock Style="{StaticResource CardTitle}" Text="PROFILES" Margin="7,0,0,0" VerticalAlignment="Center"/>
                          <TextBlock Style="{StaticResource CardTitle}" Foreground="#3C4A5E" Text="TAP TO APPLY &#xB7; RIGHT-CLICK TO EDIT" Margin="12,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                          <TextBlock Style="{StaticResource CardTitle}" Foreground="#3C4A5E" Text="APPLY TO" Margin="0,0,8,0" VerticalAlignment="Center"/>
                          <Button x:Name="BtnMonScopeAll" Style="{StaticResource ChipBtn}" Content="ALL DISPLAYS" Height="26"/>
                          <Button x:Name="BtnMonScopeOne" Style="{StaticResource ChipBtn}" Content="SELECTED" Height="26" Margin="6,0,0,0"/>
                        </StackPanel>
                      </Grid>
                      <WrapPanel x:Name="MonSceneHost" Margin="0,6,0,0"/>

                      <!-- Night schedule -->
                      <Border Background="#0C121C" CornerRadius="10" Margin="0,16,0,0" Padding="16,12">
                        <StackPanel>
                          <Grid>
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                              <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#8F86FF" Text="&#xE708;" VerticalAlignment="Center"/>
                              <TextBlock Style="{StaticResource CardTitle}" Text="NIGHT SHIFT" Margin="9,0,0,0" VerticalAlignment="Center"/>
                              <TextBlock x:Name="MonNightText" Style="{StaticResource CardSub}" Text="" Margin="10,0,0,0" VerticalAlignment="Center"/>
                            </StackPanel>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                              <Button x:Name="BtnMonNightEdit" Style="{StaticResource ChipBtn}" Content="EDIT" Margin="0,0,8,0"/>
                              <CheckBox x:Name="S_MonNight" Style="{StaticResource PillSwitch}"/>
                            </StackPanel>
                          </Grid>
                          <Canvas x:Name="MonTimeCanvas" Height="42" Margin="0,10,0,0"/>
                          <StackPanel x:Name="MonNightEdit" Orientation="Horizontal" Margin="0,8,0,0" Visibility="Collapsed">
                            <TextBlock Style="{StaticResource CardTitle}" Text="FROM" VerticalAlignment="Center"/>
                            <Button x:Name="BtnNightFromDn" Style="{StaticResource ChipBtn}" Content="&#x2013;" Width="30" Height="26" Margin="8,0,0,0"/>
                            <TextBlock x:Name="MonNightFromVal" Style="{StaticResource TileValue}" Text="23:00" Margin="8,0,8,0" VerticalAlignment="Center"/>
                            <Button x:Name="BtnNightFromUp" Style="{StaticResource ChipBtn}" Content="+" Width="30" Height="26"/>
                            <TextBlock Style="{StaticResource CardTitle}" Text="TO" Margin="20,0,0,0" VerticalAlignment="Center"/>
                            <Button x:Name="BtnNightToDn" Style="{StaticResource ChipBtn}" Content="&#x2013;" Width="30" Height="26" Margin="8,0,0,0"/>
                            <TextBlock x:Name="MonNightToVal" Style="{StaticResource TileValue}" Text="07:00" Margin="8,0,8,0" VerticalAlignment="Center"/>
                            <Button x:Name="BtnNightToUp" Style="{StaticResource ChipBtn}" Content="+" Width="30" Height="26"/>
                            <TextBlock x:Name="MonNightProfVal" Style="{StaticResource CardSub}" Text="" Margin="20,0,0,0" VerticalAlignment="Center"/>
                          </StackPanel>
                        </StackPanel>
                      </Border>
                    </StackPanel>
                  </ScrollViewer>

                  <Grid Grid.Row="2" Margin="0,12,0,0">
                    <!-- What the display itself reports about itself. -->
                    <StackPanel VerticalAlignment="Center" Margin="2,0,12,0">
                      <TextBlock x:Name="MonInfoText" Style="{StaticResource CardSub}" Text="" Margin="0" TextTrimming="CharacterEllipsis"/>
                      <TextBlock x:Name="MonInfoText2" Style="{StaticResource CardSub}" Foreground="#4A5970" Text="" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                      <Button x:Name="BtnMonRescan" Style="{StaticResource GhostBtn}" Content="Rescan" Width="96"/>
                      <Button x:Name="BtnMonClose" Style="{StaticResource PrimaryBtn}" Content="Close" Width="96" Margin="8,0,0,0"/>
                    </StackPanel>
                  </Grid>

                  <!-- New-profile sheet: name it, give it a colour, save the
                       displays' current state into it. -->
                  <Grid x:Name="MonNewLayer" Grid.Row="0" Grid.RowSpan="3" Visibility="Collapsed">
                    <Border Background="#B00A0E14"/>
                    <Border Background="#151C28" CornerRadius="12" Padding="20,16"
                            HorizontalAlignment="Center" VerticalAlignment="Center" Width="420">
                      <Border.Effect>
                        <DropShadowEffect ShadowDepth="6" BlurRadius="34" Opacity="0.65" Color="#000000"/>
                      </Border.Effect>
                      <StackPanel>
                        <TextBlock x:Name="MonNewTitle" Style="{StaticResource CardTitle}" Text="NEW PROFILE"/>
                        <TextBlock x:Name="MonNewHint" Style="{StaticResource CardSub}" Text="Saves what the displays are showing right now." TextWrapping="Wrap"/>
                        <Border Background="#0C1119" CornerRadius="8" BorderBrush="#2B3447" BorderThickness="1" Margin="0,10,0,0">
                          <TextBox x:Name="MonNewName" Background="Transparent" BorderThickness="0" Foreground="#EDF1F8"
                                   FontSize="14" FontWeight="SemiBold" Padding="12,9" CaretBrush="#6FB1FF" MaxLength="18"/>
                        </Border>
                        <Grid Margin="0,14,0,0">
                          <TextBlock Style="{StaticResource CardTitle}" Text="IDENTITY COLOR"/>
                          <TextBlock Style="{StaticResource CardTitle}" Foreground="#3C4A5E" Text="PICK ANY" HorizontalAlignment="Right"/>
                        </Grid>
                        <WrapPanel x:Name="MonNewSwatches" Margin="0,8,0,0"/>
                        <Grid Margin="0,16,0,0">
                          <Button x:Name="BtnMonNewDelete" Style="{StaticResource ChipBtn}" Content="DELETE" Foreground="#FF8A8A"
                                  HorizontalAlignment="Left" Visibility="Collapsed"/>
                          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button x:Name="BtnMonNewCancel" Style="{StaticResource GhostBtn}" Content="Cancel" Width="90"/>
                            <Button x:Name="BtnMonNewSave" Style="{StaticResource PrimaryBtn}" Content="Save" Width="90" Margin="8,0,0,0"/>
                          </StackPanel>
                        </Grid>
                      </StackPanel>
                    </Border>
                  </Grid>
                </Grid>
              </Border>
            </Border>
          </Border>
          <!-- PODS flyout: AirPods battery, read passively from Apple's own BLE
               proximity broadcasts. A small card under the PODS chip - click
               anywhere else (or Esc) to close. Shows only what the buds
               actually said and how long ago; a closed case goes silent by
               design. -->
          <Grid x:Name="PodsOverlay" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed">
            <Border x:Name="PodsBackdrop" Background="#01000000"/>
            <Border x:Name="PodsCard" Style="{StaticResource Card}" Width="304" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,2,16,0"
                    BorderThickness="1" BorderBrush="#1FFFFFFF">
              <Border.Effect>
                <DropShadowEffect BlurRadius="28" ShadowDepth="8" Direction="270" Opacity="0.6" Color="#000000"/>
              </Border.Effect>
              <!-- Battery only on the face of it: status and freshness live in
                   tooltips, and unbinding the pair is a right-click away. -->
              <Border.ContextMenu>
                <ContextMenu Style="{StaticResource DarkMenu}">
                  <MenuItem x:Name="PodsForgetItem" Style="{StaticResource DarkMenuItem}" Header="Forget these AirPods"/>
                </ContextMenu>
              </Border.ContextMenu>
              <Border Style="{StaticResource CardInner}" Padding="16,12,16,14">
                <StackPanel>
                  <Grid x:Name="PodsHead" Background="Transparent">
                    <TextBlock x:Name="PodsModelText" Style="{StaticResource CardTitle}" Text="AIRPODS" VerticalAlignment="Center"/>
                    <Ellipse x:Name="PodsDot" Width="6" Height="6" Fill="#4A5970" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                  </Grid>
                  <StackPanel x:Name="PodsEmpty" Margin="0,10,0,2">
                    <TextBlock x:Name="PodsEmptyText" Style="{StaticResource CardSub}" Margin="0" TextWrapping="Wrap" TextTrimming="None"
                               Text="No battery broadcasts yet. AirPods send them while a bud is out of the case or the lid is open - keep them near the PC."/>
                  </StackPanel>
                  <StackPanel x:Name="PodsBody" Visibility="Collapsed" Margin="0,10,0,0">
                    <Grid x:Name="PodsLRow" Margin="0,0,0,9" Background="Transparent">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/><ColumnDefinition Width="16"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="LEFT" FontSize="9" FontWeight="Bold" Foreground="#8FA3BC" VerticalAlignment="Center"/>
                      <Border Grid.Column="1" Width="166" Height="6" CornerRadius="3" Background="#1A2230" VerticalAlignment="Center" HorizontalAlignment="Left">
                        <Border x:Name="PodsLBar" Height="6" CornerRadius="3" Background="#6FB1FF" Width="0" HorizontalAlignment="Left"/>
                      </Border>
                      <TextBlock Grid.Column="2" x:Name="PodsLVal" FontSize="13" FontWeight="Bold" Foreground="#EDF1F8" Text="--" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                      <TextBlock Grid.Column="3" x:Name="PodsLChg" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#7FE0A0" Text="&#xE945;" HorizontalAlignment="Right" VerticalAlignment="Center" Visibility="Collapsed"/>
                    </Grid>
                    <Grid x:Name="PodsRRow" Margin="0,0,0,9" Background="Transparent">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/><ColumnDefinition Width="16"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="RIGHT" FontSize="9" FontWeight="Bold" Foreground="#8FA3BC" VerticalAlignment="Center"/>
                      <Border Grid.Column="1" Width="166" Height="6" CornerRadius="3" Background="#1A2230" VerticalAlignment="Center" HorizontalAlignment="Left">
                        <Border x:Name="PodsRBar" Height="6" CornerRadius="3" Background="#6FB1FF" Width="0" HorizontalAlignment="Left"/>
                      </Border>
                      <TextBlock Grid.Column="2" x:Name="PodsRVal" FontSize="13" FontWeight="Bold" Foreground="#EDF1F8" Text="--" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                      <TextBlock Grid.Column="3" x:Name="PodsRChg" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#7FE0A0" Text="&#xE945;" HorizontalAlignment="Right" VerticalAlignment="Center" Visibility="Collapsed"/>
                    </Grid>
                    <Grid x:Name="PodsCRow" Background="Transparent">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/><ColumnDefinition Width="16"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="CASE" FontSize="9" FontWeight="Bold" Foreground="#8FA3BC" VerticalAlignment="Center"/>
                      <Border Grid.Column="1" Width="166" Height="6" CornerRadius="3" Background="#1A2230" VerticalAlignment="Center" HorizontalAlignment="Left">
                        <Border x:Name="PodsCBar" Height="6" CornerRadius="3" Background="#6FB1FF" Width="0" HorizontalAlignment="Left"/>
                      </Border>
                      <TextBlock Grid.Column="2" x:Name="PodsCVal" FontSize="13" FontWeight="Bold" Foreground="#EDF1F8" Text="--" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                      <TextBlock Grid.Column="3" x:Name="PodsCChg" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#7FE0A0" Text="&#xE945;" HorizontalAlignment="Right" VerticalAlignment="Center" Visibility="Collapsed"/>
                    </Grid>
                  </StackPanel>
                </StackPanel>
              </Border>
            </Border>
          </Grid>
        </Grid>
      </Border>
    </Border>
  </Grid>
</Window>
'@

# Resolve the bundled Sora font folder into the XAML font token. WPF's
# composite-font syntax is "<folder uri>#<family>"; if the folder is missing
# the family lookup fails silently and the Segoe UI fallback takes over.
$fontDir = Join-Path $script:AppRoot 'fonts'
$fontUri = 'file:///' + (($fontDir -replace '\\', '/').TrimEnd('/')) + '/'
$fontUri = $fontUri -replace ' ', '%20'
$xaml = $xaml.Replace('__FONTS__', $fontUri)
$window = [System.Windows.Markup.XamlReader]::Parse($xaml)
if (Test-Path $script:icoPath) {
    # pick the largest frame - BitmapFrame.Create alone grabs the 16px one
    try {
        $dec = New-Object System.Windows.Media.Imaging.IconBitmapDecoder(
            (New-Object System.Uri $script:icoPath),
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::Default)
        $window.Icon = ($dec.Frames | Sort-Object Width -Descending | Select-Object -First 1)
    } catch {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri $script:icoPath))
    }
}

$el = @{}
foreach ($name in @(
    'CpuTempVal','GpuTempVal',
    'CpuSpark','GpuSpark','CpuSparkHost','GpuSparkHost',
    'CpuNameText','GpuNameText','CpuFanVal','CaseFanVal','GpuFanVal',
    'SsdTempVal','SsdSpark','SsdSparkHost','SsdNameText',
    'MbTempVal','MbSpark','MbSparkHost','MbNameText',
    'CpuHair','GpuHair','SsdHair','MbHair',
    'CpuWarnFlag','CpuWarnText','GpuWarnFlag','GpuWarnText',
    'SsdWarnFlag','SsdWarnText','MbWarnFlag','MbWarnText',
    'WinBase','WinFrame','StateBadge','StateBadgeText','UpdatePill','UpdatePillText',
    'UpdateBanner','UpdateBannerText','BtnUpdateNow','BtnUpdateLater',
    'OrbGlow','OrbCore','OrbVal','OrbLabel','HaloTrack','HaloFill','HaloDot',
    'HeroTitle','HeroSub','LabCool','LabWarm','LabHot','ModeShell',
    'SectLine1','SectLine2','FooterPill',
    'RotorCpu','RotorCase','RotorGpu',
    'CpuFanRail','CpuFanRailTrack','CaseFanRail','CaseFanRailTrack','GpuFanRail','GpuFanRailTrack',
    'AxR0','AxR1','AxR2',
    'BtnQuiet','BtnNormal','BtnPerf','BtnCurve','BtnAuto',
    'StatusDot','StatusText','WarnText','TitleBar','BtnSettings','BtnMin','BtnClose','LogoOuter',
    'SettingsOverlay','SecFans','SecBoost','SecCurve','SecGame','SecOsd','SecSafety','SecTargets','SecGeneral','SecShortcuts',
    'HkConflict','H_Osd','H_Quiet','H_Normal','H_Perf','H_Auto','H_Profile',
    'SecProfiles','VentoSceneHost','VentoEditLayer','VentoEditTitle','VP_Name','VP_Swatches','VP_FanHost','VP_OvHost','VP_DispHost','BtnVpDelete','BtnVpCancel','BtnVpSave',
    'MonitorOverlay','BtnMonitors','MonStatus','MonSceneDot','MonSceneText',
    'MonMapCanvas','MonMapTag','MonMapHint',
    'MonSelName','MonSelMeta','BtnMonSync','BtnMonIdentify','BtnMonAdv',
    'MonConRow','S_MonCon','V_MonCon','MonPreHost','MonInHost','MonSceneHost',
    'S_MonNight','MonNightText','MonTimeCanvas','BtnMonNightEdit','BtnMonRescan','BtnMonClose',
    'MonNightEdit','BtnNightFromDn','BtnNightFromUp','MonNightFromVal',
    'BtnNightToDn','BtnNightToUp','MonNightToVal','MonNightProfVal',
    'MonAdvCard','MonAdvBody','MonAdvTitle','MonAdvNa','MonWriteNote','MonRgbGroup',
    'S_MonR','V_MonR','S_MonG','V_MonG','S_MonB','V_MonB',
    'MonSharpRow','S_MonSharp','V_MonSharp','MonVolRow','S_MonVol','V_MonVol','BtnMonMute',
    'MonModeRow','MonModeHost','MonModeHint','MonRtText',
    'MonRevertBar','MonRevertText','BtnMonRevertKeep','BtnMonRevertNow',
    'MonAdvHzChip','MonAdvHz','BtnMonResetColor','BtnMonResetLevels','BtnMonSoftOff',
    'BtnMonFactory','MonFactoryConfirm','BtnMonFactoryYes','BtnMonFactoryNo',
    'BtnMonScopeAll','BtnMonScopeOne','MonInfoText','MonInfoText2',
    'MonNewLayer','MonNewTitle','MonNewHint','MonNewName','MonNewSwatches',
    'BtnMonNewDelete','BtnMonNewCancel','BtnMonNewSave',
    'S_WarnCpu','S_WarnGpu','S_WarnSsd','S_WarnMb',
    'V_WarnCpu','V_WarnGpu','V_WarnSsd','V_WarnMb',
    'S_QuietCase','S_NormalCase','S_PerfCase','S_PerfCpu',
    'S_BoostEnabled','S_BoostHigh','S_BoostLow','S_BoostCase',
    'GameActShell','S_GameActPerf','S_GameActCurve','S_GameActOff','GameSliders',
    'OsdModeShell','O_ModeAuto','O_ModeOn','O_ModeOff',
    'OsdLayoutShell','O_LayBlade','O_LayStrip','O_LayHero','O_LayPills','O_LayGhost','O_LayMicro','O_LayThermo',
    'OsdThemeShell','O_ThSirocco','O_ThEmber','O_ThVenom','O_ThViolet','O_ThCrimson','O_ThMono',
    'OsdPreviewFrame','OsdPreviewHost',
    'OsdCornerShell','O_CorTL','O_CorTR','O_CorBL','O_CorBR',
    'S_OsdScale','V_OsdScale','S_OsdSecond','S_OsdCapSafe',
    'S_OsdOpacity','V_OsdOpacity','BtnOsdMove','BtnOsdResetPos','OsdPosNote',
    'S_OsdFps','S_OsdCpu','S_OsdGpu','S_OsdLoad','S_OsdRam','S_OsdFans','S_OsdSsd','S_OsdMb','S_OsdPods',
    'O_ColFps','O_ColCpu','O_ColGpu','O_ColLoad','O_ColRam','O_ColSsd','O_ColMb','O_ColFan','O_ColPods','O_ColReset',
    'PodsOverlay','BtnPods','PodsCard','PodsHead','PodsEmpty','PodsEmptyText','PodsBody','PodsModelText',
    'PodsLVal','PodsLChg','PodsLBar','PodsRVal','PodsRChg','PodsRBar','PodsCVal','PodsCChg','PodsCBar',
    'PodsLRow','PodsRRow','PodsCRow','PodsForgetItem','PodsBackdrop','PodsDot',
    'S_C40','S_C55','S_C70','S_C80','S_GameLoad','S_GameCool',
    'S_CpuMax','S_GpuMax','S_Interval','S_StartMin','S_CloseTray','S_Updates','S_AutoStart',
    'V_QuietCase','V_NormalCase','V_PerfCase','V_PerfCpu',
    'V_BoostHigh','V_BoostLow','V_BoostCase','V_C40','V_C55','V_C70','V_C80','V_GameLoad','V_GameCool',
    'V_CpuMax','V_GpuMax','V_Interval',
    'ModeSetTitle','ModeSetHint','ModeSlots','BtnModeReset',
    'Slot1','Slot2','Slot3','Slot4','ML1','ML2','ML3','ML4','MS1','MS2','MS3','MS4','MV1','MV2','MV3','MV4','MU1','MU2','MU3','MU4',
    'FanSparkHost','CpuFanSpark','CaseFanSpark','LegCpuDot','LegCaseDot',
    'CpuSparkFill','GpuSparkFill','SsdSparkFill','MbSparkFill','CpuFanSparkFill','CaseFanSparkFill',
    'BtnSetSave','BtnSetCancel')) {
    $el[$name] = $window.FindName($name)
}

# Fit small screens. The window is a fixed 720x966 and can't be resized, so on
# a laptop at 768p or a 1080p panel at 125% scaling its bottom lands off the
# work area and can't be reached. When the work area is shorter, scale the
# whole window down uniformly - no reflow, no scrollbars, just a smaller Vento.
try {
    $wa = [System.Windows.SystemParameters]::WorkArea   # DIPs
    $needH = 986.0   # 966 window + the 10px shadow margin top/bottom
    if ($wa.Height -lt $needH -and $window.Content) {
        $k = [math]::Max(0.6, ($wa.Height - 8) / $needH)
        $window.Content.Width = 720; $window.Content.Height = 966
        $window.Content.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $k, $k
        $window.SizeToContent = 'WidthAndHeight'
    }
} catch { }

# Reuse a pre-existing WPF Application (hosted runs, e.g. ISE) - the
# constructor throws if one already lives in this AppDomain.
$script:ownsApp = $false
$script:frame = $null
$script:app = [System.Windows.Application]::Current
if (-not $script:app) {
    $script:app = New-Object System.Windows.Application
    $script:app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $script:ownsApp = $true
    $script:app.Add_DispatcherUnhandledException({ param($s, $e)
        $e.Handled = $true
        try { $e.Exception | Out-String | Out-File -FilePath (Join-Path $script:AppRoot 'error.log') -Encoding utf8 -Append } catch { }
        Quit-App
    })
}

# --- Glass main window (1.8) -----------------------------------------
# The legacy window above is still built and still holds every control the
# rest of this script drives, but it is never shown. The window people see
# is ui\main.xaml (styles in ui\theme.xaml). Its pages call the same
# functions the legacy controls did, or drive those controls directly, so
# fan, profile and display logic stay exactly as they were while each page
# moves over to the new design.
Add-Type -Namespace VentoNative -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct MARGINS { public int l, r, t, b; }
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(System.IntPtr hwnd, ref MARGINS m);
'@

$script:inv = [Globalization.CultureInfo]::InvariantCulture
$script:dot = [char]0xB7

# Windows keeps eight shades of the accent; dark mode fills with Light 2 and
# writes with Light 3. Read again whenever Windows says the color changed.
function Read-AccentPalette {
    $a = @{ Light3 = '#99EBFF'; Light2 = '#4CC2FF'; Base = '#0078D4' }
    try {
        $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -ErrorAction Stop).AccentPalette
        if ($p -and $p.Count -ge 16) {
            $hex = { param($i) '#{0:X2}{1:X2}{2:X2}' -f $p[$i * 4], $p[$i * 4 + 1], $p[$i * 4 + 2] }
            $a.Light3 = & $hex 0; $a.Light2 = & $hex 1; $a.Base = & $hex 3
        }
    } catch { }
    $a
}
$script:acc = Read-AccentPalette

function Get-GColor([string]$hex, [byte]$a = 255) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    [System.Windows.Media.Color]::FromArgb($a, $c.R, $c.G, $c.B)
}
function Get-GBrush([string]$hex, [byte]$a = 255) {
    $b = New-Object System.Windows.Media.SolidColorBrush (Get-GColor $hex $a); $b.Freeze(); $b
}
function Read-UiXaml([string]$name) {
    $x = [IO.File]::ReadAllText((Join-Path $script:AppRoot "ui\$name"))
    $logo = ('file:///' + ((Join-Path $script:AppRoot 'assets\logo') -replace '\\', '/') + '/') -replace ' ', '%20'
    $soft = '#24' + $script:acc.Light2.Substring(1)
    $x = $x.Replace('__LOGO__', $logo).Replace('__ACCENTLIGHT__', $script:acc.Light3).Replace('__ACCENTSOFT__', $soft)
    $x = $x.Replace('__ACCENTBASE__', $script:acc.Base).Replace('__ACCENT__', $script:acc.Light2)
    [System.Windows.Markup.XamlReader]::Parse($x)
}

# Theme first, at Application level, so the main window's StaticResource
# lookups resolve. The legacy window keeps its own Window.Resources.
$script:app.Resources.MergedDictionaries.Add((Read-UiXaml 'theme.xaml'))
$script:shell = Read-UiXaml 'main.xaml'
if (Test-Path $script:icoPath) { try { $script:shell.Icon = $window.Icon } catch { } }
$script:g = @{}
function G([string]$n) {
    if (-not $script:g.ContainsKey($n)) { $script:g[$n] = $script:shell.FindName($n) }
    $script:g[$n]
}

# --- the glass: DWM system backdrop behind a transparent WPF surface ---
$script:materials = @{ acrylic = 3; mica = 2; micaalt = 4 }
function Get-ShellHwnd { (New-Object System.Windows.Interop.WindowInteropHelper $script:shell).Handle }
function Set-Material([string]$kind) {
    $h = Get-ShellHwnd
    if ($h -eq [IntPtr]::Zero) { return }
    $v = [int]$script:materials[$kind]; if (-not $v) { $v = 2 }
    $hr = [VentoNative.Dwm]::DwmSetWindowAttribute($h, 38, [ref]$v, 4)
    # Acrylic over a busy desktop gets a light veil for contrast; Mica is
    # already calm. No system backdrop (older Windows, transparency off):
    # paint the Settings-app gray ourselves.
    (G 'Tint').Background = $(if ($hr -ne 0) { Get-GBrush '#202020' } elseif ($v -eq 3) { Get-GBrush '#101216' 0x59 } else { [System.Windows.Media.Brushes]::Transparent })
}
$script:shell.Add_SourceInitialized({
    $h = Get-ShellHwnd
    [System.Windows.Interop.HwndSource]::FromHwnd($h).CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
    $m = New-Object VentoNative.Dwm+MARGINS; $m.l = -1; $m.r = -1; $m.t = -1; $m.b = -1
    [void][VentoNative.Dwm]::DwmExtendFrameIntoClientArea($h, [ref]$m)
    $one = 1; [void][VentoNative.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$one, 4)    # dark frame
    $round = 2; [void][VentoNative.Dwm]::DwmSetWindowAttribute($h, 33, [ref]$round, 4) # rounded corners
    Set-Material ([string]$script:settings.windowMaterial)
    # live accent: Windows broadcasts these when the accent or theme changes
    $src = [System.Windows.Interop.HwndSource]::FromHwnd($h)
    $script:accentHook = [System.Windows.Interop.HwndSourceHook]{
        $m = [int]$args[1]
        if ($m -eq 0x0320 -or $m -eq 0x001A) { $script:accentTimer.Stop(); $script:accentTimer.Start() }
        return [IntPtr]::Zero
    }
    $src.AddHook($script:accentHook)
})
foreach ($pair in @(@('MatAcrylic', 'acrylic'), @('MatMica', 'mica'), @('MatMicaAlt', 'micaalt'))) {
    $rb = G $pair[0]; $rb.Tag = $pair[1]
    $rb.IsChecked = ([string]$script:settings.windowMaterial -eq $pair[1])
    $rb.Add_Checked({
        param($s, $e)
        Set-Material ([string]$s.Tag)
        $script:settings.windowMaterial = [string]$s.Tag
        $script:saveTimer.Stop(); $script:saveTimer.Start()
    })
}

# --- live Windows accent: recolor the shared brushes in place ---
function Set-GlassAccent($a) {
    $script:acc = $a
    # CLR-side swap (VentoNative.Res): a PowerShell indexer would store a
    # PSObject wrapper WPF can't use. Every {DynamicResource} follows.
    [VentoNative.Res]::SetBrush($script:app.Resources, 'AccentBrush', (Get-GColor $a.Light2))
    [VentoNative.Res]::SetBrush($script:app.Resources, 'AccentTextBrush', (Get-GColor $a.Light3))
    [VentoNative.Res]::SetBrush($script:app.Resources, 'AccentSoftBrush', (Get-GColor $a.Light2 0x24))
    (G 'MeterStop0').Color = Get-GColor $a.Light2; (G 'MeterStop1').Color = Get-GColor $a.Light2
    (G 'AccentHex').Text = $a.Light2
    $script:glassReveal = $false
    try { Update-Glass $sync.Data } catch { }
}
$script:accentTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:accentTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$script:accentTimer.Add_Tick({
    param($s, $e) $s.Stop()
    $n = Read-AccentPalette
    if ($n.Light2 -ne $script:acc.Light2 -or $n.Light3 -ne $script:acc.Light3) { Set-GlassAccent $n }
})

# --- motion helpers ---
function New-GAnim([double]$from, [double]$to, [int]$ms, [int]$delay = 0) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    if (-not [double]::IsNaN($from)) { $a.From = $from }
    $a.To = $to; $a.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds($ms)
    $a.BeginTime = [TimeSpan]::FromMilliseconds($delay)
    $e = New-Object System.Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'; $a.EasingFunction = $e
    $a
}

# --- navigation: sliding selection pill + staggered page entrance ---
$script:glassPages = 'PageHome', 'PageFans', 'PageAlerts', 'PageProfiles', 'PageDisplays', 'PagePods', 'PageOverlay', 'PageLights', 'PageSettings'
$script:glassReveal = $true
function Move-NavPill($item, [bool]$animate) {
    if (-not $item -or $item.ActualHeight -le 0) { return }
    $p = $item.TranslatePoint((New-Object System.Windows.Point 0, ($item.ActualHeight / 2 - 8)), (G 'NavGrid'))
    [System.Windows.Controls.Canvas]::SetLeft((G 'NavPill'), $p.X)
    $t = G 'NavPillT'
    if ($animate) {
        $t.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-GAnim ([double]::NaN) $p.Y 280))
        $k = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        foreach ($f in @(@(16, 0), @(26, 120), @(16, 280))) {
            [void]$k.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame $f[0], ([System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($f[1])))))
        }
        (G 'NavPill').BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $k)
    } else {
        $t.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null); $t.Y = $p.Y
    }
}
function Show-GlassPage([string]$name, [bool]$animate = $true) {
    foreach ($p in $script:glassPages) { (G $p).Visibility = $(if ($p -eq $name) { 'Visible' } else { 'Collapsed' }) }
    $pg = G $name
    $pg.ScrollToTop()
    $i = 0
    foreach ($child in $pg.Content.Children) {
        $tt = New-Object System.Windows.Media.TranslateTransform
        $child.RenderTransform = $tt
        if ($animate) {
            # start values sit in the base so nothing flashes during the stagger
            $child.Opacity = 0; $tt.Y = 18
            $d = [math]::Min(7, $i) * 35
            $child.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-GAnim 0 1 300 $d))
            $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-GAnim 18 0 420 $d))
        } else {
            $child.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $child.Opacity = 1
        }
        $i++
    }
    $script:glassReveal = $true
    [void]$pg.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{ try { Update-Glass $sync.Data } catch { } })
}
foreach ($n in 'NavHome', 'NavFans', 'NavAlerts', 'NavProfiles', 'NavDisplays', 'NavPods', 'NavOverlay', 'NavLights', 'NavSettings') {
    (G $n).Add_Checked({ param($s, $e) Show-GlassPage ([string]$s.Tag); Move-NavPill $s $true })
}
# "Find a setting": as you type, jump to the page that owns the word
$script:searchMap = [ordered]@{
    Fans     = 'fans fan curve quiet normal performance auto boost speed rpm mode cooling'
    Alerts   = 'alerts alert warning warnings limit limits safety target targets game detection notification notifications'
    Profiles = 'profiles profile gaming movie work'
    Displays = 'displays display monitor brightness contrast input hdmi preset night screen'
    Pods     = 'devices device airpods battery bluetooth headphones earbuds keyboard mouse controller wireless'
    Overlay  = 'overlay osd fps layout blade strip hero pills ghost micro thermo color position corner capture obs'
    Settings = 'settings startup windows tray shortcut shortcuts hotkey keyboard update material acrylic mica accent about version'
    Home     = 'home sensors sensor temperature cpu gpu ssd board'
}
(G 'Search').Add_TextChanged({
    param($s, $e)
    $q = $s.Text.Trim().ToLowerInvariant()
    if ($q.Length -lt 2) { return }
    foreach ($k in $script:searchMap.Keys) {
        if (@($script:searchMap[$k].Split(' ') | Where-Object { $_.StartsWith($q) }).Count) {
            if (-not (G "Nav$k").IsChecked) { (G "Nav$k").IsChecked = $true }
            break
        }
    }
})
$script:shell.Add_ContentRendered({ Show-GlassPage 'PageHome' $false; Move-NavPill (G 'NavHome') $false })

# --- Glass: drawing helpers --------------------------------------------
function Format-GPt([double]$x, [double]$y) { $x.ToString('0.##', $script:inv) + ',' + $y.ToString('0.##', $script:inv) }
# Catmull-Rom through the samples, as cubic Beziers: smooth, never overshooting much
function Get-GSmooth($v, [double]$w, [double]$h, [double]$lo, [double]$hi) {
    $n = $v.Count; $pts = New-Object 'System.Collections.Generic.List[System.Windows.Point]'
    for ($i = 0; $i -lt $n; $i++) {
        $pts.Add((New-Object System.Windows.Point ($w * $i / ($n - 1)), (2 + ($h - 4) * (1 - (([double]$v[$i] - $lo) / [math]::Max(0.001, $hi - $lo))))))
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('M ' + (Format-GPt $pts[0].X $pts[0].Y))
    for ($i = 0; $i -lt $n - 1; $i++) {
        $p0 = $pts[[math]::Max(0, $i - 1)]; $p1 = $pts[$i]; $p2 = $pts[$i + 1]; $p3 = $pts[[math]::Min($n - 1, $i + 2)]
        [void]$sb.Append(' C ' + (Format-GPt ($p1.X + ($p2.X - $p0.X) / 6) ($p1.Y + ($p2.Y - $p0.Y) / 6)) + ' ' +
            (Format-GPt ($p2.X - ($p3.X - $p1.X) / 6) ($p2.Y - ($p3.Y - $p1.Y) / 6)) + ' ' + (Format-GPt $p2.X $p2.Y))
    }
    @{ Line = $sb.ToString(); Last = $pts[$n - 1] }
}
function Add-GSeries($canvas, $v, [string]$hex, [double]$lo, [double]$hi, [byte]$fillTop, [double]$thick) {
    $w = $canvas.ActualWidth; $h = $canvas.ActualHeight
    if ($w -le 0 -or $h -le 0 -or $v.Count -lt 2) { return }
    $s = Get-GSmooth $v $w $h $lo $hi
    if ($fillTop -gt 0) {
        $gr = New-Object System.Windows.Media.LinearGradientBrush
        $gr.StartPoint = '0,0'; $gr.EndPoint = '0,1'
        $gr.GradientStops.Add((New-Object System.Windows.Media.GradientStop (Get-GColor $hex $fillTop), 0))
        $gr.GradientStops.Add((New-Object System.Windows.Media.GradientStop (Get-GColor $hex 0), 1))
        $f = New-Object System.Windows.Shapes.Path
        $f.Data = [System.Windows.Media.Geometry]::Parse($s.Line + ' L ' + (Format-GPt $w $h) + ' L ' + (Format-GPt 0 $h) + ' Z'); $f.Fill = $gr
        [void]$canvas.Children.Add($f)
    }
    $l = New-Object System.Windows.Shapes.Path
    $l.Data = [System.Windows.Media.Geometry]::Parse($s.Line); $l.Stroke = Get-GBrush $hex; $l.StrokeThickness = $thick; $l.StrokeLineJoin = 'Round'
    [void]$canvas.Children.Add($l)
    $d = New-Object System.Windows.Shapes.Ellipse
    $d.Width = 8; $d.Height = 8; $d.Fill = Get-GBrush $hex; $d.Stroke = Get-GBrush '#2B2B2B'; $d.StrokeThickness = 2
    [System.Windows.Controls.Canvas]::SetLeft($d, $s.Last.X - 6); [System.Windows.Controls.Canvas]::SetTop($d, $s.Last.Y - 4)
    [void]$canvas.Children.Add($d)
}
function Add-GHLine($canvas, [double]$y, [string]$hex, [byte]$a, [switch]$Dashed) {
    $gl = New-Object System.Windows.Shapes.Line
    $gl.X1 = 0; $gl.X2 = $canvas.ActualWidth; $gl.Y1 = [math]::Round($y) + 0.5; $gl.Y2 = $gl.Y1
    $gl.Stroke = Get-GBrush $hex $a; $gl.StrokeThickness = 1
    if ($Dashed) { $gl.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@(4, 3)) }
    [void]$canvas.Children.Add($gl)
}
function Add-GText($canvas, [string]$text, [double]$x, [double]$y, [switch]$Right) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.Style = $script:app.FindResource('CaptionTertiary'); $t.FontSize = 11
    if ($Right) { [System.Windows.Controls.Canvas]::SetRight($t, $x) } else { [System.Windows.Controls.Canvas]::SetLeft($t, $x) }
    [System.Windows.Controls.Canvas]::SetTop($t, $y)
    [void]$canvas.Children.Add($t)
}
function Start-GReveal($canvas) {
    $w = $canvas.ActualWidth; $h = $canvas.ActualHeight + 30
    $rg = New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect -20, -20, 0, ($h + 20))
    $canvas.Clip = $rg
    $ra = New-Object System.Windows.Media.Animation.RectAnimation (New-Object System.Windows.Rect -20, -20, 0, ($h + 20)), (New-Object System.Windows.Rect -20, -20, ($w + 40), ($h + 20)), ([System.Windows.Duration][TimeSpan]::FromMilliseconds(900))
    $e = New-Object System.Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'; $ra.EasingFunction = $e
    $rg.BeginAnimation([System.Windows.Media.RectangleGeometry]::RectProperty, $ra)
}
# Battery ring: one dashed ellipse whose single dash is the charge, rotated
# to 12 o'clock; animating the dash offset fills it like a gauge. Charging
# adds a breathing glow and a spark running round.
function Set-GRing($canvas, $pct, [double]$thick, [string]$hex, [bool]$animate, [bool]$charging) {
    $canvas.Children.Clear()
    $sz = $canvas.Width
    $t = New-Object System.Windows.Shapes.Ellipse
    $t.Width = $sz; $t.Height = $sz; $t.Stroke = Get-GBrush '#FFFFFF' 0x1F; $t.StrokeThickness = $thick
    [void]$canvas.Children.Add($t)
    if ($null -eq $pct) { return }
    $a = New-Object System.Windows.Shapes.Ellipse
    $a.Width = $sz; $a.Height = $sz; $a.Stroke = Get-GBrush $hex; $a.StrokeThickness = $thick; $a.StrokeDashCap = 'Round'
    $a.RenderTransform = New-Object System.Windows.Media.RotateTransform -90, ($sz / 2), ($sz / 2)
    $len = [math]::PI * ($sz - $thick) * [double]$pct / 100 / $thick
    $a.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@($len, 1000))
    [void]$canvas.Children.Add($a)
    if ($animate) { $a.BeginAnimation([System.Windows.Shapes.Shape]::StrokeDashOffsetProperty, (New-GAnim $len 0 900 120)) }
    if ($charging) {
        $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $glow.ShadowDepth = 0; $glow.BlurRadius = $thick * 2.2; $glow.Color = Get-GColor $hex; $glow.Opacity = 0.6
        $a.Effect = $glow
        $spark = New-Object System.Windows.Shapes.Ellipse
        $spark.Width = $sz; $spark.Height = $sz; $spark.StrokeThickness = $thick; $spark.StrokeDashCap = 'Round'
        $spark.Stroke = Get-GBrush '#FFFFFF' 0xE6
        $spark.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@(0.6, 1000))
        $rot = New-Object System.Windows.Media.RotateTransform -90, ($sz / 2), ($sz / 2); $spark.RenderTransform = $rot
        [void]$canvas.Children.Add($spark)
        $run = New-Object System.Windows.Media.Animation.DoubleAnimation -90, 270, ([System.Windows.Duration][TimeSpan]::FromSeconds(1.8))
        $run.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $rot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $run)
        $br = New-Object System.Windows.Media.Animation.DoubleAnimation 0.25, 0.9, ([System.Windows.Duration][TimeSpan]::FromSeconds(1.1))
        $br.AutoReverse = $true; $br.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $glow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $br)
    }
}

# --- Glass: Home ---------------------------------------------------------
# Thermal state of the hottest sensor relative to its own comfort target,
# the same reading the legacy hero used.
$script:glassThermal = @{
    cool = @{ Hex = { $script:acc.Light2 }; Text = { $script:acc.Light3 } }
    warm = @{ Hex = { '#FFB547' }; Text = { '#FFD08A' } }
    hot  = @{ Hex = { '#FF8A80' }; Text = { '#FFB4AD' } }
}
$script:glassHist = @{ CPU = 'histCpu'; GPU = 'histGpu'; SSD = 'histSsd'; BOARD = 'histMb' }
$script:glassModeMap = @{ quiet = 'Quiet'; normal = 'Normal'; performance = 'Perf'; curve = 'Curve'; auto = 'Auto' }
$script:glassModeSync = $false
function Set-GlassModeCards([string]$mode) {
    $tag = $script:glassModeMap[$mode]; if (-not $tag) { return }
    $script:glassModeSync = $true
    try {
        foreach ($p in 'M', 'F') { $rb = G "$p$tag"; if ($rb -and -not $rb.IsChecked) { $rb.IsChecked = $true } }
        $name = $(if ($tag -eq 'Perf') { 'Performance' } else { $tag })
        (G 'HomeFansMode').Text = $(if ($script:gDrvState -and $script:gDrvState -ne 'ok') { 'Paused' } else { $name })
    } finally { $script:glassModeSync = $false }
}
foreach ($k in $script:glassModeMap.Keys) {
    foreach ($p in 'M', 'F') {
        $rb = G ('{0}{1}' -f $p, $script:glassModeMap[$k]); if (-not $rb) { continue }
        $rb.Tag = $k
        $rb.Add_Checked({ param($s, $e) if (-not $script:glassModeSync) { Set-UserMode ([string]$s.Tag) } })
    }
}

function Update-GlassHero($d) {
    $margin = -99.0; $hotName = $null; $hotVal = $null; $target = $null
    # 'auto' follows whichever sensor sits closest to (or furthest over) its
    # target; a pinned sensor is followed even when another runs hotter.
    $pin = $(switch ([string]$script:settings.heroSensor) { 'cpu' { 'CPU' } 'gpu' { 'GPU' } 'ssd' { 'SSD' } 'board' { 'BOARD' } default { $null } })
    foreach ($probe in @(
        @($d.CpuTemp, $script:settings.warnCpu, 'CPU'), @($d.GpuTemp, $script:settings.warnGpu, 'GPU'),
        @($d.SsdTemp, $script:settings.warnSsd, 'SSD'), @($d.MbTemp, $script:settings.warnMb, 'BOARD'))) {
        if ($pin -and $probe[2] -ne $pin) { continue }
        if ($null -ne $probe[0]) {
            $m = [double]$probe[0] - $probe[1]
            if ($m -gt $margin) { $margin = $m; $hotName = $probe[2]; $hotVal = [double]$probe[0]; $target = [double]$probe[1] }
        }
    }
    if ($null -eq $hotName) {
        (G 'HomeStatus').Text = $(if ($pin) { 'This sensor is not reporting a temperature.' } else { 'Reading the sensors...' })
        return
    }
    $state = $(if ($margin -le 0) { 'cool' } elseif ($margin -le 4) { 'warm' } else { 'hot' })
    $hex = & $script:glassThermal[$state].Hex; $txt = & $script:glassThermal[$state].Text
    $label = $(if ($hotName -eq 'BOARD') { 'Board' } else { $hotName })
    (G 'HeroLabel').Text = "$label temperature"
    (G 'HeroTemp').Text = '{0}' -f [int]$hotVal
    $deg = [char]0xB0; $dot = $script:dot
    if ($margin -le -4) {
        (G 'HeroChipText').Text = "Comfortably under target $dot $([int](-$margin))$deg to spare"
        (G 'HomeStatus').Text = 'All quiet. Every sensor is comfortably under its target.'
    } elseif ($margin -le 0) {
        (G 'HeroChipText').Text = "Nearing target $dot $([math]::Round(-$margin, 1))$deg below"
        (G 'HomeStatus').Text = "All quiet. $label is $([math]::Round(-$margin, 1))$deg under its target."
    } elseif ($margin -le 4) {
        (G 'HeroChipText').Text = "Over target $dot fans compensating"
        (G 'HomeStatus').Text = "$label is $([math]::Round($margin, 1))$deg over its target. Fans are compensating."
    } else {
        (G 'HeroChipText').Text = "Running hot $dot fans working hard"
        (G 'HomeStatus').Text = "$label is running hot at $([int]$hotVal)$deg. Fans are working hard."
    }
    (G 'HeroChip').Background = Get-GBrush $hex 0x26
    (G 'HeroChipText').Foreground = Get-GBrush $txt
    (G 'HeroGlowStop').Color = Get-GColor $hex 0x2E; (G 'HeroGlowEnd').Color = Get-GColor $hex 0

    # headroom meter: 30 deg up to the target plus 25
    $mh = G 'MeterHost'; $mm = G 'MeterMarks'; $mm.Children.Clear()
    $w = $mh.ActualWidth
    if ($w -gt 0) {
        $lo = 30.0; $hi = $target + 25
        $x = { param($v) $w * ([math]::Min($hi, [math]::Max($lo, $v)) - $lo) / ($hi - $lo) }
        $tick = New-Object System.Windows.Shapes.Rectangle
        $tick.Width = 2; $tick.Height = 14; $tick.Fill = Get-GBrush '#FFFFFF' 0xCC; $tick.RadiusX = 1; $tick.RadiusY = 1
        [System.Windows.Controls.Canvas]::SetLeft($tick, (& $x $target) - 1); [System.Windows.Controls.Canvas]::SetTop($tick, 1)
        [void]$mm.Children.Add($tick)
        Add-GText $mm ('{0}{1} target' -f [int]$target, $deg) ((& $x $target) - 26) 17
        $dotEl = New-Object System.Windows.Shapes.Ellipse
        $dotEl.Width = 16; $dotEl.Height = 16; $dotEl.Fill = Get-GBrush '#FFFFFF'; $dotEl.Stroke = Get-GBrush '#2B2B2B'; $dotEl.StrokeThickness = 3
        [System.Windows.Controls.Canvas]::SetTop($dotEl, 0)
        [void]$mm.Children.Add($dotEl)
        $to = (& $x $hotVal) - 8
        if ($script:glassReveal) { $dotEl.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, (New-GAnim -8 $to 900 100)) }
        else { [System.Windows.Controls.Canvas]::SetLeft($dotEl, $to) }
        ($mh.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.HorizontalAlignment -eq 'Left' } | Select-Object -First 1).Text = '{0}{1}' -f [int]$lo, $deg
        ($mh.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.HorizontalAlignment -eq 'Right' } | Select-Object -First 1).Text = '{0}{1}' -f [int]$hi, $deg
    }

    # last ten minutes of the hottest sensor
    $c = G 'HeroChart'; $c.Children.Clear()
    $hist = Get-Variable -Scope Script -Name $script:glassHist[$hotName] -ValueOnly -ErrorAction SilentlyContinue
    if ($hist -and $hist.Count -ge 2 -and $c.ActualHeight -gt 0) {
        $mn = ($hist | Measure-Object -Minimum).Minimum; $mx = ($hist | Measure-Object -Maximum).Maximum
        $lo2 = [math]::Min($mn, $target) - 3; $hi2 = [math]::Max($mx, $target) + 3
        $yv = { param($v) 2 + ($c.ActualHeight - 4) * (1 - (($v - $lo2) / ($hi2 - $lo2))) }
        Add-GHLine $c (& $yv $hi2) '#FFFFFF' 0x10; Add-GHLine $c (& $yv $lo2) '#FFFFFF' 0x10
        Add-GHLine $c (& $yv $target) '#FFFFFF' 0x40 -Dashed
        Add-GText $c ('Target {0}{1}' -f [int]$target, $deg) 0 ((& $yv $target) - 17) -Right
        Add-GSeries $c $hist $hex $lo2 $hi2 0x55 2
        if ($script:glassReveal) { Start-GReveal $c } else { $c.Clip = $null }
    }
}

# --- Glass: Bluetooth devices -----------------------------------------------
# Every Bluetooth device that is connected right now, with the battery level
# Windows publishes for it (headsets over Hands-Free, BLE mice, keyboards,
# controllers). Paired-but-away devices never show. AirPods don't publish one
# to Windows; theirs comes from their own BLE broadcast ($script:pods), which
# also splits left / right / case.
# The scan runs in its own runspace (Get-PnpDevice takes seconds): once at
# launch, every minute while Home or Devices is on screen, on the user's
# schedule in the background (for low-battery alerts), and on Refresh.
$script:devKeyBattery   = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2'
$script:devKeyConnected = '{83DA6326-97A6-4088-9453-A1923F573B29} 15'
$script:devices = @()
$script:devScanned = $false
$script:devLastScan = $null
$script:devNextScan = [DateTime]::MinValue
$script:devAr = $null
$script:devPs = $null
$script:devHomePage = 0
$script:devHadPods = $false
$script:devLowNotified = @{}
$script:devViewKey = $null
$script:devLabelTick = 0
$script:devScanWorker = {
    param($bk, $ck)
    $all = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
    $bt = @($all | Where-Object { $_.Class -eq 'Bluetooth' -and ($_.InstanceId -like 'BTHENUM\DEV_*' -or $_.InstanceId -like 'BTHLE\DEV_*') })
    $out = New-Object System.Collections.ArrayList
    if (-not $bt.Count) { return , $out.ToArray() }
    # One device per call: handed an array, Get-PnpDeviceProperty answers
    # every entry with the first device's id and value.
    $seen = @{}
    foreach ($d in $bt) {
        if (-not (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $ck -ErrorAction SilentlyContinue).Data) { continue }
        if ($d.InstanceId -notmatch 'DEV_([0-9A-F]{12})') { continue }
        $addr = $Matches[1]
        if ($seen[$addr]) { continue }   # classic + LE nodes of one device
        $seen[$addr] = $true
        # the level sits on the device node or a child (Hands-Free and co);
        # disconnected devices keep a stale one, which is why only connected
        # devices get this far
        $bat = $null
        foreach ($c in @($all | Where-Object { $_.InstanceId -like "*$addr*" })) {
            $v = (Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName $bk -ErrorAction SilentlyContinue).Data
            if ($null -ne $v) { $bat = [int]$v; break }
        }
        [void]$out.Add(@{ Name = [string]$d.FriendlyName; Addr = $addr; Battery = $bat })
    }
    , $out.ToArray()
}

function Get-DevGlyph([string]$n) {
    if ($n -match 'airpods|buds|head|arctis|nova|earbud|wh-|wf-|jabra|beats|bose|jbl|soundcore|earphone') { return [string][char]0xE7F6 }
    if ($n -match 'keyboard|keys') { return [string][char]0xE765 }
    if ($n -match 'mouse|mx master|viper|g pro') { return [string][char]0xE962 }
    if ($n -match 'controller|xbox|dualsense|dualshock|gamepad') { return [string][char]0xE7FC }
    if ($n -match 'phone|iphone|pixel') { return [string][char]0xE8EA }
    [string][char]0xE702
}
function Get-DevSorted { @($script:devices | Sort-Object -Property @{ Expression = { -not $_.Apple } }, @{ Expression = { $_.Name } }) }

function Start-DevScan {
    if ($script:devAr) { return }
    if (-not $script:devPs) {
        $script:devPs = [powershell]::Create()
        [void]$script:devPs.AddScript($script:devScanWorker.ToString()).AddArgument($script:devKeyBattery).AddArgument($script:devKeyConnected)
    }
    $script:devAr = $script:devPs.BeginInvoke()
}
function Set-DevNextScan {
    $min = [int]$script:settings.devCheckMin
    $base = $(if ($script:devLastScan) { $script:devLastScan } else { [DateTime]::Now })
    $script:devNextScan = $(if ($min -le 0) { [DateTime]::MaxValue } else { $base.AddMinutes($min) })
}
function Update-DevLabels {
    $t = $(if ($script:devAr) { 'Checking...' } elseif (-not $script:devLastScan) { 'Not checked yet' } else {
        $m = [int][math]::Floor(([DateTime]::Now - $script:devLastScan).TotalMinutes)
        $(if ($m -lt 1) { 'Checked just now' } elseif ($m -eq 1) { 'Checked 1 min ago' } else { "Checked $m min ago" })
    })
    (G 'DevChecked').Text = $t
    $p = $script:pods
    $listening = ([DateTime]::Now -lt $script:podsSniffUntil)
    (G 'PodsCheckText').Text = $(if ($listening) { 'Listening...' } else { 'Check now' })
    (G 'PodsCheck').IsEnabled = -not $listening
    (G 'PodsUpdated').Text = $(if ($p -and $p.Seen) { 'Updated ' + (Get-PodsAgeText $p.Seen) }
                               elseif ($listening) { 'Waiting for a broadcast' } else { 'No reading yet' })
}

# A device that drops to the threshold gets one notification per charge.
# AirPods are covered per bud by Update-PodsData from their own broadcast.
function Test-DevLowBattery {
    if (-not [bool]$script:settings.devLowOn) { return }
    $lim = [int]$script:settings.podsWarn
    foreach ($d in $script:devices) {
        $v = $d.Battery
        if ($d.Apple -or $null -eq $v) { continue }
        if ($v -le $lim -and -not $script:devLowNotified[$d.Addr]) {
            $script:devLowNotified[$d.Addr] = $true
            [void](Show-Toast ('{0} battery is low' -f $d.Name) ('{0}% left. Time to put it on charge.' -f $v) 'vento-dev')
        } elseif ($v -gt $lim + 5) { $script:devLowNotified.Remove($d.Addr) }
    }
}

# Every UI tick, shown or not: collects a finished scan, starts the next one
# when it is due.
function Update-DevTick {
    $now = [DateTime]::Now
    if ($script:devAr) {
        if (-not $script:devAr.IsCompleted) { return }
        $res = @()
        try { $res = @($script:devPs.EndInvoke($script:devAr) | ForEach-Object { $_ }) } catch { }
        $script:devAr = $null
        $script:devLastScan = $now
        $script:devScanned = $true
        $script:devices = @($res | Where-Object { $_ -is [hashtable] } | ForEach-Object {
            @{ Name = $_.Name; Addr = $_.Addr; Battery = $_.Battery; Glyph = (Get-DevGlyph $_.Name); Apple = ($_.Name -match 'AirPods|Beats') }
        })
        Set-DevNextScan
        Test-DevLowBattery
        if ($script:shell.IsVisible) { Update-DevLabels }
        return
    }
    $shown = $script:shell.IsVisible -and ((G 'PageHome').Visibility -eq 'Visible' -or (G 'PagePods').Visibility -eq 'Visible')
    $due = ($now -ge $script:devNextScan) -or ($shown -and $script:devLastScan -and ($now - $script:devLastScan).TotalSeconds -ge 60)
    if ($due) { Start-DevScan; if ($script:shell.IsVisible) { Update-DevLabels } }
    elseif ($shown -and ++$script:devLabelTick % 10 -eq 0) { Update-DevLabels }
}

function Get-DevViewKey {
    $k = (@($script:devices | ForEach-Object { '{0}:{1}' -f $_.Addr, $_.Battery }) -join ',') + "|$($script:devScanned)"
    $p = $script:pods
    if ($p) { $k += '|{0},{1},{2},{3},{4},{5}' -f $p.L, $p.R, $p.Case, $p.ChgL, $p.ChgR, $p.ChgCase }
    $k
}

# --- drawing ---
function New-DevText([string]$text, [string]$style) {
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $text; $t.Style = $script:app.FindResource($style); $t.VerticalAlignment = 'Center'; $t
}
function New-DevIcon([string]$glyph) {
    $b = New-Object System.Windows.Controls.Border; $b.Style = $script:app.FindResource('IconTile')
    $t = New-DevText $glyph 'Glyph'; $t.HorizontalAlignment = 'Center'; $b.Child = $t; $b
}
function New-DevRow([int]$minH, [string]$margin) {
    $g = New-Object System.Windows.Controls.Grid; $g.MinHeight = $minH; $g.Margin = $margin
    foreach ($w in 36, -1, -2) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = $(if ($w -gt 0) { New-Object System.Windows.GridLength $w } elseif ($w -eq -1) { New-Object System.Windows.GridLength 1, 'Star' } else { [System.Windows.GridLength]::Auto })
        $g.ColumnDefinitions.Add($cd)
    }
    $g
}
function Test-DevLow($v, [bool]$chg) { ($null -ne $v -and $v -le [int]$script:settings.podsWarn -and -not $chg) }
function New-DevRing([double]$size, [double]$thick, $pct, [bool]$chg, [string]$label, [bool]$animate) {
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.HorizontalAlignment = 'Center'
    $g = New-Object System.Windows.Controls.Grid; $g.Width = $size; $g.Height = $size
    $c = New-Object System.Windows.Controls.Canvas; $c.Width = $size; $c.Height = $size
    $low = Test-DevLow $pct $chg
    $hex = $(if ($chg) { '#6CCB5F' } elseif ($low) { '#FF99A4' } else { $script:acc.Light2 })
    Set-GRing $c $pct $thick $hex $animate $chg
    $txt = New-DevText $(if ($null -eq $pct) { [string][char]0x2014 } else { "$pct" }) 'BodyStrong'
    $txt.FontSize = [math]::Round($size / 4.2); $txt.HorizontalAlignment = 'Center'
    if ($low) { $txt.Foreground = Get-GBrush '#FF99A4' }
    [void]$g.Children.Add($c); [void]$g.Children.Add($txt)
    [void]$sp.Children.Add($g)
    $lb = New-Object System.Windows.Controls.StackPanel; $lb.Orientation = 'Horizontal'; $lb.HorizontalAlignment = 'Center'; $lb.Margin = '0,6,0,0'
    if ($chg) {
        $bolt = New-DevText ([string][char]0xE945) 'Glyph'; $bolt.FontSize = 10; $bolt.Foreground = $script:app.FindResource('SuccessBrush'); $bolt.Margin = '0,0,4,0'
        [void]$lb.Children.Add($bolt)
    }
    [void]$lb.Children.Add((New-DevText $label 'Caption'))
    [void]$sp.Children.Add($lb)
    $sp
}

# Home card: one battery page per connected device (AirPods first), then a
# compact list when there is more than one. The header arrows page through.
function Get-DevHomePages {
    $pages = @()
    foreach ($d in (Get-DevSorted)) { $pages += , @{ Kind = 'battery'; Dev = $d } }
    if ($script:devices.Count -gt 1) { $pages += , @{ Kind = 'list' } }
    , $pages
}
function Add-DevHomeRow($host_, $d) {
    $g = New-DevRow 0 '0,10,0,0'
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '12,0,8,0'; $sp.VerticalAlignment = 'Center'
    $nm = New-DevText $d.Name 'BodyStrong'; $nm.FontSize = 13; $nm.TextTrimming = 'CharacterEllipsis'
    [void]$sp.Children.Add($nm)
    $v = $d.Battery; $detail = 'Bluetooth'
    if ($d.Apple) {
        $p = $script:pods
        if ($p -and $p.Seen) {
            $detail = 'Left {0} {1} Right {2}' -f $(if ($null -ne $p.L) { $p.L } else { '--' }), $script:dot, $(if ($null -ne $p.R) { $p.R } else { '--' })
            $buds = @(@($p.L, $p.R) | Where-Object { $null -ne $_ })
            $v = $(if ($buds.Count) { ($buds | Measure-Object -Minimum).Minimum } else { $null })
        } else { $detail = 'Waiting for battery' }
    }
    [void]$sp.Children.Add((New-DevText $detail 'Caption'))
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    if ($null -eq $v) {
        $val = New-DevText ([string][char]0x2014) 'CaptionTertiary'; $val.ToolTip = "This device doesn't share its battery with Windows"
    } else {
        $val = New-DevText ('{0}%' -f $v) 'Metric'; $val.FontSize = 16
        if (Test-DevLow $v $false) { $val.Foreground = Get-GBrush '#FF99A4' }
    }
    [System.Windows.Controls.Grid]::SetColumn($val, 2)
    [void]$g.Children.Add((New-DevIcon $d.Glyph)); [void]$g.Children.Add($sp); [void]$g.Children.Add($val)
    [void]$host_.Children.Add($g)
}
function Show-DevHome([int]$dir = 0) {
    $host_ = G 'HomeDevices'; $host_.Children.Clear()
    $pages = Get-DevHomePages
    (G 'DevPager').Visibility = $(if ($pages.Count -gt 1) { 'Visible' } else { 'Collapsed' })
    if (-not $pages.Count) {
        $t = New-DevText $(if ($script:devScanned) { 'No Bluetooth devices connected' } else { 'Looking for devices...' }) 'Caption'
        $t.Margin = '0,12,0,0'; [void]$host_.Children.Add($t); return
    }
    if ($script:devHomePage -ge $pages.Count) { $script:devHomePage = 0 }
    (G 'DevPageText').Text = '{0} / {1}' -f ($script:devHomePage + 1), $pages.Count
    $pg = $pages[$script:devHomePage]
    $anim = [bool]($dir -ne 0 -or $script:glassReveal)
    if ($pg.Kind -eq 'battery') {
        $d = $pg.Dev
        $hd = New-Object System.Windows.Controls.StackPanel; $hd.Orientation = 'Horizontal'; $hd.Margin = '0,6,0,12'
        $gl = New-DevText $d.Glyph 'Glyph'; $gl.FontSize = 14; $gl.Foreground = $script:app.FindResource('TextSecondaryBrush')
        $nm = New-DevText $d.Name 'Caption'; $nm.Margin = '8,0,0,0'; $nm.MaxWidth = 220; $nm.TextTrimming = 'CharacterEllipsis'
        [void]$hd.Children.Add($gl); [void]$hd.Children.Add($nm)
        [void]$host_.Children.Add($hd)
        if ($d.Apple) {
            $p = $script:pods
            $ug = New-Object System.Windows.Controls.Primitives.UniformGrid; $ug.Columns = 3
            foreach ($r in @(@('Left', 'L', 'ChgL'), @('Right', 'R', 'ChgR'), @('Case', 'Case', 'ChgCase'))) {
                $v = $(if ($p -and $p.Seen) { $p[$r[1]] } else { $null })
                [void]$ug.Children.Add((New-DevRing 56 5 $v ([bool]($p -and $p[$r[2]])) $r[0] $anim))
            }
            [void]$host_.Children.Add($ug)
        } else {
            $lbl = $(if ($null -eq $d.Battery) { 'Not shared with Windows' } else { 'Battery' })
            [void]$host_.Children.Add((New-DevRing 72 6 $d.Battery $false $lbl $anim))
        }
    } else {
        foreach ($d in @(Get-DevSorted | Select-Object -First 3)) { Add-DevHomeRow $host_ $d }
    }
    if ($dir -ne 0) {
        $tt = New-Object System.Windows.Media.TranslateTransform; $host_.RenderTransform = $tt
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (New-GAnim (40 * $dir) 0 320))
        $host_.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-GAnim 0 1 260))
    }
}
(G 'DevPrev').Add_Click({ $n = (Get-DevHomePages).Count; if ($n) { $script:devHomePage = ($script:devHomePage - 1 + $n) % $n; Show-DevHome -1 } })
(G 'DevNext').Add_Click({ $n = (Get-DevHomePages).Count; if ($n) { $script:devHomePage = ($script:devHomePage + 1) % $n; Show-DevHome 1 } })

# Devices page, "Other devices" tab: everything but the AirPods, with a bar
function Show-DevRows {
    $rows = G 'DeviceRows'; $rows.Children.Clear()
    $others = @(Get-DevSorted | Where-Object { -not $_.Apple })
    if (-not $others.Count) { $t = New-DevText 'Nothing else is connected right now.' 'Caption'; $t.Margin = '0,18'; [void]$rows.Children.Add($t) }
    for ($i = 0; $i -lt $others.Count; $i++) {
        $d = $others[$i]
        $g = New-DevRow 62 '0'
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '16,0'; $sp.VerticalAlignment = 'Center'
        [void]$sp.Children.Add((New-DevText $d.Name 'Body'))
        [void]$sp.Children.Add((New-DevText $(if ($null -eq $d.Battery) { "Bluetooth $($script:dot) doesn't share its battery with Windows" } else { "Bluetooth $($script:dot) connected" }) 'Caption'))
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $right = New-Object System.Windows.Controls.StackPanel; $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
        if ($null -ne $d.Battery) {
            $low = Test-DevLow $d.Battery $false
            $track = New-Object System.Windows.Controls.Border; $track.Width = 90; $track.Height = 6; $track.CornerRadius = 3; $track.Background = Get-GBrush '#FFFFFF' 0x1F; $track.VerticalAlignment = 'Center'
            $fill = New-Object System.Windows.Controls.Border; $fill.Width = [math]::Max(6, 90 * $d.Battery / 100); $fill.CornerRadius = 3; $fill.HorizontalAlignment = 'Left'
            $fill.Background = $(if ($low) { Get-GBrush '#FF99A4' } else { $script:app.FindResource('AccentBrush') })
            $track.Child = $fill
            $pct = New-DevText ('{0}%' -f $d.Battery) 'Body'; $pct.Width = 46; $pct.TextAlignment = 'Right'
            if ($low) { $pct.Foreground = Get-GBrush '#FF99A4' }
            [void]$right.Children.Add($track); [void]$right.Children.Add($pct)
        } else { [void]$right.Children.Add((New-DevText 'Not reported' 'CaptionTertiary')) }
        [System.Windows.Controls.Grid]::SetColumn($right, 2)
        [void]$g.Children.Add((New-DevIcon $d.Glyph)); [void]$g.Children.Add($sp); [void]$g.Children.Add($right)
        [void]$rows.Children.Add($g)
        if ($i -lt $others.Count - 1) { $dv = New-Object System.Windows.Controls.Border; $dv.Height = 1; $dv.Background = $script:app.FindResource('DividerBrush'); [void]$rows.Children.Add($dv) }
    }
}

# Devices page, AirPods tab: the three big rings from the BLE broadcast
function Show-DevPods([bool]$animate) {
    if ((G 'PodsPanel').Visibility -ne 'Visible') { return }
    $p = $script:pods
    $model = $(if ($p -and $script:podsModels.ContainsKey($p.Model)) { $script:podsModels[$p.Model] } else { $null })
    $bound = ([int]$script:settings.podsModel -ne 0)
    (G 'PodsForget').Visibility = $(if ($bound) { 'Visible' } else { 'Collapsed' })
    (G 'PodSub').Text = $(if ($p -and $p.Seen) { $(if ($model) { "$model $($script:dot) Connected" } else { 'Connected' }) }
                         elseif ($bound) { 'Waiting for a battery broadcast. Open the case near the PC or press Check now.' }
                         else { 'To read the battery, hold the AirPods next to the PC with the case open and press Check now.' })
    foreach ($t in @(@('L', 'L', 'ChgL'), @('R', 'R', 'ChgR'), @('C', 'Case', 'ChgCase'))) {
        $v = $(if ($p -and $p.Seen) { $p[$t[1]] } else { $null })
        $chg = [bool]($p -and $p[$t[2]])
        $low = Test-DevLow $v $chg
        $hex = $(if ($chg) { '#6CCB5F' } elseif ($low) { '#FF99A4' } else { $script:acc.Light2 })
        Set-GRing (G "PRing$($t[0])") $v 10 $hex $animate $chg
        $pc = G "PPct$($t[0])"
        $pc.Text = $(if ($null -ne $v) { '{0}%' -f $v } else { [string][char]0x2014 })
        $pc.Foreground = $(if ($low) { Get-GBrush '#FF99A4' } else { $script:app.FindResource('TextPrimaryBrush') })
        (G "PChg$($t[0])").Visibility = $(if ($chg) { 'Visible' } else { 'Collapsed' })
    }
    Update-DevLabels
}

function Update-DevViews {
    $pods = Get-DevSorted | Where-Object { $_.Apple } | Select-Object -First 1
    $any = $script:devices.Count -gt 0
    (G 'TabPods').Visibility = $(if ($pods) { 'Visible' } else { 'Collapsed' })
    if ($pods) { (G 'TabPods').Content = $(if ($pods.Name -match 'Beats') { 'Beats' } else { 'AirPods' }) }
    if (-not $pods -and (G 'TabPods').IsChecked) { (G 'TabOther').IsChecked = $true }
    if ($pods -and -not $script:devHadPods) { (G 'TabPods').IsChecked = $true }
    $script:devHadPods = [bool]$pods
    (G 'DevTabs').Visibility = $(if ($any) { 'Visible' } else { 'Collapsed' })
    (G 'NoDevices').Visibility = $(if ($any) { 'Collapsed' } else { 'Visible' })
    (G 'NoDevTitle').Text = $(if ($script:devScanned) { 'No Bluetooth devices connected' } else { 'Looking for devices...' })
    (G 'PodsPanel').Visibility = $(if ($pods -and (G 'TabPods').IsChecked) { 'Visible' } else { 'Collapsed' })
    (G 'OtherPanel').Visibility = $(if ($any -and (G 'TabOther').IsChecked) { 'Visible' } else { 'Collapsed' })
    if ($pods) { (G 'PodName').Text = $pods.Name }
    Show-DevPods ([bool]$script:glassReveal)
    Show-DevRows
    Show-DevHome
}
(G 'TabPods').Add_Checked({ $script:glassReveal = $true; Update-DevViews; $script:glassReveal = $false })
(G 'TabOther').Add_Checked({ Update-DevViews })

# Check now: the AirPods radio listens for one sniff window right away,
# bound or not (an unbound pair needs the user nearby anyway).
(G 'PodsCheck').Add_Click({
    $script:podsSniffUntil = [DateTime]::Now.AddSeconds($script:podsSniffLen)
    try { Update-PodsTick } catch { }
    Update-DevLabels
})
(G 'DevRefresh').Add_Click({
    Start-DevScan
    if ((G 'TabPods').Visibility -eq 'Visible') { $script:podsSniffUntil = [DateTime]::Now.AddSeconds($script:podsSniffLen); try { Update-PodsTick } catch { } }
    Update-DevLabels
})

# --- options ---
(G 'DevOsd').IsChecked = [bool]$script:settings.osdPods
(G 'DevOsd').Add_Click({
    $on = [bool](G 'DevOsd').IsChecked
    $script:settings.osdPods = $on; $sync.Settings.osdPods = $on
    if ($el.S_OsdPods) { $el.S_OsdPods.IsChecked = $on }
    try { Build-OsdContent } catch { }
    $script:saveTimer.Stop(); $script:saveTimer.Start()
})
(G 'LowBat').Value = [int]$script:settings.podsWarn
(G 'LowBatV').Text = '{0}%' -f [int]$script:settings.podsWarn
(G 'LowBatOn').IsChecked = [bool]$script:settings.devLowOn
(G 'LowBat').IsEnabled = [bool]$script:settings.devLowOn
(G 'LowBat').Add_ValueChanged({
    $v = [int](G 'LowBat').Value
    (G 'LowBatV').Text = '{0}%' -f $v
    if ($v -eq [int]$script:settings.podsWarn) { return }
    $script:settings.podsWarn = $v; $sync.Settings.podsWarn = $v
    $script:devViewKey = $null   # low colouring moves with the threshold
    $script:saveTimer.Stop(); $script:saveTimer.Start()
})
(G 'LowBatOn').Add_Click({
    $on = [bool](G 'LowBatOn').IsChecked
    $script:settings.devLowOn = $on; $sync.Settings.devLowOn = $on
    (G 'LowBat').IsEnabled = $on
    $script:saveTimer.Stop(); $script:saveTimer.Start()
})
foreach ($pair in @(@('ChkManual', 0), @('Chk15', 15), @('Chk30', 30), @('Chk60', 60))) {
    $rb = G $pair[0]
    $rb.IsChecked = ([int]$script:settings.devCheckMin -eq $pair[1])
    $rb.Add_Checked({
        param($s, $e)
        $script:settings.devCheckMin = [int]$s.Tag
        Set-DevNextScan
        $script:saveTimer.Stop(); $script:saveTimer.Start()
    })
}

$script:glassDevKey = $null
function Update-Glass($d) {
    if (-not $d -or -not $script:shell.IsVisible) { return }
    $deg = [char]0xB0
    if ((G 'PageHome').Visibility -eq 'Visible') {
        foreach ($s in @(@('TCpu', $d.CpuTemp), @('TGpu', $d.GpuTemp), @('TSsd', $d.SsdTemp))) {
            (G $s[0]).Text = $(if ($null -ne $s[1]) { '{0}{1}' -f [int]$s[1], $deg } else { '--' })
        }
        if ($null -ne $d.CpuName) { Set-ModelLabel (G 'NCpu') $d.CpuName }
        if ($null -ne $d.GpuName) { Set-ModelLabel (G 'NGpu') $d.GpuName }
        if ($null -ne $d.SsdName) { Set-ModelLabel (G 'NSsd') $d.SsdName }
        (G 'RCpu').Text = $(if ($null -ne $d.CpuFan) { '{0}' -f $d.CpuFan } else { '--' })
        (G 'RCase').Text = $(if ($null -ne $d.CaseFan) { '{0}' -f $d.CaseFan } else { '--' })
        (G 'RGpu').Text = $(if ($null -ne $d.GpuFan1) { '{0}' -f $d.GpuFan1 } else { '--' })
        # what each fan is being asked for in this mode
        $mode = [string]$d.ActiveMode
        $case = switch ($mode) {
            'quiet' { '{0}% set' -f $script:settings.quietCase }
            'normal' { '{0}% set' -f $script:settings.normalCase }
            'performance' { '{0}% set' -f $script:settings.perfCase }
            'curve' { $(if ($null -ne $d.CurveTarget) { '{0}% from curve' -f $d.CurveTarget } else { 'Following the curve' }) }
            default { 'Automatic' }
        }
        if ($d.BoostActive) { $case = 'Boost {0}%' -f $script:settings.boostCase }
        (G 'DutyCase').Text = $case
        (G 'DutyCpu').Text = $(if ($mode -eq 'performance') { '{0}% set' -f $script:settings.perfCpu } else { 'Motherboard curve' })
        if ($null -ne $d.MbName -and -not (G 'PcBoard').Text) { (G 'PcBoard').Text = $d.MbName }
        if ($script:glassReveal -or $script:histTick % 4 -eq 0) { Update-GlassHero $d }
    }
    # devices: redraw only when the list or a level changed (rings animate)
    if ((G 'PageHome').Visibility -eq 'Visible' -or (G 'PagePods').Visibility -eq 'Visible') {
        $key = Get-DevViewKey
        if ($script:glassReveal -or $key -ne $script:devViewKey) { $script:devViewKey = $key; Update-DevViews }
    }
    if ((G 'PageFans').Visibility -eq 'Visible') {
        if ($script:glassReveal -or [string]$d.ActiveMode -ne $script:gFansMode) { Update-GlassFans ([string]$d.ActiveMode) }
        if ($script:glassReveal -or $script:histTick % 4 -eq 0) {
            Show-GlassFansChart
            if ((G 'CurvePanel').IsVisible -and $null -eq $script:gCurveDrag) { Show-GlassCurve }
        }
    }
    if ((G 'PageDisplays').Visibility -eq 'Visible') {
        if ($script:glassReveal) { $script:gDispGen = $sync.Ddc.Gen; Open-GlassDisplays }
        elseif ($sync.Ddc.Gen -ne $script:gDispGen -and [System.Windows.Input.Mouse]::LeftButton -ne 'Pressed') {
            # a new snapshot; never rebuilt under a dragging hand
            $script:gDispGen = $sync.Ddc.Gen; Show-GlassDisplays
        }
        if ($sync.Ddc.WGen -ne $script:gDispWGen) { $script:gDispWGen = $sync.Ddc.WGen; Show-GDispWrite $sync.Ddc.LastWrite }
    }
    if ((G 'PageOverlay').Visibility -eq 'Visible') {
        if ($script:glassReveal) { Update-GlassOverlay }
        elseif ($script:histTick % 2 -eq 0) {
            Update-GOsdPreview
            (G 'OsdMove').Content = $(if ($script:osdEditing) { 'Done' } else { 'Move on screen' })
        }
    }
    if ((G 'PageSettings').Visibility -eq 'Visible') {
        if ($script:glassReveal) { Update-GlassSettings } elseif ($script:histTick % 2 -eq 0) { Update-GUpdateRow }
    }
    if ($script:glassReveal) {
        if ((G 'PageAlerts').Visibility -eq 'Visible') { Update-GlassAlerts }
        if ((G 'PageProfiles').Visibility -eq 'Visible') { Update-GlassProfiles }
    }
    $script:glassReveal = $false
    Set-GlassModeCards ([string]$d.ActiveMode)
}

# Hero sensor picker: the label opens a menu; the choice sticks.
$script:heroMenuItems = @((G 'HeroPick').ContextMenu.Items)
function Set-HeroPickChecks { foreach ($mi in $script:heroMenuItems) { $mi.IsChecked = ([string]$mi.Tag -eq [string]$script:settings.heroSensor) } }
Set-HeroPickChecks
(G 'HeroPick').Add_Click({
    $cm = (G 'HeroPick').ContextMenu
    $cm.PlacementTarget = G 'HeroPick'; $cm.Placement = 'Bottom'; $cm.IsOpen = $true
})
foreach ($mi in $script:heroMenuItems) {
    $mi.Add_Click({
        param($s, $e)
        $script:settings.heroSensor = [string]$s.Tag
        Set-HeroPickChecks
        $script:glassReveal = $true
        try { Update-Glass $sync.Data } catch { }
        $script:saveTimer.Stop(); $script:saveTimer.Start()
    })
}



# --- Glass: Fans -------------------------------------------------------------
# The sliders under the mode picker are the legacy mode panel's rows
# ($script:modePanelDef) re-dressed: same settings keys, same ranges, same
# Apply-ModeSetting path, so the engine sees exactly what it always did.
# Any setting change from the new pages goes through Set-GSetting.
function Set-GSetting([string]$key, $value) {
    $script:settings[$key] = $value
    $sync.Settings[$key] = $value
    $sync.SettingsChanged = $true
    $script:saveTimer.Stop(); $script:saveTimer.Start()
}
$script:gFanRow = @{
    quietCase  = @('Case fan speed', 'While no boost is running', 0xEC4A)
    boostHigh  = @('Boost above', 'CPU or GPU temperature that wakes the fans up', 0xE9CA)
    boostLow   = @('Resume below', 'Fans settle back once CPU and GPU cool to this', 0xF1E8)
    boostCase  = @('Boost speed', 'Case fan speed while boosting', 0xE945)
    normalCase = @('Case fan speed', 'A steady speed for everyday use', 0xEC4A)
    perfCase   = @('Case fan speed', 'Case fans in Performance', 0xEC4A)
    perfCpu    = @('CPU fan speed', 'CPU cooler in Performance', 0xE950)
}
$script:gFansMode = $null
$script:gFansLoading = $false
function Update-GlassFans([string]$mode) {
    $script:gFansMode = $mode
    $name = $(switch ($mode) { 'quiet' { 'Quiet' } 'normal' { 'Normal' } 'performance' { 'Performance' } 'curve' { 'Curve' } default { 'Auto' } })
    (G 'FansSection').Text = "$name mode"
    $isAuto = ($mode -eq 'auto'); $isCurve = ($mode -eq 'curve')
    (G 'FAutoHint').Visibility = $(if ($isAuto) { 'Visible' } else { 'Collapsed' })
    (G 'FansReset').Visibility = $(if ($isAuto -or $isCurve) { 'Collapsed' } else { 'Visible' })
    (G 'SlidersPanel').Visibility = $(if ($isAuto -or $isCurve) { 'Collapsed' } else { 'Visible' })
    (G 'CurvePanel').Visibility = $(if ($isCurve) { 'Visible' } else { 'Collapsed' })
    if ($isCurve) { [void](G 'CurveCanvas').Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [action]{ Show-GlassCurve }) }
    if ($isAuto -or $isCurve) { return }
    $script:gFansLoading = $true
    try {
        (G 'FBoostCard').Visibility = $(if ($mode -eq 'quiet') { 'Visible' } else { 'Collapsed' })
        (G 'FBoostOn').IsChecked = [bool]$script:settings.boostEnabled
        $boostOff = ($mode -eq 'quiet' -and -not [bool]$script:settings.boostEnabled)
        $def = @($script:modePanelDef[$mode])
        for ($i = 1; $i -le 4; $i++) {
            $slot = G "FSlot$i"; $sl = G "S$i"
            if ($i -gt $def.Count) { $sl.Tag = $null; $slot.Visibility = 'Collapsed'; continue }
            $row = $def[$i - 1]; $key = [string]$row[1]
            $meta = $script:gFanRow[$key]
            $sl.Tag = $null
            $sl.Minimum = [double]$row[2]; $sl.Maximum = [double]$row[3]
            if ($key -eq 'boostLow') { $sl.Maximum = [math]::Min([double]$row[3], [double]$script:settings.boostHigh - 3) }
            $sl.Value = [double]$script:settings[$key]
            $sl.Tag = $row
            (G "FL$i").Text = $(if ($meta) { $meta[0] } else { [string]$row[0] })
            (G "FC$i").Text = $(if ($meta) { $meta[1] } else { '' })
            (G "FI$i").Text = [string][char]$(if ($meta) { $meta[2] } else { 0xEC4A })
            (G "V$i").Text = '{0}{1}' -f [int]$sl.Value, $(if ([string]$row[4] -eq '%') { '%' } else { [string][char]0xB0 })
            $dim = $boostOff -and (@('boostHigh', 'boostLow', 'boostCase') -contains $key)
            $slot.IsEnabled = -not $dim; $slot.Opacity = $(if ($dim) { 0.45 } else { 1.0 })
            $slot.Visibility = 'Visible'
        }
    } finally { $script:gFansLoading = $false }
}
foreach ($i in 1..4) {
    (G "S$i").Add_ValueChanged({ param($s, $e)
        $row = $s.Tag
        if ($null -eq $row) { return }
        $i = [int]($s.Name.Substring(1))
        (G "V$i").Text = '{0}{1}' -f [int]$s.Value, $(if ([string]$row[4] -eq '%') { '%' } else { [string][char]0xB0 })
        if ($script:gFansLoading) { return }
        Apply-ModeSetting ([string]$row[1]) ([int]$s.Value)
        if ([string]$row[1] -eq 'boostHigh') {
            # keep 'Resume below' at least 3 degrees under 'Boost above'
            foreach ($j in 1..4) {
                $o = G "S$j"
                if ($o.Tag -and [string]$o.Tag[1] -eq 'boostLow') { $o.Maximum = [math]::Min(85, [double]$s.Value - 3) }
            }
        }
    })
}
(G 'FBoostOn').Add_Click({
    Set-GSetting 'boostEnabled' ([bool](G 'FBoostOn').IsChecked)
    Update-GlassFans $script:gFansMode
})
(G 'FansReset').Add_Click({
    $mode = $script:gFansMode
    if (-not $mode -or $mode -eq 'auto') { return }
    $defaults = Get-DefaultSettings
    foreach ($row in @($script:modePanelDef[$mode])) { Apply-ModeSetting ([string]$row[1]) ([int]$defaults[$row[1]]) }
    Update-GlassFans $mode
})

# --- curve editor: four draggable points at 40/55/70/80 deg (curve40..80) ---
$script:gCurveKeys = 40, 55, 70, 80
$script:gCurveDrag = $null
$script:gCv = @{ L = 44; R = 18; T = 34; B = 26 }
function Get-GCurveX([double]$t) { $w = (G 'CurveCanvas').ActualWidth; $script:gCv.L + ($t - 30) / 60.0 * ($w - $script:gCv.L - $script:gCv.R) }
function Get-GCurveY([double]$d) { $h = (G 'CurveCanvas').ActualHeight; $script:gCv.T + (1 - $d / 100.0) * ($h - $script:gCv.T - $script:gCv.B) }
function Get-GCurveVal([int]$k) { [int]$script:settings["curve$k"] }
function Get-GCurveDuty([double]$t) {
    $k = $script:gCurveKeys
    if ($t -le $k[0]) { return Get-GCurveVal $k[0] }
    if ($t -ge $k[3]) { return Get-GCurveVal $k[3] }
    for ($i = 0; $i -lt 3; $i++) {
        if ($t -le $k[$i + 1]) { $a = Get-GCurveVal $k[$i]; $b = Get-GCurveVal $k[$i + 1]; return $a + ($b - $a) * ($t - $k[$i]) / ($k[$i + 1] - $k[$i]) }
    }
}
function Show-GlassCurve {
    $c = G 'CurveCanvas'; $c.Children.Clear()
    $w = $c.ActualWidth; $h = $c.ActualHeight; if ($w -le 0) { return }
    $deg = [char]0xB0
    foreach ($d in 0, 25, 50, 75, 100) {
        $y = Get-GCurveY $d
        $gl = New-Object System.Windows.Shapes.Line
        $gl.X1 = $script:gCv.L; $gl.X2 = $w - $script:gCv.R; $gl.Y1 = [math]::Round($y) + 0.5; $gl.Y2 = $gl.Y1; $gl.Stroke = Get-GBrush '#FFFFFF' 0x12
        [void]$c.Children.Add($gl)
        Add-GText $c "$d%" 0 ($y - 8)
    }
    for ($t = 30; $t -le 90; $t += 10) { Add-GText $c "$t$deg" ((Get-GCurveX $t) - 9) ($h - $script:gCv.B + 8) }
    $pts = @(, @(30, (Get-GCurveVal 40))) + @($script:gCurveKeys | ForEach-Object { , @($_, (Get-GCurveVal $_)) }) + @(, @(90, (Get-GCurveVal 80)))
    $line = 'M ' + (($pts | ForEach-Object { Format-GPt (Get-GCurveX $_[0]) (Get-GCurveY $_[1]) }) -join ' L ')
    $g = New-Object System.Windows.Media.LinearGradientBrush
    $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
    $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop (Get-GColor $script:acc.Light2 0x46), 0))
    $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop (Get-GColor $script:acc.Light2 0x05), 1))
    $f = New-Object System.Windows.Shapes.Path
    $f.Data = [System.Windows.Media.Geometry]::Parse($line + ' L ' + (Format-GPt (Get-GCurveX 90) (Get-GCurveY 0)) + ' L ' + (Format-GPt (Get-GCurveX 30) (Get-GCurveY 0)) + ' Z'); $f.Fill = $g
    [void]$c.Children.Add($f)
    $l = New-Object System.Windows.Shapes.Path
    $l.Data = [System.Windows.Media.Geometry]::Parse($line); $l.Stroke = Get-GBrush $script:acc.Light2; $l.StrokeThickness = 2; $l.StrokeLineJoin = 'Round'
    [void]$c.Children.Add($l)
    # where the engine is reading right now (hotter of CPU / GPU) and the speed it buys
    $d0 = $sync.Data; $tNow = $null
    if ($d0) { foreach ($v in @($d0.CpuTemp, $d0.GpuTemp)) { if ($null -ne $v -and ($null -eq $tNow -or [double]$v -gt $tNow)) { $tNow = [double]$v } } }
    if ($null -ne $tNow) {
        $tc = [math]::Max(30, [math]::Min(90, $tNow)); $now = Get-GCurveDuty $tNow; $bx = Get-GCurveX $tc
        $vl = New-Object System.Windows.Shapes.Line
        $vl.X1 = $bx; $vl.X2 = $bx; $vl.Y1 = Get-GCurveY 100; $vl.Y2 = Get-GCurveY 0; $vl.Stroke = Get-GBrush '#FFFFFF' 0x55
        $vl.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@(3, 3))
        [void]$c.Children.Add($vl)
        $bd = New-Object System.Windows.Shapes.Ellipse
        $bd.Width = 10; $bd.Height = 10; $bd.Fill = Get-GBrush '#FFFFFF'
        [System.Windows.Controls.Canvas]::SetLeft($bd, $bx - 5); [System.Windows.Controls.Canvas]::SetTop($bd, (Get-GCurveY $now) - 5)
        [void]$c.Children.Add($bd)
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = ('Now {0:0}{1}  {2}  {3:0}%' -f $tNow, $deg, [char]0x2192, $now); $lbl.Style = $script:app.FindResource('Caption'); $lbl.Foreground = Get-GBrush '#FFFFFF'
        if ($bx -gt $w - 170) { [System.Windows.Controls.Canvas]::SetLeft($lbl, $bx - 160) } else { [System.Windows.Controls.Canvas]::SetLeft($lbl, $bx + 8) }
        [System.Windows.Controls.Canvas]::SetTop($lbl, (Get-GCurveY 100) - 28)
        [void]$c.Children.Add($lbl)
    }
    foreach ($k in $script:gCurveKeys) {
        $x = Get-GCurveX $k; $y = Get-GCurveY (Get-GCurveVal $k)
        $th = New-Object System.Windows.Controls.Grid
        $th.Width = 22; $th.Height = 22; $th.Cursor = [System.Windows.Input.Cursors]::SizeNS
        $o = New-Object System.Windows.Shapes.Ellipse; $o.Fill = Get-GBrush '#454545'; $o.Stroke = Get-GBrush '#FFFFFF' 0x33
        $i = New-Object System.Windows.Shapes.Ellipse; $i.Width = $(if ($script:gCurveDrag -eq $k) { 10 } else { 12 }); $i.Height = $i.Width; $i.Fill = Get-GBrush $script:acc.Light2
        [void]$th.Children.Add($o); [void]$th.Children.Add($i)
        [System.Windows.Controls.Canvas]::SetLeft($th, $x - 11); [System.Windows.Controls.Canvas]::SetTop($th, $y - 11)
        [void]$c.Children.Add($th)
        $v = New-Object System.Windows.Controls.TextBlock
        $v.Text = '{0}%' -f (Get-GCurveVal $k); $v.Style = $script:app.FindResource('BodyStrong'); $v.FontSize = 12; $v.Width = 30; $v.TextAlignment = 'Center'
        [System.Windows.Controls.Canvas]::SetLeft($v, $x - 15); [System.Windows.Controls.Canvas]::SetTop($v, $y - 32)
        [void]$c.Children.Add($v)
    }
}
$script:gCurveCanvas = G 'CurveCanvas'
$script:gCurveCanvas.Add_MouseLeftButtonDown({
    param($s, $e)
    $p = $e.GetPosition($script:gCurveCanvas)
    foreach ($k in $script:gCurveKeys) {
        if ([math]::Abs($p.X - (Get-GCurveX $k)) -lt 16 -and [math]::Abs($p.Y - (Get-GCurveY (Get-GCurveVal $k))) -lt 16) {
            $script:gCurveDrag = $k; [void]$script:gCurveCanvas.CaptureMouse(); Show-GlassCurve; break
        }
    }
})
$script:gCurveCanvas.Add_MouseMove({
    param($s, $e)
    if ($null -eq $script:gCurveDrag) { return }
    $p = $e.GetPosition($script:gCurveCanvas)
    $h = $script:gCurveCanvas.ActualHeight
    $d = [math]::Round((1 - ($p.Y - $script:gCv.T) / ($h - $script:gCv.T - $script:gCv.B)) * 100)
    # a curve never dips: each point stays between its neighbours; the engine
    # never runs case fans under 20%
    $i = [array]::IndexOf($script:gCurveKeys, $script:gCurveDrag)
    $min = $(if ($i -gt 0) { Get-GCurveVal $script:gCurveKeys[$i - 1] } else { 20 })
    $max = $(if ($i -lt 3) { Get-GCurveVal $script:gCurveKeys[$i + 1] } else { 100 })
    $v = [int][math]::Max([math]::Max(20, $min), [math]::Min($max, $d))
    if ($v -ne (Get-GCurveVal $script:gCurveDrag)) { Apply-ModeSetting "curve$($script:gCurveDrag)" $v; Show-GlassCurve }
})
$script:gCurveCanvas.Add_MouseLeftButtonUp({ $script:gCurveDrag = $null; $script:gCurveCanvas.ReleaseMouseCapture(); Show-GlassCurve })
$script:gCurveCanvas.Add_SizeChanged({ if ((G 'CurvePanel').IsVisible) { Show-GlassCurve } })
(G 'CurveReset').Add_Click({
    $defaults = Get-DefaultSettings
    foreach ($k in $script:gCurveKeys) { Apply-ModeSetting "curve$k" ([int]$defaults["curve$k"]) }
    Show-GlassCurve
})

# --- activity chart: the same 10-minute fan history the legacy graph used ---
function Show-GlassFansChart {
    $c = G 'FansChart'; $c.Children.Clear()
    if ($c.ActualWidth -le 0 -or $script:histFanCpu.Count -lt 2) { return }
    $mx = 800.0
    foreach ($h in @($script:histFanCpu, $script:histFanCase)) { if ($h.Count) { $mx = [math]::Max($mx, ($h | Measure-Object -Maximum).Maximum) } }
    $hi = [math]::Ceiling($mx * 1.1 / 100) * 100
    Add-GHLine $c 2 '#FFFFFF' 0x10; Add-GHLine $c ($c.ActualHeight - 2) '#FFFFFF' 0x10
    Add-GText $c ('{0} rpm' -f $hi) 0 4 -Right
    # every 4th sample keeps the path light: 300 points over 10 minutes
    $cpu = New-Object 'System.Collections.Generic.List[double]'; $case = New-Object 'System.Collections.Generic.List[double]'
    for ($i = 0; $i -lt $script:histFanCpu.Count; $i += 4) { $cpu.Add($script:histFanCpu[$i]); $case.Add($script:histFanCase[$i]) }
    Add-GSeries $c $cpu '#FFFFFF' 0 $hi 0x18 1.6
    Add-GSeries $c $case $script:acc.Light2 0 $hi 0x40 2
}

# --- Glass: Alerts -------------------------------------------------------------
# Comfort targets (warn*), safety limits (cpu/gpuMaxTemp), game detection
# (gameAction / gameOnLoad / gameCooldownSec) and the notification switch.
# Ranges in the XAML match Import-Settings' validation.
$script:gAlertSliders = @(
    @('WCpu', 'WCpuV', 'warnCpu', 'deg'), @('WGpu', 'WGpuV', 'warnGpu', 'deg'),
    @('WSsd', 'WSsdV', 'warnSsd', 'deg'), @('WMb', 'WMbV', 'warnMb', 'deg'),
    @('LimCpu', 'LimCpuV', 'cpuMaxTemp', 'deg'), @('LimGpu', 'LimGpuV', 'gpuMaxTemp', 'deg'),
    @('GameLoad', 'GameLoadV', 'gameOnLoad', 'pct'), @('GameCool', 'GameCoolV', 'gameCooldownSec', 'sec'))
$script:gAlertsLoading = $false
function Format-GAlertVal([string]$kind, [int]$v) {
    switch ($kind) { 'deg' { '{0}{1}' -f $v, [char]0xB0 } 'pct' { '{0}%' -f $v } default { $(if ($v -le 0) { 'Off' } else { '{0} s' -f $v }) } }
}
function Update-GlassAlerts {
    $script:gAlertsLoading = $true
    try {
        foreach ($r in $script:gAlertSliders) {
            $sl = G $r[0]; $sl.Tag = $r
            $sl.Value = [double]$script:settings[$r[2]]
            (G $r[1]).Text = Format-GAlertVal $r[3] ([int]$sl.Value)
        }
        $act = [string]$script:settings.gameAction
        (G 'GameOn').IsChecked = ($act -ne 'off')
        (G 'GaPerf').IsChecked = ($act -ne 'curve')
        (G 'GaCurve').IsChecked = ($act -eq 'curve')
        Set-GlassGameRows
        (G 'ToastOn').IsChecked = [bool]$script:settings.toastsOn
        (G 'TestToast').IsEnabled = [bool]$script:settings.toastsOn
        # the limits name the actual parts in this PC
        $d0 = $sync.Data
        (G 'LimCpuCap').Text = $(if ($d0 -and $d0.CpuName) { [string]$d0.CpuName } else { 'Processor' })
        (G 'LimGpuCap').Text = $(if ($d0 -and $d0.GpuName) { [string]$d0.GpuName } else { 'Graphics card' })
    } finally { $script:gAlertsLoading = $false }
}
function Set-GlassGameRows {
    $on = [bool](G 'GameOn').IsChecked
    (G 'GameRows').IsEnabled = $on; (G 'GameRows').Opacity = $(if ($on) { 1 } else { 0.45 })
}
foreach ($r in $script:gAlertSliders) {
    (G $r[0]).Add_ValueChanged({ param($s, $e)
        $r = $s.Tag; if ($null -eq $r) { return }
        $v = [int][math]::Round($s.Value)
        (G $r[1]).Text = Format-GAlertVal $r[3] $v
        if ($script:gAlertsLoading -or [int]$script:settings[$r[2]] -eq $v) { return }
        Set-GSetting ([string]$r[2]) $v
    })
}
function Save-GlassGameAction {
    if ($script:gAlertsLoading) { return }
    $act = $(if (-not [bool](G 'GameOn').IsChecked) { 'off' } elseif ([bool](G 'GaCurve').IsChecked) { 'curve' } else { 'performance' })
    Set-GSetting 'gameAction' $act
    # the legacy settings sheet stages this value too; keep it from writing an old one back
    $script:gameActionUI = $act
}
(G 'GameOn').Add_Click({ Set-GlassGameRows; Save-GlassGameAction })
(G 'GaPerf').Add_Checked({ Save-GlassGameAction })
(G 'GaCurve').Add_Checked({ Save-GlassGameAction })
(G 'ToastOn').Add_Click({
    $on = [bool](G 'ToastOn').IsChecked
    Set-GSetting 'toastsOn' $on
    (G 'TestToast').IsEnabled = $on
})
(G 'TestToast').Add_Click({
    $ok = Show-Toast 'Vento' 'Notifications are working. Safety, low battery and update notices will show up like this.' 'vento-test'
    if (-not $ok) { (G 'TestToast').Content = 'Not available' }
})

# --- Glass: Displays -------------------------------------------------------------
# One card per display from the DDC worker's snapshot ($sync.Ddc.Monitors),
# rebuilt when the worker publishes a new one (Gen). Every write goes through
# Queue-DdcSet like the legacy panel, and an input switch keeps its 12 s
# self-revert: on many displays DDC/CI rides the active input, so a wrong
# switch could otherwise leave no way back from software.
$script:gDispGen = -1
$script:gDispWGen = -1
$script:gDispLoading = $false
$script:gMonCards = @()
function Format-GMonTime([int]$mins) { '{0:00}:{1:00}' -f ([math]::Floor($mins / 60)), ($mins % 60) }

function New-GMonCard([int]$idx, $m) {
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Style="{StaticResource Card}" Padding="20,18,20,18" Margin="0,0,12,12">
  <StackPanel>
    <Grid Margin="0,0,0,18">
      <Grid.ColumnDefinitions><ColumnDefinition Width="48"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Style="{StaticResource IconTile}" Width="48" Height="48" CornerRadius="8">
        <TextBlock Text="&#xE7F4;" Style="{StaticResource Glyph}" FontSize="22" HorizontalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
        <TextBlock x:Name="MName" Style="{StaticResource BodyStrong}" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="MInfo" Style="{StaticResource Caption}" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </Grid>
    <TextBlock x:Name="MErr" Text="DDC/CI is not answering. Turn it on in the display's own menu, then Rescan." Style="{StaticResource Caption}" TextWrapping="Wrap" Visibility="Collapsed"/>
    <StackPanel x:Name="MBody">
      <Grid Margin="0,0,0,12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
        <TextBlock Text="&#xE706;" Style="{StaticResource Glyph}" Foreground="{StaticResource TextSecondaryBrush}"/>
        <TextBlock Grid.Column="1" Text="Brightness" Style="{StaticResource Body}" VerticalAlignment="Center"/>
        <Slider Grid.Column="2" x:Name="MB" Style="{StaticResource FluentSlider}" Minimum="0" Maximum="100" IsSnapToTickEnabled="True" TickFrequency="1"/>
        <TextBlock Grid.Column="3" x:Name="MBV" Style="{StaticResource Body}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
      <Grid x:Name="MCRow" Margin="0,0,0,12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
        <TextBlock Text="&#xE793;" Style="{StaticResource Glyph}" Foreground="{StaticResource TextSecondaryBrush}"/>
        <TextBlock Grid.Column="1" Text="Contrast" Style="{StaticResource Body}" VerticalAlignment="Center"/>
        <Slider Grid.Column="2" x:Name="MC" Style="{StaticResource FluentSlider}" Minimum="0" Maximum="100" IsSnapToTickEnabled="True" TickFrequency="1"/>
        <TextBlock Grid.Column="3" x:Name="MCV" Style="{StaticResource Body}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
      <StackPanel x:Name="MPreRow" Margin="28,4,0,0">
        <TextBlock Text="Color" Style="{StaticResource Body}" Margin="0,0,0,6"/>
        <Border Style="{StaticResource SegHost}" HorizontalAlignment="Left"><WrapPanel x:Name="MPre"/></Border>
      </StackPanel>
      <StackPanel x:Name="MInRow" Margin="28,12,0,0">
        <TextBlock Text="Input" Style="{StaticResource Body}" Margin="0,0,0,6"/>
        <Border Style="{StaticResource SegHost}" HorizontalAlignment="Left"><WrapPanel x:Name="MIn"/></Border>
      </StackPanel>
      <Button x:Name="MAdvBtn" Style="{StaticResource LinkButton}" Content="More controls" Margin="22,14,0,0" HorizontalAlignment="Left"/>
      <StackPanel x:Name="MAdv" Visibility="Collapsed" Margin="0,10,0,0">
        <Grid x:Name="MSharpRow" Margin="0,0,0,10">
          <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
          <TextBlock Text="&#xE8B3;" Style="{StaticResource Glyph}" Foreground="{StaticResource TextSecondaryBrush}"/>
          <TextBlock Grid.Column="1" Text="Sharpness" Style="{StaticResource Body}" VerticalAlignment="Center"/>
          <Slider Grid.Column="2" x:Name="MSharp" Style="{StaticResource FluentSlider}" IsSnapToTickEnabled="True" TickFrequency="1"/>
          <TextBlock Grid.Column="3" x:Name="MSharpV" Style="{StaticResource Body}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Grid x:Name="MVolRow" Margin="0,0,0,10">
          <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
          <Button x:Name="MMute" Style="{StaticResource IconButton}" Content="&#xE767;" Width="26" Height="26" FontSize="13" HorizontalAlignment="Left" Margin="-6,0,0,0" ToolTip="Mute the display's speakers"/>
          <TextBlock Grid.Column="1" Text="Volume" Style="{StaticResource Body}" VerticalAlignment="Center"/>
          <Slider Grid.Column="2" x:Name="MVol" Style="{StaticResource FluentSlider}" IsSnapToTickEnabled="True" TickFrequency="1"/>
          <TextBlock Grid.Column="3" x:Name="MVolV" Style="{StaticResource Body}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel x:Name="MRgbRow">
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
            <Ellipse Width="10" Height="10" Fill="#FF7A7A" HorizontalAlignment="Left"/>
            <TextBlock Grid.Column="1" Text="Red" Style="{StaticResource Body}" VerticalAlignment="Center"/>
            <Slider Grid.Column="2" x:Name="MRed" Style="{StaticResource FluentSlider}" IsSnapToTickEnabled="True" TickFrequency="1"/>
            <TextBlock Grid.Column="3" x:Name="MRedV" Style="{StaticResource Body}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
            <Ellipse Width="10" Height="10" Fill="#7FE0A0" HorizontalAlignment="Left"/>
            <TextBlock Grid.Column="1" Text="Green" Style="{StaticResource Body}" VerticalAlignment="Center"/>
            <Slider Grid.Column="2" x:Name="MGreen" Style="{StaticResource FluentSlider}" IsSnapToTickEnabled="True" TickFrequency="1"/>
            <TextBlock Grid.Column="3" x:Name="MGreenV" Style="{StaticResource Body}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
            <Ellipse Width="10" Height="10" Fill="#6FB1FF" HorizontalAlignment="Left"/>
            <TextBlock Grid.Column="1" Text="Blue" Style="{StaticResource Body}" VerticalAlignment="Center"/>
            <Slider Grid.Column="2" x:Name="MBlue" Style="{StaticResource FluentSlider}" IsSnapToTickEnabled="True" TickFrequency="1"/>
            <TextBlock Grid.Column="3" x:Name="MBlueV" Style="{StaticResource Body}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
        </StackPanel>
        <StackPanel x:Name="MModeRow" Margin="28,2,0,0">
          <TextBlock Text="Picture mode" Style="{StaticResource Body}" Margin="0,0,0,6"/>
          <Border Style="{StaticResource SegHost}" HorizontalAlignment="Left"><WrapPanel x:Name="MMode"/></Border>
          <TextBlock x:Name="MModeHint" Text="This display doesn't report its current mode; pick one to set it." Style="{StaticResource Caption}" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>
        </StackPanel>
        <WrapPanel Margin="28,14,0,0">
          <Button x:Name="MResetColor" Style="{StaticResource FluentButton}" Content="Reset colors" FontSize="13" MinHeight="28" Padding="12,3" Margin="0,0,8,8"/>
          <Button x:Name="MResetLevels" Style="{StaticResource FluentButton}" Content="Reset brightness" FontSize="13" MinHeight="28" Padding="12,3" Margin="0,0,8,8"/>
          <Button x:Name="MOff" Style="{StaticResource FluentButton}" Content="Turn off" FontSize="13" MinHeight="28" Padding="12,3" Margin="0,0,8,8"/>
          <Button x:Name="MFactory" Style="{StaticResource FluentButton}" Content="Factory reset" FontSize="13" MinHeight="28" Padding="12,3" Margin="0,0,8,8" Foreground="#FF99A4"/>
        </WrapPanel>
        <TextBlock x:Name="MNa" Style="{StaticResource Caption}" TextWrapping="Wrap" Margin="28,6,0,0"/>
      </StackPanel>
    </StackPanel>
  </StackPanel>
</Border>
"@
    $c = [System.Windows.Markup.XamlReader]::Parse($x)
    $desc = ([string]$m.Desc).Trim()
    $c.FindName('MName').Text = $(if ($desc) { $desc } else { 'Display {0}' -f ($idx + 1) })
    $info = @()
    if ($m.Primary) { $info += 'Primary' }
    if ([int]$m.MapW -gt 0) { $info += '{0} x {1}' -f [int]$m.MapW, [int]$m.MapH }
    if ($null -ne $m.Hz) { $info += '{0} Hz' -f ([double]$m.Hz).ToString('0.#', [cultureinfo]::InvariantCulture) }
    if ($null -ne $m.InCur -and $script:inputNames.ContainsKey([int]$m.InCur)) { $info += $script:inputNames[[int]$m.InCur] }
    $c.FindName('MInfo').Text = $info -join " $($script:dot) "
    if (-not $m.Ok) { $c.FindName('MBody').Visibility = 'Collapsed'; $c.FindName('MErr').Visibility = 'Visible'; return $c }
    $b = $c.FindName('MB'); $b.Maximum = [double][math]::Max(1, [int]$m.BriMax); $b.Value = [double][int]$m.BriCur; $b.Tag = $idx
    $c.FindName('MBV').Text = '{0}' -f [int]$m.BriCur
    $b.Add_ValueChanged({ param($s, $e) Set-GMonLevel ([int]$s.Tag) 'Bri' ([int]$s.Value) })
    if ($null -ne $m.ConCur) {
        $k = $c.FindName('MC'); $k.Maximum = [double][math]::Max(1, [int]$m.ConMax); $k.Value = [double][int]$m.ConCur; $k.Tag = $idx
        $c.FindName('MCV').Text = '{0}' -f [int]$m.ConCur
        $k.Add_ValueChanged({ param($s, $e) Set-GMonLevel ([int]$s.Tag) 'Con' ([int]$s.Value) })
    } else { $c.FindName('MCRow').Visibility = 'Collapsed' }
    foreach ($row in @(@('MPre', 'MPreRow', @($m.Presets), $m.PreCur, $script:presetNames, 0x14), @('MIn', 'MInRow', @($m.Inputs), $m.InCur, $script:inputNames, 0x60))) {
        $codes = @($row[2] | Where-Object { $null -ne $_ })
        if (-not $codes.Count) { $c.FindName($row[1]).Visibility = 'Collapsed'; continue }
        $wp = $c.FindName($row[0])
        foreach ($code in $codes) {
            $rb = New-Object System.Windows.Controls.RadioButton
            $rb.GroupName = 'Mon{0}_{1:X2}' -f $idx, $row[5]; $rb.Style = $script:app.FindResource('SegItem')
            $rb.Content = $(if ($row[4].ContainsKey([int]$code)) { $row[4][[int]$code] } else { '0x{0:X2}' -f [int]$code })
            $rb.IsChecked = ($null -ne $row[3] -and [int]$row[3] -eq [int]$code)
            $rb.Tag = @($idx, [int]$code, [int]$row[5])
            $rb.Add_Checked({ param($s, $e) if (-not $script:gDispLoading) { Set-GMonVcp $s.Tag } })
            [void]$wp.Children.Add($rb)
        }
    }
    Set-GMonAdvanced $c $idx $m
    $c
}

# "More controls": everything else the display answers to over DDC/CI, and
# an honest line about what it keeps to itself.
$script:gMonAdvOpen = @{}
function Set-GMonAdvanced($c, [int]$idx, $m) {
    $adv = $c.FindName('MAdv'); $btn = $c.FindName('MAdvBtn')
    $btn.Tag = @($idx, $adv)
    $open = [bool]$script:gMonAdvOpen[$idx]
    $adv.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
    $btn.Content = $(if ($open) { 'Fewer controls' } else { 'More controls' })
    $btn.Add_Click({ param($s, $e)
        $i = [int]$s.Tag[0]; $o = -not [bool]$script:gMonAdvOpen[$i]; $script:gMonAdvOpen[$i] = $o
        $s.Tag[1].Visibility = $(if ($o) { 'Visible' } else { 'Collapsed' })
        $s.Content = $(if ($o) { 'Fewer controls' } else { 'More controls' })
    })
    $na = @()
    # sliders: name, current, max, VCP code
    foreach ($r in @(@('MSharp', 'MSharpRow', $m.SharpCur, $m.SharpMax, 0x87, 'sharpness'), @('MVol', 'MVolRow', $m.VolCur, $m.VolMax, 0x62, 'speaker volume'),
                     @('MRed', $null, $m.RCur, $m.RMax, 0x16, $null), @('MGreen', $null, $m.GCur, $m.GMax, 0x18, $null), @('MBlue', $null, $m.BCur, $m.BMax, 0x1A, $null))) {
        $sl = $c.FindName($r[0])
        if ($null -eq $r[2]) { if ($r[1]) { $c.FindName($r[1]).Visibility = 'Collapsed'; $na += $r[5] }; continue }
        $sl.Maximum = [double][math]::Max(1, [int]$r[3]); $sl.Value = [double][int]$r[2]
        $c.FindName("$($r[0])V").Text = '{0}' -f [int]$r[2]
        $sl.Tag = @($idx, [int]$r[4], $c.FindName("$($r[0])V"))
        $sl.Add_ValueChanged({ param($s, $e)
            $s.Tag[2].Text = '{0}' -f [int]$s.Value
            if (-not $script:gDispLoading) { Queue-DdcSet 'SetVcp' ([int]$s.Tag[0]) ([int]$s.Value) ([int]$s.Tag[1]) }
        })
    }
    if ($null -eq $m.RCur -or $null -eq $m.GCur -or $null -eq $m.BCur) { $c.FindName('MRgbRow').Visibility = 'Collapsed'; $na += 'RGB gain' }
    $mute = $c.FindName('MMute')
    if ($null -eq $m.MuteCur) { $mute.Visibility = 'Hidden' } else {
        $mute.Content = [string][char]$(if ([int]$m.MuteCur -eq 1) { 0xE74F } else { 0xE767 })
        $mute.Tag = $idx
        $mute.Add_Click({ param($s, $e)
            $ms = @($sync.Ddc.Monitors); $i = [int]$s.Tag
            if ($i -ge $ms.Count -or $null -eq $ms[$i].MuteCur) { return }
            $new = $(if ([int]$ms[$i].MuteCur -eq 1) { 2 } else { 1 }); $ms[$i].MuteCur = $new
            Queue-DdcSet 'SetVcp' $i $new 0x8D
            $s.Content = [string][char]$(if ($new -eq 1) { 0xE74F } else { 0xE767 })
        })
    }
    # picture modes, straight from the display's own list
    $modes = @($m.Modes | Where-Object { $null -ne $_ })
    if ($modes.Count -le 1) { $c.FindName('MModeRow').Visibility = 'Collapsed'; $na += 'picture modes' } else {
        $wp = $c.FindName('MMode')
        foreach ($code in $modes) {
            $rb = New-Object System.Windows.Controls.RadioButton
            $rb.GroupName = 'Mon{0}_DC' -f $idx; $rb.Style = $script:app.FindResource('SegItem')
            $rb.Content = Get-MonModeName $m ([int]$code); $rb.Tag = @($idx, [int]$code, 0xDC)
            $rb.IsChecked = ($null -ne $m.ModeCur -and [int]$m.ModeCur -eq [int]$code)
            $rb.Add_Checked({ param($s, $e)
                if ($script:gDispLoading) { return }
                $ms = @($sync.Ddc.Monitors); $t = $s.Tag
                if ([int]$t[0] -lt $ms.Count) { $ms[[int]$t[0]].ModeCur = [int]$t[1] }
                Queue-DdcSet 'SetVcp' ([int]$t[0]) ([int]$t[1]) 0xDC
            })
            [void]$wp.Children.Add($rb)
        }
        if ($null -eq $m.ModeCur) { $c.FindName('MModeHint').Visibility = 'Visible' }
    }
    if (@($m.Inputs).Count -le 1) { $na += 'input switching' }
    # one-shot actions; the destructive one wants a second click
    foreach ($a in @(@('MResetColor', $m.HasColorReset, 0x08, 1), @('MResetLevels', $m.HasLevelReset, 0x05, 1), @('MOff', ($null -ne $m.PowerOff), 0xD6, $m.PowerOff), @('MFactory', $m.HasFactoryReset, 0x04, 1))) {
        $b = $c.FindName($a[0])
        if (-not $a[1]) { $b.Visibility = 'Collapsed'; continue }
        $b.Tag = @($idx, [int]$a[2], [int]$a[3])
        $b.Add_Click({ param($s, $e)
            $t = $s.Tag
            if ($t[1] -eq 0x04 -and [string]$s.Content -ne 'Click again to reset') {
                $s.Content = 'Click again to reset'
                $tm = New-Object System.Windows.Threading.DispatcherTimer; $tm.Interval = [TimeSpan]::FromSeconds(4); $tm.Tag = $s
                $tm.Add_Tick({ param($x, $y) $x.Stop(); $x.Tag.Content = 'Factory reset' }); $tm.Start()
                return
            }
            Queue-DdcSet 'SetVcp' ([int]$t[0]) ([int]$t[2]) ([int]$t[1])
            if ($t[1] -eq 0x04) { $s.Content = 'Factory reset'; if ($script:psDdc) { $sync.DdcQueue.Enqueue(@{ Cmd = 'Enum' }) } }
            if ($t[1] -in 0x05, 0x08) { if ($script:psDdc) { $sync.DdcQueue.Enqueue(@{ Cmd = 'Enum' }) } }
        })
    }
    if ($m.PowerHard) { $c.FindName('MOff').ToolTip = 'Turns this display off. It may need its own power button to come back on.' }
    else { $c.FindName('MOff').ToolTip = 'Puts this display to sleep. It wakes when video returns.' }
    # no MCCS code exists for response time on consumer displays
    $na += 'response time / 1ms mode'
    $c.FindName('MNa').Text = 'Not available over DDC/CI on this display: {0}. Set those in its own menu.' -f ($na -join ', ')
}

# Brightness / contrast: with Match on, the worker's -1 target writes every
# display and the other cards' sliders follow on screen.
function Set-GMonLevel([int]$idx, [string]$what, [int]$v) {
    if ($idx -lt $script:gMonCards.Count) { $script:gMonCards[$idx].FindName("M$($what.Substring(0,1))V").Text = "$v" }
    if ($script:gDispLoading) { return }
    $mons = @($sync.Ddc.Monitors)
    $sync0 = [bool]$script:settings.monSync
    Queue-DdcSet "Set$what" $(if ($sync0) { -1 } else { $idx }) $v 0
    for ($i = 0; $i -lt $mons.Count; $i++) {
        if ($i -ne $idx -and -not $sync0) { continue }
        if ($what -eq 'Bri') { $mons[$i].BriCur = $v } elseif ($null -ne $mons[$i].ConCur) { $mons[$i].ConCur = $v }
        if ($i -ne $idx -and $i -lt $script:gMonCards.Count) {
            $script:gDispLoading = $true
            try { $sl = $script:gMonCards[$i].FindName("M$($what.Substring(0,1))"); if ($sl) { $sl.Value = $v } } finally { $script:gDispLoading = $false }
            $script:gMonCards[$i].FindName("M$($what.Substring(0,1))V").Text = "$v"
        }
    }
    # a hand-set level is no longer the preset
    if ([string]$script:settings.monProfile) { $script:settings.monProfile = ''; Update-GDispPresets }
}
function Set-GMonVcp($t) {
    $i = [int]$t[0]; $val = [int]$t[1]; $code = [int]$t[2]
    $mons = @($sync.Ddc.Monitors); $prev = $null
    if ($i -lt $mons.Count) {
        if ($code -eq 0x14) { $prev = $mons[$i].PreCur; $mons[$i].PreCur = $val }
        else { $prev = $mons[$i].InCur; $mons[$i].InCur = $val }
    }
    Queue-DdcSet 'SetVcp' $i $val $code
    if ($code -eq 0x60 -and $null -ne $prev -and [int]$prev -ne $val) { Start-GMonRevert $i ([int]$prev) $val }
}

# --- input safety net ---
$script:gRevert = $null
$script:gRevertTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:gRevertTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:gRevertTimer.Add_Tick({
    $script:gRevert.Left--
    if ($script:gRevert.Left -le 0) { Stop-GMonRevert $true } else { Show-GMonRevert }
})
function Show-GMonRevert {
    $r = $script:gRevert
    $nm = $(if ($script:inputNames.ContainsKey($r.Now)) { $script:inputNames[$r.Now] } else { '0x{0:X2}' -f $r.Now })
    (G 'DispRevertText').Text = 'Switched to {0}. Going back in {1} s unless you keep it.' -f $nm, $r.Left
    (G 'DispRevertBar').Visibility = 'Visible'
}
function Start-GMonRevert([int]$mon, [int]$back, [int]$now) {
    $script:gRevert = @{ Mon = $mon; Back = $back; Now = $now; Left = 12 }
    Show-GMonRevert
    $script:gRevertTimer.Stop(); $script:gRevertTimer.Start()
}
function Stop-GMonRevert([bool]$goBack) {
    $script:gRevertTimer.Stop()
    $r = $script:gRevert; $script:gRevert = $null
    (G 'DispRevertBar').Visibility = 'Collapsed'
    if ($goBack -and $r) {
        Queue-DdcSet 'SetVcp' $r.Mon $r.Back 0x60
        $mons = @($sync.Ddc.Monitors)
        if ($r.Mon -lt $mons.Count) { $mons[$r.Mon].InCur = $r.Back }
        Show-GlassDisplays
    }
}
(G 'DispRevertKeep').Add_Click({ Stop-GMonRevert $false })
(G 'DispRevertNow').Add_Click({ Stop-GMonRevert $true })

# --- presets (the display profiles: Day, Night, Cinema, Game...) ---
function Update-GDispPresets {
    $wp = G 'DispPresets'
    $script:gDispLoading = $true
    try {
        $wp.Children.Clear()
        foreach ($p in (Get-MonProfiles)) {
            $rb = New-Object System.Windows.Controls.RadioButton
            $rb.GroupName = 'DispPreset'; $rb.Style = $script:app.FindResource('SegItem')
            $rb.Content = Format-ProfName $p.Name; $rb.Tag = [string]$p.Name
            $rb.IsChecked = ([string]$p.Name -eq [string]$script:settings.monProfile)
            $rb.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; Open-GPresetMenu $s })
            $rb.Add_Checked({ param($s, $e)
                if ($script:gDispLoading) { return }
                $mp = Get-MonProfile ([string]$s.Tag)
                if (-not $mp) { return }
                # every display, whatever the legacy panel's scope was
                $prev = [string]$script:settings.monProfileScope
                $script:settings.monProfileScope = 'all'
                try { Apply-MonProfile $mp } catch { } finally { $script:settings.monProfileScope = $prev }
                Show-GlassDisplays
            })
            [void]$wp.Children.Add($rb)
        }
    } finally { $script:gDispLoading = $false }
}

function Show-GlassDisplays {
    $mons = @($sync.Ddc.Monitors)
    (G 'DispStatus').Text = $(if (-not $script:psDdc) { 'DDC/CI is unavailable on this PC' }
                              elseif ($sync.Ddc.Busy) { 'Reading monitors...' }
                              elseif ($mons.Count -eq 0) { 'No DDC/CI display found' }
                              else { '{0} {1} {2} DDC/CI live' -f $mons.Count, $(if ($mons.Count -eq 1) { 'display' } else { 'displays' }), $script:dot })
    $script:gDispLoading = $true
    try {
        $h = G 'MonHost'; $h.Children.Clear()
        $h.Columns = [math]::Max(1, [math]::Min(2, $mons.Count))
        $cards = @()
        for ($i = 0; $i -lt $mons.Count; $i++) { $c = New-GMonCard $i $mons[$i]; $cards += , $c; [void]$h.Children.Add($c) }
        $script:gMonCards = $cards
        (G 'DispPresetCard').Visibility = $(if (@($mons | Where-Object { $_.Ok }).Count) { 'Visible' } else { 'Collapsed' })
        (G 'DispSync').IsChecked = [bool]$script:settings.monSync
        Update-GNight
    } finally { $script:gDispLoading = $false }
    Update-GDispPresets
}
function Open-GlassDisplays {
    Start-DdcWorker
    if ($script:psDdc -and -not $sync.Ddc.Busy) { $sync.DdcQueue.Enqueue(@{ Cmd = 'Enum' }) }
    Show-GlassDisplays
}
(G 'DispRescan').Add_Click({ if ($script:psDdc) { $sync.DdcQueue.Enqueue(@{ Cmd = 'Enum' }); (G 'DispStatus').Text = 'Reading monitors...' } else { Open-GlassDisplays } })
(G 'DispSync').Add_Click({ Set-GSetting 'monSync' ([bool](G 'DispSync').IsChecked) })

# A write the display quietly ignored is said out loud, and the slider snaps
# back to what the display really holds.
function Show-GDispWrite($w) {
    if (-not $w) { return }
    if ($w.Took) { (G 'DispNote').Visibility = 'Collapsed'; return }
    $name = $(if ($script:monWriteNames.ContainsKey([int]$w.Code)) { $script:monWriteNames[[int]$w.Code] } else { '0x{0:X2}' -f [int]$w.Code })
    (G 'DispNote').Text = '{0} stayed at {1} on display {2}: it ignored the change. Some displays only allow it from their own menu or in another color preset.' -f $name, $w.Actual, ([int]$w.Mon + 1)
    (G 'DispNote').Visibility = 'Visible'
    $i = [int]$w.Mon
    if ($null -ne $w.Actual -and $i -lt $script:gMonCards.Count) {
        $nm = $(switch ([int]$w.Code) { 0x10 { 'MB' } 0x12 { 'MC' } default { $null } })
        if ($nm) {
            $script:gDispLoading = $true
            try { $script:gMonCards[$i].FindName($nm).Value = [double][int]$w.Actual; $script:gMonCards[$i].FindName("${nm}V").Text = '{0}' -f [int]$w.Actual } finally { $script:gDispLoading = $false }
        }
    }
}

# --- night schedule (Test-NightShift in the main tick does the applying) ---
function Update-GNight {
    $np = [string]$script:settings.monNightProfile
    (G 'NightOn').IsChecked = [bool]$script:settings.monNight
    (G 'NightFrom').Text = Format-GMonTime ([int]$script:settings.monNightFrom)
    (G 'NightTo').Text = Format-GMonTime ([int]$script:settings.monNightTo)
    (G 'NightText').Text = $(if (Get-MonProfile $np) { 'Switches every display to the {0} preset in this window' -f (Format-ProfName $np) } else { 'Needs a display preset named Night' })
}
function Step-GNight([string]$key, [int]$delta) {
    Set-GSetting $key ((([int]$script:settings[$key] + $delta) % 1440 + 1440) % 1440)
    $script:nightApplied = $false
    Update-GNight
}
(G 'NightFromDn').Add_Click({ Step-GNight 'monNightFrom' (-30) })
(G 'NightFromUp').Add_Click({ Step-GNight 'monNightFrom' 30 })
(G 'NightToDn').Add_Click({ Step-GNight 'monNightTo' (-30) })
(G 'NightToUp').Add_Click({ Step-GNight 'monNightTo' 30 })
(G 'NightOn').Add_Click({
    Set-GSetting 'monNight' ([bool](G 'NightOn').IsChecked)
    $script:nightApplied = $false
    # the schedule needs the displays enumerated to act on them
    if ([bool]$script:settings.monNight) { Start-DdcWorker; Test-NightShift }
    else { Test-NightShift }
})

# --- Glass: Overlay --------------------------------------------------------------
# Every control writes the same osd* settings the legacy sheet did and then
# rebuilds the live overlay (Update-OsdLayout), so a change is visible on the
# game screen right away. The preview card mirrors the chosen theme, metrics
# and per-metric colors with live values.
$script:gOsdNames = @{ fps = 'FPS'; cpu = 'CPU temperature'; gpu = 'GPU temperature'; load = 'GPU load'; ram = 'Memory'
                       ssd = 'SSD temperature'; mb = 'Board temperature'; fan = 'Fan speed'; pods = 'AirPods battery' }
$script:gOsdCornerNames = @{ tl = 'Top left'; tr = 'Top right'; bl = 'Bottom left'; br = 'Bottom right' }
$script:gOsdSwatches = @('#6FB1FF', '#7CF29B', '#FFB25C', '#FF6B7E', '#B18CFF', '#6FE0FF', '#FF6FD8', '#F2F4F7')
$script:gOsdLoading = $false
$script:gOsdPrevVals = @{}

function Set-GOsd([string]$key, $value) {
    Set-GSetting $key $value
    try { Update-OsdLayout } catch { }
    Update-GOsdPreview
}
function Update-GOsdTheme {
    $t = Get-OsdTheme
    foreach ($p in @(@('OsdAccentBrush', $t.Acc), @('OsdPanelBrush', $t.Panel), @('OsdBorderBrush', $t.Border), @('OsdInkBrush', $t.Ink), @('OsdLabBrush', $t.Lab))) {
        [VentoNative.Res]::SetBrush($script:shell.Resources, $p[0], (Get-GColor $p[1]))
    }
}
function Get-GOsdValues {
    $d = $sync.Data; $deg = [char]0xB0; $mid = $script:dot
    if (-not $d) { return @{} }
    $f = { param($v, $u) if ($null -ne $v) { '{0}{1}' -f [int]$v, $u } else { '--' } }
    $fps = '--'
    if ($script:fpsOn -and ('VentoNative.Fps' -as [type])) { try { $n = [VentoNative.Fps]::Current($PID); if ($n -gt 0) { $fps = "$n" } } catch { } }
    $pd = $script:pods
    @{
        fps = $fps; cpu = (& $f $d.CpuTemp $deg); gpu = (& $f $d.GpuTemp $deg); load = (& $f $d.GpuLoad '%')
        ram = $(if ($null -ne $d.RamLoad -and $null -ne $d.RamTemp) { '{0}% {1} {2}{3}' -f [int]$d.RamLoad, $mid, [int]$d.RamTemp, $deg } else { & $f $d.RamLoad '%' })
        ssd = (& $f $d.SsdTemp $deg); mb = (& $f $d.MbTemp $deg)
        fan = '{0} {1} {2}' -f $(if ($null -ne $d.CpuFan) { $d.CpuFan } else { '--' }), $mid, $(if ($null -ne $d.CaseFan) { $d.CaseFan } else { '--' })
        pods = $(if ($pd -and $pd.Seen) { '{0}{1}{2}' -f $(if ($null -ne $pd.L) { $pd.L } else { '-' }), $mid, $(if ($null -ne $pd.R) { $pd.R } else { '-' }) } else { '--' })
    }
}
function Update-GOsdPreview {
    $hostO = G 'OsdItems'; $hostO.Children.Clear()
    $s = $script:settings
    $on = @($script:osdMetricDef | Where-Object { [bool]$s[$_.Key] })
    $vals = Get-GOsdValues
    for ($i = 0; $i -lt $on.Count; $i++) {
        $m = $on[$i]; $hero = ($i -eq 0)
        $v = New-Object System.Windows.Controls.TextBlock
        $v.Text = $(if ($vals.ContainsKey($m.Id)) { $vals[$m.Id] } else { '--' }); $v.FontWeight = 'Bold'; $v.FontSize = $(if ($hero) { 16 } else { 13 }); $v.VerticalAlignment = 'Center'
        $col = [string]$s[$m.Col]
        if ($col) { $v.Foreground = Get-GBrush $col }
        elseif ($hero) { $v.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'OsdAccentBrush') }
        else { $v.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'OsdInkBrush') }
        [System.Windows.Documents.Typography]::SetNumeralAlignment($v, 'Tabular')
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $m.Lab; $l.FontWeight = 'Bold'; $l.FontSize = 10; $l.VerticalAlignment = 'Center'
        $l.Margin = $(if ($i -lt $on.Count - 1) { '4,2,12,0' } else { '4,2,0,0' })
        $l.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'OsdLabBrush')
        [void]$hostO.Children.Add($v); [void]$hostO.Children.Add($l)
    }
    $mock = G 'OsdMock'
    $k = [double]$s.osdScale / 100.0
    $mock.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $k, $k
    $mock.Opacity = [double]$s.osdOpacity / 100.0
    $mock.HorizontalAlignment = $(if ([string]$s.osdCorner -in 'tl', 'bl') { 'Left' } else { 'Right' })
    $mock.VerticalAlignment = $(if ([string]$s.osdCorner -in 'bl', 'br') { 'Bottom' } else { 'Top' })
    $mock.Visibility = $(if ([string]$s.osdMode -eq 'off') { 'Hidden' } else { 'Visible' })
}

# per-metric color: theme color, a swatch, or a custom pick
function Open-GOsdColorMenu($dot) {
    $m = $dot.Tag
    $cm = New-Object System.Windows.Controls.ContextMenu; $cm.Style = $script:app.FindResource('FluentMenu')
    $items = @(@('', 'Theme color')) + @($script:gOsdSwatches | ForEach-Object { , @($_, $_) }) + @(, @('*', 'Custom...'))
    foreach ($it in $items) {
        $mi = New-Object System.Windows.Controls.MenuItem; $mi.Style = $script:app.FindResource('FluentMenuItem')
        $mi.IsChecked = ($it[0] -eq [string]$script:settings[$m.Col])
        if ($it[0] -and $it[0] -ne '*') {
            $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
            $e = New-Object System.Windows.Shapes.Ellipse; $e.Width = 14; $e.Height = 14; $e.Fill = Get-GBrush $it[0]; $e.Margin = '0,0,10,0'
            $tx = New-Object System.Windows.Controls.TextBlock; $tx.Text = $it[1]; $tx.VerticalAlignment = 'Center'
            [void]$sp.Children.Add($e); [void]$sp.Children.Add($tx); $mi.Header = $sp
        } else { $mi.Header = $it[1] }
        $mi.Tag = @($m.Col, $it[0])
        $mi.Add_Click({ param($s, $e)
            $key = [string]$s.Tag[0]; $hex = [string]$s.Tag[1]
            if ($hex -eq '*') { $hex = Show-ColorPicker $(if ([string]$script:settings[$key]) { [string]$script:settings[$key] } else { '#6FB1FF' }); if (-not $hex) { return } }
            Set-GOsd $key $hex
            Show-GOsdMetrics
        })
        [void]$cm.Items.Add($mi)
    }
    $cm.PlacementTarget = $dot; $cm.Placement = 'Bottom'; $cm.IsOpen = $true
}
function Show-GOsdMetrics {
    $rows = G 'MetricRows'; $rows.Children.Clear()
    foreach ($m in $script:osdMetricDef) {
        $g = New-Object System.Windows.Controls.Grid; $g.MinHeight = 50; $g.Margin = '0,0,16,0'
        foreach ($w in -2, -1, -2) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = $(if ($w -eq -1) { New-Object System.Windows.GridLength 1, 'Star' } else { [System.Windows.GridLength]::Auto }); $g.ColumnDefinitions.Add($cd)
        }
        $dot = New-Object System.Windows.Controls.Border; $dot.Width = 14; $dot.Height = 14; $dot.CornerRadius = 7; $dot.VerticalAlignment = 'Center'
        $dot.BorderBrush = Get-GBrush '#FFFFFF' 0x40; $dot.BorderThickness = 1; $dot.Cursor = [System.Windows.Input.Cursors]::Hand; $dot.ToolTip = 'Change its color'
        $col = [string]$script:settings[$m.Col]
        if ($col) { $dot.Background = Get-GBrush $col } else { $dot.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'OsdInkBrush') }
        $dot.Tag = $m
        $dot.Add_MouseLeftButtonUp({ param($s, $e) Open-GOsdColorMenu $s })
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $script:gOsdNames[$m.Id]; $t.Style = $script:app.FindResource('Body'); $t.VerticalAlignment = 'Center'; $t.Margin = '12,0,0,0'
        [System.Windows.Controls.Grid]::SetColumn($t, 1)
        $sw = New-Object System.Windows.Controls.CheckBox; $sw.Style = $script:app.FindResource('ToggleSwitch'); $sw.IsChecked = [bool]$script:settings[$m.Key]; $sw.Tag = $m.Key
        $sw.Add_Click({ param($s, $e)
            Set-GOsd ([string]$s.Tag) ([bool]$s.IsChecked)
            # the AirPods metric is also the Devices page's overlay switch
            if ([string]$s.Tag -eq 'osdPods') { (G 'DevOsd').IsChecked = [bool]$s.IsChecked }
        })
        [System.Windows.Controls.Grid]::SetColumn($sw, 2)
        [void]$g.Children.Add($dot); [void]$g.Children.Add($t); [void]$g.Children.Add($sw)
        [void]$rows.Children.Add($g)
    }
}

function Update-GlassOverlay {
    $s = $script:settings
    $script:gOsdLoading = $true
    try {
        Update-GOsdTheme
        foreach ($n in 'LayBlade', 'LayStrip', 'LayHero', 'LayPills', 'LayGhost', 'LayMicro', 'LayThermo') { (G $n).IsChecked = ([string](G $n).Tag -eq [string]$s.osdLayout) }
        foreach ($n in 'ThSirocco', 'ThEmber', 'ThVenom', 'ThViolet', 'ThCrimson', 'ThMono') { (G $n).IsChecked = ([string](G $n).Tag -eq [string]$s.osdTheme) }
        (G 'OsdThemeName').Text = (Get-Culture).TextInfo.ToTitleCase([string]$s.osdTheme)
        foreach ($n in 'CorTL', 'CorTR', 'CorBL', 'CorBR') { (G $n).IsChecked = ([string](G $n).Tag -eq [string]$s.osdCorner) }
        (G 'OsdCornerName').Text = $(if ([bool]$s.osdFree) { 'Where you dragged it' } else { $script:gOsdCornerNames[[string]$s.osdCorner] })
        (G 'OsdResetPos').Visibility = $(if ([bool]$s.osdFree) { 'Visible' } else { 'Collapsed' })
        (G 'OsdMove').Content = $(if ($script:osdEditing) { 'Done' } else { 'Move on screen' })
        (G 'OsdScale').Value = [double]$s.osdScale; (G 'OsdScaleV').Text = '{0}%' -f [int]$s.osdScale
        (G 'OsdOpacity').Value = [double]$s.osdOpacity; (G 'OsdOpacityV').Text = '{0}%' -f [int]$s.osdOpacity
        foreach ($n in 'OmAuto', 'OmOn', 'OmOff') { (G $n).IsChecked = ([string](G $n).Tag -eq [string]$s.osdMode) }
        (G 'OsdCapSafe').IsChecked = [bool]$s.osdCapSafe
        (G 'OsdSecond').IsChecked = [bool]$s.osdOnSecondary
        Show-GOsdMetrics
    } finally { $script:gOsdLoading = $false }
    Update-GOsdPreview
}
foreach ($n in 'LayBlade', 'LayStrip', 'LayHero', 'LayPills', 'LayGhost', 'LayMicro', 'LayThermo') {
    (G $n).Add_Checked({ param($s, $e) if (-not $script:gOsdLoading) { Set-GOsd 'osdLayout' ([string]$s.Tag) } })
}
foreach ($n in 'ThSirocco', 'ThEmber', 'ThVenom', 'ThViolet', 'ThCrimson', 'ThMono') {
    (G $n).Add_Checked({ param($s, $e)
        if ($script:gOsdLoading) { return }
        Set-GOsd 'osdTheme' ([string]$s.Tag)
        try { Update-OsdAccent } catch { }
        Update-GOsdTheme
        (G 'OsdThemeName').Text = (Get-Culture).TextInfo.ToTitleCase([string]$s.Tag)
    })
}
foreach ($n in 'CorTL', 'CorTR', 'CorBL', 'CorBR') {
    (G $n).Add_Checked({ param($s, $e)
        if ($script:gOsdLoading) { return }
        # picking a corner is an explicit snap back from a dragged position
        $script:settings.osdFree = $false; $sync.Settings.osdFree = $false
        Set-GOsd 'osdCorner' ([string]$s.Tag)
        (G 'OsdCornerName').Text = $script:gOsdCornerNames[[string]$s.Tag]; (G 'OsdResetPos').Visibility = 'Collapsed'
    })
}
foreach ($p in @(@('OsdScale', 'OsdScaleV', 'osdScale'), @('OsdOpacity', 'OsdOpacityV', 'osdOpacity'))) {
    (G $p[0]).Tag = $p
    (G $p[0]).Add_ValueChanged({ param($s, $e)
        $p = $s.Tag; $v = [int][math]::Round($s.Value)
        (G $p[1]).Text = '{0}%' -f $v
        if ($script:gOsdLoading -or [int]$script:settings[$p[2]] -eq $v) { return }
        if ($p[2] -eq 'osdOpacity') {
            # opacity needs no rebuild, just the window's own Opacity
            Set-GSetting 'osdOpacity' $v
            if ($script:osd) { $script:osd.Opacity = $v / 100.0 }
            Update-GOsdPreview
        } else { Set-GOsd $p[2] $v }
    })
}
foreach ($n in 'OmAuto', 'OmOn', 'OmOff') {
    (G $n).Add_Checked({ param($s, $e)
        if ($script:gOsdLoading) { return }
        $m = [string]$s.Tag
        if ($m -ne 'off') { $script:osdModePrev = $m }
        $script:osdModePick = $m
        Set-GSetting 'osdMode' $m
        Update-GOsdPreview
    })
}
(G 'OsdCapSafe').Add_Click({ Set-GSetting 'osdCapSafe' ([bool](G 'OsdCapSafe').IsChecked); try { Set-OsdCapSafe } catch { } })
(G 'OsdSecond').Add_Click({ Set-GOsd 'osdOnSecondary' ([bool](G 'OsdSecond').IsChecked); try { Position-Osd } catch { } })
(G 'OsdMove').Add_Click({
    try { Set-OsdEdit (-not $script:osdEditing) } catch { }
    (G 'OsdMove').Content = $(if ($script:osdEditing) { 'Done' } else { 'Move on screen' })
})
(G 'OsdResetPos').Add_Click({
    Set-GSetting 'osdFree' $false
    try { Position-Osd } catch { }
    (G 'OsdCornerName').Text = $script:gOsdCornerNames[[string]$script:settings.osdCorner]
    (G 'OsdResetPos').Visibility = 'Collapsed'
})

# --- Glass: Settings ---------------------------------------------------------------
# Shortcuts are recorded straight into hk* settings and re-registered at once;
# a combination the OS refuses or another Vento action already owns is said
# on its row. Startup toggles call the same task code as the installer.
function New-GKeycap([string]$text) {
    $b = New-Object System.Windows.Controls.Border; $b.Style = $script:app.FindResource('Keycap')
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $text; $b.Child = $t; $b
}
function Set-GKeys($panel, [string]$combo) {
    $panel.Children.Clear()
    if (-not $combo) {
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = 'Not set'; $t.Style = $script:app.FindResource('CaptionTertiary'); $t.VerticalAlignment = 'Center'
        [void]$panel.Children.Add($t); return
    }
    foreach ($k in ((Format-HotkeyText $combo) -split ' \+ ')) { [void]$panel.Children.Add((New-GKeycap $k)) }
}
$script:gHkRec = $null
$script:gHkRows = @{}
function Show-GHotkeys([hashtable]$problems = @{}) {
    $rows = G 'HotkeyRows'; $rows.Children.Clear(); $script:gHkRows = @{}
    $acts = @($script:hotkeyActions)
    for ($i = 0; $i -lt $acts.Count; $i++) {
        $a = $acts[$i]
        $g = New-Object System.Windows.Controls.Grid; $g.MinHeight = 54
        foreach ($w in '*', 'Auto', 'Auto') {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = $(if ($w -eq '*') { New-Object System.Windows.GridLength 1, 'Star' } else { [System.Windows.GridLength]::Auto }); $g.ColumnDefinitions.Add($cd)
        }
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $(if ($a.Id -eq 'profile') { 'Next profile' } else { $a.Label }); $t.Style = $script:app.FindResource('Body')
        [void]$sp.Children.Add($t)
        if ($problems.ContainsKey($a.Label)) {
            $w0 = New-Object System.Windows.Controls.TextBlock; $w0.Text = $problems[$a.Label]; $w0.Style = $script:app.FindResource('Caption'); $w0.Foreground = Get-GBrush '#FF99A4'
            [void]$sp.Children.Add($w0)
        }
        $kp = New-Object System.Windows.Controls.StackPanel; $kp.Orientation = 'Horizontal'; $kp.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($kp, 1); Set-GKeys $kp ([string]$script:settings[$a.Set])
        $btn = New-Object System.Windows.Controls.Button; $btn.Style = $script:app.FindResource('FluentButton')
        $btn.Content = $(if ([string]$script:settings[$a.Set]) { 'Change' } else { 'Record' })
        $btn.FontSize = 13; $btn.MinHeight = 28; $btn.Padding = '12,3'; $btn.Margin = '14,0,0,0'; $btn.VerticalAlignment = 'Center'; $btn.MinWidth = 96
        [System.Windows.Controls.Grid]::SetColumn($btn, 2)
        $btn.Tag = @{ Act = $a; Panel = $kp }
        $btn.Add_Click({ param($s, $e)
            if ($script:gHkRec) { Stop-GHkRecord }
            $script:gHkRec = $s
            $s.Content = 'Press keys...'
            $kp = $s.Tag.Panel; $kp.Children.Clear()
            $w = New-Object System.Windows.Controls.TextBlock; $w.Text = 'Esc cancels, Backspace clears'; $w.Style = $script:app.FindResource('Caption'); $w.Foreground = $script:app.FindResource('AccentTextBrush')
            [void]$kp.Children.Add($w)
            [void]$s.Focus()
        })
        $btn.Add_LostKeyboardFocus({ param($s, $e) if ($script:gHkRec -eq $s) { Stop-GHkRecord } })
        [void]$g.Children.Add($sp); [void]$g.Children.Add($kp); [void]$g.Children.Add($btn)
        [void]$rows.Children.Add($g)
        if ($i -lt $acts.Count - 1) { $dv = New-Object System.Windows.Controls.Border; $dv.Height = 1; $dv.Background = $script:app.FindResource('DividerBrush'); [void]$rows.Children.Add($dv) }
    }
    # the Profiles page's shortcut row shows the same binding
    $hp = [string]$script:settings.hkProfile
    (G 'CycleKeyText').Text = $(if ($hp) { 'Step through your profiles from anywhere with {0}' -f (Format-HotkeyText $hp) } else { 'Step through your profiles from anywhere' })
    (G 'GoHotkeys').Content = $(if ($hp) { 'Change' } else { 'Set in Settings' })
}
function Stop-GHkRecord {
    $b = $script:gHkRec; $script:gHkRec = $null
    if (-not $b) { return }
    $set = [string]$b.Tag.Act.Set
    Set-GKeys $b.Tag.Panel ([string]$script:settings[$set])
    $b.Content = $(if ([string]$script:settings[$set]) { 'Change' } else { 'Record' })
}
function Save-GHotkey([string]$set, [string]$combo) {
    $script:settings[$set] = $combo; $sync.Settings[$set] = $combo
    $script:hotkeyStage[$set] = $combo
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    $r = Register-Hotkeys
    $probs = @{}
    foreach ($l in @($r.Conflicts)) { if ($l) { $probs[$l] = 'Another app already uses this combination' } }
    foreach ($l in @($r.Dupes)) { if ($l) { $probs[$l] = 'Another Vento shortcut has this combination' } }
    Show-GHotkeys $probs
}
$script:shell.Add_PreviewKeyDown({ param($s, $e)
    $b = $script:gHkRec
    if (-not $b) { return }
    $e.Handled = $true
    $key = $e.Key
    if ($key -eq [System.Windows.Input.Key]::System) { $key = $e.SystemKey }
    $name = $key.ToString()
    if (@('LeftCtrl', 'RightCtrl', 'LeftAlt', 'RightAlt', 'LeftShift', 'RightShift', 'LWin', 'RWin', 'System', 'None') -contains $name) { return }
    if ($key -eq [System.Windows.Input.Key]::Escape) { Stop-GHkRecord; return }
    $set = [string]$b.Tag.Act.Set
    if ($key -eq [System.Windows.Input.Key]::Back -or $key -eq [System.Windows.Input.Key]::Delete) { $script:gHkRec = $null; Save-GHotkey $set ''; return }
    $m = [int][System.Windows.Input.Keyboard]::Modifiers
    if ($m -eq 0) { $b.Content = 'Add Ctrl, Alt or Shift'; return }
    $parts = @()
    if ($m -band [int][System.Windows.Input.ModifierKeys]::Control) { $parts += 'Ctrl' }
    if ($m -band [int][System.Windows.Input.ModifierKeys]::Alt) { $parts += 'Alt' }
    if ($m -band [int][System.Windows.Input.ModifierKeys]::Shift) { $parts += 'Shift' }
    if ($m -band [int][System.Windows.Input.ModifierKeys]::Windows) { $parts += 'Win' }
    $norm = ($parts + $name) -join '+'
    if (-not (Parse-Hotkey $norm)) { $b.Content = 'Unsupported key'; return }
    $script:gHkRec = $null
    Save-GHotkey $set $norm
})

function Update-GlassSettings {
    Show-GHotkeys
    Update-GSettingsExtra
    (G 'StartWin').IsChecked = [bool](Test-AutoStart)
    (G 'KeepTray').IsChecked = [bool]$script:settings.closeToTray
    (G 'AutoUpd').IsChecked = [bool]$script:settings.checkUpdates
    Update-GUpdateRow
}
(G 'StartWin').Add_Click({
    $want = [bool](G 'StartWin').IsChecked
    $err = Set-AutoStart $want
    if ($err) {
        (G 'StartWin').IsChecked = [bool](Test-AutoStart)
        [void][System.Windows.MessageBox]::Show(('Start with Windows could not be changed:{0}{0}{1}' -f [Environment]::NewLine, $err), 'Vento', 'OK', 'Warning')
    }
})
(G 'KeepTray').Add_Click({ Set-GSetting 'closeToTray' ([bool](G 'KeepTray').IsChecked) })
(G 'AutoUpd').Add_Click({ Set-GSetting 'checkUpdates' ([bool](G 'AutoUpd').IsChecked) })

# --- updates: the About row checks on demand and installs what it finds ---
$script:gUpdAsked = $false
function Update-GUpdateRow {
    $b = G 'AboutUpdate'; $t = G 'AboutUpdText'
    if ($sync.Update) {
        $b.Content = 'Install {0}' -f $sync.Update.Version; $b.IsEnabled = $true
        $t.Text = 'Vento {0} is ready to install.' -f $sync.Update.Version; $t.Visibility = 'Visible'
    } elseif ($script:updAr -and -not $script:updAr.IsCompleted) {
        $b.Content = 'Checking...'; $b.IsEnabled = $false; $t.Visibility = 'Collapsed'
    } else {
        $b.Content = 'Check for updates'; $b.IsEnabled = $true
        if ($script:gUpdAsked -and $sync.UpdChecked) {
            $t.Text = $(if ($sync.UpdFailed) { 'Could not reach GitHub. Check the connection and try again.' } else { 'You have the latest version.' })
            $t.Visibility = 'Visible'
        } else { $t.Visibility = 'Collapsed' }
    }
}
function Request-GUpdateCheck {
    $script:gUpdAsked = $true
    Start-UpdateCheck
    Update-GUpdateRow
}
(G 'AboutUpdate').Add_Click({ if ($sync.Update) { Install-Update } else { Request-GUpdateCheck } })


# --- Glass: fan driver watch -----------------------------------------------------
# LibreHardwareMonitor reaches the SuperIO chip through the PawnIO kernel
# driver. When it is missing (uninstalled with other tools, say) the fans fall
# back to their BIOS settings without a word - so Home says it, offers the
# official package, and once the driver is back asks for the restart that
# lets the sensor library open it.
Add-Type -AssemblyName System.ServiceProcess
$script:gDrvHadAtStart = $null
$script:gDrvState = $null      # 'ok' | 'missing' | 'restart'
$script:gDrvDismissed = $false
$script:gDrvNext = [DateTime]::MinValue
function Test-PawnIO {
    try { return [bool]@([System.ServiceProcess.ServiceController]::GetDevices() | Where-Object { $_.ServiceName -eq 'PawnIO' }).Count } catch { return $true }
}
function Update-DriverWatch {
    $now = [DateTime]::Now
    if ($now -lt $script:gDrvNext) { return }
    $script:gDrvNext = $now.AddSeconds($(if ($script:gDrvState -eq 'missing') { 10 } else { 60 }))
    $has = Test-PawnIO
    if ($null -eq $script:gDrvHadAtStart) { $script:gDrvHadAtStart = $has }
    $state = $(if (-not $has) { 'missing' } elseif (-not $script:gDrvHadAtStart) { 'restart' } else { 'ok' })
    if ($state -eq $script:gDrvState) { return }
    $script:gDrvState = $state; $script:gDrvDismissed = $false
    $bar = G 'DriverBar'
    switch ($state) {
        'missing' {
            (G 'DriverTitle').Text = 'Fan control is paused'
            (G 'DriverMsg').Text = "Vento can't reach the fan controller: the PawnIO driver is missing. Your fans are running on their BIOS settings until it is back."
            (G 'DriverFix').Content = 'Install driver'
            $bar.Visibility = 'Visible'
            [void](Show-Toast 'Fan control is paused' 'The PawnIO driver is missing, so your fans are on their BIOS settings. Open Vento to install it again.' 'vento-driver')
        }
        'restart' {
            (G 'DriverTitle').Text = 'Driver installed'
            (G 'DriverMsg').Text = 'Restart Vento so it can take the fans back.'
            (G 'DriverFix').Content = 'Restart Vento'
            $bar.Visibility = 'Visible'
        }
        default { $bar.Visibility = 'Collapsed' }
    }
}
function Restart-Vento {
    $exe = Join-Path $script:AppRoot 'Vento.exe'
    if (-not (Test-Path $exe)) { return }
    # the single-instance lock is released when this one exits; start the new
    # one a moment later
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', ("Start-Sleep -Seconds 3; Start-Process -FilePath '{0}'" -f $exe.Replace("'", "''"))
    Quit-App
}
(G 'DriverFix').Add_Click({
    if ($script:gDrvState -eq 'restart') { Restart-Vento; return }
    # The official package through winget, in a window the user can follow;
    # without winget, the project's own download page.
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wg) { Start-Process -FilePath $wg.Source -ArgumentList 'install', '--id', 'namazso.PawnIO', '-e', '--accept-source-agreements', '--accept-package-agreements' }
    else { Start-Process 'https://pawnio.eu/' }
    (G 'DriverMsg').Text = 'Installing PawnIO. This bar changes as soon as the driver is in place.'
    $script:gDrvNext = [DateTime]::Now.AddSeconds(5)
})
(G 'DriverClose').Add_Click({ (G 'DriverBar').Visibility = 'Collapsed'; $script:gDrvDismissed = $true })

# --- Glass: tray flyout ------------------------------------------------------------
# A left click on the tray icon opens a Quick Settings style panel above the
# taskbar: mode tiles, the overlay switch, this mode's case fan speed, the
# key numbers and the first connected device's battery. It closes when it
# loses focus, like the Windows flyouts it imitates.
$script:fly = Read-UiXaml 'flyout.xaml'
$script:flyHiddenAt = [DateTime]::MinValue
$script:flySync = $false
function F([string]$n) { $script:fly.FindName($n) }
$script:fly.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:fly).Handle
    [System.Windows.Interop.HwndSource]::FromHwnd($h).CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
    $m = New-Object VentoNative.Dwm+MARGINS; $m.l = -1; $m.r = -1; $m.t = -1; $m.b = -1
    [void][VentoNative.Dwm]::DwmExtendFrameIntoClientArea($h, [ref]$m)
    $one = 1; [void][VentoNative.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$one, 4)
    $round = 2; [void][VentoNative.Dwm]::DwmSetWindowAttribute($h, 33, [ref]$round, 4)
    $acr = 3; $hr = [VentoNative.Dwm]::DwmSetWindowAttribute($h, 38, [ref]$acr, 4)
    if ($hr -ne 0) { (F 'FTint').Background = Get-GBrush '#202020' }
})
$script:fly.Add_Deactivated({ if ($script:fly.IsVisible) { $script:fly.Hide(); $script:flyHiddenAt = [DateTime]::Now } })
$script:fly.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $script:fly.Hide() } })

# which setting the slider moves in each mode; Curve and Auto have none
$script:flyCaseKey = @{ quiet = 'quietCase'; normal = 'normalCase'; performance = 'perfCase' }
function Update-GFlyout($d) {
    if (-not $script:fly.IsVisible -or -not $d) { return }
    $deg = [char]0xB0
    $script:flySync = $true
    try {
        $tag = $script:glassModeMap[[string]$d.ActiveMode]
        if ($tag) { $rb = F "Q$tag"; if (-not $rb.IsChecked) { $rb.IsChecked = $true } }
        (F 'QOverlay').IsChecked = ([string]$script:settings.osdMode -ne 'off')
        $key = $script:flyCaseKey[[string]$d.ActiveMode]
        $sl = F 'QCase'
        if ($key) {
            $sl.IsEnabled = $true
            if (-not $sl.IsMouseCaptureWithin) { $sl.Value = [double]$script:settings[$key] }
            (F 'QCaseV').Text = '{0}%' -f [int]$sl.Value
        } else {
            $sl.IsEnabled = $false
            (F 'QCaseV').Text = $(if ($null -ne $d.CurveTarget) { '{0}%' -f $d.CurveTarget } else { 'Auto' })
        }
    } finally { $script:flySync = $false }
    (F 'FBoard').Text = $(if ($null -ne $d.MbTemp) { 'Board {0}{1}' -f [int]$d.MbTemp, $deg } else { '' })
    (F 'QCpu').Text = $(if ($null -ne $d.CpuTemp) { '{0}{1}' -f [int]$d.CpuTemp, $deg } else { '--' })
    (F 'QGpu').Text = $(if ($null -ne $d.GpuTemp) { '{0}{1}' -f [int]$d.GpuTemp, $deg } else { '--' })
    (F 'QRpm').Text = $(if ($null -ne $d.CpuFan) { '{0}' -f $d.CpuFan } else { '--' })
    $vp = [string]$script:settings.ventoProfile
    (F 'QProfile').Text = $(if ($vp) { 'Profile: {0}' -f (Format-ProfName $vp) } else { 'No profile' })
    # device row
    $dev = @(Get-DevSorted | Where-Object { $_.Apple -or $null -ne $_.Battery }) | Select-Object -First 1
    $row = F 'QDevRow'
    if (-not $dev) { $row.Visibility = 'Collapsed'; return }
    $row.Visibility = 'Visible'
    (F 'QPodName').Text = $dev.Name; (F 'QDevGlyph').Text = $dev.Glyph
    $vals = F 'QDevVals'; $vals.Children.Clear()
    $pairs = @()
    if ($dev.Apple) {
        $p = $script:pods
        if ($p -and $p.Seen) { $pairs = @(@('L', $p.L), @('R', $p.R), @('Case', $p.Case)) } else { $pairs = @(, @('', $null)) }
    } else { $pairs = @(, @('', $dev.Battery)) }
    for ($i = 0; $i -lt $pairs.Count; $i++) {
        if ($pairs[$i][0]) {
            $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $pairs[$i][0]; $l.Style = $script:app.FindResource('CaptionTertiary'); $l.VerticalAlignment = 'Center'
            [void]$vals.Children.Add($l)
        }
        $v = New-Object System.Windows.Controls.TextBlock; $v.Style = $script:app.FindResource('BodyStrong'); $v.FontSize = 13
        $v.Text = $(if ($null -ne $pairs[$i][1]) { '{0}%' -f $pairs[$i][1] } else { [string][char]0x2014 })
        $v.Margin = $(if ($i -lt $pairs.Count - 1) { '5,0,12,0' } else { '5,0,0,0' })
        if (Test-DevLow $pairs[$i][1] $false) { $v.Foreground = Get-GBrush '#FF99A4' }
        [void]$vals.Children.Add($v)
    }
}
function Show-GFlyout {
    # a click on the tray icon while it is open first deactivates it; don't reopen
    if (([DateTime]::Now - $script:flyHiddenAt).TotalMilliseconds -lt 350) { return }
    $script:fly.Show()
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:fly.UpdateLayout()
    $script:fly.Left = $wa.Right - $script:fly.ActualWidth - 12
    $script:fly.Top = $wa.Bottom - $script:fly.ActualHeight - 12
    [void]$script:fly.Activate()
    Update-GFlyout $sync.Data
    $b = F 'FBody'
    $tt = New-Object System.Windows.Media.TranslateTransform; $b.RenderTransform = $tt
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-GAnim 24 0 260))
    $b.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-GAnim 0 1 180))
}
function Toggle-GFlyout { if ($script:fly.IsVisible) { $script:fly.Hide(); $script:flyHiddenAt = [DateTime]::Now } else { Show-GFlyout } }
foreach ($t in 'Quiet', 'Normal', 'Perf', 'Curve', 'Auto') {
    $rb = F "Q$t"
    $rb.Tag = ($script:glassModeMap.GetEnumerator() | Where-Object { $_.Value -eq $t } | Select-Object -First 1).Key
    $rb.Add_Checked({ param($s, $e) if (-not $script:flySync) { Set-UserMode ([string]$s.Tag) } })
}
(F 'QOverlay').Add_Click({ Toggle-Overlay })
(F 'QCase').Add_ValueChanged({ param($s, $e)
    (F 'QCaseV').Text = '{0}%' -f [int]$s.Value
    if ($script:flySync) { return }
    $key = $script:flyCaseKey[[string]$sync.Data.ActiveMode]
    if ($key -and [int]$script:settings[$key] -ne [int]$s.Value) { Apply-ModeSetting $key ([int]$s.Value) }
})
(F 'QOpen').Add_Click({ $script:fly.Hide(); Show-Main })
(F 'QExpand').Add_Click({ $script:fly.Hide(); Show-Main })
(F 'QSettings').Add_Click({ $script:fly.Hide(); Show-Main; (G 'NavSettings').IsChecked = $true })
$script:shell.Add_Closed({ try { $script:fly.Close() } catch { } })

# --- Glass: remaining controls ---------------------------------------------------
# Display identify + preset management, AirPods forget, and the two Settings
# rows the legacy sheet had (start in tray, sensor refresh).

# IDENTIFY: flash each display's brightness so cards can be matched to panels
(G 'DispIdentify').Add_Click({
    $mons = @($sync.Ddc.Monitors)
    for ($i = 0; $i -lt $mons.Count; $i++) { if ($mons[$i].Ok) { Queue-DdcSet 'SetBri' $i ([int][math]::Max(0, [int]$mons[$i].BriMax - 5)) 0 } }
    $t = New-Object System.Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromMilliseconds(900)
    $t.Add_Tick({ param($s0, $e0)
        $s0.Stop()
        $ms = @($sync.Ddc.Monitors)
        for ($i = 0; $i -lt $ms.Count; $i++) { if ($ms[$i].Ok) { Queue-DdcSet 'SetBri' $i ([int]$ms[$i].BriCur) 0 } }
    })
    $t.Start()
})

# presets: + saves the first display's current levels; right-click updates or deletes
$script:gPresetColor = '#6FB1FF'
function Show-GPresetColors {
    $w = G 'PresetColors'; $w.Children.Clear()
    foreach ($hex in $script:gProfColors) {
        $b = New-Object System.Windows.Controls.Border
        $b.Width = 28; $b.Height = 28; $b.CornerRadius = 14; $b.Margin = '0,0,8,8'; $b.Cursor = 'Hand'; $b.Background = Get-GBrush $hex; $b.Tag = $hex
        if ($hex -eq $script:gPresetColor) { $b.BorderThickness = 2; $b.BorderBrush = Get-GBrush '#FFFFFF' }
        $b.Add_MouseLeftButtonUp({ param($s, $e) $script:gPresetColor = [string]$s.Tag; Show-GPresetColors })
        [void]$w.Children.Add($b)
    }
}
function Get-GPresetSeed { @($sync.Ddc.Monitors | Where-Object { $_.Ok }) | Select-Object -First 1 }
(G 'DispPresetAdd').Add_Click({
    if (-not (Get-GPresetSeed)) { return }
    $script:gPresetColor = '#6FB1FF'
    (G 'PresetName').Text = 'My preset'; (G 'PresetErr').Visibility = 'Collapsed'
    Show-GPresetColors
    (G 'PresetDialog').Visibility = 'Visible'
    [void](G 'PresetName').Focus(); (G 'PresetName').SelectAll()
})
(G 'PresetCancel').Add_Click({ (G 'PresetDialog').Visibility = 'Collapsed' })
(G 'PresetBackdrop').Add_MouseLeftButtonUp({ (G 'PresetDialog').Visibility = 'Collapsed' })
(G 'PresetSave').Add_Click({
    $name = ([string](G 'PresetName').Text).Trim().ToUpperInvariant()
    $err = G 'PresetErr'
    if (-not $name) { $err.Text = 'Give the preset a name.'; $err.Visibility = 'Visible'; return }
    if (Get-MonProfile $name) { $err.Text = 'A preset with this name already exists.'; $err.Visibility = 'Visible'; return }
    $m = Get-GPresetSeed
    if (-not $m) { (G 'PresetDialog').Visibility = 'Collapsed'; return }
    $arr = @(Get-MonProfiles)
    $arr += , @{ Name = $name; Color = $script:gPresetColor; Bri = [int]$m.BriCur
                 Con = $(if ($null -ne $m.ConCur) { [int]$m.ConCur } else { 50 }); Preset = $(if ($null -ne $m.PreCur) { [int]$m.PreCur } else { 0 }); Builtin = $false }
    Save-MonProfiles $arr
    $script:settings.monProfile = $name
    (G 'PresetDialog').Visibility = 'Collapsed'
    Update-GDispPresets
})
function Open-GPresetMenu($rb) {
    $name = [string]$rb.Tag; $p = Get-MonProfile $name
    if (-not $p) { return }
    $cm = New-Object System.Windows.Controls.ContextMenu; $cm.Style = $script:app.FindResource('FluentMenu')
    $up = New-Object System.Windows.Controls.MenuItem; $up.Style = $script:app.FindResource('FluentMenuItem'); $up.Header = 'Update with current levels'; $up.Tag = $name
    $up.Add_Click({ param($s, $e)
        $m = Get-GPresetSeed; if (-not $m) { return }
        $arr = @(Get-MonProfiles | ForEach-Object {
            if ($_.Name -eq [string]$s.Tag) {
                $_.Bri = [int]$m.BriCur
                if ($null -ne $m.ConCur) { $_.Con = [int]$m.ConCur }
                if ($null -ne $m.PreCur) { $_.Preset = [int]$m.PreCur }
            }
            , $_
        })
        Save-MonProfiles $arr
    })
    [void]$cm.Items.Add($up)
    if (-not $p.Builtin) {
        $del = New-Object System.Windows.Controls.MenuItem; $del.Style = $script:app.FindResource('FluentMenuItem'); $del.Header = 'Delete'; $del.Tag = $name
        $del.Add_Click({ param($s, $e)
            $n = [string]$s.Tag
            Save-MonProfiles @(Get-MonProfiles | Where-Object { $_.Name -ne $n })
            if ([string]$script:settings.monProfile -eq $n) { $script:settings.monProfile = '' }
            # a Vento profile pointing at it falls back to leaving displays alone
            $vps = @(Get-VentoProfiles | ForEach-Object { if ([string]$_.Display -eq $n) { $_.Display = '' }; , $_ })
            Save-VentoProfiles $vps
            Update-GDispPresets
        })
        [void]$cm.Items.Add($del)
    }
    $cm.PlacementTarget = $rb; $cm.IsOpen = $true
}

# AirPods: unbind, so the next pair held close to the PC is learned instead
(G 'PodsForget').Add_Click({
    $script:settings.podsModel = 0; $sync.Settings.podsModel = 0
    if ('VentoNative.Pods' -as [type]) { try { [VentoNative.Pods]::SetModel(0) } catch { } }
    $script:pods = $null; $script:podsLearn = $null; $script:podsFiltered = 0
    $script:podsWarned = @{ L = $false; R = $false; C = $false }
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    $script:podsSniffUntil = [DateTime]::Now.AddSeconds($script:podsSniffLen)
    try { Update-PodsTick } catch { }
    $script:devViewKey = $null
    (G 'PodSub').Text = 'Forgotten. Hold the AirPods you want next to the PC with the case open.'
})

# Settings: start in the tray, sensor refresh
(G 'StartMin').Add_Click({ Set-GSetting 'startMinimized' ([bool](G 'StartMin').IsChecked) })
(G 'Poll').Add_ValueChanged({ param($s, $e)
    $v = [int][math]::Round($s.Value)
    (G 'PollV').Text = '{0} s' -f $v
    if ([int]$script:settings.updateIntervalMs -ne $v * 1000 -and -not $script:gPollLoading) { Set-GSetting 'updateIntervalMs' ($v * 1000) }
})
$script:gPollLoading = $false
function Update-GSettingsExtra {
    $script:gPollLoading = $true
    try {
        (G 'StartMin').IsChecked = [bool]$script:settings.startMinimized
        (G 'Poll').Value = [math]::Round([int]$script:settings.updateIntervalMs / 1000)
        (G 'PollV').Text = '{0} s' -f [int](G 'Poll').Value
    } finally { $script:gPollLoading = $false }
}
# --- Glass: Profiles ---------------------------------------------------------
# Cards for every Vento profile (settings.ventoProfiles - the same list the
# tray submenu and the cycle hotkey use), chips on Home, and an editor
# dialog. Apply goes through Apply-VentoProfile, so fans, overlay and
# displays switch exactly as they do from the tray.
$script:gFanName = @{ quiet = 'Quiet'; normal = 'Normal'; performance = 'Performance'; curve = 'Curve'; auto = 'Auto' }
$script:gOsdName = @{ on = 'On'; off = 'Off'; auto = 'While gaming' }
$script:gProfColors = @('#7FE0A0', '#FF7A8A', '#FFC46F', '#8F86FF', '#6FB1FF', '#FF9E6F', '#6FE0FF', '#FF6FD8', '#B6FF6F')
# Built-ins are stored upper-case (GAMING); the new design reads them in
# title case. A name the user typed in mixed case is shown as typed.
function Format-ProfName([string]$n) {
    if ($n -cmatch '^[A-Z0-9 ]+$') { return [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($n.ToLowerInvariant()) }
    $n
}
function ConvertTo-XmlText([string]$s) { [System.Security.SecurityElement]::Escape($s) }

function New-ProfileCard($p, [bool]$active) {
    $col = [string]$p.Color
    $c6 = $col.TrimStart('#')
    $disp = $(if ([string]$p.Display) { Format-ProfName ([string]$p.Display) } else { 'Unchanged' })
    $fan = $(if ($script:gFanName.ContainsKey([string]$p.Fan)) { $script:gFanName[[string]$p.Fan] } else { [string]$p.Fan })
    $osd = $(if ($script:gOsdName.ContainsKey([string]$p.Overlay)) { $script:gOsdName[[string]$p.Overlay] } else { [string]$p.Overlay })
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Style="{StaticResource Card}" Margin="0,0,12,12" Padding="0">
  <Grid>
    <Border CornerRadius="8" IsHitTestVisible="False">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
          <GradientStop Color="#26$c6" Offset="0"/>
          <GradientStop Color="#00$c6" Offset="0.6"/>
        </LinearGradientBrush>
      </Border.Background>
    </Border>
    <StackPanel Margin="20,18,20,18">
      <Grid>
        <StackPanel Orientation="Horizontal" Margin="0,0,70,0">
          <Ellipse Width="10" Height="10" Fill="$col" VerticalAlignment="Center"/>
          <TextBlock Text="$(ConvertTo-XmlText (Format-ProfName $p.Name))" Style="{StaticResource Subtitle}" FontSize="18" Margin="10,0,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <Border CornerRadius="10" Background="{DynamicResource AccentBrush}" Padding="9,2,9,3" HorizontalAlignment="Right" VerticalAlignment="Center" Visibility="$(if ($active) { 'Visible' } else { 'Collapsed' })">
          <TextBlock Text="Active" Style="{StaticResource Caption}" Foreground="#000000" FontWeight="SemiBold"/>
        </Border>
      </Grid>
      <Grid Margin="0,16,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="26"/><RowDefinition Height="26"/></Grid.RowDefinitions>
        <Viewbox Width="14" Height="14" HorizontalAlignment="Left"><Path Data="{StaticResource FanGeometrySmall}" Style="{StaticResource FluentIcon}" Fill="{StaticResource TextSecondaryBrush}"/></Viewbox>
        <TextBlock Grid.Column="1" Text="Fans" Style="{StaticResource Caption}" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="2" Text="$(ConvertTo-XmlText $fan)" Style="{StaticResource Body}" VerticalAlignment="Center"/>
        <TextBlock Grid.Row="1" Text="&#xE81E;" Style="{StaticResource Glyph}" FontSize="14" Foreground="{StaticResource TextSecondaryBrush}"/>
        <TextBlock Grid.Row="1" Grid.Column="1" Text="Overlay" Style="{StaticResource Caption}" VerticalAlignment="Center"/>
        <TextBlock Grid.Row="1" Grid.Column="2" Text="$(ConvertTo-XmlText $osd)" Style="{StaticResource Body}" VerticalAlignment="Center"/>
        <TextBlock Grid.Row="2" Text="&#xE7F4;" Style="{StaticResource Glyph}" FontSize="14" Foreground="{StaticResource TextSecondaryBrush}"/>
        <TextBlock Grid.Row="2" Grid.Column="1" Text="Displays" Style="{StaticResource Caption}" VerticalAlignment="Center"/>
        <TextBlock Grid.Row="2" Grid.Column="2" Text="$(ConvertTo-XmlText $disp)" Style="{StaticResource Body}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </Grid>
      <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
        <Button Style="{StaticResource AccentButton}" Content="$(if ($active) { 'Apply again' } else { 'Apply' })" FontSize="13" MinHeight="30" Padding="16,4"/>
        <Button Style="{StaticResource FluentButton}" Content="Edit" FontSize="13" MinHeight="30" Padding="16,4" Margin="8,0,0,0"/>
      </StackPanel>
    </StackPanel>
  </Grid>
</Border>
"@
    $card = [System.Windows.Markup.XamlReader]::Parse($x)
    $btns = $card.Child.Children[1].Children[2].Children
    $btns[0].Tag = [string]$p.Name; $btns[1].Tag = [string]$p.Name
    $btns[0].Add_Click({ param($s, $e) Apply-VentoProfile ([string]$s.Tag) })
    $btns[1].Add_Click({ param($s, $e) Open-ProfileDialog ([string]$s.Tag) })
    $card
}
function New-ProfileAddTile {
    $x = @"
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,0,12,12" MinHeight="196" Cursor="Hand" Background="Transparent">
  <Rectangle RadiusX="8" RadiusY="8" Stroke="#3DFFFFFF" StrokeThickness="1" StrokeDashArray="4 3"/>
  <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
    <Border Width="40" Height="40" CornerRadius="20" Background="#0FFFFFFF" HorizontalAlignment="Center">
      <TextBlock Text="&#xE710;" Style="{StaticResource Glyph}" HorizontalAlignment="Center"/>
    </Border>
    <TextBlock Text="New profile" Style="{StaticResource BodyStrong}" HorizontalAlignment="Center" Margin="0,10,0,0"/>
    <TextBlock Text="Fans, overlay and displays under one name" Style="{StaticResource Caption}" HorizontalAlignment="Center" Margin="0,2,0,0"/>
  </StackPanel>
</Grid>
"@
    $t = [System.Windows.Markup.XamlReader]::Parse($x)
    $t.Add_MouseLeftButtonUp({ Open-ProfileDialog '' })
    $t
}

$script:gProfChipSync = $false
function Update-GlassProfiles {
    $active = [string]$script:settings.ventoProfile
    $ps = @(Get-VentoProfiles)
    $hostP = G 'ProfileHost'; $hostP.Children.Clear()
    foreach ($p in $ps) { [void]$hostP.Children.Add((New-ProfileCard $p ($p.Name -eq $active))) }
    [void]$hostP.Children.Add((New-ProfileAddTile))
    # Home: chips for the first four, checked on the active one
    $script:gProfChipSync = $true
    try {
        $hc = G 'HomeProfiles'; $hc.Children.Clear()
        foreach ($p in @($ps | Select-Object -First 4)) {
            $rb = New-Object System.Windows.Controls.RadioButton
            $rb.GroupName = 'HomeProfile'; $rb.Style = $script:app.FindResource('ProfileChip')
            $rb.Background = Get-GBrush ([string]$p.Color); $rb.Content = Format-ProfName $p.Name; $rb.Tag = [string]$p.Name
            $rb.IsChecked = ($p.Name -eq $active)
            $rb.Add_Checked({ param($s, $e) if (-not $script:gProfChipSync) { Apply-VentoProfile ([string]$s.Tag) } })
            [void]$hc.Children.Add($rb)
        }
    } finally { $script:gProfChipSync = $false }
}

# --- editor dialog ---
$script:gProfEdit = ''
$script:gProfColor = '#6FB1FF'
$script:gProfDisplay = ''
function Show-ProfColors {
    $w = G 'ProfColors'; $w.Children.Clear()
    $picks = @($script:gProfColors)
    if ($picks -notcontains $script:gProfColor) { $picks += $script:gProfColor }
    foreach ($hex in $picks) {
        $b = New-Object System.Windows.Controls.Border
        $b.Width = 28; $b.Height = 28; $b.CornerRadius = 14; $b.Margin = '0,0,8,8'; $b.Cursor = 'Hand'
        $b.Background = Get-GBrush $hex; $b.Tag = $hex
        if ($hex -eq $script:gProfColor) { $b.BorderThickness = 2; $b.BorderBrush = Get-GBrush '#FFFFFF' }
        $b.Add_MouseLeftButtonUp({ param($s, $e) $script:gProfColor = [string]$s.Tag; Show-ProfColors })
        [void]$w.Children.Add($b)
    }
}
function Show-ProfDisplays {
    $w = G 'ProfDisplays'; $w.Children.Clear()
    $opts = @(, @('', 'Unchanged')) + @(Get-MonProfiles | ForEach-Object { , @([string]$_.Name, (Format-ProfName $_.Name)) })
    foreach ($o in $opts) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.GroupName = 'PfDisp'; $rb.Style = $script:app.FindResource('SegItem')
        $rb.Content = $o[1]; $rb.Tag = $o[0]; $rb.IsChecked = ($o[0] -eq $script:gProfDisplay)
        $rb.Add_Checked({ param($s, $e) $script:gProfDisplay = [string]$s.Tag })
        [void]$w.Children.Add($rb)
    }
}
function Open-ProfileDialog([string]$name) {
    $p = $(if ($name) { Get-VentoProfile $name } else { $null })
    $script:gProfEdit = $(if ($p) { [string]$p.Name } else { '' })
    $script:gProfColor = $(if ($p) { [string]$p.Color } else { '#6FB1FF' })
    $script:gProfDisplay = $(if ($p) { [string]$p.Display } else { '' })
    $fan = $(if ($p) { [string]$p.Fan } else { [string]$script:settings.lastMode })
    $osd = $(if ($p) { [string]$p.Overlay } else { 'auto' })
    (G 'ProfDlgTitle').Text = $(if ($p) { 'Edit profile' } else { 'New profile' })
    $nm = G 'ProfName'
    $nm.Text = $(if ($p) { Format-ProfName $p.Name } else { 'My profile' })
    # a built-in's name is its identity (re-seeded by name), so it stays put
    $nm.IsReadOnly = [bool]($p -and $p.Builtin)
    (G 'ProfDelete').Visibility = $(if ($p -and -not $p.Builtin) { 'Visible' } else { 'Collapsed' })
    (G 'ProfErr').Visibility = 'Collapsed'
    foreach ($rb in 'PfQuiet', 'PfNormal', 'PfPerf', 'PfCurve', 'PfAuto') { (G $rb).IsChecked = ([string](G $rb).Tag -eq $fan) }
    if (-not @('PfQuiet', 'PfNormal', 'PfPerf', 'PfCurve', 'PfAuto' | Where-Object { (G $_).IsChecked }).Count) { (G 'PfNormal').IsChecked = $true }
    foreach ($rb in 'PoOn', 'PoOff', 'PoAuto') { (G $rb).IsChecked = ([string](G $rb).Tag -eq $osd) }
    Show-ProfColors
    Show-ProfDisplays
    (G 'ProfileDialog').Visibility = 'Visible'
    [void]$nm.Focus(); $nm.SelectAll()
}
function Close-ProfileDialog { (G 'ProfileDialog').Visibility = 'Collapsed'; $script:gProfEdit = '' }
(G 'ProfCancel').Add_Click({ Close-ProfileDialog })
(G 'ProfDlgBackdrop').Add_MouseLeftButtonUp({ Close-ProfileDialog })
(G 'ProfSave').Add_Click({
    $old = [string]$script:gProfEdit
    $prev = $(if ($old) { Get-VentoProfile $old } else { $null })
    $typed = ([string](G 'ProfName').Text).Trim()
    # built-ins keep their stored name; others save as typed
    $name = $(if ($prev -and $prev.Builtin) { [string]$prev.Name } else { $typed })
    $err = G 'ProfErr'
    if (-not $name) { $err.Text = 'Give the profile a name.'; $err.Visibility = 'Visible'; return }
    # case-insensitive: 'gaming' must not sit next to the built-in GAMING
    $clash = @(Get-VentoProfiles | Where-Object { $_.Name -ieq $name -and $_.Name -ne $old })
    if ($clash.Count) { $err.Text = 'A profile with this name already exists.'; $err.Visibility = 'Visible'; return }
    $fan = [string](@('PfQuiet', 'PfNormal', 'PfPerf', 'PfCurve', 'PfAuto' | Where-Object { (G $_).IsChecked } | ForEach-Object { (G $_).Tag }) | Select-Object -First 1)
    $osd = [string](@('PoOn', 'PoOff', 'PoAuto' | Where-Object { (G $_).IsChecked } | ForEach-Object { (G $_).Tag }) | Select-Object -First 1)
    if (-not $fan) { $fan = 'normal' }; if (-not $osd) { $osd = 'auto' }
    $p = @{ Name = $name; Color = [string]$script:gProfColor; Fan = $fan; Overlay = $osd; Display = [string]$script:gProfDisplay
            Builtin = $(if ($prev) { [bool]$prev.Builtin } else { $false }) }
    # keep the list order: replace in place, append when new
    $arr = @(); $placed = $false
    foreach ($q in (Get-VentoProfiles)) {
        if ($old -and $q.Name -eq $old) { $arr += , $p; $placed = $true } else { $arr += , $q }
    }
    if (-not $placed) { $arr += , $p }
    Save-VentoProfiles $arr
    if ($old -and $old -ne $name -and [string]$script:settings.ventoProfile -eq $old) {
        $script:settings.ventoProfile = $name; $sync.Settings.ventoProfile = $name
    }
    Close-ProfileDialog
    Update-GlassProfiles
    Update-TrayProfiles
})
(G 'ProfDelete').Add_Click({
    $name = [string]$script:gProfEdit
    $p = $(if ($name) { Get-VentoProfile $name } else { $null })
    if (-not $p -or $p.Builtin) { return }
    Save-VentoProfiles @(Get-VentoProfiles | Where-Object { $_.Name -ne $name })
    if ([string]$script:settings.ventoProfile -eq $name) { $script:settings.ventoProfile = ''; $sync.Settings.ventoProfile = '' }
    Close-ProfileDialog
    Update-GlassProfiles
    Update-TrayProfiles
})
(G 'GoHotkeys').Add_Click({ (G 'NavSettings').IsChecked = $true })
# --- Glass: update notice --------------------------------------------------
(G 'InfoClose').Add_Click({ (G 'InfoBar').Visibility = 'Collapsed' })
(G 'InfoRestart').Add_Click({ Install-Update })
function Show-GlassUpdate([string]$ver) {
    (G 'InfoTitle').Text = "Vento $ver is ready"
    (G 'InfoMsg').Text = 'Install it now and Vento restarts itself when it is done.'
    (G 'InfoRestart').Content = 'Install now'; (G 'InfoRestart').Visibility = 'Visible'
    (G 'InfoBar').Visibility = 'Visible'
}
(G 'PcName').Text = $env:COMPUTERNAME
(G 'AboutVersion').Text = "Version $($script:AppVersion)"
(G 'AccentHex').Text = $script:acc.Light2

# --- Glass: Lights -----------------------------------------------------------
# A BLE LED strip (MR Star / "GATT--DEMO", protocol read out of its Android app):
# frames are BC cmd len payload 55. The page exists only where
# HKCU\Software\Vento\Lights = 1. The user connects and disconnects by hand;
# the strip takes one central at a time, so while Vento holds it the phone
# app can't. Nothing here ever sends 0x02 (RGB order) or 0x03 (LED count):
# those are persistent settings inside the strip, and the native class
# refuses them too.
$script:ledEnabled = $false
try { $script:ledEnabled = [int](Get-ItemProperty 'HKCU:\Software\Vento' -Name Lights -ErrorAction Stop).Lights -eq 1 } catch { }

$script:ledCs = @'
using System;
using System.Collections.Generic;
using System.Threading;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Foundation;
using Windows.Storage.Streams;

namespace VentoNative {
  // MR Star BLE strip link. The user connects and disconnects by hand: the
  // strip takes one central at a time, so while Vento holds it the phone app
  // can't, and Disconnect hands it back. One worker thread owns the link.
  // Frames that only set state (colour, effect, speed, brightness) replace an
  // unsent frame of the same command, so a fast animation never builds a
  // backlog. Commands 0x02 (RGB order) and 0x03 (LED count) are persistent
  // settings inside the strip and are refused outright.
  public static class Led {
    static readonly object Gate = new object();
    static readonly List<byte[]> s_q = new List<byte[]>();
    static Thread s_th;
    static BluetoothLEDevice s_dev;
    static GattDeviceService s_svc;
    static GattCharacteristic s_ch;
    static ulong s_addr;
    static bool s_want;          // user asked to be connected
    static string s_state = "disconnected";
    static string s_err = "";
    static int s_connectMs = -1;
    static readonly Guid Svc = new Guid("0000fff0-0000-1000-8000-00805f9b34fb");
    static readonly Guid Chr = new Guid("0000fff3-0000-1000-8000-00805f9b34fb");

    public static void Connect(ulong addr) {
      lock (Gate) {
        s_addr = addr; s_want = true; s_err = "";
        if (s_th == null) { s_th = new Thread(Run); s_th.IsBackground = true; s_th.Name = "VentoLed"; s_th.Start(); }
        Monitor.PulseAll(Gate);
      }
    }
    public static int Gap = 120;
    public static void Disconnect() {    public static void Disconnect() { lock (Gate) { s_want = false; s_q.Clear(); Monitor.PulseAll(Gate); } }

    public static bool Send(byte[] f) {
      if (f == null || f.Length < 4 || f[0] != 0xBC || f[f.Length - 1] != 0x55 || f[2] != f.Length - 4) return false;
      if (f[1] == 0x02 || f[1] == 0x03) return false;
      lock (Gate) {
        if (!s_want) return false;
        if (f[1] != 0x01) {
          for (int i = 0; i < s_q.Count; i++) if (s_q[i][1] == f[1]) { s_q[i] = f; Monitor.PulseAll(Gate); return true; }
        }
        if (s_q.Count > 32) s_q.RemoveAt(0);
        s_q.Add(f);
        Monitor.PulseAll(Gate);
      }
      return true;
    }

    // "state;connectMs;queued;err"  state: disconnected|connecting|connected|retrying
    public static string Status() { lock (Gate) { return s_state + ";" + s_connectMs + ";" + s_q.Count + ";" + s_err; } }

    // WinRT async without AsTask (its overloads need the full Windows.winmd union)
    static T Wait<T>(IAsyncOperation<T> op) {
      int t0 = Environment.TickCount;
      while (op.Status == AsyncStatus.Started) {
        if (Environment.TickCount - t0 > 10000) { try { op.Cancel(); } catch { } throw new TimeoutException("timed out"); }
        Thread.Sleep(15);
      }
      if (op.Status != AsyncStatus.Completed) throw (op.ErrorCode ?? new Exception(op.Status.ToString()));
      return op.GetResults();
    }

    static void Drop() {
      if (s_dev != null) { try { s_dev.ConnectionStatusChanged -= OnStatus; } catch { } }
      try { if (s_svc != null) s_svc.Dispose(); } catch { }
      try { if (s_dev != null) s_dev.Dispose(); } catch { }
      s_svc = null; s_dev = null; s_ch = null;
    }

    static void OnStatus(BluetoothLEDevice d, object o) {
      if (d.ConnectionStatus == BluetoothConnectionStatus.Disconnected) lock (Gate) { s_lost = true; Monitor.PulseAll(Gate); }
    }
    static bool s_lost;

    static bool Open(ulong addr) {
      int t0 = Environment.TickCount;
      try {
        // hear the strip first: its advertisement carries the address type
        // (it uses a random address), which a bare connect by address guesses wrong
        BluetoothAddressType at = Listen(addr, 15000);
        if (at == BluetoothAddressType.Unspecified) throw new Exception("Strip not found. Is it powered, and is the phone app closed?");
        var dev = Wait(BluetoothLEDevice.FromBluetoothAddressAsync(addr, at));
        if (dev == null) throw new Exception("Strip not found. Is it powered, and is the phone app closed?");
        s_dev = dev;
        GattDeviceServicesResult sr = null;
        for (int i = 0; i < 3; i++) {
          sr = Wait(dev.GetGattServicesForUuidAsync(Svc, BluetoothCacheMode.Uncached));
          if (sr.Status == GattCommunicationStatus.Success && sr.Services.Count > 0) break;
          Thread.Sleep(500);
        }
        if (sr.Status != GattCommunicationStatus.Success || sr.Services.Count == 0)
          throw new Exception("The strip did not answer (" + sr.Status + "). Close the phone app and try again.");
        s_svc = sr.Services[0];
        var cr = Wait(s_svc.GetCharacteristicsForUuidAsync(Chr, BluetoothCacheMode.Uncached));
        if (cr.Status != GattCommunicationStatus.Success || cr.Characteristics.Count == 0) throw new Exception("characteristic " + cr.Status);
        s_ch = cr.Characteristics[0];
        lock (Gate) { s_lost = false; }
        dev.ConnectionStatusChanged += OnStatus;
        lock (Gate) { s_state = "connected"; s_connectMs = Environment.TickCount - t0; s_err = ""; }
        return true;
      } catch (Exception e) {
        Exception x = e is AggregateException && e.InnerException != null ? e.InnerException : e;
        Drop();
        lock (Gate) { s_err = x.Message.Replace(";", ","); }
        return false;
      }
    }

    static BluetoothAddressType Listen(ulong addr, int ms) {
      var found = BluetoothAddressType.Unspecified;
      var hit = new ManualResetEvent(false);
      var w = new BluetoothLEAdvertisementWatcher();
      w.ScanningMode = BluetoothLEScanningMode.Active;
      w.Received += (sender, a) => { if (a.BluetoothAddress == addr) { found = a.BluetoothAddressType; hit.Set(); } };
      w.Start();
      try { hit.WaitOne(ms); } finally { try { w.Stop(); } catch { } }
      return found;
    }

    static IBuffer Buf(byte[] f) { var w = new DataWriter(); w.WriteBytes(f); return w.DetachBuffer(); }

    static void Run() {
      int fails = 0;
      while (true) {
        byte[] f = null; bool want; ulong addr;
        lock (Gate) {
          // a link Windows reports lost is reopened on the next pass
          if (s_lost && s_ch != null) { s_lost = false; Drop(); }
          if (s_want == (s_ch != null) && s_q.Count == 0) Monitor.Wait(Gate, s_ch != null ? 2000 : Timeout.Infinite);
          want = s_want; addr = s_addr;
          if (s_q.Count > 0 && s_ch != null) { f = s_q[0]; s_q.RemoveAt(0); }
        }
        if (!want) {
          if (s_ch != null || s_dev != null) Drop();
          lock (Gate) { s_state = "disconnected"; s_q.Clear(); }
          fails = 0; continue;
        }
        if (s_ch == null) {
          lock (Gate) { s_state = fails == 0 ? "connecting" : "retrying"; }
          if (!Open(addr)) {
            fails++;
            // keep trying while the user wants the link, slower each time
            int nap = Math.Min(20000, 2000 * fails);
            lock (Gate) { s_state = "retrying"; if (s_want) Monitor.Wait(Gate, nap); }
          } else fails = 0;
          continue;
        }
        if (f == null) continue;
        try {
          var st = Wait(s_ch.WriteValueAsync(Buf(f), GattWriteOption.WriteWithoutResponse));
          if (st != GattCommunicationStatus.Success) throw new Exception("write " + st);
          // the strip garbles frames that arrive close together (its own app
          // sends one per finished gesture), so writes are spaced out
          Thread.Sleep(Gap);
        } catch (Exception e) {
          Exception x = e is AggregateException && e.InnerException != null ? e.InnerException : e;
          Drop(); lock (Gate) { s_err = x.Message.Replace(";", ","); }
        }
      }
    }
  }
}
'@

# the strip's built-in effects, numbered as the strip numbers them
$script:ledFxList = @(
@'
1|Automatic loop
2|Symphony
3|Colorful energy
4|Colorful jumps
5|Red-green-blue jumps
6|Yellow-blue-purple jumps
7|7 colors strobe
8|Red-green-blue strobe
9|Yellow-purple-blue strobe
10|7 colors gradient
11|Alternate red-yellow gradient
12|Alternate red-purple gradient
13|Green-green alternate gradient
14|Alternate green-yellow gradient
15|Blue-purple alternating gradient
16|Red racing
17|Green racing
18|Blue racing
19|Yellow racing
20|Cyan racing
21|Purple racing
22|White racing
23|Colorful chasing light
24|Red-green-blue follow-up
25|Yellow-cyan-purple follow-up light
26|Colorful fluttering
27|Red-green-blue fluttering
28|Yellow-cyan-purple fluttering
29|Colorful brushing
30|Red-green-blue color brushing
31|Yellow-cyan-purple color brushing
32|Colorful brush color brush closed-pull
33|Red-green-blue color brush closed-pull
34|Yellow-cyan-purple color brush closed-pull
35|7 colors opening-closing
36|Red-green-blue opening-closing
37|Yellow-cyan-purple opening-closing
38|Red opening-closing
39|Green opening-closing
40|Blue opening-closing
41|Yellow opening-closing
42|Cyan opening-closing
43|Purple opening-closing
44|White opening-closing
45|7 colors light-dark transition
46|Blue-red-green light-dark transition
47|Violet-green-yellow light-dark transition
48|6 colors light-dark transition red
49|6 colors light-dark transition green
50|6 colors light-dark transition blue
51|6 colors light-dark transition cyan
52|6 colors light-dark transition yellow
53|6 colors light-dark transition purple
54|6 colors light-dark transition white
55|7 colors flowing water
56|Blue-green-red running water
57|Purple-green-yellow running water
58|Red-green running water
59|Green-blue running water
60|Yellow-blue running water
61|Yellow-cyan running water
62|Blue-purple running water
63|Black-white running water
64|White-red-white flow
65|White-green-white flow
66|White-blue-white flow
67|White-yellow-white flow
68|White-green-white flow
69|White-purple-white flow
70|Red-white-red flow
71|Green-white-green flow
72|Blue-white-blue flow
73|Yellow-white-yellow flow
74|Blue-white-blue flow
75|Purple-white-purple flow
76|7 colors trailing
77|Red trailing
78|Green trailing
79|Blue trailing
80|Yellow trailing
81|Cyan trailing
82|Purple trailing
83|White trailing
84|Red running
85|Green running
86|Blue running
87|Yellow running
88|Cyan running
89|Purple running
90|White running
91|7 colors running
92|Blue-green-red running
93|Purple-cyan-yellow running
94|Blue-purple-cyan-yellow running
95|Blue-green-cyan-yellow running
96|Red dot on white background running
97|Red background and green dot running
98|Green background and blue dot running
99|Yellow dot on the blue background running
100|Yellow background and blue dots running
101|Blue background and purple dots running
102|White dots running on purple background
103|Red background and white dots running
104|7 colors running with red background
105|7 colors running with green background
106|7 colors running with blue background
107|7 colors yellow background running
108|Green background 7 colors running
109|7 colors running with purple background
110|7 colors running on white background
111|Blue background and green dot running
112|Red background and green dot running
113|Red dot on the blue background running
114|Yellow background and blue dots running
115|Yellow dots running on purple background
116|Yellow background and white dots running
117|Yellow dots on white background running
'@ -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $p = $_ -split '\|', 2; @{ N = [int]$p[0]; Name = $p[1] } })
# the strip's app carries names for 117, but offers (and this strip runs) only these;
# the rest do nothing at all
$script:ledFxOk = @(1, 2, 3, 4, 7, 10, 26, 27) + (29..32) + (35..93)
$script:ledFxList = @($script:ledFxList | Where-Object { $script:ledFxOk -contains $_.N })

$script:ledWordColors = [ordered]@{
    red = '#FF3B30'; green = '#30D158'; blue = '#2F6BFF'; yellow = '#FFD60A'; cyan = '#32D4F5'
    purple = '#B04CFF'; violet = '#B04CFF'; white = '#F2F2F2'; black = '#1A1A1A'
}
$script:ledRainbow = @('#FF3B30', '#FF9500', '#FFD60A', '#30D158', '#32D4F5', '#2F6BFF', '#B04CFF')
$script:ledSep = ' ' + [char]0xB7 + ' '
# loop timing is stored in half seconds
function Format-LedSec($half) { ([double][int]$half * 0.5).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture) }
$script:ledSwatchHex = @('#FF0000', '#FF5A00', '#FFB000', '#FFE600', '#7CFF00', '#00FF40', '#00FFC8', '#00B4FF', '#0040FF', '#5A00FF', '#B400FF', '#FF00B4', '#FFFFFF')

# colors an effect's name promises, in order; "7 colors" and friends mean the rainbow
function Get-LedFxColors([string]$name) {
    $l = $name.ToLowerInvariant()
    $hits = @()
    foreach ($m in [regex]::Matches($l, '[a-z]+')) {
        $w = $m.Value
        if ($script:ledWordColors.Contains($w)) { $c = $script:ledWordColors[$w]; if ($hits -notcontains $c) { $hits += $c } }
    }
    if ($l -match '7 colors|colorful|symphony|automatic' -or $hits.Count -eq 0) {
        if ($l -match 'background|dot') { return @($hits) + $script:ledRainbow }
        return $script:ledRainbow
    }
    @($hits)
}
function Get-LedFxGroup([string]$name) {
    $l = $name.ToLowerInvariant()
    if ($l -match 'dot|background') { return 'dots' }
    if ($l -match 'strobe|jump') { return 'strobe' }
    if ($l -match 'flow|water|flutter') { return 'flow' }
    if ($l -match 'running|racing|trailing|chasing|follow') { return 'running' }
    'fade'
}
function New-LedGradient([string[]]$cols, [bool]$hard = $false) {
    $g = New-Object System.Windows.Media.LinearGradientBrush
    $g.StartPoint = New-Object System.Windows.Point 0, 0.5; $g.EndPoint = New-Object System.Windows.Point 1, 0.5
    $n = $cols.Count
    if ($n -eq 1) { $cols = @($cols[0], $cols[0]); $n = 2 }
    for ($i = 0; $i -lt $n; $i++) {
        $c = Get-GColor $cols[$i]
        if ($hard) {
            $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop $c, ($i / $n)))
            $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop $c, (($i + 1) / $n)))
        } else { $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop $c, ($i / ($n - 1)))) }
    }
    $g.Freeze(); $g
}
# background + dots: the first color fills, the rest sit on it as dots
function New-LedFxBrush([string]$name) {
    $cols = @(Get-LedFxColors $name)
    if ((Get-LedFxGroup $name) -eq 'dots' -and $cols.Count -ge 2) {
        $seq = @()
        $dots = @($cols | Select-Object -Skip 1)
        for ($i = 0; $i -lt 12; $i++) { $seq += $(if ($i % 3 -eq 1) { $dots[[int][math]::Floor($i / 3) % $dots.Count] } else { $cols[0] }) }
        return New-LedGradient $seq $true
    }
    New-LedGradient $cols ($name -match '(?i)strobe|jump')
}

# --- color math: the strip takes HSV (hue 0-359, saturation x1000) ---
function ConvertTo-LedHsv([string]$hex) {
    $c = Get-GColor $hex
    $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
    $max = [math]::Max($r, [math]::Max($g, $b)); $min = [math]::Min($r, [math]::Min($g, $b)); $d = $max - $min
    $h = 0.0
    if ($d -gt 0) {
        if ($max -eq $r) { $h = 60 * ((($g - $b) / $d) % 6) }
        elseif ($max -eq $g) { $h = 60 * ((($b - $r) / $d) + 2) }
        else { $h = 60 * ((($r - $g) / $d) + 4) }
    }
    if ($h -lt 0) { $h += 360 }
    $s = $(if ($max -gt 0) { $d / $max } else { 0 })
    @(([int][math]::Round($h) % 360), [int][math]::Round($s * 100))
}
function ConvertFrom-LedHsv([double]$h, [double]$s) {
    $s = $s / 100.0; $c = $s; $x = $c * (1 - [math]::Abs((($h / 60) % 2) - 1)); $m = 1 - $c
    $rgb = switch ([int][math]::Floor($h / 60) % 6) { 0 { $c, $x, 0 } 1 { $x, $c, 0 } 2 { 0, $c, $x } 3 { 0, $x, $c } 4 { $x, 0, $c } default { $c, 0, $x } }
    '#{0:X2}{1:X2}{2:X2}' -f [int](($rgb[0] + $m) * 255), [int](($rgb[1] + $m) * 255), [int](($rgb[2] + $m) * 255)
}
function Mix-LedHex([string]$a, [string]$b, [double]$t) {
    $ca = Get-GColor $a; $cb = Get-GColor $b
    '#{0:X2}{1:X2}{2:X2}' -f [int]($ca.R + ($cb.R - $ca.R) * $t), [int]($ca.G + ($cb.G - $ca.G) * $t), [int]($ca.B + ($cb.B - $ca.B) * $t)
}

# --- frames ---
function New-LedFrame([int]$cmd, [int[]]$payload) {
    $f = New-Object 'byte[]' ($payload.Count + 4)
    $f[0] = 0xBC; $f[1] = $cmd; $f[2] = $payload.Count
    for ($i = 0; $i -lt $payload.Count; $i++) { $f[3 + $i] = [byte]($payload[$i] -band 0xFF) }
    $f[$f.Length - 1] = 0x55
    , $f
}
function Send-Led([int]$cmd, [int[]]$payload) {
    if ($cmd -eq 0x02 -or $cmd -eq 0x03) { return $false }
    if (-not ('VentoNative.Led' -as [type])) { return $false }
    [VentoNative.Led]::Send((New-LedFrame $cmd $payload))
}
function Send-LedPower([bool]$on) { Send-Led 0x01 @([int]$on) }
function Send-LedBri([int]$pct) { $v = [int](Limit $pct 1 100) * 10; Send-Led 0x13 @(($v -shr 8), ($v -band 0xFF)) }
function Send-LedHsv([int]$h, [int]$s) { $sv = [int](Limit $s 0 100) * 10; Send-Led 0x04 @(($h -shr 8), ($h -band 0xFF), ($sv -shr 8), ($sv -band 0xFF), 0, 0) }
function Send-LedHex([string]$hex) { $hs = ConvertTo-LedHsv $hex; Send-LedHsv $hs[0] $hs[1] }
function Send-LedFx([int]$n) { Send-Led 0x06 @([int][math]::Floor($n / 255), ($n % 255)) }
function Send-LedSpeed([int]$v) { Send-Led 0x08 @([int](Limit $v 1 100)) }

# --- the native link, compiled off the UI thread the first time it is needed ---
$script:ledCompileStarted = $false
function Start-LedCompile {
    if ($script:ledCompileStarted -or ('VentoNative.Led' -as [type])) { return }
    $script:ledCompileStarted = $true
    $body = {
        param($sync, $cs)
        try {
            $gac = "$env:SystemRoot\Microsoft.NET\assembly\GAC_MSIL"
            $refs = @(
                "$env:SystemRoot\System32\WinMetadata\Windows.Devices.winmd"
                "$env:SystemRoot\System32\WinMetadata\Windows.Foundation.winmd"
                "$env:SystemRoot\System32\WinMetadata\Windows.Storage.winmd"
                'System.dll'
            )
            foreach ($n in 'System.Runtime', 'System.Runtime.WindowsRuntime', 'System.Runtime.InteropServices.WindowsRuntime') {
                $dll = Get-ChildItem (Join-Path $gac $n) -Recurse -Filter "$n.dll" -ErrorAction Stop | Select-Object -First 1
                if (-not $dll) { throw "facade missing: $n" }
                $refs += $dll.FullName
            }
            $cp = New-Object System.CodeDom.Compiler.CompilerParameters
            $cp.ReferencedAssemblies.AddRange([string[]]$refs)
            Add-Type -CompilerParameters $cp -TypeDefinition $cs
            $sync.LedReady = $true
        } catch { $sync.LedErr = "$_" }
    }
    $script:ledRunspace = [runspacefactory]::CreateRunspace()
    $script:ledRunspace.Open()
    $script:psLed = [powershell]::Create()
    $script:psLed.Runspace = $script:ledRunspace
    [void]$script:psLed.AddScript($body.ToString()).AddArgument($sync).AddArgument($script:ledCs)
    [void]$script:psLed.BeginInvoke()
}
$script:ledWantConnect = $false
function Connect-Led {
    $script:ledWantConnect = $true
    (G 'LedErr').Text = ''
    Start-LedCompile
    if ('VentoNative.Led' -as [type]) { [VentoNative.Led]::Connect([Convert]::ToUInt64([string]$script:settings.ledAddr, 16)) }
    Update-LedStatus
}
function Disconnect-Led {
    $script:ledWantConnect = $false
    Stop-LedLoop
    if ('VentoNative.Led' -as [type]) { [VentoNative.Led]::Disconnect() }
    Update-LedStatus
}

# --- status: the dot, the button, and whether the controls can be used ---
$script:ledLastState = ''
function Get-LedState {
    if ($script:ledWantConnect -and -not ('VentoNative.Led' -as [type])) {
        if ($sync.LedErr) { return @('error', '', "Bluetooth support failed to load: $($sync.LedErr)") }
        return @('connecting', '', '')
    }
    if (-not ('VentoNative.Led' -as [type])) { return @('disconnected', '', '') }
    $p = ([VentoNative.Led]::Status()) -split ';', 4
    @($p[0], $p[1], $p[3])
}
function Update-LedStatus {
    if (-not $script:ledEnabled) { return }
    # the compile finished after Connect was pressed: carry the request through
    if ($script:ledWantConnect -and ('VentoNative.Led' -as [type]) -and ([VentoNative.Led]::Status()) -like 'disconnected*') {
        [VentoNative.Led]::Connect([Convert]::ToUInt64([string]$script:settings.ledAddr, 16))
    }
    $st = Get-LedState
    $state = [string]$st[0]
    $txt = switch ($state) {
        'connected'  { 'Connected' }
        'connecting' { 'Connecting...' }
        'retrying'   { 'Trying again...' }
        'error'      { 'Bluetooth unavailable' }
        default      { 'Not connected' }
    }
    (G 'LedState').Text = $txt
    (G 'LedDot').Fill = $(switch ($state) {
        'connected' { Get-GBrush '#6CCB5F' }
        { $_ -in 'connecting', 'retrying' } { Get-GBrush '#FCE100' }
        'error' { Get-GBrush '#FF99A4' }
        default { $script:app.FindResource('TextTertiaryBrush') } })
    $err = [string]$st[2]
    (G 'LedErr').Text = $(if ($state -ne 'connected' -and $err) { $err } else { '' })
    $wanted = $script:ledWantConnect
    $btn = G 'LedConnect'
    $btn.Content = $(if ($wanted) { 'Disconnect' } else { 'Connect' })
    $btn.Style = $script:app.FindResource($(if ($wanted) { 'FluentButton' } else { 'AccentButton' }))
    $on = $state -eq 'connected'
    $ctl = G 'LedControls'
    $ctl.IsEnabled = $on; $ctl.Opacity = $(if ($on) { 1 } else { 0.45 })
    if ($on -and $script:ledLastState -ne 'connected') {
        # a loop the user left playing picks up where the link comes back
        if ([string]$script:settings.ledKind -eq 'loop' -and $script:settings.ledLoop -and -not $script:ledLoopTimer.IsEnabled) {
            $lp = Get-LedLoop ([string]$script:settings.ledLoop)
            if ($lp) { Start-LedLoop $lp }
        }
    }
    $script:ledLastState = $state
}

# --- the preview bar mirrors what Vento last told the strip ---
function Update-LedPreview([string]$liveHex = '') {
    $s = $script:settings
    $bar = G 'LedBar'; $halo = G 'LedHalo'
    if (-not $s.ledOn) {
        $bar.Background = Get-GBrush '#2A2A2A'; $halo.Background = $null
        (G 'LedNow').Text = 'Off'
        return
    }
    $kind = [string]$s.ledKind
    if ($kind -eq 'effect') {
        $fx = $script:ledFxList | Where-Object { $_.N -eq [int]$s.ledFx } | Select-Object -First 1
        $br = New-LedFxBrush ([string]$fx.Name)
        (G 'LedNow').Text = 'Effect {0}{1}{2}' -f $fx.N, $script:ledSep, $fx.Name
    } elseif ($kind -eq 'loop' -and $liveHex) {
        $br = Get-GBrush $liveHex
        (G 'LedNow').Text = 'Loop{0}{1}' -f $script:ledSep, $s.ledLoop
    } elseif ($kind -eq 'loop') {
        $lp = Get-LedLoop ([string]$s.ledLoop)
        $br = $(if ($lp) { New-LedGradient @($lp.Colors) } else { Get-GBrush '#2A2A2A' })
        (G 'LedNow').Text = 'Loop{0}{1}' -f $script:ledSep, $s.ledLoop
    } else {
        $hex = ConvertFrom-LedHsv $s.ledHue $s.ledSat
        $br = Get-GBrush $hex
        (G 'LedNow').Text = '{0}{1}{2}%' -f $hex, $script:ledSep, $s.ledBri
    }
    $bar.Background = $br; $halo.Background = $br
    $halo.Opacity = 0.25 + 0.45 * ([int]$s.ledBri / 100.0)
}

# --- color: swatches and the hue / saturation sliders ---
$script:ledSync = $false
foreach ($hex in $script:ledSwatchHex) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $script:app.FindResource('Swatch'); $rb.GroupName = 'LedSw'; $rb.Background = Get-GBrush $hex; $rb.Tag = $hex; $rb.ToolTip = $hex
    $rb.Add_Click({ param($sd, $e)
        $hs = ConvertTo-LedHsv ([string]$sd.Tag)
        $script:ledSync = $true
        try { (G 'LedHue').Value = $hs[0]; (G 'LedSat').Value = $hs[1] } finally { $script:ledSync = $false }
        Set-LedColor $hs[0] $hs[1] -Now
    })
    [void](G 'LedSwatches').Children.Add($rb)
}
$script:ledPending = @{}
$script:ledDeb = New-Object System.Windows.Threading.DispatcherTimer
$script:ledDeb.Interval = [TimeSpan]::FromMilliseconds(280)
$script:ledDeb.Add_Tick({
    $script:ledDeb.Stop()
    $p = $script:ledPending; $script:ledPending = @{}
    if ($p.ContainsKey('hsv')) { [void](Send-LedHsv $p.hsv[0] $p.hsv[1]) }
    if ($p.ContainsKey('bri')) { [void](Send-LedBri $p.bri) }
    if ($p.ContainsKey('speed')) { [void](Send-LedSpeed $p.speed) }
})
function Defer-Led([string]$key, $value) { $script:ledPending[$key] = $value; $script:ledDeb.Stop(); $script:ledDeb.Start() }
function Set-LedColor([int]$h, [int]$s, [switch]$Now) {
    Stop-LedLoop
    $script:settings.ledHue = $h; $script:settings.ledSat = $s; $script:settings.ledKind = 'color'
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    if ($Now) { $script:ledPending.Remove('hsv'); [void](Send-LedHsv $h $s) } else { Defer-Led 'hsv' @($h, $s) }
    (G 'LedHuePrev').Background = Get-GBrush (ConvertFrom-LedHsv $h $s)
    (G 'LedSatV').Text = '{0}%' -f $s
    Update-LedFxChecks
    Update-LedPreview
}
(G 'LedHue').Add_ValueChanged({ param($sd, $e)
    (G 'LedHuePrev').Background = Get-GBrush (ConvertFrom-LedHsv $sd.Value (G 'LedSat').Value)
    if (-not $script:ledSync) { Set-LedColor ([int]$sd.Value) ([int](G 'LedSat').Value) }
})
(G 'LedSat').Add_ValueChanged({ param($sd, $e)
    (G 'LedSatV').Text = '{0}%' -f [int]$sd.Value
    if (-not $script:ledSync) { Set-LedColor ([int](G 'LedHue').Value) ([int]$sd.Value) }
})

# --- power, brightness, speed ---
(G 'LedPower').Add_Click({
    $on = [bool](G 'LedPower').IsChecked
    $script:settings.ledOn = $on; $script:saveTimer.Stop(); $script:saveTimer.Start()
    if (-not $on) { Stop-LedLoop }
    [void](Send-LedPower $on)
    Update-LedPreview
})
(G 'LedBri').Add_ValueChanged({ param($sd, $e)
    $v = [int]$sd.Value
    (G 'LedBriV').Text = '{0}%' -f $v
    if ($script:ledSync) { return }
    $script:settings.ledBri = $v; $script:saveTimer.Stop(); $script:saveTimer.Start()
    Defer-Led 'bri' $v
    Update-LedPreview
})
(G 'LedSpeed').Add_ValueChanged({ param($sd, $e)
    $v = [int]$sd.Value
    (G 'LedSpeedV').Text = '{0}' -f $v
    if ($script:ledSync) { return }
    $script:settings.ledSpeed = $v; $script:saveTimer.Stop(); $script:saveTimer.Start()
    Defer-Led 'speed' $v
})
(G 'LedConnect').Add_Click({ if ($script:ledWantConnect) { Disconnect-Led } else { Connect-Led } })
(G 'LedAutoConn').Add_Click({ Set-GSetting 'ledAutoConn' ([bool](G 'LedAutoConn').IsChecked) })

# --- built-in effects: filter chips and one tile per effect ---
$script:ledFilter = 'all'
$script:ledFxBuilt = $false
foreach ($f in @(@('all', 'All'), @('rainbow', 'Rainbow'), @('running', 'Running'), @('flow', 'Flow'), @('strobe', 'Strobe'), @('fade', 'Fades'))) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $script:app.FindResource('SegItem'); $rb.GroupName = 'LedFilter'; $rb.Content = $f[1]; $rb.Tag = $f[0]
    if ($f[0] -eq 'all') { $rb.IsChecked = $true }
    $rb.Add_Checked({ param($sd, $e) $script:ledFilter = [string]$sd.Tag; Update-LedFxFilter })
    [void](G 'LedFilters').Children.Add($rb)
}
function Build-LedEffects {
    if ($script:ledFxBuilt) { return }
    $script:ledFxBuilt = $true
    $wp = G 'LedEffects'
    foreach ($fx in $script:ledFxList) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $script:app.FindResource('ModeCard'); $rb.GroupName = 'LedFx'; $rb.Width = 172; $rb.Margin = '4,0,4,8'; $rb.Padding = '10,10,10,9'
        $rb.Tag = $fx.N
        $sp = New-Object System.Windows.Controls.StackPanel
        $bar = New-Object System.Windows.Controls.Border
        $bar.Height = 8; $bar.CornerRadius = 4; $bar.Margin = '0,2,24,10'; $bar.Background = New-LedFxBrush $fx.Name
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $fx.Name; $nm.Style = $script:app.FindResource('Body'); $nm.FontSize = 13; $nm.TextWrapping = 'Wrap'; $nm.Height = 36
        $no = New-Object System.Windows.Controls.TextBlock
        $no.Text = '#{0}' -f $fx.N; $no.Style = $script:app.FindResource('CaptionTertiary'); $no.Margin = '0,2,0,0'
        [void]$sp.Children.Add($bar); [void]$sp.Children.Add($nm); [void]$sp.Children.Add($no)
        $rb.Content = $sp
        $rb.Add_Click({ param($sd, $e) Set-LedEffect ([int]$sd.Tag) })
        $lname = $fx.Name.ToLowerInvariant()
        $rb.Resources['grp'] = Get-LedFxGroup $fx.Name
        $rb.Resources['rainbow'] = [bool]($lname -match '7 colors|colorful|symphony|automatic')
        [void]$wp.Children.Add($rb)
    }
    Update-LedFxFilter
    Update-LedFxChecks
}
function Update-LedFxFilter {
    foreach ($rb in (G 'LedEffects').Children) {
        $show = switch ($script:ledFilter) {
            'all' { $true }
            'rainbow' { [bool]$rb.Resources['rainbow'] }
            default { [string]$rb.Resources['grp'] -eq $script:ledFilter }
        }
        $rb.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
    }
}
function Update-LedFxChecks {
    $cur = $(if ([string]$script:settings.ledKind -eq 'effect') { [int]$script:settings.ledFx } else { -1 })
    foreach ($rb in (G 'LedEffects').Children) { $rb.IsChecked = ([int]$rb.Tag -eq $cur) }
}
function Set-LedEffect([int]$n) {
    Stop-LedLoop
    $script:settings.ledFx = $n; $script:settings.ledKind = 'effect'
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    [void](Send-LedFx $n)
    Update-LedFxChecks
    Update-LedPreview
}

# --- my color loops: Vento plays them, one color frame per tick ---
function Get-LedLoop([string]$name) { @($script:settings.ledLoops) | Where-Object { $_.Name -eq $name } | Select-Object -First 1 }
$script:ledLoopTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ledLoopTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$script:ledLoopRun = $null
$script:ledLoopLast = ''
function Get-LedLoopFrame($lp, [double]$t) {
    # returns @(hex, brightnessFactor 0..1)
    $cols = @($lp.Colors); $n = $cols.Count
    $seg = [double]$lp.Half * 0.5
    $pos = $t / $seg; $i = [int][math]::Floor($pos) % $n; $u = $pos - [math]::Floor($pos)
    switch ([string]$lp.Trans) {
        'jump' { return @($cols[$i], 1.0) }
        'breathe' { return @($cols[$i], (0.08 + 0.92 * [math]::Sin([math]::PI * $u))) }
        default {
            # hold the color for 40% of its time, then blend into the next
            if ($u -lt 0.4 -or $n -eq 1) { return @($cols[$i], 1.0) }
            $k = ($u - 0.4) / 0.6; $k = $k * $k * (3 - 2 * $k)
            return @((Mix-LedHex $cols[$i] $cols[($i + 1) % $n] $k), 1.0)
        }
    }
}
$script:ledLoopTimer.Add_Tick({
    $r = $script:ledLoopRun
    if (-not $r) { $script:ledLoopTimer.Stop(); return }
    $t = ([DateTime]::Now - $r.Start).TotalSeconds
    $fr = Get-LedLoopFrame $r.Loop $t
    $hex = [string]$fr[0]
    $key = '{0}/{1:0.00}' -f $hex, $fr[1]
    if ($key -eq $script:ledLoopLast) { return }
    $script:ledLoopLast = $key
    [void](Send-LedHex $hex)
    if ([string]$r.Loop.Trans -eq 'breathe') { [void](Send-LedBri ([int][math]::Max(1, [int]$script:settings.ledBri * $fr[1]))) }
    if ((G 'PageLights').Visibility -eq 'Visible') { Update-LedPreview $hex }
})
function Start-LedLoop($lp) {
    $script:ledLoopRun = @{ Loop = $lp; Start = [DateTime]::Now }
    $script:ledLoopLast = ''
    $script:settings.ledKind = 'loop'; $script:settings.ledLoop = [string]$lp.Name
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    $script:ledLoopTimer.Start()
    Update-LedFxChecks
    Show-LedLoops
}
function Stop-LedLoop {
    if (-not $script:ledLoopRun) { return }
    $was = $script:ledLoopRun
    $script:ledLoopRun = $null; $script:ledLoopTimer.Stop()
    # breathing leaves the brightness wherever it was; put the slider's value back
    if ([string]$was.Loop.Trans -eq 'breathe') { [void](Send-LedBri ([int]$script:settings.ledBri)) }
    Show-LedLoops
}
function Show-LedLoops {
    $host0 = G 'LedLoops'; $host0.Children.Clear()
    foreach ($lp in @($script:settings.ledLoops)) {
        $playing = $script:ledLoopRun -and [string]$script:ledLoopRun.Loop.Name -eq [string]$lp.Name
        $b = New-Object System.Windows.Controls.Border
        $b.Style = $script:app.FindResource('SettingsCard')
        if ($playing) { $b.BorderBrush = $script:app.FindResource('AccentBrush') }
        $g = New-Object System.Windows.Controls.Grid
        foreach ($w in '120', '*', 'Auto') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
        $bar = New-Object System.Windows.Controls.Border
        $bar.Height = 10; $bar.CornerRadius = 5; $bar.VerticalAlignment = 'Center'
        $bar.Background = New-LedGradient @($lp.Colors) ([string]$lp.Trans -eq 'jump')
        $txt = New-Object System.Windows.Controls.StackPanel; $txt.Margin = '16,0'; $txt.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($txt, 1)
        $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = $lp.Name; $t1.Style = $script:app.FindResource('Body')
        $trName = @{ fade = 'Fade'; jump = 'Jump'; breathe = 'Breathe' }[[string]$lp.Trans]
        $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Style = $script:app.FindResource('Caption')
        $t2.Text = '{0} colors{1}{2}{1}{3} s each{4}' -f @($lp.Colors).Count, $script:ledSep, $trName, (Format-LedSec $lp.Half), $(if ($playing) { $script:ledSep + 'Playing' } else { '' })
        [void]$txt.Children.Add($t1); [void]$txt.Children.Add($t2)
        $btns = New-Object System.Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'; $btns.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($btns, 2)
        foreach ($spec in @(@($(if ($playing) { [char]0xE71A } else { [char]0xE768 }), 'play', $(if ($playing) { 'Stop' } else { 'Play' })), @([char]0xE70F, 'edit', 'Edit'), @([char]0xE74D, 'del', 'Delete'))) {
            $bt = New-Object System.Windows.Controls.Button
            $bt.Style = $script:app.FindResource('IconButton'); $bt.Content = [string]$spec[0]; $bt.FontSize = 14; $bt.ToolTip = $spec[2]
            $bt.Tag = @{ Act = $spec[1]; Name = [string]$lp.Name }
            $bt.Add_Click({ param($sd, $e)
                $a = $sd.Tag; $l = Get-LedLoop $a.Name
                if (-not $l) { return }
                switch ($a.Act) {
                    'play' { if ($script:ledLoopRun -and [string]$script:ledLoopRun.Loop.Name -eq $a.Name) { Stop-LedLoop; $script:settings.ledKind = 'color'; Update-LedPreview } else { Start-LedLoop $l } }
                    'edit' { Open-LedLoopEditor $l }
                    'del' {
                        if ($script:ledLoopRun -and [string]$script:ledLoopRun.Loop.Name -eq $a.Name) { Stop-LedLoop }
                        Set-GSetting 'ledLoops' @(@($script:settings.ledLoops) | Where-Object { $_.Name -ne $a.Name })
                        if ([string]$script:settings.ledLoop -eq $a.Name) { $script:settings.ledLoop = '' }
                        Show-LedLoops
                    }
                }
            })
            [void]$btns.Children.Add($bt)
        }
        [void]$g.Children.Add($bar); [void]$g.Children.Add($txt); [void]$g.Children.Add($btns)
        $b.Child = $g
        [void]$host0.Children.Add($b)
    }
}

# --- loop editor ---
$script:ledEdit = $null
function Show-LedEditColors {
    $wp = G 'LedLoopColors'; $wp.Children.Clear()
    $i = 0
    foreach ($hex in @($script:ledEdit.Colors)) {
        $bt = New-Object System.Windows.Controls.Button
        $bt.Style = $script:app.FindResource('IconButton'); $bt.Width = 34; $bt.Height = 34; $bt.Margin = '0,0,6,6'; $bt.Tag = $i
        $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 24; $dot.Height = 24; $dot.Fill = Get-GBrush $hex; $dot.Stroke = Get-GBrush '#FFFFFF' 0x30
        $bt.Content = $dot; $bt.ToolTip = "$hex - click to remove"
        $bt.Add_Click({ param($sd, $e)
            $k = [int]$sd.Tag; $c = [System.Collections.ArrayList]@($script:ledEdit.Colors); $c.RemoveAt($k); $script:ledEdit.Colors = @($c); Show-LedEditColors
        })
        [void]$wp.Children.Add($bt); $i++
    }
    if (@($script:ledEdit.Colors).Count -lt 12) {
        $add = New-Object System.Windows.Controls.Button
        $add.Style = $script:app.FindResource('FluentButton'); $add.MinHeight = 34; $add.Padding = '10,0'; $add.Margin = '0,0,6,6'; $add.FontSize = 13
        $cur = ConvertFrom-LedHsv (G 'LedHue').Value (G 'LedSat').Value
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width = 14; $dot.Height = 14; $dot.Fill = Get-GBrush $cur; $dot.VerticalAlignment = 'Center'
        $tx = New-Object System.Windows.Controls.TextBlock; $tx.Text = 'Add this color'; $tx.Margin = '8,0,0,0'; $tx.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($dot); [void]$sp.Children.Add($tx); $add.Content = $sp
        $add.Add_Click({ $script:ledEdit.Colors = @($script:ledEdit.Colors) + @(ConvertFrom-LedHsv (G 'LedHue').Value (G 'LedSat').Value); Show-LedEditColors })
        [void]$wp.Children.Add($add)
    }
}
function Open-LedLoopEditor($lp) {
    if ($lp) { $script:ledEdit = @{ Orig = [string]$lp.Name; Colors = @($lp.Colors); Trans = [string]$lp.Trans; Half = [int]$lp.Half }; (G 'LedLoopName').Text = $lp.Name }
    else { $script:ledEdit = @{ Orig = ''; Colors = @(); Trans = 'fade'; Half = 6 }; (G 'LedLoopName').Text = 'My loop' }
    foreach ($t in 'Fade', 'Jump', 'Breathe') { $r = G "LedTr$t"; $r.IsChecked = ([string]$r.Tag -eq $script:ledEdit.Trans) }
    (G 'LedLoopSec').Value = $script:ledEdit.Half
    (G 'LedLoopErr').Text = ''
    Show-LedEditColors
    (G 'LedLoopEdit').Visibility = 'Visible'
    [void](G 'LedLoopName').Focus(); (G 'LedLoopName').SelectAll()
}
(G 'LedLoopSec').Add_ValueChanged({ param($sd, $e) (G 'LedLoopSecV').Text = '{0} s' -f (Format-LedSec $sd.Value) })
(G 'LedLoopNew').Add_Click({ Open-LedLoopEditor $null })
(G 'LedLoopCancel').Add_Click({ (G 'LedLoopEdit').Visibility = 'Collapsed'; $script:ledEdit = $null })
(G 'LedLoopSave').Add_Click({
    $e = $script:ledEdit; if (-not $e) { return }
    $name = ([string](G 'LedLoopName').Text).Trim()
    $err = G 'LedLoopErr'
    if (-not $name) { $err.Text = 'Give the loop a name.'; return }
    if (@($e.Colors).Count -lt 2) { $err.Text = 'Add at least two colors.'; return }
    if ($name -ne $e.Orig -and (Get-LedLoop $name)) { $err.Text = 'A loop with this name already exists.'; return }
    $tr = 'fade'; foreach ($t in 'Fade', 'Jump', 'Breathe') { if ((G "LedTr$t").IsChecked) { $tr = [string](G "LedTr$t").Tag } }
    $new = @{ Name = $name; Colors = @($e.Colors); Trans = $tr; Half = [int](G 'LedLoopSec').Value }
    $list = @()
    $placed = $false
    foreach ($l in @($script:settings.ledLoops)) {
        if ($e.Orig -and $l.Name -eq $e.Orig) { $list += , $new; $placed = $true } else { $list += , $l }
    }
    if (-not $placed) { $list += , $new }
    Set-GSetting 'ledLoops' @($list)
    (G 'LedLoopEdit').Visibility = 'Collapsed'; $script:ledEdit = $null
    if ($script:ledLoopRun) { Stop-LedLoop }
    Start-LedLoop $new
})

# --- page load / periodic refresh ---
function Update-GlassLights {
    if (-not $script:ledEnabled) { return }
    Build-LedEffects
    $s = $script:settings
    $script:ledSync = $true
    try {
        (G 'LedAutoConn').IsChecked = [bool]$s.ledAutoConn
        (G 'LedPower').IsChecked = [bool]$s.ledOn
        (G 'LedBri').Value = [int]$s.ledBri; (G 'LedBriV').Text = '{0}%' -f [int]$s.ledBri
        (G 'LedHue').Value = [int]$s.ledHue
        (G 'LedSat').Value = [int]$s.ledSat; (G 'LedSatV').Text = '{0}%' -f [int]$s.ledSat
        (G 'LedHuePrev').Background = Get-GBrush (ConvertFrom-LedHsv $s.ledHue $s.ledSat)
        (G 'LedSpeed').Value = [int]$s.ledSpeed; (G 'LedSpeedV').Text = '{0}' -f [int]$s.ledSpeed
        (G 'LedLoopSecV').Text = '{0} s' -f (Format-LedSec (G 'LedLoopSec').Value)
    } finally { $script:ledSync = $false }
    Update-LedFxChecks
    Show-LedLoops
    Update-LedPreview
    Update-LedStatus
}
if ($script:ledEnabled) {
    (G 'NavLights').Visibility = 'Visible'
    $script:searchMap['Lights'] = 'lights led strip leds rgb lighting effects loop bluetooth'
    $script:ledStatusTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ledStatusTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:ledStatusTimer.Add_Tick({ try { Update-LedStatus } catch { } })
    $script:ledStatusTimer.Start()
    (G 'NavLights').Add_Checked({ try { Update-GlassLights } catch { } })
    if ($script:settings.ledAutoConn) { Connect-Led }
    $script:shell.Add_Closed({ try { Stop-LedLoop; if ('VentoNative.Led' -as [type]) { [VentoNative.Led]::Disconnect() } } catch { } })
}
# --- Glass: Lights end -------------------------------------------------------

function New-Brush([string]$hex) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex))
    $b.Freeze()
    return $b
}
$script:brushText   = New-Brush '#E6EAF2'
$script:brushMuted  = New-Brush '#566073'
$script:brushDim    = New-Brush '#8A93A6'
$script:brushGreen  = New-Brush '#3DD68C'
$script:brushYellow = New-Brush '#F5C359'
$script:brushRed    = New-Brush '#F26D78'
$script:brushDark   = New-Brush '#0B0E14'
$script:brushClear  = New-Brush '#00000000'

function New-VAreaBrush([string]$hex, [byte]$topAlpha) {
    # vertical fade for sparkline area fills: hex at topAlpha -> transparent
    $c = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $top = [System.Windows.Media.Color]::FromArgb($topAlpha, $c.R, $c.G, $c.B)
    $bot = [System.Windows.Media.Color]::FromArgb(0, $c.R, $c.G, $c.B)
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point 0, 0
    $b.EndPoint   = New-Object System.Windows.Point 0, 1
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop $top, 0))
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop $bot, 1))
    $b.Freeze()
    return $b
}
$script:fillGreen  = New-VAreaBrush '#3DD68C' 0x4D
$script:fillYellow = New-VAreaBrush '#F5C359' 0x4D
$script:fillRed    = New-VAreaBrush '#F26D78' 0x4D

function New-TrailBrush([string]$hex) {
    # sparkline stroke: history fades in from the left, "now" is fully lit -
    # reads as a trace instead of a stray border line
    $c = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point 0, 0.5
    $b.EndPoint   = New-Object System.Windows.Point 1, 0.5
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(0x00, $c.R, $c.G, $c.B)), 0))
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(0x80, $c.R, $c.G, $c.B)), 0.45))
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb(0xFF, $c.R, $c.G, $c.B)), 1))
    $b.Freeze()
    return $b
}
$script:trailGreen  = New-TrailBrush '#3DD68C'
$script:trailYellow = New-TrailBrush '#F5C359'
$script:trailRed    = New-TrailBrush '#F26D78'

function New-PillBrush([string]$hex) {
    # active-mode pill: accent lightened 16% at the top -> accent, so the
    # selected button reads dimensional instead of flat
    $c = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $top = [System.Windows.Media.Color]::FromRgb(
        [byte][math]::Min(255, $c.R + (255 - $c.R) * 0.16),
        [byte][math]::Min(255, $c.G + (255 - $c.G) * 0.16),
        [byte][math]::Min(255, $c.B + (255 - $c.B) * 0.16))
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point 0, 0
    $b.EndPoint   = New-Object System.Windows.Point 0, 1
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop $top, 0))
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop $c, 1))
    $b.Freeze()
    return $b
}

$script:deg = [char]176
$script:thin = [char]0x2009   # thin space used to letter-space the orb label
$script:modeNames    = @{ quiet = 'Quiet'; normal = 'Normal'; performance = 'Performance'; curve = 'Curve'; auto = 'Auto' }
$script:sliderNames  = @('S_QuietCase','S_NormalCase','S_PerfCase','S_PerfCpu','S_BoostHigh','S_BoostLow','S_BoostCase',
                         'S_C40','S_C55','S_C70','S_C80','S_GameLoad','S_GameCool','S_CpuMax','S_GpuMax',
                         'S_WarnCpu','S_WarnGpu','S_WarnSsd','S_WarnMb','S_Interval','S_OsdScale')

# All code-generated UI strings live here so a future language option is a
# table swap (XAML labels move here in the same pass).
$script:mid = [char]183   # middot separator; kept out of literals so the file stays ASCII
$script:L = @{
    Starting      = 'Starting sensors...'
    Connected     = "Connected $script:mid updating every {0:0.#}s"
    BoostActive   = "Cooling boost active $script:mid case fans at {0}% until below {1}{2}C"
    CurveActive   = "Curve mode $script:mid case fans at {0}%"
    GameActive    = "Game detected $script:mid Performance until the GPU goes idle"
    GameActiveCurve = "Game detected $script:mid Curve fans until the GPU goes idle"
    CoolDown      = "Post-game cooldown $script:mid {0}s, then back to {1}"
    Downloading   = 'Downloading update...'
    UpdateBalloon = 'Version {0} is available. Use the tray menu to install it.'
    InstallItem   = 'Install Vento {0}'
    TrayOpen      = 'Open Vento'
    TrayExit      = 'Exit'
    TrayStillHere = 'Still running here in the tray.'
    SensorFail    = 'Could not read the sensors. See error.log for details.'
    AppError      = 'Application error: {0}'
}

# --- Tray icon -------------------------------------------------------
function New-TrayIcon([string]$hex) {
    # Prefer the shipped multi-size icon; fall back to a drawn glyph
    if (Test-Path $script:icoPath) { return New-Object System.Drawing.Icon($script:icoPath, 32, 32) }
    $col = [System.Drawing.ColorTranslator]::FromHtml($hex)
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $fill = New-Object System.Drawing.SolidBrush $col
    $hole = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(11, 14, 20))
    $g.FillEllipse($fill, 2, 2, 28, 28)
    $g.FillEllipse($hole, 11, 11, 10, 10)
    $g.Dispose(); $fill.Dispose(); $hole.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

# --- Sirocco thermal palette -----------------------------------------
# Every UI color derives from one thermal position: the hottest sensor's
# distance to its own warning threshold. 8 degC or more under the threshold
# is the cool (blue) anchor, the threshold itself sits near the coral
# anchor, 4 degC over is fully hot (red); everything between is a smooth
# per-channel lerp, so the window's light shifts with the temperature.
$script:thAnchorHex = @{
    cool = @{ acc='#6FB1FF'; accB='#9CCBFF'; ink='#EDF1F8'; dim='#8FA3BC'; faint='#5A6B84'; base='#0A0D13'; tile='#10151D'; track='#16202E'; grid='#151D2A'; chartA='#D8E4F2'; core1='#8FC0FF'; core2='#3D77D6'; coreInk='#0A1A33' }
    warm = @{ acc='#FF8A5C'; accB='#FFA478'; ink='#F5EFE9'; dim='#A89584'; faint='#6E6154'; base='#0D0B0A'; tile='#171210'; track='#241B14'; grid='#241B14'; chartA='#E8D9CC'; core1='#FFA478'; core2='#E06E3C'; coreInk='#2A1206' }
    hot  = @{ acc='#E85B52'; accB='#F0867A'; ink='#F5EDEA'; dim='#B09090'; faint='#755A57'; base='#100B0B'; tile='#181010'; track='#271515'; grid='#241313'; chartA='#EBD8D4'; core1='#EE7E70'; core2='#BC3B34'; coreInk='#2A0A08' }
}
$script:thAnchor = @{}
foreach ($k in @($script:thAnchorHex.Keys)) {
    $p = @{}
    foreach ($n in @($script:thAnchorHex[$k].Keys)) { $p[$n] = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($script:thAnchorHex[$k][$n]) }
    $script:thAnchor[$k] = $p
}
function Mix-Color($a, $b, [double]$u) {
    [System.Windows.Media.Color]::FromRgb(
        [byte]($a.R + ($b.R - $a.R) * $u),
        [byte]($a.G + ($b.G - $a.G) * $u),
        [byte]($a.B + ($b.B - $a.B) * $u))
}
function Get-ThermalMix([double]$margin) {
    if ($margin -le -8)    { $pos = 0.02 }
    elseif ($margin -lt 0) { $pos = 0.55 * (($margin + 8) / 8.0) }
    elseif ($margin -lt 4) { $pos = 0.55 + 0.45 * ($margin / 4.0) }
    else                   { $pos = 1.0 }
    $pos = [math]::Max(0.02, [math]::Min(1.0, $pos))
    # The palette snaps to the three anchors (blue / orange / red) on the same
    # thresholds as the state badge - no in-between blends. Only the halo dot
    # travels continuously along the arc.
    $state = if ($pos -lt 0.35) { 'cool' } elseif ($pos -le 0.8) { 'warm' } else { 'hot' }
    return @{ pal = $script:thAnchor[$state]; pos = $pos }
}
function New-SolidBrushC($c) { $b = New-Object System.Windows.Media.SolidColorBrush $c; $b.Freeze(); return $b }
function New-AlphaColor($c, [byte]$a) { return [System.Windows.Media.Color]::FromArgb($a, $c.R, $c.G, $c.B) }
function Get-HexOf($c) { return ('#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B) }

$script:thLastAcc = $null
$script:thLastPos = -1.0
function Apply-Thermal($mix) {
    $pal = $mix.pal; $pos = $mix.pos
    $acc = $pal.acc
    if ($script:thLastAcc) {
        $delta = [math]::Abs($acc.R - $script:thLastAcc.R) + [math]::Abs($acc.G - $script:thLastAcc.G) + [math]::Abs($acc.B - $script:thLastAcc.B)
        if ($delta -lt 3 -and [math]::Abs($pos - $script:thLastPos) -lt 0.004) { return }
    }
    $script:thLastAcc = $acc; $script:thLastPos = $pos

    foreach ($pair in @(
        @('AccentBrush', $acc),
        @('AccentSoftBrush', (New-AlphaColor $acc 0x26)),
        @('ThInkBrush', $pal.ink), @('ThDimBrush', $pal.dim), @('ThFaintBrush', $pal.faint),
        @('ThTileBrush', $pal.tile), @('ThTrackBrush', $pal.track), @('ThGridBrush', $pal.grid),
        @('ThChartABrush', $pal.chartA))) {
        [VentoNative.Res]::SetBrush($window.Resources, $pair[0], $pair[1])
    }

    $script:brushAccent     = New-SolidBrushC $acc
    $script:brushAccentB    = New-SolidBrushC $pal.accB
    $script:brushInk        = New-SolidBrushC $pal.ink
    $script:brushChartA     = New-SolidBrushC $pal.chartA
    $script:brushAccentPill = New-PillBrush (Get-HexOf $acc)

    # window chrome ambience: base coat + accent-tinted top light
    $el.WinBase.Background = New-SolidBrushC $pal.base
    $rb = New-Object System.Windows.Media.RadialGradientBrush
    $rb.Center = New-Object System.Windows.Point 0.5, 0
    $rb.GradientOrigin = New-Object System.Windows.Point 0.5, 0
    $rb.RadiusX = 0.9; $rb.RadiusY = 0.55
    $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop (New-AlphaColor $acc 0x20), 0))
    $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop $pal.base, 1))
    $rb.Freeze()
    $el.WinFrame.Background = $rb
    $fb = New-Object System.Windows.Media.LinearGradientBrush
    $fb.StartPoint = New-Object System.Windows.Point 0, 0
    $fb.EndPoint   = New-Object System.Windows.Point 0, 1
    $fb.GradientStops.Add((New-Object System.Windows.Media.GradientStop (New-AlphaColor $acc 0x38), 0))
    $fb.GradientStops.Add((New-Object System.Windows.Media.GradientStop $pal.track, 1))
    $fb.Freeze()
    $el.WinFrame.BorderBrush = $fb

    # hero orb: breathing glow + sun core carrying the hottest sensor
    $og = New-Object System.Windows.Media.RadialGradientBrush
    $og.GradientStops.Add((New-Object System.Windows.Media.GradientStop (New-AlphaColor $acc 0x3C), 0))
    $og.GradientStops.Add((New-Object System.Windows.Media.GradientStop (New-AlphaColor $acc 0x00), 1))
    $og.Freeze()
    $el.OrbGlow.Fill = $og
    $cg = New-Object System.Windows.Media.RadialGradientBrush
    $cg.Center = New-Object System.Windows.Point 0.5, 0.38
    $cg.GradientOrigin = New-Object System.Windows.Point 0.5, 0.38
    $cg.RadiusX = 0.75; $cg.RadiusY = 0.75
    $cg.GradientStops.Add((New-Object System.Windows.Media.GradientStop $pal.core1, 0))
    $cg.GradientStops.Add((New-Object System.Windows.Media.GradientStop $pal.core2, 1))
    $cg.Freeze()
    $el.OrbCore.Fill = $cg
    $el.OrbCore.Stroke = New-SolidBrushC (New-AlphaColor $pal.accB 0x8C)
    $el.OrbVal.Foreground = New-SolidBrushC $pal.coreInk
    $el.OrbLabel.Foreground = New-SolidBrushC (New-AlphaColor $pal.coreInk 0x9E)

    # halo arc: 240 deg scale around the orb, filled up to the position
    $sweep = 240.0 * $pos
    $rad = (150.0 + $sweep) * [math]::PI / 180.0
    $ex = 103.0 + 92.0 * [math]::Cos($rad)
    $ey = 103.0 + 92.0 * [math]::Sin($rad)
    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = New-Object System.Windows.Point 23.3, 149.0
    $arc = New-Object System.Windows.Media.ArcSegment
    $arc.Point = New-Object System.Windows.Point $ex, $ey
    $arc.Size = New-Object System.Windows.Size 92, 92
    $arc.IsLargeArc = ($sweep -gt 180)
    $arc.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
    $fig.Segments.Add($arc)
    $geo = New-Object System.Windows.Media.PathGeometry
    $geo.Figures.Add($fig)
    $geo.Freeze()
    $el.HaloFill.Data = $geo
    [System.Windows.Controls.Canvas]::SetLeft($el.HaloDot, $ex - 4.5)
    [System.Windows.Controls.Canvas]::SetTop($el.HaloDot, $ey - 4.5)
    $el.HaloDot.Visibility = 'Visible'

    # state labels, badge, section lines, shells
    $onIdx = if ($pos -lt 0.35) { 0 } elseif ($pos -le 0.8) { 1 } else { 2 }
    $labs = @($el.LabCool, $el.LabWarm, $el.LabHot)
    $faintBrush = New-SolidBrushC $pal.faint
    for ($i = 0; $i -lt 3; $i++) {
        $labs[$i].Foreground = if ($i -eq $onIdx) { $script:brushAccentB } else { $faintBrush }
    }
    $el.StateBadge.Background  = New-SolidBrushC (New-AlphaColor $acc 0x1A)
    $el.StateBadge.BorderBrush = New-SolidBrushC (New-AlphaColor $acc 0x42)
    $el.UpdatePill.Background  = $el.StateBadge.Background
    $el.UpdatePill.BorderBrush = $el.StateBadge.BorderBrush
    # banner: accent-washed panel with an accent glow so it demands the eye
    $el.UpdateBanner.BorderBrush = New-SolidBrushC (New-AlphaColor $acc 0xB3)
    $bbg = New-Object System.Windows.Media.LinearGradientBrush
    $bbg.StartPoint = New-Object System.Windows.Point 0, 0
    $bbg.EndPoint   = New-Object System.Windows.Point 0, 1
    $bbg.GradientStops.Add((New-Object System.Windows.Media.GradientStop (Mix-Color $pal.tile $acc 0.30), 0))
    $bbg.GradientStops.Add((New-Object System.Windows.Media.GradientStop (Mix-Color $pal.tile $acc 0.10), 1))
    $bbg.Freeze()
    $el.UpdateBanner.Background = $bbg
    if ($el.UpdateBanner.Effect) {
        $el.UpdateBanner.Effect.Color = $acc
        $el.UpdateBanner.Effect.Opacity = 0.5
        $el.UpdateBanner.Effect.BlurRadius = 22
    }
    $el.StateBadgeText.Text = @('COOL', 'WARM', 'HOT')[$onIdx]
    $sectBrush = New-SolidBrushC (New-AlphaColor $acc 0x22)
    $el.SectLine1.Background = $sectBrush
    $el.SectLine2.Background = $sectBrush
    $el.ModeShell.BorderBrush  = New-SolidBrushC (New-AlphaColor $acc 0x24)
    $shellBrush = New-SolidBrushC (New-AlphaColor $acc 0x24)
    foreach ($sh in 'GameActShell', 'OsdModeShell', 'OsdCornerShell', 'OsdLayoutShell', 'OsdThemeShell') { $el[$sh].BorderBrush = $shellBrush }
    $el.FooterPill.BorderBrush = New-SolidBrushC (New-AlphaColor $acc 0x26)
    $slotBorder = New-SolidBrushC (New-AlphaColor $acc 0x1C)
    foreach ($sl in 'Slot1', 'Slot2', 'Slot3', 'Slot4') { $el[$sl].BorderBrush = $slotBorder }

    # tile top hairlines
    $hair = New-Object System.Windows.Media.LinearGradientBrush
    $hair.StartPoint = New-Object System.Windows.Point 0, 0.5
    $hair.EndPoint   = New-Object System.Windows.Point 1, 0.5
    $hair.GradientStops.Add((New-Object System.Windows.Media.GradientStop (New-AlphaColor $acc 0x5C), 0))
    $hair.GradientStops.Add((New-Object System.Windows.Media.GradientStop (New-AlphaColor $acc 0x0D), 1))
    $hair.Freeze()
    foreach ($h in 'CpuHair', 'GpuHair', 'SsdHair', 'MbHair') { $el[$h].Background = $hair }

    # activity chart: CPU fan = light neutral, case fans = thermal accent
    $accHex = Get-HexOf $acc
    $chartAHex = Get-HexOf $pal.chartA
    $el.CpuFanSpark.Stroke = New-TrailBrush $chartAHex
    $el.CpuFanSparkFill.Fill = New-VAreaBrush $chartAHex 0x1F
    $el.CaseFanSpark.Stroke = New-TrailBrush $accHex
    $el.CaseFanSparkFill.Fill = New-VAreaBrush $accHex 0x30
    $el.LegCpuDot.Fill = $script:brushChartA
    $el.LegCaseDot.Fill = $script:brushAccent

    # temp sparklines: quiet dim traces with a soft accent area
    $spTrail = New-TrailBrush (Get-HexOf $pal.dim)
    $spFill = New-VAreaBrush $accHex 0x12
    foreach ($sp in 'CpuSpark', 'GpuSpark', 'SsdSpark', 'MbSpark') { $el[$sp].Stroke = $spTrail }
    foreach ($sp in 'CpuSparkFill', 'GpuSparkFill', 'SsdSparkFill', 'MbSparkFill') { $el[$sp].Fill = $spFill }

    # settings + mode panel accents
    foreach ($sec in 'SecFans', 'SecBoost', 'SecCurve', 'SecGame', 'SecOsd', 'SecSafety', 'SecTargets', 'SecGeneral', 'SecShortcuts', 'SecProfiles') { $el[$sec].Foreground = $script:brushAccent }
    # slider fills: dark -> bright accent, so the bar "charges up" toward the
    # blade (user call: karanliktan parlaga)
    $sgb = New-Object System.Windows.Media.LinearGradientBrush
    $sgb.StartPoint = New-Object System.Windows.Point 0, 0.5
    $sgb.EndPoint   = New-Object System.Windows.Point 1, 0.5
    $sgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop (New-AlphaColor $acc 0x4D), 0))
    $sgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop $acc, 0.72))
    $sgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop $pal.accB, 1))
    $sgb.Freeze()
    foreach ($sn in $script:sliderNames) { $el[$sn].Foreground = $sgb }
    foreach ($i in 1..4) { $el["MS$i"].Foreground = $sgb }
    $el.LogoOuter.Fill = $script:brushAccent
    $el.BtnSetSave.Foreground = $script:brushDark
}

function Init-Sirocco {
    # halo track fill: the full cool->warm->hot scale as an absolute-mapped
    # gradient, so the growing arc reveals it instead of stretching it
    $hg = New-Object System.Windows.Media.LinearGradientBrush
    $hg.MappingMode = [System.Windows.Media.BrushMappingMode]::Absolute
    $hg.StartPoint = New-Object System.Windows.Point 0, 0
    $hg.EndPoint   = New-Object System.Windows.Point 206, 0
    $hg.GradientStops.Add((New-Object System.Windows.Media.GradientStop $script:thAnchor.cool.acc, 0))
    $hg.GradientStops.Add((New-Object System.Windows.Media.GradientStop $script:thAnchor.warm.accB, 0.55))
    $hg.GradientStops.Add((New-Object System.Windows.Media.GradientStop $script:thAnchor.hot.acc, 1))
    $hg.Freeze()
    $el.HaloFill.Stroke = $hg

    # breathing hero glow - peak capped low so the hot state never flares.
    # Without a frame cap these forever-animations render at the display
    # refresh rate and cost about half a core; 30fps is indistinguishable.
    $ba = New-Object System.Windows.Media.Animation.DoubleAnimation 0.34, 0.56, ([System.Windows.Duration][TimeSpan]::FromSeconds(1.6))
    $ba.AutoReverse = $true
    $ba.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($ba, 30)
    $el.OrbGlow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $ba)

    # fan rotor spinners: a controllable storyboard per rotor whose speed
    # ratio follows the real RPM; paused entirely at 0
    $script:rotorSb = @{}
    $script:rotorRatio = @{}
    foreach ($r in 'RotorCpu', 'RotorCase', 'RotorGpu') {
        $rt = New-Object System.Windows.Media.RotateTransform 0
        $el[$r].RenderTransform = $rt
        $an = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 360, ([System.Windows.Duration][TimeSpan]::FromSeconds(1))
        $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($an, 30)
        [System.Windows.Media.Animation.Storyboard]::SetTarget($an, $el[$r])
        [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($an, (New-Object System.Windows.PropertyPath '(UIElement.RenderTransform).(RotateTransform.Angle)'))
        $sb = New-Object System.Windows.Media.Animation.Storyboard
        [void]$sb.Children.Add($an)
        $sb.Begin($el[$r], $true)
        $sb.Pause($el[$r])
        $script:rotorSb[$r] = $sb
        $script:rotorRatio[$r] = 0.0
    }
    Apply-Thermal (Get-ThermalMix -20)
}

function Set-RotorSpeed([string]$name, $rpm) {
    $sb = $script:rotorSb[$name]
    if (-not $sb) { return }
    if ($null -eq $rpm -or $rpm -lt 60) {
        if ($script:rotorRatio[$name] -ne 0) { $sb.Pause($el[$name]); $script:rotorRatio[$name] = 0 }
        return
    }
    $ratio = [math]::Min(3.0, [math]::Max(0.25, $rpm / 900.0))
    $last = $script:rotorRatio[$name]
    if ($last -eq 0) { $sb.Resume($el[$name]) }
    if ($last -eq 0 -or [math]::Abs($ratio - $last) / [math]::Max($last, 0.01) -gt 0.12) {
        $sb.SetSpeedRatio($el[$name], $ratio)
        $script:rotorRatio[$name] = $ratio
    }
}

# --- Settings panel --------------------------------------------------
$script:sliderMap = @(
    @('S_QuietCase',  'V_QuietCase',  'quietCase',  '%'),
    @('S_NormalCase', 'V_NormalCase', 'normalCase', '%'),
    @('S_PerfCase',   'V_PerfCase',   'perfCase',   '%'),
    @('S_PerfCpu',    'V_PerfCpu',    'perfCpu',    '%'),
    @('S_BoostHigh',  'V_BoostHigh',  'boostHigh',  "$script:deg"),
    @('S_BoostLow',   'V_BoostLow',   'boostLow',   "$script:deg"),
    @('S_BoostCase',  'V_BoostCase',  'boostCase',  '%'),
    @('S_C40',        'V_C40',        'curve40',    '%'),
    @('S_C55',        'V_C55',        'curve55',    '%'),
    @('S_C70',        'V_C70',        'curve70',    '%'),
    @('S_C80',        'V_C80',        'curve80',    '%'),
    @('S_GameLoad',   'V_GameLoad',   'gameOnLoad', '%'),
    @('S_GameCool',   'V_GameCool',   'gameCooldownSec', 's'),
    @('S_OsdScale',   'V_OsdScale',   'osdScale',   '%'),
    @('S_OsdOpacity', 'V_OsdOpacity', 'osdOpacity', '%'),
    @('S_CpuMax',     'V_CpuMax',     'cpuMaxTemp', "$script:deg"),
    @('S_GpuMax',     'V_GpuMax',     'gpuMaxTemp', "$script:deg"),
    @('S_WarnCpu',    'V_WarnCpu',    'warnCpu',    "$script:deg"),
    @('S_WarnGpu',    'V_WarnGpu',    'warnGpu',    "$script:deg"),
    @('S_WarnSsd',    'V_WarnSsd',    'warnSsd',    "$script:deg"),
    @('S_WarnMb',     'V_WarnMb',     'warnMb',     "$script:deg")
)
foreach ($row in $script:sliderMap) {
    $sName = $row[0]; $vName = $row[1]; $suffix = $row[3]
    $el[$sName].Add_ValueChanged({
        $el[$vName].Text = '{0}{1}' -f [int]$el[$sName].Value, $suffix
    }.GetNewClosure())
}
$el.S_Interval.Add_ValueChanged({ $el.V_Interval.Text = '{0}s' -f [int]$el.S_Interval.Value })

function Update-SliderLabels {
    # Explicit refresh: assigning Value == Minimum raises no ValueChanged event
    foreach ($row in $script:sliderMap) { $el[$row[1]].Text = '{0}{1}' -f [int]$el[$row[0]].Value, $row[3] }
    $el.V_Interval.Text = '{0}s' -f [int]$el.S_Interval.Value
}

# --- Mode panel: live per-mode settings under the mode selector ------
# Slot rows: label, settings key, min, max, suffix. Changes apply to the
# fans immediately; the disk write is debounced while a slider is dragged.
$script:modePanelDef = @{
    quiet       = @(@('Case fans','quietCase',20,100,'%'),
                    @('Boost above','boostHigh',60,90,"$script:deg"),
                    @('Resume below','boostLow',40,85,"$script:deg"),
                    @('Boost fans','boostCase',30,100,'%'))
    normal      = @(,@('Case fans','normalCase',20,100,'%'))
    performance = @(@('Case fans','perfCase',20,100,'%'),
                    @('CPU fan','perfCpu',30,100,'%'))
    curve       = @(@("At 40$($script:deg)C",'curve40',20,100,'%'),
                    @("At 55$($script:deg)C",'curve55',20,100,'%'),
                    @("At 70$($script:deg)C",'curve70',20,100,'%'),
                    @("At 80$($script:deg)C",'curve80',20,100,'%'))
    auto        = @()
}
$script:panelMode = $null
$script:panelLoading = $false

$script:saveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:saveTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$script:saveTimer.Add_Tick({
    $script:saveTimer.Stop()
    Export-Settings $script:settings
})

function Apply-ModeSetting([string]$key, [int]$v) {
    $script:settings[$key] = $v
    $sync.Settings[$key] = $v
    $sync.SettingsChanged = $true
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
}

function Set-UserMode([string]$m) {
    # user-chosen mode: apply it and remember it across restarts
    $sync.PendingMode = $m
    if ([string]$script:settings.lastMode -ne $m) {
        $script:settings.lastMode = $m
        $sync.Settings.lastMode = $m
        $script:saveTimer.Stop()
        $script:saveTimer.Start()
    }
}

function Update-ModePanel([string]$mode) {
    if (-not $script:modePanelDef.ContainsKey($mode)) { return }
    $script:panelMode = $mode
    $script:panelLoading = $true
    $def = @($script:modePanelDef[$mode])
    $el.ModeSetTitle.Text = '{0} MODE' -f $script:modeNames[$mode].ToUpperInvariant()
    for ($i = 1; $i -le 4; $i++) {
        if ($i -le $def.Count) {
            $row = $def[$i - 1]
            $sl = $el["MS$i"]
            $sl.Tag = $null      # mute the apply handler while reconfiguring
            $sl.Minimum = [double]$row[2]
            $sl.Maximum = [double]$row[3]
            $sl.Value = [double]$script:settings[$row[1]]
            $sl.Tag = $row
            $el["ML$i"].Text = ([string]$row[0]).ToUpperInvariant()
            $el["MV$i"].Text = '{0}' -f [int]$sl.Value
            $el["MU$i"].Text = [string]$row[4]
            # percent reads as a subscript unit, a degree sign belongs up top
            if ([string]$row[4] -eq '%') {
                $el["MU$i"].VerticalAlignment = 'Bottom'
                $el["MU$i"].Margin = New-Object System.Windows.Thickness 2, 0, 0, 2
            } else {
                $el["MU$i"].VerticalAlignment = 'Top'
                $el["MU$i"].Margin = New-Object System.Windows.Thickness 2, 2, 0, 0
            }
            $el["Slot$i"].Visibility = 'Visible'
        } else {
            $el["MS$i"].Tag = $null
            $el["Slot$i"].Visibility = 'Collapsed'
        }
    }
    if ($mode -eq 'quiet') {
        # keep 'Resume below' at least 3 degrees under 'Boost above'
        foreach ($j in 1..4) {
            $o = $el["MS$j"]
            if ($o.Tag -and [string]$o.Tag[1] -eq 'boostLow') { $o.Maximum = [math]::Min(85, [double]$script:settings.boostHigh - 3) }
        }
    }
    # Grey out the boost rows when the feature itself is off, so the panel
    # never advertises sliders that have no effect.
    $boostOff = ($mode -eq 'quiet' -and -not [bool]$script:settings.boostEnabled)
    foreach ($j in 1..4) {
        $o = $el["MS$j"]
        $dim = $boostOff -and $o.Tag -and (@('boostHigh','boostLow','boostCase') -contains [string]$o.Tag[1])
        $el["Slot$j"].IsEnabled = -not $dim
        $el["Slot$j"].Opacity = $(if ($dim) { 0.45 } else { 1.0 })
    }
    if ($mode -eq 'auto') {
        $el.ModeSetHint.Text = 'The motherboard is driving the fans in Auto mode. Pick another mode to set speeds yourself.'
        $el.ModeSetHint.Visibility = 'Visible'
        $el.ModeSlots.Visibility = 'Collapsed'
        $el.BtnModeReset.Visibility = 'Collapsed'
    } else {
        if ($boostOff) {
            $el.ModeSetHint.Text = 'Cooling boost is turned off in Settings - the greyed-out sliders have no effect.'
            $el.ModeSetHint.Visibility = 'Visible'
        } else {
            $el.ModeSetHint.Visibility = 'Collapsed'
        }
        $el.ModeSlots.Visibility = 'Visible'
        $el.BtnModeReset.Visibility = 'Visible'
    }
    $script:panelLoading = $false
}

foreach ($i in 1..4) {
    # One shared handler; the slot's row definition rides on the slider's Tag
    # (no GetNewClosure - see the swatch note above about $script: scope).
    $el["MS$i"].Add_ValueChanged({ param($s, $e)
        $row = $s.Tag
        if ($null -eq $row) { return }
        $el[($s.Name -replace '^MS', 'MV')].Text = '{0}' -f [int]$s.Value
        if ($script:panelLoading) { return }
        Apply-ModeSetting ([string]$row[1]) ([int]$s.Value)
        if ([string]$row[1] -eq 'boostHigh') {
            # push 'Resume below' down with it; the clamp re-enters this
            # handler for that slider and applies the new value
            foreach ($j in 1..4) {
                $o = $el["MS$j"]
                if ($o.Tag -and [string]$o.Tag[1] -eq 'boostLow') { $o.Maximum = [math]::Min(85, [double]$s.Value - 3) }
            }
        }
    })
}

$el.BtnModeReset.Add_Click({
    $mode = $script:panelMode
    if (-not $mode -or $mode -eq 'auto') { return }
    $defaults = Get-DefaultSettings
    foreach ($row in @($script:modePanelDef[$mode])) { Apply-ModeSetting ([string]$row[1]) ([int]$defaults[$row[1]]) }
    Update-ModePanel $mode
})

# --- Settings pickers: segmented buttons for game action + OSD -------
$script:gameActionUI  = 'performance'
$script:osdModePick   = 'auto'
$script:osdCornerPick = 'tr'
$script:osdLayoutPick = 'blade'
$script:osdThemePick  = 'sirocco'
$script:osdColorStage = @{}      # metric color overrides staged while the panel is open
$script:osdCheckMap = @(@('S_OsdFps','osdFps'), @('S_OsdCpu','osdCpu'), @('S_OsdGpu','osdGpu'), @('S_OsdLoad','osdGpuLoad'),
                        @('S_OsdRam','osdRam'),
                        @('S_OsdFans','osdFans'), @('S_OsdSsd','osdSsd'), @('S_OsdMb','osdMb'), @('S_OsdPods','osdPods'))
$script:osdColBtnMap = @(@('O_ColFps','osdColFps'), @('O_ColCpu','osdColCpu'), @('O_ColGpu','osdColGpu'), @('O_ColLoad','osdColLoad'),
                         @('O_ColRam','osdColRam'), @('O_ColSsd','osdColSsd'), @('O_ColMb','osdColMb'),
                         @('O_ColFan','osdColFan'), @('O_ColPods','osdColPods'))

function Update-PickerButtons($map, [string]$picked) {
    foreach ($k in @($map.Keys)) {
        $b = $el[$map[$k]]
        if ($k -eq $picked) { $b.Background = $script:brushAccentPill; $b.Foreground = $script:brushDark }
        else { $b.Background = $script:brushClear; $b.Foreground = $script:brushDim }
    }
}
$script:gameActBtns   = @{ performance = 'S_GameActPerf'; curve = 'S_GameActCurve'; off = 'S_GameActOff' }
$script:osdModeBtns   = @{ auto = 'O_ModeAuto'; on = 'O_ModeOn'; off = 'O_ModeOff' }
$script:osdCornerBtns = @{ tl = 'O_CorTL'; tr = 'O_CorTR'; bl = 'O_CorBL'; br = 'O_CorBR' }
$script:osdLayoutBtns = @{ blade = 'O_LayBlade'; strip = 'O_LayStrip'; hero = 'O_LayHero'; pills = 'O_LayPills';
                           ghost = 'O_LayGhost'; micro = 'O_LayMicro'; thermo = 'O_LayThermo' }
$script:osdThemeBtns  = @{ sirocco = 'O_ThSirocco'; ember = 'O_ThEmber'; venom = 'O_ThVenom'; violet = 'O_ThViolet';
                           crimson = 'O_ThCrimson'; mono = 'O_ThMono' }

function Update-GameActionButtons {
    Update-PickerButtons $script:gameActBtns $script:gameActionUI
    $off = ($script:gameActionUI -eq 'off')
    $el.GameSliders.IsEnabled = -not $off
    $el.GameSliders.Opacity = $(if ($off) { 0.45 } else { 1.0 })
}
function Update-OsdColorButtons {
    foreach ($row in $script:osdColBtnMap) {
        $b = $el[$row[0]]
        $hex = [string]$script:osdColorStage[$row[1]]
        if ($hex) {
            $b.Background = New-SolidBrushC ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
            $b.Foreground = $script:brushDark
        } else {
            $b.Background = $script:brushClear
            $b.Foreground = $script:brushDim
        }
    }
    $el.O_ColReset.Background = $script:brushClear
    $el.O_ColReset.Foreground = $script:brushDim
}
function Update-OsdPickers {
    Update-PickerButtons $script:osdModeBtns $script:osdModePick
    Update-PickerButtons $script:osdCornerBtns $script:osdCornerPick
    Update-PickerButtons $script:osdLayoutBtns $script:osdLayoutPick
    Update-PickerButtons $script:osdThemeBtns $script:osdThemePick
    Update-OsdColorButtons
    Update-OsdPreview
}

# Live preview inside the settings panel: runs the real overlay builder
# against the STAGED picks (nothing is saved yet) by briefly swapping the
# builder's context, then restoring the live overlay's references.
function Update-OsdPreview {
    if (-not $el.OsdPreviewHost) { return }
    $stage = @{}
    foreach ($k in $script:settings.Keys) { $stage[$k] = $script:settings[$k] }
    $stage.osdLayout = [string]$script:osdLayoutPick
    $stage.osdTheme  = [string]$script:osdThemePick
    $stage.osdScale  = [int]$el.S_OsdScale.Value
    foreach ($p in $script:osdCheckMap) { $stage[$p[1]] = [bool]$el[$p[0]].IsChecked }
    foreach ($row in $script:osdColBtnMap) { $stage[$row[1]] = [string]$script:osdColorStage[$row[1]] }
    $bakSettings = $script:settings; $bakHost = $script:osdHost
    $bakVals = $script:osdVals; $bakAcc = $script:osdAccented
    $bakDot = $script:osdThermoDot; $bakHero = $script:osdHeroId; $bakState = $script:osdState
    try {
        $script:settings = $stage
        $script:osdHost = $el.OsdPreviewHost
        $script:osdState = 'cool'
        Build-OsdContent
        $sample = @{ cpu = "62$($script:deg)"; gpu = "71$($script:deg)"; load = '98%'; ram = '54%'
                     ssd = "48$($script:deg)"; mb = "46$($script:deg)"; fan = "842 $($script:mid) 615"
                     fps = '144'; pods = "100$($script:mid)90$($script:mid)30" }
        foreach ($id in @($script:osdVals.Keys)) { $script:osdVals[$id].Text = $sample[$id] }
        if ($el.OsdPreviewHost.Children.Count -gt 0) {
            $c = $el.OsdPreviewHost.Children[$el.OsdPreviewHost.Children.Count - 1]
            switch ([string]$script:osdCornerPick) {
                'tl' { $c.HorizontalAlignment = 'Left';  $c.VerticalAlignment = 'Top' }
                'bl' { $c.HorizontalAlignment = 'Left';  $c.VerticalAlignment = 'Bottom' }
                'br' { $c.HorizontalAlignment = 'Right'; $c.VerticalAlignment = 'Bottom' }
                default { $c.HorizontalAlignment = 'Right'; $c.VerticalAlignment = 'Top' }
            }
            $c.Margin = New-Object System.Windows.Thickness 12
        }
    } catch { } finally {
        $script:settings = $bakSettings; $script:osdHost = $bakHost
        $script:osdVals = $bakVals; $script:osdAccented = $bakAcc
        $script:osdThermoDot = $bakDot; $script:osdHeroId = $bakHero; $script:osdState = $bakState
    }
}
foreach ($k in @($script:gameActBtns.Keys)) {
    $el[$script:gameActBtns[$k]].Tag = $k
    $el[$script:gameActBtns[$k]].Add_Click({ param($s0, $e0) $script:gameActionUI = [string]$s0.Tag; Update-GameActionButtons })
}
foreach ($k in @($script:osdModeBtns.Keys)) {
    $el[$script:osdModeBtns[$k]].Tag = $k
    $el[$script:osdModeBtns[$k]].Add_Click({ param($s0, $e0) $script:osdModePick = [string]$s0.Tag; Update-OsdPickers })
}
foreach ($k in @($script:osdCornerBtns.Keys)) {
    $el[$script:osdCornerBtns[$k]].Tag = $k
    $el[$script:osdCornerBtns[$k]].Add_Click({ param($s0, $e0) $script:osdCornerPick = [string]$s0.Tag; Update-OsdPickers })
}
foreach ($k in @($script:osdLayoutBtns.Keys)) {
    $el[$script:osdLayoutBtns[$k]].Tag = $k
    $el[$script:osdLayoutBtns[$k]].Add_Click({ param($s0, $e0) $script:osdLayoutPick = [string]$s0.Tag; Update-OsdPickers })
}
foreach ($k in @($script:osdThemeBtns.Keys)) {
    $el[$script:osdThemeBtns[$k]].Tag = $k
    $el[$script:osdThemeBtns[$k]].Add_Click({ param($s0, $e0) $script:osdThemePick = [string]$s0.Tag; Update-OsdPickers })
}
foreach ($row in $script:osdColBtnMap) {
    $el[$row[0]].Tag = $row[1]
    $el[$row[0]].Add_Click({ param($s0, $e0)
        $key = [string]$s0.Tag
        $dlg = New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen = $true
        $cur = [string]$script:osdColorStage[$key]
        if ($cur) {
            try { $dlg.Color = [System.Drawing.ColorTranslator]::FromHtml($cur) } catch { }
        }
        # Owned by the main window so the picker always opens in front of it.
        $own = New-Object System.Windows.Forms.NativeWindow
        try { $own.AssignHandle((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle) } catch { }
        if ($dlg.ShowDialog($own) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:osdColorStage[$key] = '#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B
            Update-OsdColorButtons
            Update-OsdPreview
        }
        try { $own.ReleaseHandle() } catch { }
        $dlg.Dispose()
    })
}
$el.O_ColReset.Add_Click({ $script:osdColorStage = @{}; Update-OsdColorButtons; Update-OsdPreview })
foreach ($p in $script:osdCheckMap) {
    $el[$p[0]].Add_Click({ Update-OsdPreview })
}
$el.S_OsdScale.Add_ValueChanged({ if ($el.SettingsOverlay.Visibility -eq 'Visible') { Update-OsdPreview } })

function Open-Settings {
    $s = $script:settings
    foreach ($row in $script:sliderMap) { $el[$row[0]].Value = [double]$s[$row[2]] }
    $el.S_Interval.Value = [math]::Round($s.updateIntervalMs / 1000)
    Update-SliderLabels
    $el.S_BoostEnabled.IsChecked = [bool]$s.boostEnabled
    $el.BtnOsdResetPos.Visibility = $(if ([bool]$s.osdFree) { 'Visible' } else { 'Collapsed' })
    $el.OsdPosNote.Text = $(if ([bool]$s.osdFree) { 'parked where you dragged it' } else { '' })
    $script:gameActionUI  = [string]$s.gameAction
    $script:osdModePick   = [string]$s.osdMode
    $script:osdCornerPick = [string]$s.osdCorner
    $script:osdLayoutPick = [string]$s.osdLayout
    $script:osdThemePick  = [string]$s.osdTheme
    $script:osdColorStage = @{}
    foreach ($row in $script:osdColBtnMap) { if ([string]$s[$row[1]]) { $script:osdColorStage[$row[1]] = [string]$s[$row[1]] } }
    $el.S_OsdSecond.IsChecked = [bool]$s.osdOnSecondary
    $el.S_OsdCapSafe.IsChecked = [bool]$s.osdCapSafe
    foreach ($p in $script:osdCheckMap) { $el[$p[0]].IsChecked = [bool]$s[$p[1]] }
    $script:hkCapturing = $null
    foreach ($hkA in $script:hotkeyActions) {
        $script:hotkeyStage[$hkA.Set] = [string]$s[$hkA.Set]
        $el[$hkA.Btn].Content = Format-HotkeyText ([string]$s[$hkA.Set])
    }
    $el.HkConflict.Visibility = 'Collapsed'
    $el.VentoEditLayer.Visibility = 'Collapsed'
    Build-VentoScenes
    Update-GameActionButtons
    Update-OsdPickers
    $el.S_StartMin.IsChecked     = [bool]$s.startMinimized
    $el.S_CloseTray.IsChecked    = [bool]$s.closeToTray
    $el.S_Updates.IsChecked      = [bool]$s.checkUpdates
    $el.S_AutoStart.IsChecked    = Test-AutoStart
    $el.SettingsOverlay.Visibility = 'Visible'
}

function Save-Settings {
    $s = $script:settings
    foreach ($row in $script:sliderMap) { $s[$row[2]] = [int]$el[$row[0]].Value }
    if ($s.boostLow -gt $s.boostHigh - 3) { $s.boostLow = $s.boostHigh - 3 }
    $s.updateIntervalMs = [int]$el.S_Interval.Value * 1000
    $s.boostEnabled   = [bool]$el.S_BoostEnabled.IsChecked
    $s.startMinimized = [bool]$el.S_StartMin.IsChecked
    $s.closeToTray    = [bool]$el.S_CloseTray.IsChecked
    $s.checkUpdates   = [bool]$el.S_Updates.IsChecked
    $s.gameAction     = [string]$script:gameActionUI
    $s.osdMode        = [string]$script:osdModePick
    # Picking a corner is an explicit "snap back": it clears a dragged position.
    if ([string]$s.osdCorner -ne [string]$script:osdCornerPick) { $s.osdFree = $false }
    $s.osdCorner      = [string]$script:osdCornerPick
    $s.osdLayout      = [string]$script:osdLayoutPick
    $s.osdTheme       = [string]$script:osdThemePick
    $s.osdOnSecondary = [bool]$el.S_OsdSecond.IsChecked
    $s.osdCapSafe     = [bool]$el.S_OsdCapSafe.IsChecked
    foreach ($hkA in $script:hotkeyActions) { $s[$hkA.Set] = [string]$script:hotkeyStage[$hkA.Set] }
    foreach ($p in $script:osdCheckMap) { $s[$p[1]] = [bool]$el[$p[0]].IsChecked }
    foreach ($row in $script:osdColBtnMap) { $s[$row[1]] = [string]$script:osdColorStage[$row[1]] }
    $want = [bool]$el.S_AutoStart.IsChecked
    if ($want -ne (Test-AutoStart)) {
        $err = Set-AutoStart $want
        if ($err) {
            $el.S_AutoStart.IsChecked = (Test-AutoStart)
            [void][System.Windows.MessageBox]::Show(
                ("Could not {0} the 'Start with Windows' task:`n`n{1}" -f $(if ($want) { 'register' } else { 'remove' }), $err),
                'Vento', 'OK', 'Warning')
        }
    }
    Export-Settings $s
    foreach ($k in $s.Keys) { $sync.Settings[$k] = $s[$k] }
    $sync.SettingsChanged = $true
    if ($script:panelMode) { Update-ModePanel $script:panelMode }
    Update-OsdLayout
    $hkR = Register-Hotkeys
    $el.SettingsOverlay.Visibility = 'Collapsed'
    $msgs = @()
    if ($hkR.Conflicts -and $hkR.Conflicts.Count) { $msgs += 'Already used by another app: ' + ($hkR.Conflicts -join ', ') }
    if ($hkR.Dupes -and $hkR.Dupes.Count)         { $msgs += 'Sharing a combination with another Vento shortcut: ' + ($hkR.Dupes -join ', ') }
    if ($msgs.Count) {
        [void][System.Windows.MessageBox]::Show(
            ("Some shortcuts could not be set:`n`n{0}" -f ($msgs -join "`n`n")),
            'Vento', 'OK', 'Warning')
    }
}

$el.BtnSetSave.Add_Click({ Save-Settings })
$el.BtnSetCancel.Add_Click({
    $el.SettingsOverlay.Visibility = 'Collapsed'
    # The opacity slider previews live on the real overlay; Cancel puts the
    # saved value back.
    if ($script:osd) { $script:osd.Opacity = ([int]$script:settings.osdOpacity) / 100.0 }
})
$el.S_OsdOpacity.Add_ValueChanged({
    if ($script:osd) { $script:osd.Opacity = [double]$el.S_OsdOpacity.Value / 100.0 }
})
$el.BtnOsdMove.Add_Click({
    $el.SettingsOverlay.Visibility = 'Collapsed'
    Set-OsdEdit $true
})
$el.BtnOsdResetPos.Add_Click({
    $script:settings.osdFree = $false
    $sync.Settings.osdFree = $false
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    $el.BtnOsdResetPos.Visibility = 'Collapsed'
    $el.OsdPosNote.Text = ''
    Position-Osd
})
# --- Global hotkeys --------------------------------------------------
# Each action has a settings key (the binding string) and a capture button.
$script:hotkeyActions = @(
    @{ Id = 'osd';    Set = 'hkOsd';    Btn = 'H_Osd';    Label = 'Toggle overlay' }
    @{ Id = 'quiet';  Set = 'hkQuiet';  Btn = 'H_Quiet';  Label = 'Quiet mode' }
    @{ Id = 'normal'; Set = 'hkNormal'; Btn = 'H_Normal'; Label = 'Normal mode' }
    @{ Id = 'perf';    Set = 'hkPerf';    Btn = 'H_Perf';    Label = 'Performance mode' }
    @{ Id = 'auto';    Set = 'hkAuto';    Btn = 'H_Auto';    Label = 'Auto mode' }
    @{ Id = 'profile'; Set = 'hkProfile'; Btn = 'H_Profile'; Label = 'Cycle Vento profile' }
)
$script:hkIds       = @{}            # WM_HOTKEY id -> action id
$script:hkHwnd      = [IntPtr]::Zero
$script:hkHook      = $null
$script:hkCapturing = $null          # the button currently listening for a combo
$script:hotkeyStage = @{}            # set-key -> binding, staged while the panel is open

# 'Ctrl+Alt+F9' -> @{ Mods=<MOD_* flags>; Vk=<virtual key> }, or $null for junk.
function Parse-Hotkey([string]$str) {
    if (-not $str) { return $null }
    $mods = 0x4000   # MOD_NOREPEAT: one fire per press, not key autorepeat
    $keyName = $null
    foreach ($p in ($str -split '\+')) {
        $t = $p.Trim(); if (-not $t) { continue }
        switch ($t.ToLowerInvariant()) {
            'ctrl'  { $mods = $mods -bor 0x0002 }
            'alt'   { $mods = $mods -bor 0x0001 }
            'shift' { $mods = $mods -bor 0x0004 }
            'win'   { $mods = $mods -bor 0x0008 }
            default { $keyName = $t }
        }
    }
    if (-not $keyName) { return $null }
    # A bare number would parse as the Key enum's underlying value (Key '1' is
    # Cancel, not the digit), binding the wrong physical key. Digit keys are
    # stored as their enum names ('D1'..'D9'), so reject a numeric-only token.
    if ($keyName -match '^\d+$') { return $null }
    try {
        $key = [System.Windows.Input.Key][Enum]::Parse([System.Windows.Input.Key], $keyName, $true)
        $vk  = [System.Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
        if ($vk -le 0) { return $null }
        return @{ Mods = $mods; Vk = $vk }
    } catch { return $null }
}

# Key-enum names -> a friendly label ('D9' -> '9').
function Format-HotkeyText([string]$str) {
    if (-not $str) { return 'Not set' }
    $out = @()
    foreach ($p in ($str -split '\+')) {
        $t = $p.Trim(); if (-not $t) { continue }
        if ($t -match '^D([0-9])$') { $out += $Matches[1] }
        else {
            switch ($t.ToLowerInvariant()) {
                'ctrl'  { $out += 'Ctrl' }
                'alt'   { $out += 'Alt' }
                'shift' { $out += 'Shift' }
                'win'   { $out += 'Win' }
                default { $out += $t }
            }
        }
    }
    return ($out -join ' + ')
}

function Refresh-HkButton($btn) {
    if ($btn) { $btn.Content = Format-HotkeyText ([string]$script:hotkeyStage[[string]$btn.Tag]) }
}

# Overlay on/off, shared by the tray item and the hotkey.
function Toggle-Overlay {
    $s = $script:settings
    if ([string]$s.osdMode -eq 'off') {
        $s.osdMode = $(if ($script:osdModePrev) { $script:osdModePrev } else { 'auto' })
    } else {
        $script:osdModePrev = [string]$s.osdMode
        $s.osdMode = 'off'
    }
    $sync.Settings.osdMode = $s.osdMode
    $script:saveTimer.Stop(); $script:saveTimer.Start()
}

function Invoke-HotkeyAction([string]$id) {
    try {
        switch ($id) {
            'osd'    { Toggle-Overlay }
            'quiet'  { Set-UserMode 'quiet' }
            'normal' { Set-UserMode 'normal' }
            'perf'    { Set-UserMode 'performance' }
            'auto'    { Set-UserMode 'auto' }
            'profile' { Cycle-VentoProfile }
        }
    } catch { }
}

# (Re)bind every configured hotkey to the main window. Returns the labels that
# Windows refused (already owned by another app, or a duplicate combo).
function Register-Hotkeys {
    if (-not ('VentoNative.Hotkey' -as [type])) { return @() }
    $h = [IntPtr]::Zero
    try { $h = (New-Object System.Windows.Interop.WindowInteropHelper $window).EnsureHandle() } catch { return @() }
    if ($h -eq [IntPtr]::Zero) { return @() }
    # Route WM_HOTKEY through a hook on the live handle, attached once.
    if ($script:hkHwnd -ne $h) {
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($h)
        if ($src) {
            if ($script:hkHook) { try { $src.RemoveHook($script:hkHook) } catch { } }
            $script:hkHook = [System.Windows.Interop.HwndSourceHook]{
                # args: hwnd, msg, wParam, lParam, handled. [void] so an action
                # that ever leaks output can't turn the delegate's return into a
                # collection that fails to marshal back as IntPtr.
                if ([int]$args[1] -eq 0x0312) {
                    $hid = ([IntPtr]$args[2]).ToInt32()
                    if ($script:hkIds.ContainsKey($hid)) { [void](Invoke-HotkeyAction $script:hkIds[$hid]) }
                }
                return [IntPtr]::Zero
            }
            $src.AddHook($script:hkHook)
            $script:hkHwnd = $h
        }
    }
    foreach ($oid in @($script:hkIds.Keys)) { [void][VentoNative.Hotkey]::UnregisterHotKey($h, $oid) }
    $script:hkIds = @{}
    $conflicts = @()   # the OS refused (another app owns it)
    $dupes = @()       # two Vento actions asked for the same combo
    $seen = @{}
    $id = 1
    foreach ($act in $script:hotkeyActions) {
        $p = Parse-Hotkey ([string]$script:settings[$act.Set])
        if (-not $p) { continue }
        $ck = '{0}:{1}' -f $p.Mods, $p.Vk
        if ($seen.ContainsKey($ck)) { $dupes += $act.Label; continue }
        if ([VentoNative.Hotkey]::RegisterHotKey($h, $id, [uint32]$p.Mods, [uint32]$p.Vk)) {
            $script:hkIds[$id] = $act.Id; $id++; $seen[$ck] = $true
        } else {
            $conflicts += $act.Label
        }
    }
    return @{ Conflicts = $conflicts; Dupes = $dupes }
}

# Capture wiring: click a field, then press the combination.
foreach ($hkAct in $script:hotkeyActions) {
    $hkBtn = $el[$hkAct.Btn]
    if (-not $hkBtn) { continue }
    $hkBtn.Tag = $hkAct.Set   # read back in the handlers - avoids a closure capture
    $hkBtn.Add_Click({ param($s0, $e0)
        if ($script:hkCapturing -and $script:hkCapturing -ne $s0) { Refresh-HkButton $script:hkCapturing }
        $script:hkCapturing = $s0
        $s0.Content = 'Press keys...'
        [void]$s0.Focus()
    })
    $hkBtn.Add_PreviewKeyDown({ param($s0, $e0)
        if ($script:hkCapturing -ne $s0) { return }
        $e0.Handled = $true
        $key = $e0.Key
        if ($key -eq [System.Windows.Input.Key]::System) { $key = $e0.SystemKey }
        $name = $key.ToString()
        if (@('LeftCtrl','RightCtrl','LeftAlt','RightAlt','LeftShift','RightShift','LWin','RWin','System','None') -contains $name) { return }
        if ($key -eq [System.Windows.Input.Key]::Escape) { $script:hkCapturing = $null; Refresh-HkButton $s0; return }
        if ($key -eq [System.Windows.Input.Key]::Back -or $key -eq [System.Windows.Input.Key]::Delete) {
            $script:hotkeyStage[[string]$s0.Tag] = ''; $script:hkCapturing = $null; $s0.Content = 'Not set'; return
        }
        $m = [int][System.Windows.Input.Keyboard]::Modifiers
        if ($m -eq 0) { $s0.Content = 'Add a modifier...'; return }   # keep listening
        $parts = @()
        if ($m -band [int][System.Windows.Input.ModifierKeys]::Control) { $parts += 'Ctrl' }
        if ($m -band [int][System.Windows.Input.ModifierKeys]::Alt)     { $parts += 'Alt' }
        if ($m -band [int][System.Windows.Input.ModifierKeys]::Shift)   { $parts += 'Shift' }
        if ($m -band [int][System.Windows.Input.ModifierKeys]::Windows) { $parts += 'Win' }
        $parts += $name
        $norm = $parts -join '+'
        if (-not (Parse-Hotkey $norm)) { $s0.Content = 'Unsupported key'; return }
        $script:hotkeyStage[[string]$s0.Tag] = $norm
        $script:hkCapturing = $null
        $s0.Content = Format-HotkeyText $norm
    })
    # Leaving the field mid-capture puts the saved label back.
    $hkBtn.Add_LostKeyboardFocus({ param($s0, $e0)
        if ($script:hkCapturing -eq $s0) { $script:hkCapturing = $null; Refresh-HkButton $s0 }
    })
}

$el.UpdatePill.Add_MouseLeftButtonUp({ Install-Update })

# --- Update banner ---------------------------------------------------
# Drops in when the update is first detected and again whenever the window
# is (re)opened while one is pending; Later dismisses it for the session.
$script:bannerDismissed = $false
$el.UpdateBanner.RenderTransform = New-Object System.Windows.Media.TranslateTransform 0, -70
$script:bannerTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:bannerTimer.Interval = [TimeSpan]::FromSeconds(10)

function Show-UpdateBanner {
    if (-not $sync.Update -or $script:bannerDismissed -or $sync.DlState) { return }
    $el.UpdateBannerText.Text = 'Vento {0} is available' -f $sync.Update.Version
    $el.UpdateBanner.Visibility = 'Visible'
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $ay = New-Object System.Windows.Media.Animation.DoubleAnimation -70, 0, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(380))
    $ay.EasingFunction = $ease
    $el.UpdateBanner.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ay)
    $ao = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 1, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(300))
    $el.UpdateBanner.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $ao)
    $script:bannerTimer.Stop(); $script:bannerTimer.Start()
}
function Hide-UpdateBanner {
    $script:bannerTimer.Stop()
    if ($el.UpdateBanner.Visibility -ne 'Visible') { return }
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn
    $ay = New-Object System.Windows.Media.Animation.DoubleAnimation 0, -70, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(300))
    $ay.EasingFunction = $ease
    $el.UpdateBanner.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $ay)
    $ao = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(280))
    $ao.Add_Completed({ $el.UpdateBanner.Visibility = 'Collapsed' })
    $el.UpdateBanner.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $ao)
}
$script:bannerTimer.Add_Tick({ Hide-UpdateBanner })
$el.BtnUpdateNow.Add_Click({ $script:bannerDismissed = $true; Hide-UpdateBanner; Install-Update })
$el.BtnUpdateLater.Add_Click({ $script:bannerDismissed = $true; Hide-UpdateBanner })
$el.BtnSettings.Add_Click({
    if ($el.SettingsOverlay.Visibility -eq 'Visible') { $el.SettingsOverlay.Visibility = 'Collapsed' }
    else { $el.PodsOverlay.Visibility = 'Collapsed'; Open-Settings }
})

# --- Monitor panel (DDC/CI) ------------------------------------------
# The monitors are the source of truth: values are read fresh on every
# panel open, only the sync preference is persisted. Slider moves are
# debounced into the DDC worker's queue so dragging never blocks the UI.
$script:monLoading = $false
$script:monGen = -1
$script:monWGen = 0
$script:nightLastMin = -1
$script:ddcPending = @{}
$script:presetNames = @{ 1 = 'sRGB'; 2 = 'Native'; 3 = '4000K'; 4 = '5000K'; 5 = '6500K'; 6 = '7500K';
                         7 = '8200K'; 8 = '9300K'; 9 = '10000K'; 10 = '11500K'; 11 = 'User 1'; 12 = 'User 2'; 13 = 'User 3' }
# VCP 0x60 input sources, standard MCCS numbering.
$script:inputNames  = @{ 1 = 'VGA 1'; 2 = 'VGA 2'; 3 = 'DVI 1'; 4 = 'DVI 2'; 5 = 'Composite'; 6 = 'Composite 2';
                         7 = 'S-Video'; 8 = 'S-Video 2'; 9 = 'Tuner'; 12 = 'Component'; 15 = 'DP 1'; 16 = 'DP 2';
                         17 = 'HDMI 1'; 18 = 'HDMI 2' }
# VCP 0xDC picture modes, standard MCCS numbering.
$script:modeNamesDdc = @{ 1 = 'Productivity'; 2 = 'Mixed'; 3 = 'Movie'; 4 = 'User'; 5 = 'Games';
                          6 = 'Sports'; 7 = 'Professional'; 8 = 'Eco'; 9 = 'Low power'; 10 = 'Demo'; 240 = 'Dynamic' }
# The chips carry the standard MCCS names. Vendors label these slots their
# own way in the OSD, but no mapping is guessed here: a wrong name is worse
# than a generic one.
function Get-MonModeName($m, [int]$code) {
    if ($script:modeNamesDdc.ContainsKey($code)) { return $script:modeNamesDdc[$code] }
    return '0x{0:X2}' -f $code
}
$script:monSel      = 0        # index of the display the controls act on
$script:monMapItems = @()      # map tiles, index-aligned with the DDC snapshot
$script:nightApplied = $false  # night profile is currently forced by the schedule
$script:nightPrev    = $null   # profile to restore when the window closes

# Slider moves are throttled, not debounced: while a blade is being dragged
# the newest value goes out every 40 ms instead of waiting for the hand to
# stop, so the other display follows the drag rather than the release. A DDC
# write is ~60 ms, and the worker keeps only the newest value per target, so
# a fast drag never queues up stale steps.
$script:ddcSendTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ddcSendTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$script:ddcSendTimer.Add_Tick({
    $script:ddcSendTimer.Stop()
    foreach ($k in @($script:ddcPending.Keys)) { $sync.DdcQueue.Enqueue($script:ddcPending[$k]) }
    $script:ddcPending = @{}
})
function Queue-DdcSet([string]$cmd, [int]$mon, [int]$value, [int]$code) {
    $script:ddcPending['{0}:{1}:{2}' -f $cmd, $mon, $code] = @{ Cmd = $cmd; Mon = $mon; Value = $value; Code = $code }
    if (-not $script:ddcSendTimer.IsEnabled) { $script:ddcSendTimer.Start() }
}

function ConvertTo-MonColor([string]$hex) {
    try { return [System.Windows.Media.ColorConverter]::ConvertFromString($hex) }
    catch { return [System.Windows.Media.ColorConverter]::ConvertFromString('#6FB1FF') }
}
# Bar fill in the app's language: dark at the left, bright under the blade.
function New-MonBarBrush($col) {
    $dark = [System.Windows.Media.Color]::FromArgb(0xFF, [byte]($col.R * 0.32), [byte]($col.G * 0.32), [byte]($col.B * 0.32))
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point 0, 0.5
    $b.EndPoint   = New-Object System.Windows.Point 1, 0.5
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop $dark, 0))
    $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop $col, 1))
    $b.Freeze()
    return $b
}
function New-MonBrush($col, [byte]$alpha = 255) {
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($alpha, $col.R, $col.G, $col.B))
    $b.Freeze(); return $b
}
function Show-ColorPicker([string]$current) {
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    if ($current) { try { $dlg.Color = [System.Drawing.ColorTranslator]::FromHtml($current) } catch { } }
    # Owned by the main window so the picker can't open behind the elevated app.
    $own = New-Object System.Windows.Forms.NativeWindow
    try { $own.AssignHandle((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle) } catch { }
    $res = $null
    if ($dlg.ShowDialog($own) -eq [System.Windows.Forms.DialogResult]::OK) {
        $res = '#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B
    }
    try { $own.ReleaseHandle() } catch { }
    $dlg.Dispose()
    return $res
}

# --- Display profiles ------------------------------------------------
# A profile is a snapshot the displays can be put back into with one tap:
# brightness, contrast and colour preset, plus an identity colour that
# tints the panel while it is the active one.
function Get-MonProfiles {
    $out = @()
    foreach ($p in @($script:settings.monProfiles)) {
        if ($null -eq $p) { continue }
        $h = @{}
        if ($p -is [hashtable]) { foreach ($k in $p.Keys) { $h[$k] = $p[$k] } }
        else { foreach ($pp in $p.PSObject.Properties) { $h[$pp.Name] = $pp.Value } }
        if (-not $h.Name) { continue }
        $h.Name    = [string]$h.Name
        $h.Color   = [string]$h.Color
        $h.Bri     = [int](Limit ([int]$h.Bri) 0 100)
        $h.Con     = [int](Limit ([int]$h.Con) 0 100)
        $h.Preset  = [int]$h.Preset
        $h.Builtin = [bool]$h.Builtin
        try { [void][System.Windows.Media.ColorConverter]::ConvertFromString($h.Color) } catch { $h.Color = '#6FB1FF' }
        $out += ,$h
    }
    return $out
}
function Save-MonProfiles($arr) {
    $script:settings.monProfiles = @($arr)
    $script:saveTimer.Stop(); $script:saveTimer.Start()
}
function Get-MonProfile([string]$name) {
    foreach ($p in (Get-MonProfiles)) { if ($p.Name -eq $name) { return $p } }
    return $null
}
# Which profile is showing on a display: in 'all' scope every display shares
# one, in 'one' scope each display remembers its own.
function Get-MonActiveProfileName([int]$idx) {
    if ([string]$script:settings.monProfileScope -eq 'all') { return [string]$script:settings.monProfile }
    $by = @($script:settings.monProfileByMon)
    if ($idx -ge 0 -and $idx -lt $by.Count -and $by[$idx]) { return [string]$by[$idx] }
    return ''
}
function Set-MonActiveProfileName([int]$idx, [string]$name) {
    $by = @($script:settings.monProfileByMon)
    $need = [math]::Max($idx + 1, @($sync.Ddc.Monitors).Count)
    while ($by.Count -lt $need) { $by += '' }
    $by[$idx] = $name
    $script:settings.monProfileByMon = @($by)
}
# Applies to every display, or only the selected one, per the scope switch.
function Apply-MonProfile($p, [switch]$Silent) {
    if (-not $p) { return }
    $mons = @($sync.Ddc.Monitors)
    $one = ([string]$script:settings.monProfileScope -eq 'one')
    $targets = if ($one) { ,$script:monSel } else { 0..([math]::Max(0, $mons.Count - 1)) }
    foreach ($i in $targets) {
        if ($i -lt 0 -or $i -ge $mons.Count -or -not $mons[$i].Ok) { continue }
        Queue-DdcSet 'SetBri' $i ([int]$p.Bri) 0
        if ($null -ne $mons[$i].ConCur) { Queue-DdcSet 'SetCon' $i ([int]$p.Con) 0 }
        if ([int]$p.Preset -gt 0 -and @($mons[$i].Presets) -contains [int]$p.Preset) {
            Queue-DdcSet 'SetVcp' $i ([int]$p.Preset) 0x14
        }
        # Reflect the new values locally; the next Enum re-reads them from the display.
        $mons[$i].BriCur = [int]$p.Bri
        if ($null -ne $mons[$i].ConCur) { $mons[$i].ConCur = [int]$p.Con }
        if ([int]$p.Preset -gt 0 -and @($mons[$i].Presets) -contains [int]$p.Preset) { $mons[$i].PreCur = [int]$p.Preset }
        Set-MonActiveProfileName $i ([string]$p.Name)
    }
    if (-not $one) { $script:settings.monProfile = [string]$p.Name }
    if (-not $Silent) { $script:saveTimer.Stop(); $script:saveTimer.Start() }
    Update-MonitorPanel
}

# --- Vento profiles: the whole machine under one name ----------------
# A Vento profile sets a fan mode, the overlay state, and a display profile
# (referenced by name, so it rides on the display scenes above rather than
# duplicating them). Switched from the tray submenu and the cycle hotkey.
function Get-VentoProfiles {
    $out = @()
    foreach ($p in @($script:settings.ventoProfiles)) {
        if ($null -eq $p) { continue }
        $h = @{}
        if ($p -is [hashtable]) { foreach ($k in $p.Keys) { $h[$k] = $p[$k] } }
        else { foreach ($pp in $p.PSObject.Properties) { $h[$pp.Name] = $pp.Value } }
        if (-not $h.Name) { continue }
        $h.Name    = [string]$h.Name
        $h.Color   = [string]$h.Color
        $h.Fan     = [string]$h.Fan
        $h.Overlay = [string]$h.Overlay
        $h.Display = [string]$h.Display
        $h.Builtin = [bool]$h.Builtin
        try { [void][System.Windows.Media.ColorConverter]::ConvertFromString($h.Color) } catch { $h.Color = '#6FB1FF' }
        $out += ,$h
    }
    return $out
}
function Get-VentoProfile([string]$name) {
    foreach ($p in (Get-VentoProfiles)) { if ($p.Name -eq $name) { return $p } }
    return $null
}
function Save-VentoProfiles($arr) {
    $script:settings.ventoProfiles = @($arr)
    $sync.Settings.ventoProfiles = @($arr)
    $script:saveTimer.Stop(); $script:saveTimer.Start()
}
function Apply-VentoProfile([string]$name) {
    $p = Get-VentoProfile $name
    if (-not $p) { return }
    if (@('quiet','normal','performance','curve','auto') -contains [string]$p.Fan) { Set-UserMode ([string]$p.Fan) }
    if (@('on','off','auto') -contains [string]$p.Overlay) {
        $script:settings.osdMode = [string]$p.Overlay
        $sync.Settings.osdMode = [string]$p.Overlay
        if ([string]$p.Overlay -ne 'off') { $script:osdModePrev = [string]$p.Overlay }
        # Keep the settings panel's staged overlay pick in step, or a later
        # panel Save (which writes osdModePick back to osdMode) would silently
        # undo the profile's overlay choice.
        $script:osdModePick = [string]$p.Overlay
        if ($el.SettingsOverlay -and $el.SettingsOverlay.Visibility -eq 'Visible') { Update-OsdPickers }
    }
    # The display profile lands on every screen, whatever the panel's scope is.
    # A DDC failure here must not abort the rest of the apply (the pointer + tray
    # update below) or surface unhandled on the dispatcher from a tray/tile click.
    if ([string]$p.Display) {
        $mp = Get-MonProfile ([string]$p.Display)
        if ($mp) {
            $prevScope = [string]$script:settings.monProfileScope
            $script:settings.monProfileScope = 'all'
            try { Apply-MonProfile $mp -Silent } catch { } finally { $script:settings.monProfileScope = $prevScope }
        }
    }
    $script:settings.ventoProfile = [string]$p.Name
    $sync.Settings.ventoProfile = [string]$p.Name
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    Update-TrayProfiles
    if ($el.SettingsOverlay -and $el.SettingsOverlay.Visibility -eq 'Visible') { Build-VentoScenes }
    try { Update-GlassProfiles } catch { }
}
# The cycle hotkey: step to the next profile in the list.
function Cycle-VentoProfile {
    $ps = @(Get-VentoProfiles)
    if (-not $ps.Count) { return }
    $cur = [string]$script:settings.ventoProfile
    $idx = -1
    for ($i = 0; $i -lt $ps.Count; $i++) { if ($ps[$i].Name -eq $cur) { $idx = $i; break } }
    Apply-VentoProfile ([string]$ps[($idx + 1) % $ps.Count].Name)
}
# Rebuild the tray "Profiles" submenu (checkmark on the active one).
function Update-TrayProfiles {
    if (-not $script:trayProfileMenu) { return }
    $script:trayProfileMenu.DropDownItems.Clear()
    $active = [string]$script:settings.ventoProfile
    foreach ($vp in (Get-VentoProfiles)) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem ([string]$vp.Name)
        $mi.Tag = [string]$vp.Name
        $mi.Checked = ($vp.Name -eq $active)
        $mi.add_Click({ param($s0, $e0) Apply-VentoProfile ([string]$s0.Tag) })
        [void]$script:trayProfileMenu.DropDownItems.Add($mi)
    }
}

# --- Vento profile management UI (Settings > PROFILES) ---------------
$script:vpEditName = ''
$script:vpColor    = '#6FB1FF'
$script:vpFan      = 'normal'
$script:vpOverlay  = 'auto'
$script:vpDisplay  = ''

# Tiles echo the display scenes: identity colour, click to apply, right-click
# to edit, an ACTIVE pill on the current one, plus a + NEW tile.
function Build-VentoScenes {
    if (-not $el.VentoSceneHost) { return }
    $host0 = $el.VentoSceneHost
    $host0.Children.Clear()
    $active = [string]$script:settings.ventoProfile
    $tileW = 128.0; $tileH = 94.0
    $fanShort = @{ quiet = 'QUIET'; normal = 'NORMAL'; performance = 'PERF'; curve = 'CURVE'; auto = 'AUTO' }
    $ovShort  = @{ on = 'HUD ON'; off = 'HUD OFF'; auto = 'HUD AUTO' }
    foreach ($p in (Get-VentoProfiles)) {
        $col = ConvertTo-MonColor $p.Color
        $on = ($p.Name -eq $active)
        $tile = New-Object System.Windows.Controls.Border
        $tile.CornerRadius = New-Object System.Windows.CornerRadius 10
        $tile.Width = $tileW; $tile.Height = $tileH
        $tile.Margin = New-Object System.Windows.Thickness 0, 0, 8, 8
        $tile.Padding = New-Object System.Windows.Thickness 11, 9, 11, 9
        $tile.BorderThickness = New-Object System.Windows.Thickness 1
        $tile.Cursor = [System.Windows.Input.Cursors]::Hand
        if ($on) {
            $tile.Background = New-MonBrush $col 0x1F
            $tile.BorderBrush = New-MonBrush $col 0xCC
            $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
            $fx.ShadowDepth = 0; $fx.BlurRadius = 20; $fx.Opacity = 0.55; $fx.Color = $col
            $tile.Effect = $fx
        } else {
            $tile.Background = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x0C, 0x12, 0x1C))
            $tile.BorderBrush = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x1E, 0x27, 0x36))
        }
        $tile.Tag = $p.Name
        $tile.Add_MouseLeftButtonDown({ param($s0, $e0) Apply-VentoProfile ([string]$s0.Tag) })
        $tile.Add_MouseRightButtonUp({ param($s0, $e0) Open-VentoSheet ([string]$s0.Tag) })
        $tile.ToolTip = 'Click to apply, right-click to edit or delete'
        $sp = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $chip = New-Object System.Windows.Controls.Border
        $chip.Width = 22; $chip.Height = 22
        $chip.CornerRadius = New-Object System.Windows.CornerRadius 7
        $chip.Background = New-MonBrush $col 0x2E
        $gl = New-Object System.Windows.Controls.TextBlock
        $gl.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
        $gl.FontSize = 11
        $gl.Text = [char]0xE945
        $gl.Foreground = New-MonBrush $col
        $gl.HorizontalAlignment = 'Center'; $gl.VerticalAlignment = 'Center'
        $chip.Child = $gl
        [void]$head.Children.Add($chip)
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $p.Name.ToUpperInvariant()
        $nm.FontSize = 12; $nm.FontWeight = 'Bold'
        $nm.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
        $nm.VerticalAlignment = 'Center'
        $nm.TextTrimming = 'CharacterEllipsis'
        $nm.Foreground = if ($on) { New-MonBrush ([System.Windows.Media.Color]::FromRgb(0xED, 0xF1, 0xF8)) } else { New-MonBrush ([System.Windows.Media.Color]::FromRgb(0xC9, 0xD2, 0xE2)) }
        [void]$head.Children.Add($nm)
        [void]$sp.Children.Add($head)
        # Fan + HUD on one line, the display profile on its own second line: a
        # long display name (CINEMA, or anything user-made) gets the full tile
        # width instead of an ellipsis.
        $rc = New-Object System.Windows.Controls.TextBlock
        $fs = if ($fanShort.ContainsKey([string]$p.Fan)) { $fanShort[[string]$p.Fan] } else { ([string]$p.Fan).ToUpperInvariant() }
        $os = if ($ovShort.ContainsKey([string]$p.Overlay)) { $ovShort[[string]$p.Overlay] } else { '' }
        $rc.Text = (('{0}  {1}' -f $fs, $os)).Trim()
        $rc.FontSize = 9; $rc.FontWeight = 'SemiBold'
        $rc.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0
        $rc.TextTrimming = 'CharacterEllipsis'
        $rc.Foreground = New-MonBrush $col 0xCC
        [void]$sp.Children.Add($rc)
        $disp = ([string]$p.Display).ToUpperInvariant()
        if ($disp) {
            $rc2 = New-Object System.Windows.Controls.TextBlock
            $rc2.Text = $disp
            $rc2.FontSize = 9; $rc2.FontWeight = 'SemiBold'
            $rc2.Margin = New-Object System.Windows.Thickness 0, 1, 0, 0
            $rc2.TextTrimming = 'CharacterEllipsis'
            $rc2.ToolTip = $disp
            $rc2.Foreground = New-MonBrush $col 0x99
            [void]$sp.Children.Add($rc2)
        }
        if ($on) {
            $pill = New-Object System.Windows.Controls.Border
            $pill.Background = New-MonBrush $col 0x33
            $pill.CornerRadius = New-Object System.Windows.CornerRadius 6
            $pill.Padding = New-Object System.Windows.Thickness 7, 2, 7, 2
            $pill.HorizontalAlignment = 'Left'
            $pill.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
            $pt = New-Object System.Windows.Controls.TextBlock
            $pt.Text = 'ACTIVE'; $pt.FontSize = 8; $pt.FontWeight = 'Bold'
            $pt.Foreground = New-MonBrush $col
            $pill.Child = $pt
            [void]$sp.Children.Add($pill)
        }
        $tile.Child = $sp
        [void]$host0.Children.Add($tile)
    }
    $nt = New-Object System.Windows.Controls.Border
    $nt.CornerRadius = New-Object System.Windows.CornerRadius 10
    $nt.Width = $tileW; $nt.Height = $tileH
    $nt.Margin = New-Object System.Windows.Thickness 0, 0, 8, 8
    $nt.BorderThickness = New-Object System.Windows.Thickness 1
    $nt.BorderBrush = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x2B, 0x34, 0x47))
    $nt.Background = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x0A, 0x0F, 0x17))
    $nt.Cursor = [System.Windows.Input.Cursors]::Hand
    $nt.Add_MouseLeftButtonDown({ Open-VentoSheet })
    $ns = New-Object System.Windows.Controls.StackPanel
    $ns.HorizontalAlignment = 'Center'; $ns.VerticalAlignment = 'Center'
    $nl = New-Object System.Windows.Controls.TextBlock
    $nl.Text = '+ NEW'; $nl.FontSize = 12; $nl.FontWeight = 'Bold'
    $nl.HorizontalAlignment = 'Center'
    $nl.Foreground = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x8F, 0xA3, 0xBC))
    [void]$ns.Children.Add($nl)
    $nt.Child = $ns
    [void]$host0.Children.Add($nt)
}

# A small selectable chip for the editor's fan / overlay / display / colour rows.
function New-VpChip([string]$text, [string]$tag, [bool]$sel, $col) {
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = New-Object System.Windows.CornerRadius 8
    $b.Padding = New-Object System.Windows.Thickness 11, 6, 11, 6
    $b.Margin = New-Object System.Windows.Thickness 0, 0, 7, 7
    $b.BorderThickness = New-Object System.Windows.Thickness 1
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $b.Tag = $tag
    if ($sel) {
        $b.Background = New-MonBrush $col 0x28
        $b.BorderBrush = New-MonBrush $col 0xCC
    } else {
        $b.Background = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x0C, 0x12, 0x1C))
        $b.BorderBrush = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x25, 0x2F, 0x40))
    }
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = 11; $t.FontWeight = 'Bold'
    $t.Foreground = if ($sel) { New-MonBrush ([System.Windows.Media.Colors]::White) } else { New-MonBrush ([System.Windows.Media.Color]::FromRgb(0xC9, 0xD2, 0xE2)) }
    $b.Child = $t
    return $b
}

# Fills the editor's swatch + fan + overlay + display pickers from the vp* state.
function Build-VentoChips {
    if (-not $el.VP_Swatches) { return }
    $col = ConvertTo-MonColor $script:vpColor
    $sw = $el.VP_Swatches; $sw.Children.Clear()
    $picks = @('#7FE0A0', '#FF7A8A', '#FFC46F', '#8F86FF', '#6FB1FF', '#FF9E6F', '#6FE0FF', '#FF6FD8', '#B6FF6F')
    if ($picks -notcontains $script:vpColor) { $picks += $script:vpColor }
    foreach ($hex in $picks) {
        $b = New-Object System.Windows.Controls.Border
        $b.Width = 28; $b.Height = 28
        $b.CornerRadius = New-Object System.Windows.CornerRadius 14
        $b.Margin = New-Object System.Windows.Thickness 0, 0, 7, 7
        $b.Background = New-MonBrush (ConvertTo-MonColor $hex)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.Tag = $hex
        if ($hex -eq $script:vpColor) {
            $b.BorderThickness = New-Object System.Windows.Thickness 2.5
            $b.BorderBrush = New-MonBrush ([System.Windows.Media.Colors]::White)
        }
        $b.Add_MouseLeftButtonDown({ param($s0, $e0) $script:vpColor = [string]$s0.Tag; Build-VentoChips })
        [void]$sw.Children.Add($b)
    }
    $c = New-Object System.Windows.Controls.Border
    $c.Width = 28; $c.Height = 28
    $c.CornerRadius = New-Object System.Windows.CornerRadius 14
    $c.Margin = New-Object System.Windows.Thickness 0, 0, 7, 7
    $c.Cursor = [System.Windows.Input.Cursors]::Hand
    $rb = New-Object System.Windows.Media.LinearGradientBrush
    $rb.StartPoint = New-Object System.Windows.Point 0, 0
    $rb.EndPoint = New-Object System.Windows.Point 1, 1
    foreach ($stop in @(@('#FF6F6F', 0.0), @('#FFC46F', 0.25), @('#7FE0A0', 0.5), @('#6FB1FF', 0.75), @('#C86FFF', 1.0))) {
        $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop (ConvertTo-MonColor ([string]$stop[0])), ([double]$stop[1])))
    }
    $rb.Freeze()
    $c.Background = $rb
    $c.Add_MouseLeftButtonDown({ $picked = Show-ColorPicker $script:vpColor; if ($picked) { $script:vpColor = $picked }; Build-VentoChips })
    [void]$sw.Children.Add($c)
    $fh = $el.VP_FanHost; $fh.Children.Clear()
    foreach ($f in @(@('quiet', 'Quiet'), @('normal', 'Normal'), @('performance', 'Performance'), @('curve', 'Curve'), @('auto', 'Auto'))) {
        $chip = New-VpChip $f[1] $f[0] ($script:vpFan -eq $f[0]) $col
        $chip.Add_MouseLeftButtonDown({ param($s0, $e0) $script:vpFan = [string]$s0.Tag; Build-VentoChips })
        [void]$fh.Children.Add($chip)
    }
    $oh = $el.VP_OvHost; $oh.Children.Clear()
    foreach ($o in @(@('on', 'On'), @('off', 'Off'), @('auto', 'While gaming'))) {
        $chip = New-VpChip $o[1] $o[0] ($script:vpOverlay -eq $o[0]) $col
        $chip.Add_MouseLeftButtonDown({ param($s0, $e0) $script:vpOverlay = [string]$s0.Tag; Build-VentoChips })
        [void]$oh.Children.Add($chip)
    }
    $dh = $el.VP_DispHost; $dh.Children.Clear()
    $none = New-VpChip 'None' '' ($script:vpDisplay -eq '') $col
    $none.Add_MouseLeftButtonDown({ param($s0, $e0) $script:vpDisplay = ''; Build-VentoChips })
    [void]$dh.Children.Add($none)
    foreach ($mp in (Get-MonProfiles)) {
        $mc = ConvertTo-MonColor $mp.Color
        $chip = New-VpChip $mp.Name.ToUpperInvariant() $mp.Name ($script:vpDisplay -eq $mp.Name) $mc
        $chip.Add_MouseLeftButtonDown({ param($s0, $e0) $script:vpDisplay = [string]$s0.Tag; Build-VentoChips })
        [void]$dh.Children.Add($chip)
    }
}

function Open-VentoSheet([string]$name = '') {
    $script:vpEditName = $name
    $p = if ($name) { Get-VentoProfile $name } else { $null }
    if ($p) {
        $script:vpColor = [string]$p.Color
        $script:vpFan = [string]$p.Fan
        $script:vpOverlay = [string]$p.Overlay
        $script:vpDisplay = [string]$p.Display
        $el.VP_Name.Text = $p.Name
        $el.VentoEditTitle.Text = $(if ($p.Builtin) { 'EDIT PROFILE (built-in)' } else { 'EDIT PROFILE' })
        $el.BtnVpDelete.Visibility = $(if ($p.Builtin) { 'Collapsed' } else { 'Visible' })
        # A built-in's name is its identity - the re-seed keys on it - so it
        # cannot be renamed, only re-tuned. Its fields stay fully editable.
        $el.VP_Name.IsReadOnly = [bool]$p.Builtin
    } else {
        $script:vpColor = '#6FB1FF'
        $script:vpFan = 'normal'
        $script:vpOverlay = 'auto'
        $script:vpDisplay = ''
        $el.VP_Name.Text = 'My profile'
        $el.VentoEditTitle.Text = 'NEW PROFILE'
        $el.BtnVpDelete.Visibility = 'Collapsed'
        $el.VP_Name.IsReadOnly = $false
    }
    Build-VentoChips
    $el.VentoEditLayer.Visibility = 'Visible'
    [void]$el.VP_Name.Focus()
    $el.VP_Name.SelectAll()
}
$el.BtnVpCancel.Add_Click({ $el.VentoEditLayer.Visibility = 'Collapsed' })
$el.BtnVpSave.Add_Click({
    $name = ([string]$el.VP_Name.Text).Trim()
    if (-not $name) { return }
    $old = [string]$script:vpEditName
    # A name already owned by a DIFFERENT profile would silently delete that
    # profile (the save filter drops it) and, on a built-in, strip its flag.
    # Reject the collision instead of destroying data.
    if ($name -ne $old -and (Get-VentoProfile $name)) {
        [void][System.Windows.MessageBox]::Show(
            ("A profile named '{0}' already exists. Pick a different name." -f $name),
            'Vento', 'OK', 'Warning')
        return
    }
    $prev = Get-VentoProfile $old
    $p = @{
        Name    = $name
        Color   = [string]$script:vpColor
        Fan     = [string]$script:vpFan
        Overlay = [string]$script:vpOverlay
        Display = [string]$script:vpDisplay
        Builtin = $(if ($prev) { [bool]$prev.Builtin } else { $false })
    }
    $arr = @(Get-VentoProfiles | Where-Object { $_.Name -ne $name -and $_.Name -ne $old })
    $arr += ,$p
    Save-VentoProfiles $arr
    if ($old -and $old -ne $name -and [string]$script:settings.ventoProfile -eq $old) {
        $script:settings.ventoProfile = $name
        $sync.Settings.ventoProfile = $name
    }
    $script:vpEditName = ''
    $el.VentoEditLayer.Visibility = 'Collapsed'
    Build-VentoScenes
    Update-TrayProfiles
})
$el.BtnVpDelete.Add_Click({
    $name = [string]$script:vpEditName
    if (-not $name) { return }
    $p = Get-VentoProfile $name
    if (-not $p -or $p.Builtin) { return }
    Save-VentoProfiles @(Get-VentoProfiles | Where-Object { $_.Name -ne $name })
    if ([string]$script:settings.ventoProfile -eq $name) {
        $script:settings.ventoProfile = ''
        $sync.Settings.ventoProfile = ''
    }
    $script:vpEditName = ''
    $el.VentoEditLayer.Visibility = 'Collapsed'
    Build-VentoScenes
    Update-TrayProfiles
})

# --- Panel painting --------------------------------------------------
function Get-MonAccent {
    $p = Get-MonProfile (Get-MonActiveProfileName $script:monSel)
    if ($p) { return (ConvertTo-MonColor $p.Color) }
    return (ConvertTo-MonColor '#6FB1FF')
}

# Desk map: the real desktop layout, scaled to the stage. Brightness lives
# on the screens themselves - the value large in the middle, its blade
# docked along the bottom edge.
function Build-MonMap {
    $cv = $el.MonMapCanvas
    $cv.Children.Clear()
    $script:monMapItems = @()
    $W = $cv.ActualWidth; $H = $cv.ActualHeight
    if ($W -lt 40 -or $H -lt 40) { return }
    $mons = @($sync.Ddc.Monitors)
    if ($mons.Count -eq 0) { return }
    $acc = Get-MonAccent
    $accBrush = New-MonBrush $acc
    # Bounding box of every display that reported a rectangle.
    $minX = $null; $minY = $null; $maxX = $null; $maxY = $null
    foreach ($m in $mons) {
        if ($null -eq $m.MapW -or [int]$m.MapW -le 0) { continue }
        $l = [int]$m.MapX; $t = [int]$m.MapY; $r = $l + [int]$m.MapW; $b = $t + [int]$m.MapH
        if ($null -eq $minX -or $l -lt $minX) { $minX = $l }
        if ($null -eq $minY -or $t -lt $minY) { $minY = $t }
        if ($null -eq $maxX -or $r -gt $maxX) { $maxX = $r }
        if ($null -eq $maxY -or $b -gt $maxY) { $maxY = $b }
    }
    if ($null -eq $minX) { return }
    $padX = 26.0; $padTop = 34.0; $padBot = 30.0
    $spanX = [double]($maxX - $minX); $spanY = [double]($maxY - $minY)
    if ($spanX -le 0 -or $spanY -le 0) { return }
    $scale = [math]::Min(($W - 2 * $padX) / $spanX, ($H - $padTop - $padBot) / $spanY)
    $offX = ($W - $spanX * $scale) / 2.0
    $offY = ($H - $padBot - $spanY * $scale) / 2.0 + 4
    $el.MonMapTag.Text = 'DESK {0} {1} x {2}' -f $script:mid, $spanX, $spanY

    for ($i = 0; $i -lt $mons.Count; $i++) {
        $m = $mons[$i]
        if ($null -eq $m.MapW -or [int]$m.MapW -le 0) { continue }
        $x = $offX + ([int]$m.MapX - $minX) * $scale
        $y = $offY + ([int]$m.MapY - $minY) * $scale
        $w = [int]$m.MapW * $scale
        $h = [int]$m.MapH * $scale
        if ($w -lt 60 -or $h -lt 40) { continue }
        $sel = ($i -eq $script:monSel)
        $bri = [double]0.5
        if ($m.Ok -and [int]$m.BriMax -gt 0) { $bri = [double][int]$m.BriCur / [double][int]$m.BriMax }

        # Screen face: a steel-blue gradient whose lift tracks brightness.
        $face = New-Object System.Windows.Controls.Border
        $face.Width = $w; $face.Height = $h
        $face.CornerRadius = New-Object System.Windows.CornerRadius ([math]::Min(9, $h / 2 - 1))
        $g = New-Object System.Windows.Media.LinearGradientBrush
        $g.StartPoint = New-Object System.Windows.Point 0, 0
        $g.EndPoint   = New-Object System.Windows.Point 0.4, 1
        $lift = 0.12 + 0.78 * $bri
        $c1 = [System.Windows.Media.Color]::FromRgb([byte](26 + 150 * $lift), [byte](36 + 150 * $lift), [byte](52 + 140 * $lift))
        $c2 = [System.Windows.Media.Color]::FromRgb([byte](18 + 110 * $lift), [byte](26 + 115 * $lift), [byte](40 + 120 * $lift))
        $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop $c1, 0))
        $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop $c2, 1))
        $g.Freeze()
        $face.Background = $g
        $face.BorderThickness = New-Object System.Windows.Thickness 2
        if ($sel) {
            $face.BorderBrush = $accBrush
            $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
            $fx.ShadowDepth = 0; $fx.BlurRadius = 26; $fx.Opacity = 0.75; $fx.Color = $acc
            $face.Effect = $fx
        } else {
            $face.BorderBrush = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x2A, 0x35, 0x49))
        }
        $face.Cursor = [System.Windows.Input.Cursors]::Hand
        $face.Tag = $i
        $face.Add_MouseLeftButtonDown({ param($s0, $e0)
            $script:monSel = [int]$s0.Tag
            Update-MonitorPanel
        })
        [System.Windows.Controls.Canvas]::SetLeft($face, $x)
        [System.Windows.Controls.Canvas]::SetTop($face, $y)
        [void]$cv.Children.Add($face)

        $inner = New-Object System.Windows.Controls.Grid
        $face.Child = $inner

        # index badge
        $badge = New-Object System.Windows.Controls.Border
        $badge.Background = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x0A, 0x0F, 0x18)) 0xB0
        $badge.CornerRadius = New-Object System.Windows.CornerRadius 6
        $badge.Padding = New-Object System.Windows.Thickness 7, 2, 7, 2
        $badge.HorizontalAlignment = 'Left'; $badge.VerticalAlignment = 'Top'
        $badge.Margin = New-Object System.Windows.Thickness 8, 8, 0, 0
        $bt = New-Object System.Windows.Controls.TextBlock
        $bt.Text = if ($m.Primary) { '{0} {1} PRIMARY' -f ($i + 1), $script:mid } else { '{0}' -f ($i + 1) }
        $bt.FontSize = 8.5; $bt.FontWeight = 'SemiBold'
        $bt.Foreground = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0xC9, 0xD2, 0xE2))
        $badge.Child = $bt
        [void]$inner.Children.Add($badge)

        if ($m.Ok) {
            # brightness value + unit
            $vs = New-Object System.Windows.Controls.StackPanel
            $vs.Orientation = 'Horizontal'
            $vs.HorizontalAlignment = 'Center'; $vs.VerticalAlignment = 'Center'
            $vs.Margin = New-Object System.Windows.Thickness 0, 0, 0, 14
            $vt = New-Object System.Windows.Controls.TextBlock
            $vt.Text = '{0}' -f [int]$m.BriCur
            $vt.FontSize = [math]::Max(20, [math]::Min(34, $h * 0.34))
            $vt.FontWeight = 'Bold'
            $vt.Foreground = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0xF2, 0xF6, 0xFC))
            if ($sel) {
                $tx = New-Object System.Windows.Media.Effects.DropShadowEffect
                $tx.ShadowDepth = 0; $tx.BlurRadius = 14; $tx.Opacity = 0.8; $tx.Color = [System.Windows.Media.Colors]::White
                $vt.Effect = $tx
            }
            $ut = New-Object System.Windows.Controls.TextBlock
            $ut.Text = '%'; $ut.FontSize = 10; $ut.FontWeight = 'SemiBold'
            $ut.VerticalAlignment = 'Bottom'
            $ut.Margin = New-Object System.Windows.Thickness 3, 0, 0, 5
            $ut.Foreground = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0xB6, 0xC4, 0xD8))
            [void]$vs.Children.Add($vt); [void]$vs.Children.Add($ut)
            [void]$inner.Children.Add($vs)

            # docked brightness blade
            $sl = New-Object System.Windows.Controls.Slider
            $sl.Style = $window.FindResource('SetSlider')
            $sl.Minimum = 0; $sl.Maximum = [double][math]::Max(1, [int]$m.BriMax)
            $sl.Value = [double][int]$m.BriCur
            $sl.Width = [math]::Max(40, $w - 26)
            $sl.HorizontalAlignment = 'Center'; $sl.VerticalAlignment = 'Bottom'
            $sl.Margin = New-Object System.Windows.Thickness 0, 0, 0, 9
            $sl.Foreground = New-MonBarBrush (ConvertTo-MonColor '#6FB1FF')
            $sl.Tag = @($i, $vt)
            $sl.Add_ValueChanged({ param($s0, $e0)
                $t = $s0.Tag
                $t[1].Text = '{0}' -f [int]$s0.Value
                if (-not $script:monLoading) {
                    $tgt = if ([bool]$script:settings.monSync) { -1 } else { [int]$t[0] }
                    Queue-DdcSet 'SetBri' $tgt ([int]$s0.Value) 0
                    # In sync the other screens' blades follow the drag on the
                    # spot; the hardware catches up ~60 ms behind.
                    if ($tgt -lt 0) {
                        $script:monLoading = $true
                        try {
                            foreach ($it in $script:monMapItems) {
                                if ([int]$it.Idx -ne [int]$t[0]) { $it.Slider.Value = $s0.Value; $it.Value.Text = $t[1].Text }
                            }
                        } finally { $script:monLoading = $false }
                    }
                }
            })
            [void]$inner.Children.Add($sl)
            $script:monMapItems += ,@{ Idx = $i; Slider = $sl; Value = $vt }
        } else {
            $na = New-Object System.Windows.Controls.TextBlock
            $na.Text = 'NO DDC/CI'
            $na.FontSize = 9; $na.FontWeight = 'SemiBold'
            $na.HorizontalAlignment = 'Center'; $na.VerticalAlignment = 'Center'
            $na.Foreground = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x6B, 0x79, 0x8C))
            [void]$inner.Children.Add($na)
        }

        # stand + name plate under the screen
        $stand = New-Object System.Windows.Shapes.Rectangle
        $stand.Width = [math]::Max(24, $w * 0.22); $stand.Height = 4
        $stand.RadiusX = 2; $stand.RadiusY = 2
        $stand.Fill = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x22, 0x2B, 0x3B))
        [System.Windows.Controls.Canvas]::SetLeft($stand, $x + ($w - $stand.Width) / 2)
        [System.Windows.Controls.Canvas]::SetTop($stand, $y + $h + 3)
        [void]$cv.Children.Add($stand)

        $nm = New-Object System.Windows.Controls.TextBlock
        $desc = ([string]$m.Desc).Trim()
        $nm.Text = if ($desc) { $desc.ToUpperInvariant() } else { 'DISPLAY {0}' -f ($i + 1) }
        $nm.FontSize = 9; $nm.FontWeight = 'SemiBold'
        $nm.Foreground = if ($sel) { $accBrush } else { New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x5A, 0x6B, 0x84)) }
        $nm.Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
        [System.Windows.Controls.Canvas]::SetLeft($nm, $x + ($w - $nm.DesiredSize.Width) / 2)
        [System.Windows.Controls.Canvas]::SetTop($nm, $y + $h + 11)
        [void]$cv.Children.Add($nm)
    }
}

# Profile row: built-ins plus whatever the user has saved, then + NEW.
function Build-MonScenes {
    $host0 = $el.MonSceneHost
    $host0.Children.Clear()
    $profiles = Get-MonProfiles
    $active = Get-MonActiveProfileName $script:monSel
    # Fixed-size tiles in a wrap panel: adding profiles grows a second row
    # instead of squeezing every name into an ellipsis.
    $tileW = 118.0; $tileH = 84.0
    foreach ($p in $profiles) {
        $col = ConvertTo-MonColor $p.Color
        $on = ($p.Name -eq $active)
        $tile = New-Object System.Windows.Controls.Border
        $tile.CornerRadius = New-Object System.Windows.CornerRadius 10
        $tile.Width = $tileW; $tile.Height = $tileH
        $tile.Margin = New-Object System.Windows.Thickness 0, 0, 8, 8
        $tile.Padding = New-Object System.Windows.Thickness 11, 9, 11, 9
        $tile.BorderThickness = New-Object System.Windows.Thickness 1
        $tile.Cursor = [System.Windows.Input.Cursors]::Hand
        if ($on) {
            $tile.Background = New-MonBrush $col 0x1F
            $tile.BorderBrush = New-MonBrush $col 0xCC
            $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
            $fx.ShadowDepth = 0; $fx.BlurRadius = 20; $fx.Opacity = 0.55; $fx.Color = $col
            $tile.Effect = $fx
        } else {
            $tile.Background = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x0C, 0x12, 0x1C))
            $tile.BorderBrush = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x1E, 0x27, 0x36))
        }
        $tile.Tag = $p.Name
        $tile.Add_MouseLeftButtonDown({ param($s0, $e0)
            $pr = Get-MonProfile ([string]$s0.Tag)
            if ($pr) { Apply-MonProfile $pr }
        })
        $tile.Add_MouseRightButtonUp({ param($s0, $e0)
            Open-MonProfileSheet ([string]$s0.Tag)
        })
        $tile.ToolTip = 'Click to apply, right-click to rename, recolour or delete'
        $sp = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $chip = New-Object System.Windows.Controls.Border
        $chip.Width = 22; $chip.Height = 22
        $chip.CornerRadius = New-Object System.Windows.CornerRadius 7
        $chip.Background = New-MonBrush $col 0x2E
        $gl = New-Object System.Windows.Controls.TextBlock
        $gl.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
        $gl.FontSize = 11
        $gl.Text = switch ($p.Name) { 'DAY' { [char]0xE706 } 'NIGHT' { [char]0xE708 } 'CINEMA' { [char]0xE714 } 'GAME' { [char]0xE7FC } default { [char]0xE790 } }
        $gl.Foreground = New-MonBrush $col
        $gl.HorizontalAlignment = 'Center'; $gl.VerticalAlignment = 'Center'
        $chip.Child = $gl
        [void]$head.Children.Add($chip)
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $p.Name.ToUpperInvariant()
        $nm.FontSize = 12; $nm.FontWeight = 'Bold'
        $nm.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
        $nm.VerticalAlignment = 'Center'
        $nm.TextTrimming = 'CharacterEllipsis'
        $nm.Foreground = if ($on) { New-MonBrush ([System.Windows.Media.Color]::FromRgb(0xED, 0xF1, 0xF8)) } else { New-MonBrush ([System.Windows.Media.Color]::FromRgb(0xC9, 0xD2, 0xE2)) }
        [void]$head.Children.Add($nm)
        [void]$sp.Children.Add($head)
        $rc = New-Object System.Windows.Controls.TextBlock
        $pn = if ($script:presetNames.ContainsKey([int]$p.Preset)) { $script:presetNames[[int]$p.Preset] } else { '' }
        $rc.Text = ('{0} {1} {2}' -f $p.Bri, $script:mid, $p.Con) + $(if ($pn) { ' {0} {1}' -f $script:mid, $pn } else { '' })
        $rc.FontSize = 9.5; $rc.FontWeight = 'SemiBold'
        $rc.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
        $rc.Foreground = New-MonBrush $col 0xCC
        [void]$sp.Children.Add($rc)
        if ($on) {
            $pill = New-Object System.Windows.Controls.Border
            $pill.Background = New-MonBrush $col 0x33
            $pill.CornerRadius = New-Object System.Windows.CornerRadius 6
            $pill.Padding = New-Object System.Windows.Thickness 7, 2, 7, 2
            $pill.HorizontalAlignment = 'Left'
            $pill.Margin = New-Object System.Windows.Thickness 0, 7, 0, 0
            $pt = New-Object System.Windows.Controls.TextBlock
            $pt.Text = 'ACTIVE'; $pt.FontSize = 8; $pt.FontWeight = 'Bold'
            $pt.Foreground = New-MonBrush $col
            $pill.Child = $pt
            [void]$sp.Children.Add($pill)
        }
        $tile.Child = $sp
        [void]$host0.Children.Add($tile)
    }
    # + NEW
    $nt = New-Object System.Windows.Controls.Border
    $nt.CornerRadius = New-Object System.Windows.CornerRadius 10
    $nt.Width = $tileW; $nt.Height = $tileH
    $nt.Margin = New-Object System.Windows.Thickness 0, 0, 8, 8
    $nt.BorderThickness = New-Object System.Windows.Thickness 1
    $nt.BorderBrush = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x2B, 0x34, 0x47))
    $nt.Background = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x0A, 0x0F, 0x17))
    $nt.Cursor = [System.Windows.Input.Cursors]::Hand
    $nt.Add_MouseLeftButtonDown({ Open-MonProfileSheet })
    $ns = New-Object System.Windows.Controls.StackPanel
    $ns.HorizontalAlignment = 'Center'; $ns.VerticalAlignment = 'Center'
    $nl = New-Object System.Windows.Controls.TextBlock
    $nl.Text = '+ NEW'; $nl.FontSize = 12; $nl.FontWeight = 'Bold'
    $nl.HorizontalAlignment = 'Center'
    $nl.Foreground = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x8F, 0xA3, 0xBC))
    [void]$ns.Children.Add($nl)
    $dots = New-Object System.Windows.Controls.StackPanel
    $dots.Orientation = 'Horizontal'; $dots.HorizontalAlignment = 'Center'
    $dots.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
    foreach ($hex in @('#FFC46F', '#8F86FF', '#FF7A8A', '#7FE0A0')) {
        $d = New-Object System.Windows.Shapes.Ellipse
        $d.Width = 6; $d.Height = 6
        $d.Margin = New-Object System.Windows.Thickness 2, 0, 2, 0
        $d.Fill = New-MonBrush (ConvertTo-MonColor $hex)
        [void]$dots.Children.Add($d)
    }
    [void]$ns.Children.Add($dots)
    $nt.Child = $ns
    [void]$host0.Children.Add($nt)
}

# 24-hour band: the night window in the schedule profile's colour, the day
# stretch dim, and a light blade at the current time.
function Build-MonTimeline {
    $cv = $el.MonTimeCanvas
    $cv.Children.Clear()
    $W = $cv.ActualWidth
    if ($W -lt 60) { return }
    $barH = 22.0
    $from = [int]$script:settings.monNightFrom
    $to   = [int]$script:settings.monNightTo
    $np = Get-MonProfile ([string]$script:settings.monNightProfile)
    $nc = if ($np) { ConvertTo-MonColor $np.Color } else { ConvertTo-MonColor '#8F86FF' }
    $dp = Get-MonProfile 'DAY'
    $dc = if ($dp) { ConvertTo-MonColor $dp.Color } else { ConvertTo-MonColor '#FFC46F' }
    $on = [bool]$script:settings.monNight

    $groove = New-Object System.Windows.Shapes.Rectangle
    $groove.Width = $W; $groove.Height = $barH
    $groove.RadiusX = 6; $groove.RadiusY = 6
    $groove.Fill = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x08, 0x0C, 0x14))
    [System.Windows.Controls.Canvas]::SetLeft($groove, 0)
    [System.Windows.Controls.Canvas]::SetTop($groove, 0)
    [void]$cv.Children.Add($groove)

    # Day stretch first, night blocks over it (night may wrap midnight).
    $spans = @()
    if ($from -eq $to) { $spans += ,@(0, 1440, $dc, $false) }
    elseif ($from -lt $to) {
        $spans += ,@(0, $from, $dc, $false); $spans += ,@($from, $to, $nc, $true); $spans += ,@($to, 1440, $dc, $false)
    } else {
        $spans += ,@(0, $to, $nc, $true); $spans += ,@($to, $from, $dc, $false); $spans += ,@($from, 1440, $nc, $true)
    }
    foreach ($s in $spans) {
        $a = [double]$s[0]; $b = [double]$s[1]
        if ($b - $a -lt 1) { continue }
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = [math]::Max(2, ($b - $a) / 1440.0 * $W)
        $r.Height = $barH - 4
        $r.RadiusX = 4; $r.RadiusY = 4
        $isNight = [bool]$s[3]
        $alpha = if ($isNight) { if ($on) { 0xCC } else { 0x55 } } else { 0x2A }
        $r.Fill = New-MonBrush $s[2] $alpha
        [System.Windows.Controls.Canvas]::SetLeft($r, $a / 1440.0 * $W)
        [System.Windows.Controls.Canvas]::SetTop($r, 2)
        [void]$cv.Children.Add($r)
    }
    # hour ticks
    foreach ($hr in @(0, 6, 12, 18, 24)) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = '{0:00}' -f $hr
        $t.FontSize = 8.5; $t.FontWeight = 'SemiBold'
        $t.Foreground = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x4A, 0x59, 0x70))
        $t.Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
        $x = $hr / 24.0 * $W
        if ($hr -eq 24) { $x -= $t.DesiredSize.Width }
        elseif ($hr -gt 0) { $x -= $t.DesiredSize.Width / 2 }
        [System.Windows.Controls.Canvas]::SetLeft($t, $x)
        [System.Windows.Controls.Canvas]::SetTop($t, $barH + 5)
        [void]$cv.Children.Add($t)
    }
    # now blade
    $now = [datetime]::Now
    $nx = ($now.Hour * 60 + $now.Minute) / 1440.0 * $W
    $bl = New-Object System.Windows.Shapes.Rectangle
    $bl.Width = 3; $bl.Height = $barH + 8
    $bl.RadiusX = 1.5; $bl.RadiusY = 1.5
    $bl.Fill = New-MonBrush ([System.Windows.Media.Colors]::White)
    $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
    $fx.ShadowDepth = 0; $fx.BlurRadius = 8; $fx.Opacity = 0.7; $fx.Color = [System.Windows.Media.Colors]::White
    $bl.Effect = $fx
    [System.Windows.Controls.Canvas]::SetLeft($bl, [math]::Min([math]::Max(0, $nx - 1.5), $W - 3))
    [System.Windows.Controls.Canvas]::SetTop($bl, -4)
    [void]$cv.Children.Add($bl)
}

function Format-MonTime([int]$mins) { '{0:00}:{1:00}' -f ([math]::Floor($mins / 60)), ($mins % 60) }

function Update-MonitorPanel {
    $mons = @($sync.Ddc.Monitors)
    $script:monLoading = $true
    try {
        # Not while an enum is mid-flight: the progressive publish briefly holds
        # fewer monitors than are really there, and resetting here would drop the
        # user's selection to 0 on every rescan. An out-of-range index reads as
        # $null in PS5.1 and the empty branch renders until the display arrives.
        if ($script:monSel -ge $mons.Count -and -not $sync.Ddc.Busy) { $script:monSel = 0 }
        $el.MonStatus.Text = if ($sync.Ddc.Busy) { 'Reading monitors...' }
                             elseif ($mons.Count -eq 0) { 'No DDC/CI-capable display found' }
                             else { '{0} displays {1} DDC/CI live' -f $mons.Count, $script:mid }
        $acc = Get-MonAccent
        $accBrush = New-MonBrush $acc
        $prof = Get-MonProfile (Get-MonActiveProfileName $script:monSel)
        $el.MonSceneDot.Fill = if ($prof) { $accBrush } else { New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x5A, 0x6B, 0x84)) }
        $el.MonSceneText.Text = if ($prof) { '{0} PROFILE' -f $prof.Name.ToUpperInvariant() } else { '' }
        $el.MonSceneText.Foreground = $accBrush

        Build-MonMap
        Build-MonScenes
        Build-MonTimeline

        $el.BtnMonSync.Foreground = if ([bool]$script:settings.monSync) { $accBrush } else { New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x8A, 0x93, 0xA6)) }
        $one = ([string]$script:settings.monProfileScope -eq 'one')
        $dimB = New-MonBrush ([System.Windows.Media.Color]::FromRgb(0x8A, 0x93, 0xA6))
        $el.BtnMonScopeAll.Foreground = if ($one) { $dimB } else { $accBrush }
        $el.BtnMonScopeOne.Foreground = if ($one) { $accBrush } else { $dimB }
        $el.S_MonNight.IsChecked = [bool]$script:settings.monNight
        $el.MonNightText.Text = '{0} {1} {2} {3} {4}' -f (Format-MonTime ([int]$script:settings.monNightFrom)), [char]0x2013,
                                (Format-MonTime ([int]$script:settings.monNightTo)), $script:mid, ('dims every display to {0}' -f [string]$script:settings.monNightProfile)
        $el.MonNightFromVal.Text = Format-MonTime ([int]$script:settings.monNightFrom)
        $el.MonNightToVal.Text   = Format-MonTime ([int]$script:settings.monNightTo)
        $el.MonNightProfVal.Text = 'applies {0}' -f [string]$script:settings.monNightProfile

        if ($mons.Count -eq 0 -or -not $mons[$script:monSel].Ok) {
            $el.MonSelName.Text = ''
            $el.MonSelMeta.Text = if ($mons.Count -eq 0) { '' } else { 'DDC/CI not responding - enable it in the display menu' }
            $el.MonPreHost.Children.Clear(); $el.MonInHost.Children.Clear()
            $el.MonConRow.Visibility = 'Collapsed'
            $el.MonInfoText.Text = ''; $el.MonInfoText2.Text = ''
            return
        }
        $m = $mons[$script:monSel]
        $desc = ([string]$m.Desc).Trim()
        $el.MonSelName.Text = if ($desc) { $desc.ToUpperInvariant() } else { 'DISPLAY {0}' -f ($script:monSel + 1) }
        $el.MonSelName.Foreground = $accBrush
        $meta = @()
        if ([int]$m.MapW -gt 0) { $meta += '{0} x {1}' -f [int]$m.MapW, [int]$m.MapH }
        # Invariant so the refresh rate reads 143.8, not a locale's 143,8.
        if ($null -ne $m.Hz) { $meta += '{0} Hz' -f ([double]$m.Hz).ToString('0.#', [cultureinfo]::InvariantCulture) }
        if ($null -ne $m.InCur -and $script:inputNames.ContainsKey([int]$m.InCur)) { $meta += $script:inputNames[[int]$m.InCur] }
        $el.MonSelMeta.Text = if ($meta.Count) { '{0} {1}' -f $script:mid, ($meta -join " $script:mid ") } else { '' }

        # contrast
        if ($null -ne $m.ConCur) {
            $el.MonConRow.Visibility = 'Visible'
            $el.S_MonCon.Maximum = [double][math]::Max(1, [int]$m.ConMax)
            $el.S_MonCon.Value = [double][int]$m.ConCur
            $el.V_MonCon.Text = '{0}' -f [int]$m.ConCur
            $el.S_MonCon.Foreground = New-MonBarBrush (ConvertTo-MonColor '#6FB1FF')
        } else { $el.MonConRow.Visibility = 'Collapsed' }

        # colour presets + inputs
        $el.MonPreHost.Children.Clear()
        foreach ($code in @($m.Presets)) {
            $nm = if ($script:presetNames.ContainsKey([int]$code)) { $script:presetNames[[int]$code] } else { '0x{0:X2}' -f [int]$code }
            $b = New-MonChip $nm ($null -ne $m.PreCur -and [int]$m.PreCur -eq [int]$code) @($script:monSel, [int]$code, 0x14)
            [void]$el.MonPreHost.Children.Add($b)
        }
        $el.MonInHost.Children.Clear()
        foreach ($code in @($m.Inputs)) {
            $nm = if ($script:inputNames.ContainsKey([int]$code)) { $script:inputNames[[int]$code] } else { '0x{0:X2}' -f [int]$code }
            $b = New-MonChip $nm ($null -ne $m.InCur -and [int]$m.InCur -eq [int]$code) @($script:monSel, [int]$code, 0x60)
            [void]$el.MonInHost.Children.Add($b)
        }
        if (-not $script:revertPending) { $el.MonRevertBar.Visibility = 'Collapsed' }
        Build-MonInfoLine $m
        Update-MonAdv
    } finally { $script:monLoading = $false }
}

# The footer line: what the display reports about itself, straight off the
# wire - no guessing from Windows' side.
function Build-MonInfoLine($m) {
    $a = @()
    $desc = ([string]$m.Desc).Trim()
    if ($desc) { $a += $desc }
    if ([int]$m.MapW -gt 0) { $a += '{0} x {1}' -f [int]$m.MapW, [int]$m.MapH }
    if ($null -ne $m.Hz) { $a += '{0} Hz' -f ([double]$m.Hz).ToString('0.#', [cultureinfo]::InvariantCulture) }
    if ($m.Primary) { $a += 'primary' }
    $el.MonInfoText.Text = $a -join "  $script:mid  "
    $b = @()
    if ($m.Tech) { $b += [string]$m.Tech }
    if ($m.SubPixel) { $b += [string]$m.SubPixel }
    if ($null -ne $m.UsageHours) { $b += '{0} h powered on' -f ([int]$m.UsageHours).ToString('N0', [cultureinfo]::InvariantCulture) }
    if ($m.Mccs) { $b += 'MCCS {0}' -f [string]$m.Mccs }
    $b += '{0} controls' -f (@($m.Presets).Count + @($m.Inputs).Count +
          $(if ($null -ne $m.ConCur) { 1 } else { 0 }) + $(if ($null -ne $m.SharpCur) { 1 } else { 0 }) +
          $(if ($null -ne $m.VolCur) { 1 } else { 0 }) + $(if ($null -ne $m.RCur) { 3 } else { 0 }) + 1)
    $el.MonInfoText2.Text = $b -join "  $script:mid  "
}

function New-MonChip([string]$text, [bool]$on, $tag) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $window.FindResource('SegBtn')
    $b.Content = $text
    $b.Tag = $tag
    $b.Margin = New-Object System.Windows.Thickness 0, 2, 5, 2
    $b.MinWidth = 58
    if ($on) { $b.Background = $script:brushAccentPill; $b.Foreground = $script:brushDark }
    else { $b.Background = $script:brushClear; $b.Foreground = $script:brushDim }
    $b.Add_Click({ param($s0, $e0)
        $t = $s0.Tag
        $i = [int]$t[0]; $val = [int]$t[1]; $code = [int]$t[2]
        $mons = @($sync.Ddc.Monitors)
        $prev = $null
        if ($i -lt $mons.Count) {
            switch ($code) {
                0x14 { $prev = $mons[$i].PreCur;  $mons[$i].PreCur  = $val }
                0x60 { $prev = $mons[$i].InCur;   $mons[$i].InCur   = $val }
                0xDC { $prev = $mons[$i].ModeCur; $mons[$i].ModeCur = $val }
            }
        }
        Queue-DdcSet 'SetVcp' $i $val $code
        foreach ($sib in $s0.Parent.Children) { $sib.Background = $script:brushClear; $sib.Foreground = $script:brushDim }
        $s0.Background = $script:brushAccentPill; $s0.Foreground = $script:brushDark
        # An input switch can black out the display it lands on - and on many
        # panels DDC/CI rides the active input, so there is no way to switch
        # back. It therefore reverts itself unless the user says to keep it.
        if ($code -eq 0x60 -and $null -ne $prev -and [int]$prev -ne $val) {
            Start-MonRevert $i ([int]$prev) $val
        }
    })
    return $b
}

# --- Input-switch safety net -----------------------------------------
$script:revertPending = $false
$script:revertMon = 0
$script:revertTo = 0
$script:revertLeft = 0
$script:revertTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:revertTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:revertTimer.Add_Tick({
    $script:revertLeft--
    if ($script:revertLeft -le 0) { Stop-MonRevert -Apply }
    else {
        $el.MonRevertText.Text = 'Input switched. Reverting in {0}s unless you keep it.' -f $script:revertLeft
    }
})
function Start-MonRevert([int]$mon, [int]$back, [int]$now) {
    $script:revertPending = $true
    $script:revertMon = $mon
    $script:revertTo = $back
    $script:revertLeft = 12
    $nm = if ($script:inputNames.ContainsKey($now)) { $script:inputNames[$now] } else { '0x{0:X2}' -f $now }
    $el.MonRevertText.Text = 'Switched to {0}. Reverting in {1}s unless you keep it.' -f $nm, $script:revertLeft
    $el.MonRevertBar.Visibility = 'Visible'
    $script:revertTimer.Stop(); $script:revertTimer.Start()
}
function Stop-MonRevert([switch]$Apply) {
    $script:revertTimer.Stop()
    if ($Apply -and $script:revertPending) {
        Queue-DdcSet 'SetVcp' $script:revertMon $script:revertTo 0x60
        $mons = @($sync.Ddc.Monitors)
        if ($script:revertMon -lt $mons.Count) { $mons[$script:revertMon].InCur = $script:revertTo }
    }
    $script:revertPending = $false
    $el.MonRevertBar.Visibility = 'Collapsed'
    Update-MonitorPanel
}
$el.BtnMonRevertKeep.Add_Click({ Stop-MonRevert })
$el.BtnMonRevertNow.Add_Click({ Stop-MonRevert -Apply })

# ADVANCED sheet: only the codes this display actually advertises.
function Update-MonAdv {
    $mons = @($sync.Ddc.Monitors)
    if ($script:monSel -ge $mons.Count) { return }
    $m = $mons[$script:monSel]
    $desc = ([string]$m.Desc).Trim()
    $open = [bool]$script:settings.monAdvOpen
    $el.MonAdvBody.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
    $el.BtnMonAdv.Content = $(if ($open) { 'HIDE' } else { 'SHOW' })
    $el.MonAdvTitle.Text = $(if ($desc) { 'on {0}' -f $desc } else { '' })
    $hasRgb = ($null -ne $m.RCur -and $null -ne $m.GCur -and $null -ne $m.BCur)
    $el.MonRgbGroup.Visibility = $(if ($hasRgb) { 'Visible' } else { 'Collapsed' })
    if ($hasRgb) {
        foreach ($row in @(@('R', $m.RCur, $m.RMax, '#FF7A7A'), @('G', $m.GCur, $m.GMax, '#7FE0A0'), @('B', $m.BCur, $m.BMax, '#6FB1FF'))) {
            $sl = $el["S_Mon$($row[0])"]
            $sl.Maximum = [double][math]::Max(1, [int]$row[2])
            $sl.Value = [double][int]$row[1]
            $sl.Foreground = New-MonBarBrush (ConvertTo-MonColor $row[3])
            $el["V_Mon$($row[0])"].Text = '{0}' -f [int]$row[1]
        }
    }
    if ($null -ne $m.SharpCur) {
        $el.MonSharpRow.Visibility = 'Visible'
        $el.S_MonSharp.Maximum = [double][math]::Max(1, [int]$m.SharpMax)
        $el.S_MonSharp.Value = [double][int]$m.SharpCur
        $el.S_MonSharp.Foreground = New-MonBarBrush (ConvertTo-MonColor '#6FB1FF')
        $el.V_MonSharp.Text = '{0}' -f [int]$m.SharpCur
    } else { $el.MonSharpRow.Visibility = 'Collapsed' }
    if ($null -ne $m.VolCur) {
        $el.MonVolRow.Visibility = 'Visible'
        $el.S_MonVol.Maximum = [double][math]::Max(1, [int]$m.VolMax)
        $el.S_MonVol.Value = [double][int]$m.VolCur
        $el.S_MonVol.Foreground = New-MonBarBrush (ConvertTo-MonColor '#6FB1FF')
        $el.V_MonVol.Text = '{0}' -f [int]$m.VolCur
        $muted = ($null -ne $m.MuteCur -and [int]$m.MuteCur -eq 1)
        $el.BtnMonMute.Content = [string][char]$(if ($muted) { 0xE74F } else { 0xE767 })
        $el.BtnMonMute.Visibility = $(if ($null -ne $m.MuteCur) { 'Visible' } else { 'Collapsed' })
    } else { $el.MonVolRow.Visibility = 'Collapsed' }
    # Picture mode chips, straight from the display's own list.
    $el.MonModeHost.Children.Clear()
    $modes = @($m.Modes)
    $el.MonModeRow.Visibility = $(if ($modes.Count -gt 1) { 'Visible' } else { 'Collapsed' })
    foreach ($code in $modes) {
        $nm = Get-MonModeName $m ([int]$code)
        $b = New-MonChip $nm ($null -ne $m.ModeCur -and [int]$m.ModeCur -eq [int]$code) @($script:monSel, [int]$code, 0xDC)
        [void]$el.MonModeHost.Children.Add($b)
    }
    # Picture mode cannot be read back on these panels, so the chips can't
    # show which one is active; say so instead of showing nothing selected.
    $el.MonModeHint.Text = $(if ($modes.Count -gt 1 -and $null -eq $m.ModeCur) {
        'The display does not report its current mode - tap one to set it.' } else { '' })
    $el.MonModeHint.Visibility = $(if ($el.MonModeHint.Text) { 'Visible' } else { 'Collapsed' })
    $bits = @()
    if ($null -ne $m.Hz) { $bits += '{0} HZ' -f ([double]$m.Hz).ToString('0.#', [cultureinfo]::InvariantCulture) }
    if ($null -ne $m.InCur -and $script:inputNames.ContainsKey([int]$m.InCur)) { $bits += ($script:inputNames[[int]$m.InCur]).ToUpperInvariant() }
    $el.MonAdvHz.Text = $bits -join " $script:mid "
    $el.MonAdvHzChip.Visibility = $(if ($bits.Count) { 'Visible' } else { 'Collapsed' })
    $el.BtnMonResetColor.Visibility = $(if ($m.HasColorReset) { 'Visible' } else { 'Collapsed' })
    $el.BtnMonResetLevels.Visibility = $(if ($m.HasLevelReset) { 'Visible' } else { 'Collapsed' })
    $el.BtnMonSoftOff.Visibility = $(if ($null -ne $m.PowerOff) { 'Visible' } else { 'Collapsed' })
    # 0x05 is a real power-down: MCCS warns the display may need its own power
    # button to come back, so the button says so instead of promising a wake.
    if ($m.PowerHard) {
        $el.BtnMonSoftOff.Content = 'POWER OFF'
        $el.BtnMonSoftOff.ToolTip = 'Turns this display off. It may need its own power button to come back on.'
    } else {
        $el.BtnMonSoftOff.Content = 'SOFT OFF'
        $el.BtnMonSoftOff.ToolTip = 'Sleeps this display. It wakes as soon as video returns.'
    }
    $el.BtnMonFactory.Visibility = $(if ($m.HasFactoryReset) { 'Visible' } else { 'Collapsed' })
    $el.MonFactoryConfirm.Visibility = 'Collapsed'
    # Say what this display withholds, so a missing slider reads as a limit of
    # the hardware rather than a gap in Vento.
    $na = @()
    if (@($m.Modes).Count -le 1) { $na += 'picture modes' }
    if (-not $hasRgb) { $na += 'RGB gain' }
    if ($null -eq $m.SharpCur) { $na += 'sharpness' }
    if ($null -eq $m.VolCur) { $na += 'speaker volume' }
    if (@($m.Inputs).Count -le 1) { $na += 'input switching' }
    # One honest list of everything this display keeps to itself. Response
    # time / overdrive is on it for every consumer display: no MCCS code
    # exists for it, and the XG2705's 1ms mode changed nothing across a
    # full 256-code sweep.
    $na += 'response time / 1ms mode'
    $el.MonRtText.Text = ('{0}. These are not exposed over DDC/CI by this display, so no software can reach them - set them in its own menu once; Vento''s profiles compensate the brightness a 1ms mode costs.' -f (
        (($na | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join ', ')))
    $el.MonAdvNa.Visibility = 'Collapsed'
}

# Reports what the display actually did with the last write, and corrects the
# control to the value it settled on.
$script:monWriteNames = @{ 0x10 = 'Brightness'; 0x12 = 'Contrast'; 0x14 = 'Color preset'; 0x60 = 'Input'
                           0x62 = 'Volume'; 0x87 = 'Sharpness'; 0x16 = 'Red gain'; 0x18 = 'Green gain'
                           0x1A = 'Blue gain'; 0xDC = 'Picture mode'; 0x08 = 'Color reset'
                           0x05 = 'Level reset'; 0x04 = 'Factory reset'; 0xD6 = 'Power'; 0x8D = 'Mute' }
function Show-MonWriteResult($w) {
    if (-not $w) { return }
    $name = if ($script:monWriteNames.ContainsKey([int]$w.Code)) { $script:monWriteNames[[int]$w.Code] } else { '0x{0:X2}' -f [int]$w.Code }
    if ($w.Took) { $el.MonWriteNote.Visibility = 'Collapsed'; return }
    $el.MonWriteNote.Text = '{0} stayed at {1} - this display ignored the change. It may only allow it from its own menu, or in a different color preset.' -f $name, $w.Actual
    $el.MonWriteNote.Visibility = 'Visible'
    # Snap the control back to the truth.
    $script:monLoading = $true
    try {
        $mons = @($sync.Ddc.Monitors)
        if ([int]$w.Mon -eq $script:monSel -and $script:monSel -lt $mons.Count) {
            $m = $mons[$script:monSel]
            switch ([int]$w.Code) {
                0x12 { $el.S_MonCon.Value = [double][int]$w.Actual; $el.V_MonCon.Text = '{0}' -f [int]$w.Actual }
                0x87 { $el.S_MonSharp.Value = [double][int]$w.Actual; $el.V_MonSharp.Text = '{0}' -f [int]$w.Actual }
                0x62 { $el.S_MonVol.Value = [double][int]$w.Actual; $el.V_MonVol.Text = '{0}' -f [int]$w.Actual }
                0x16 { $el.S_MonR.Value = [double][int]$w.Actual; $el.V_MonR.Text = '{0}' -f [int]$w.Actual }
                0x18 { $el.S_MonG.Value = [double][int]$w.Actual; $el.V_MonG.Text = '{0}' -f [int]$w.Actual }
                0x1A { $el.S_MonB.Value = [double][int]$w.Actual; $el.V_MonB.Text = '{0}' -f [int]$w.Actual }
            }
        }
    } finally { $script:monLoading = $false }
}

function Open-Monitors {
    Start-DdcWorker
    if (-not $script:psDdc) { $el.MonStatus.Text = 'DDC/CI is unavailable on this system' }
    else { $el.MonStatus.Text = 'Reading monitors...'; $sync.DdcQueue.Enqueue(@{ Cmd = 'Enum' }) }
    $el.MonNewLayer.Visibility = 'Collapsed'
    Update-MonitorPanel
    $el.MonitorOverlay.Visibility = 'Visible'
}

# --- Panel wiring ----------------------------------------------------
$el.MonMapCanvas.Add_SizeChanged({ if ($el.MonitorOverlay.Visibility -eq 'Visible') { Build-MonMap } })
$el.MonTimeCanvas.Add_SizeChanged({ if ($el.MonitorOverlay.Visibility -eq 'Visible') { Build-MonTimeline } })
$el.BtnMonitors.Add_Click({
    if ($el.MonitorOverlay.Visibility -eq 'Visible') { $el.MonitorOverlay.Visibility = 'Collapsed' }
    else { $el.PodsOverlay.Visibility = 'Collapsed'; Open-Monitors }
})
$el.BtnMonClose.Add_Click({ $el.MonitorOverlay.Visibility = 'Collapsed' })
$el.BtnMonRescan.Add_Click({
    if ($script:psDdc) { $el.MonStatus.Text = 'Reading monitors...'; $sync.DdcQueue.Enqueue(@{ Cmd = 'Enum' }) }
})
$el.BtnMonSync.Add_Click({
    $script:settings.monSync = -not [bool]$script:settings.monSync
    $sync.Settings.monSync = $script:settings.monSync
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    Update-MonitorPanel
})
# IDENTIFY: flash each display's own brightness so the numbers on the map
# can be matched to the panels on the desk.
$el.BtnMonIdentify.Add_Click({
    $mons = @($sync.Ddc.Monitors)
    for ($i = 0; $i -lt $mons.Count; $i++) {
        if (-not $mons[$i].Ok) { continue }
        Queue-DdcSet 'SetBri' $i ([int][math]::Max(0, [int]$mons[$i].BriMax - 5)) 0
    }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(900)
    $t.Add_Tick({ param($s0, $e0)
        $s0.Stop()
        $ms = @($sync.Ddc.Monitors)
        for ($i = 0; $i -lt $ms.Count; $i++) {
            if ($ms[$i].Ok) { Queue-DdcSet 'SetBri' $i ([int]$ms[$i].BriCur) 0 }
        }
    })
    $t.Start()
})
$el.S_MonCon.Add_ValueChanged({
    $el.V_MonCon.Text = '{0}' -f [int]$el.S_MonCon.Value
    if (-not $script:monLoading) {
        $tgt = if ([bool]$script:settings.monSync) { -1 } else { $script:monSel }
        Queue-DdcSet 'SetCon' $tgt ([int]$el.S_MonCon.Value) 0
    }
})
foreach ($ch in @(@('R', 0x16), @('G', 0x18), @('B', 0x1A))) {
    $sn = "S_Mon$($ch[0])"; $vn = "V_Mon$($ch[0])"; $code = [int]$ch[1]
    $el[$sn].Add_ValueChanged({
        $el[$vn].Text = '{0}' -f [int]$el[$sn].Value
        if (-not $script:monLoading) { Queue-DdcSet 'SetVcp' $script:monSel ([int]$el[$sn].Value) $code }
    }.GetNewClosure())
}
$el.S_MonSharp.Add_ValueChanged({
    $el.V_MonSharp.Text = '{0}' -f [int]$el.S_MonSharp.Value
    if (-not $script:monLoading) { Queue-DdcSet 'SetVcp' $script:monSel ([int]$el.S_MonSharp.Value) 0x87 }
})
$el.S_MonVol.Add_ValueChanged({
    $el.V_MonVol.Text = '{0}' -f [int]$el.S_MonVol.Value
    if (-not $script:monLoading) { Queue-DdcSet 'SetVcp' $script:monSel ([int]$el.S_MonVol.Value) 0x62 }
})
$el.BtnMonMute.Add_Click({
    $mons = @($sync.Ddc.Monitors)
    if ($script:monSel -ge $mons.Count) { return }
    $m = $mons[$script:monSel]
    if ($null -eq $m.MuteCur) { return }
    $new = if ([int]$m.MuteCur -eq 1) { 2 } else { 1 }
    $m.MuteCur = $new
    Queue-DdcSet 'SetVcp' $script:monSel $new 0x8D
    Update-MonAdv
})
# VCP 0x08 restores the factory colour defaults (0x05 would reset
# brightness/contrast instead, which is not what this button says).
$el.BtnMonResetColor.Add_Click({ Queue-DdcSet 'SetVcp' $script:monSel 1 0x08 })
# 0x05 restores the factory brightness/contrast pair.
$el.BtnMonResetLevels.Add_Click({ Queue-DdcSet 'SetVcp' $script:monSel 1 0x05 })
# 0x04 wipes every setting on the display and cannot be undone from software,
# so it takes a second click.
$el.BtnMonFactory.Add_Click({
    $el.BtnMonFactory.Visibility = 'Collapsed'
    $el.MonFactoryConfirm.Visibility = 'Visible'
})
$el.BtnMonFactoryNo.Add_Click({
    $el.MonFactoryConfirm.Visibility = 'Collapsed'
    $el.BtnMonFactory.Visibility = 'Visible'
})
$el.BtnMonFactoryYes.Add_Click({
    Queue-DdcSet 'SetVcp' $script:monSel 1 0x04
    $el.MonFactoryConfirm.Visibility = 'Collapsed'
    $el.BtnMonFactory.Visibility = 'Visible'
    if ($script:psDdc) { $sync.DdcQueue.Enqueue(@{ Cmd = 'Enum' }) }
})
$el.BtnMonSoftOff.Add_Click({
    $mons = @($sync.Ddc.Monitors)
    if ($script:monSel -ge $mons.Count) { return }
    $v = $mons[$script:monSel].PowerOff
    if ($null -ne $v) { Queue-DdcSet 'SetVcp' $script:monSel ([int]$v) 0xD6 }
})
$el.BtnMonAdv.Add_Click({
    $script:settings.monAdvOpen = -not [bool]$script:settings.monAdvOpen
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    Update-MonAdv
})

# --- Night schedule --------------------------------------------------
$el.S_MonNight.Add_Click({
    $script:settings.monNight = [bool]$el.S_MonNight.IsChecked
    $script:nightApplied = $false
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    Build-MonTimeline
    Test-NightShift
})
$el.BtnMonNightEdit.Add_Click({
    $el.MonNightEdit.Visibility = $(if ($el.MonNightEdit.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' })
})
function Step-NightTime([string]$key, [int]$delta) {
    $v = ([int]$script:settings[$key] + $delta + 1440) % 1440
    $script:settings[$key] = $v
    $script:nightApplied = $false
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    $el.MonNightFromVal.Text = Format-MonTime ([int]$script:settings.monNightFrom)
    $el.MonNightToVal.Text   = Format-MonTime ([int]$script:settings.monNightTo)
    $el.MonNightText.Text = '{0} {1} {2} {3} {4}' -f (Format-MonTime ([int]$script:settings.monNightFrom)), [char]0x2013,
                            (Format-MonTime ([int]$script:settings.monNightTo)), $script:mid, ('dims every display to {0}' -f [string]$script:settings.monNightProfile)
    Build-MonTimeline
}
$el.BtnNightFromDn.Add_Click({ Step-NightTime 'monNightFrom' (-30) })
$el.BtnNightFromUp.Add_Click({ Step-NightTime 'monNightFrom'   30  })
$el.BtnNightToDn.Add_Click({   Step-NightTime 'monNightTo'   (-30) })
$el.BtnNightToUp.Add_Click({   Step-NightTime 'monNightTo'     30  })

# Applies the night profile inside its window and restores the previous one
# on the way out. Runs from the main tick, so it survives sleep/wake too.
function Test-NightShift {
    if (-not [bool]$script:settings.monNight) {
        if ($script:nightApplied) {
            $script:nightApplied = $false
            $p = Get-MonProfile ([string]$script:nightPrev)
            if ($p) { Apply-MonProfile $p }
        }
        return
    }
    if (@($sync.Ddc.Monitors).Count -eq 0) { return }
    $now = [datetime]::Now
    $mins = $now.Hour * 60 + $now.Minute
    $from = [int]$script:settings.monNightFrom
    $to   = [int]$script:settings.monNightTo
    $inWindow = if ($from -eq $to) { $false }
                elseif ($from -lt $to) { $mins -ge $from -and $mins -lt $to }
                else { $mins -ge $from -or $mins -lt $to }
    if ($inWindow -and -not $script:nightApplied) {
        $np = Get-MonProfile ([string]$script:settings.monNightProfile)
        if ($np) {
            $script:nightPrev = [string]$script:settings.monProfile
            $script:nightApplied = $true
            Apply-MonProfile $np
        }
    } elseif (-not $inWindow -and $script:nightApplied) {
        $script:nightApplied = $false
        $p = Get-MonProfile ([string]$script:nightPrev)
        if (-not $p) { $p = Get-MonProfile 'DAY' }
        if ($p) { Apply-MonProfile $p }
    }
}

# --- New profile sheet -----------------------------------------------
$script:monNewColor = '#6FB1FF'
function Build-MonSwatches {
    $host0 = $el.MonNewSwatches
    $host0.Children.Clear()
    $picks = @('#FFC46F', '#8F86FF', '#FF7A8A', '#7FE0A0', '#6FB1FF', '#FF9E6F', '#6FE0FF', '#FF6FD8', '#B6FF6F')
    if ($picks -notcontains $script:monNewColor) { $picks += $script:monNewColor }
    foreach ($hex in $picks) {
        $b = New-Object System.Windows.Controls.Border
        $b.Width = 30; $b.Height = 30
        $b.CornerRadius = New-Object System.Windows.CornerRadius 15
        $b.Margin = New-Object System.Windows.Thickness 0, 0, 8, 8
        $b.Background = New-MonBrush (ConvertTo-MonColor $hex)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.Tag = $hex
        if ($hex -eq $script:monNewColor) {
            $b.BorderThickness = New-Object System.Windows.Thickness 2.5
            $b.BorderBrush = New-MonBrush ([System.Windows.Media.Colors]::White)
        }
        $b.Add_MouseLeftButtonDown({ param($s0, $e0)
            $script:monNewColor = [string]$s0.Tag
            Build-MonSwatches
        })
        [void]$host0.Children.Add($b)
    }
    # custom picker
    $c = New-Object System.Windows.Controls.Border
    $c.Width = 30; $c.Height = 30
    $c.CornerRadius = New-Object System.Windows.CornerRadius 15
    $c.Margin = New-Object System.Windows.Thickness 0, 0, 8, 8
    $c.Cursor = [System.Windows.Input.Cursors]::Hand
    $rb = New-Object System.Windows.Media.LinearGradientBrush
    $rb.StartPoint = New-Object System.Windows.Point 0, 0
    $rb.EndPoint = New-Object System.Windows.Point 1, 1
    foreach ($stop in @(@('#FF6F6F', 0.0), @('#FFC46F', 0.25), @('#7FE0A0', 0.5), @('#6FB1FF', 0.75), @('#C86FFF', 1.0))) {
        $sc = ConvertTo-MonColor ([string]$stop[0])
        $so = [double]$stop[1]
        $rb.GradientStops.Add((New-Object System.Windows.Media.GradientStop $sc, $so))
    }
    $rb.Freeze()
    $c.Background = $rb
    $c.Add_MouseLeftButtonDown({
        $picked = Show-ColorPicker $script:monNewColor
        if ($picked) { $script:monNewColor = $picked }
        Build-MonSwatches
    })
    [void]$host0.Children.Add($c)
}
# One sheet for both jobs: creating a profile from what the displays are
# showing, and editing or deleting an existing one.
$script:monEditName = ''
function Open-MonProfileSheet([string]$name = '') {
    $script:monEditName = $name
    $p = if ($name) { Get-MonProfile $name } else { $null }
    if ($p) {
        $script:monNewColor = [string]$p.Color
        $el.MonNewName.Text = $p.Name
        $el.MonNewTitle.Text = 'EDIT PROFILE'
        $el.MonNewHint.Text = 'Save re-captures what the displays are showing right now.'
        $el.BtnMonNewDelete.Visibility = $(if ($p.Builtin) { 'Collapsed' } else { 'Visible' })
    } else {
        $script:monNewColor = '#6FB1FF'
        $el.MonNewName.Text = 'My profile'
        $el.MonNewTitle.Text = 'NEW PROFILE'
        $el.MonNewHint.Text = 'Saves what the displays are showing right now.'
        $el.BtnMonNewDelete.Visibility = 'Collapsed'
    }
    Build-MonSwatches
    $el.MonNewLayer.Visibility = 'Visible'
    [void]$el.MonNewName.Focus()
    $el.MonNewName.SelectAll()
}
$el.BtnMonNewCancel.Add_Click({ $el.MonNewLayer.Visibility = 'Collapsed' })
$el.BtnMonNewSave.Add_Click({
    $name = ([string]$el.MonNewName.Text).Trim()
    if (-not $name) { return }
    $old = [string]$script:monEditName
    $mons = @($sync.Ddc.Monitors)
    # The selected display seeds the recipe; it is the one the user was just
    # looking at.
    $seed = $null
    if ($script:monSel -lt $mons.Count -and $mons[$script:monSel].Ok) { $seed = $mons[$script:monSel] }
    if (-not $seed) { foreach ($m in $mons) { if ($m.Ok) { $seed = $m; break } } }
    $prev = Get-MonProfile $old
    if (-not $seed -and -not $prev) { $el.MonNewLayer.Visibility = 'Collapsed'; return }
    $p = @{
        Name    = $name
        Color   = $script:monNewColor
        Bri     = $(if ($seed) { [int]$seed.BriCur } else { [int]$prev.Bri })
        Con     = $(if ($seed -and $null -ne $seed.ConCur) { [int]$seed.ConCur } elseif ($prev) { [int]$prev.Con } else { 50 })
        Preset  = $(if ($seed -and $null -ne $seed.PreCur) { [int]$seed.PreCur } elseif ($prev) { [int]$prev.Preset } else { 0 })
        Builtin = $(if ($prev) { [bool]$prev.Builtin } else { $false })
    }
    $arr = @(Get-MonProfiles | Where-Object { $_.Name -ne $name -and $_.Name -ne $old })
    $arr += ,$p
    Save-MonProfiles $arr
    # A rename carries the active/schedule pointers with it.
    if ($old -and $old -ne $name) {
        if ([string]$script:settings.monProfile -eq $old) { $script:settings.monProfile = $name }
        if ([string]$script:settings.monNightProfile -eq $old) { $script:settings.monNightProfile = $name }
        $by = @($script:settings.monProfileByMon)
        for ($i = 0; $i -lt $by.Count; $i++) { if ($by[$i] -eq $old) { $by[$i] = $name } }
        $script:settings.monProfileByMon = @($by)
    }
    $script:monEditName = ''
    $el.MonNewLayer.Visibility = 'Collapsed'
    Update-MonitorPanel
})
$el.BtnMonNewDelete.Add_Click({
    $name = [string]$script:monEditName
    if (-not $name) { return }
    $p = Get-MonProfile $name
    if (-not $p -or $p.Builtin) { return }
    Save-MonProfiles @(Get-MonProfiles | Where-Object { $_.Name -ne $name })
    # Anything still pointing at the deleted profile falls back to a built-in.
    if ([string]$script:settings.monProfile -eq $name) { $script:settings.monProfile = 'DAY' }
    if ([string]$script:settings.monNightProfile -eq $name) { $script:settings.monNightProfile = 'NIGHT' }
    $by = @($script:settings.monProfileByMon)
    for ($i = 0; $i -lt $by.Count; $i++) { if ($by[$i] -eq $name) { $by[$i] = '' } }
    $script:settings.monProfileByMon = @($by)
    $script:monEditName = ''
    $el.MonNewLayer.Visibility = 'Collapsed'
    Update-MonitorPanel
})
# Scope: one profile across every display, or per display.
function Set-MonScope([string]$scope) {
    $script:settings.monProfileScope = $scope
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    Update-MonitorPanel
}
$el.BtnMonScopeAll.Add_Click({ Set-MonScope 'all' })
$el.BtnMonScopeOne.Add_Click({ Set-MonScope 'one' })

# --- Silent update install -------------------------------------------
$script:psDl = $null
$script:dlRunspace = $null
$script:pendingSetup = $null
function Install-Update {
    $u = $sync.Update
    if (-not $u) { return }
    if (-not $u.AssetUrl) { Start-Process $u.Url; return }
    if ($sync.DlState) { return }
    $sync.DlState = 'downloading'
    $dst = Join-Path $env:TEMP $u.AssetName
    $dl = {
        param($sync, $url, $dst, $sha)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 300
            # This installer is about to run elevated. When the release
            # published a hash, refuse to run anything that doesn't match it -
            # a tampered or truncated download never reaches the user.
            if ($sha) {
                $actual = (Get-FileHash -Path $dst -Algorithm SHA256).Hash.ToLower()
                if ($actual -ne ([string]$sha).ToLower()) {
                    try { Remove-Item $dst -Force } catch { }
                    $sync.DlState = 'badhash'
                    return
                }
            }
            $sync.SetupFile = $dst
        } catch {
            $sync.DlState = $null
        }
    }
    $script:dlRunspace = [runspacefactory]::CreateRunspace()
    $script:dlRunspace.Open()
    $script:psDl = [powershell]::Create()
    $script:psDl.Runspace = $script:dlRunspace
    [void]$script:psDl.AddScript($dl.ToString()).AddArgument($sync).AddArgument($u.AssetUrl).AddArgument($dst).AddArgument($u.Sha256)
    [void]$script:psDl.BeginInvoke()
}

# --- AirPods battery (BLE) -------------------------------------------
# AirPods broadcast their battery in Apple's BLE proximity advertisements
# (company id 0x004C, message type 0x07). Vento listens passively - nothing
# is ever sent to the buds. Wire format from public research (INRIA
# hal-02394619, furiousMAC continuity). The WinRT advertisement watcher
# cannot be driven from PowerShell directly (WinRT events + winmd refs), so
# a small C# class owns it; it is compiled in a background runspace because
# the winmd-referencing compile takes ~1s that the UI thread shouldn't pay.
$script:podsCompileStarted = $false
$script:podsModels = @{
    0x2002 = 'AirPods';   0x200F = 'AirPods 2'; 0x2013 = 'AirPods 3'
    0x2019 = 'AirPods 4'; 0x201B = 'AirPods 4 ANC'
    0x200E = 'AirPods Pro'; 0x2014 = 'AirPods Pro 2'; 0x2024 = 'AirPods Pro 2'
    0x2027 = 'AirPods Pro 3'; 0x200A = 'AirPods Max'; 0x201F = 'AirPods Max'
    0x2012 = 'Beats Fit Pro'
}
$script:pods = $null           # last merged state (see Update-PodsData)
$script:podsBarWarn = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF8A8A'))
$script:podsBarWarn.Freeze()
$script:podsInk = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#EDF1F8'))
$script:podsInk.Freeze()
$script:podsLastPP = 0         # packet counter already processed
$script:podsRetryAt = [DateTime]::MinValue
$script:podsWarned = @{ L = $false; R = $false; C = $false }
$script:podsLearn = $null      # unbound: @{Model;N} streak toward binding
$script:podsFiltered = 0       # packets heard but rejected by the identity gates
$script:podsModelPushed = $false
$script:podsBarW = 166         # px, the flyout's bar track (PodsLBar & co in XAML)
$script:podsDotLive = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#7FE0A0'))
$script:podsDotLive.Freeze()
$script:podsDotIdle = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#4A5970'))
$script:podsDotIdle.Freeze()
# On-demand radio. The watcher is passive - the buds broadcast whether or
# not anyone listens, so it costs them nothing - but there is no reason to
# hold the PC's adapter in scan mode all day either. It listens while
# something shows the data (the PODS flyout, the OSD pods metric) and
# otherwise wakes for a short sniff every few minutes, first one right at
# launch, so the low-battery toast still fires. Unbound pods (podsModel 0)
# never sniff: binding needs the user looking at the flyout, so a neighbour's
# pair can't be adopted blind.
$script:podsSniffEvery = 600   # seconds between background sniffs
$script:podsSniffLen   = 20    # seconds each sniff listens
$script:podsIdleGrace  = 10    # seconds the radio stays on after the last consumer
$script:podsSniffNext  = [DateTime]::MinValue
$script:podsSniffUntil = [DateTime]::MinValue
$script:podsWantAt     = [DateTime]::MinValue   # last tick that wanted the radio
$script:podsWant       = $false
$script:podsStartFailed = $false   # last Start() was refused (Bluetooth off?) - drives the flyout's red status

# Pure decision: should the radio listen right now? A consumer wins outright
# and pushes the next sniff out - no point sniffing right after it closes.
function Get-PodsScanWant([bool]$consumer, [bool]$bound, [DateTime]$now) {
    if ($consumer) { $script:podsSniffNext = $now.AddSeconds($script:podsSniffEvery); return $true }
    if ($now -lt $script:podsSniffUntil) { return $true }
    if ($bound -and $now -ge $script:podsSniffNext) {
        $script:podsSniffUntil = $now.AddSeconds($script:podsSniffLen)
        $script:podsSniffNext  = $now.AddSeconds($script:podsSniffEvery)
        return $true
    }
    return $false
}

function Start-PodsCompile {
    if ($script:podsCompileStarted) { return }
    $script:podsCompileStarted = $true
    $body = {
        param($sync)
        try {
            $gac = "$env:SystemRoot\Microsoft.NET\assembly\GAC_MSIL"
            $refs = @(
                "$env:SystemRoot\System32\WinMetadata\Windows.Devices.winmd"
                "$env:SystemRoot\System32\WinMetadata\Windows.Foundation.winmd"
                "$env:SystemRoot\System32\WinMetadata\Windows.Storage.winmd"
                'System.dll'
            )
            # GAC folder names carry versions - resolve, never hardcode.
            foreach ($n in 'System.Runtime', 'System.Runtime.WindowsRuntime', 'System.Runtime.InteropServices.WindowsRuntime') {
                $dll = Get-ChildItem (Join-Path $gac $n) -Recurse -Filter "$n.dll" -ErrorAction Stop | Select-Object -First 1
                if (-not $dll) { throw "facade missing: $n" }
                $refs += $dll.FullName
            }
            $cp = New-Object System.CodeDom.Compiler.CompilerParameters
            $cp.ReferencedAssemblies.AddRange([string[]]$refs)
            Add-Type -CompilerParameters $cp -TypeDefinition @'
using System;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Storage.Streams;

namespace VentoNative {
  public static class Pods {
    static readonly object Gate = new object();
    static BluetoothLEAdvertisementWatcher s_w;
    static byte[] s_pkt; static short s_rssi; static long s_seenTick;
    static int s_pp; static int s_model; static string s_err = "";

    public static bool Running { get { lock (Gate) { return s_w != null; } } }
    // Once bound, foreign models are dropped BEFORE the single latest-packet
    // slot: otherwise a neighbour's chattier AirPods would keep overwriting
    // ours and starve every consumer. 0 accepts everything (learning).
    public static void SetModel(int m) { lock (Gate) { s_model = m; } }

    public static int Start() {
      lock (Gate) {
        if (s_w != null) return 0;
        try {
          var w = new BluetoothLEAdvertisementWatcher();
          // Win11 26100 refuses Start() without a Received handler attached.
          w.Received += OnReceived;
          w.Stopped += OnStopped;
          w.Start();
          s_w = w; s_err = "";
          return 0;
        } catch (Exception e) { s_err = e.Message; s_w = null; return -1; }
      }
    }
    public static void Stop() {
      lock (Gate) { if (s_w != null) { try { s_w.Stop(); } catch (Exception) { } s_w = null; } }
    }
    static void OnReceived(BluetoothLEAdvertisementWatcher w, BluetoothLEAdvertisementReceivedEventArgs a) {
      try {
        var md = a.Advertisement.ManufacturerData;
        for (int i = 0; i < md.Count; i++) {
          var m = md[i];
          if (m.CompanyId != 0x004C) continue;
          var buf = m.Data;
          if (buf == null || buf.Length != 27) continue;
          var bytes = new byte[27];
          DataReader.FromBuffer(buf).ReadBytes(bytes);
          if (bytes[0] != 0x07 || bytes[1] != 25) continue;
          int model = (bytes[4] << 8) | bytes[3];
          lock (Gate) {
            if (s_model != 0 && model != s_model) continue;
            s_pkt = bytes; s_rssi = a.RawSignalStrengthInDBm;
            s_seenTick = Environment.TickCount; s_pp++;
          }
        }
      } catch (Exception) { }
    }
    static void OnStopped(BluetoothLEAdvertisementWatcher w, BluetoothLEAdvertisementWatcherStoppedEventArgs a) {
      lock (Gate) { s_err = a.Error.ToString(); s_w = null; }
    }
    // "pp;rssi;ageMs;hex22" - only the first 11 payload bytes ever leave this
    // class; bytes 11-26 are a privacy-sensitive opaque blob and stay here.
    public static string Poll() {
      lock (Gate) {
        string err = s_err.Length > 0 ? ";ERR:" + s_err : "";
        if (s_pkt == null) return s_pp + ";;;" + err;
        long age = (long)(Environment.TickCount - s_seenTick);
        return s_pp + ";" + s_rssi + ";" + age + ";" +
               BitConverter.ToString(s_pkt, 0, 11).Replace("-", "") + err;
      }
    }
  }
}
'@
            $sync.PodsReady = $true
        } catch { $sync.PodsErr = "$_" }
    }
    $script:podsRunspace = [runspacefactory]::CreateRunspace()
    $script:podsRunspace.Open()
    $script:psPods = [powershell]::Create()
    $script:psPods.Runspace = $script:podsRunspace
    [void]$script:psPods.AddScript($body.ToString()).AddArgument($sync)
    [void]$script:psPods.BeginInvoke()
}

# Decode one Poll() snapshot into $script:pods. Every claim the UI makes
# traces back to a real packet: fields update only when the packet carried a
# valid value, and everything is stamped with when it was last heard.
function Update-PodsData {
    if (-not ('VentoNative.Pods' -as [type])) { return }
    $s = $script:settings
    $snap = [VentoNative.Pods]::Poll()
    $p = $snap -split ';', 5
    $pp = [int]$p[0]
    if ($pp -eq $script:podsLastPP -or -not $p[3]) { return }
    $script:podsLastPP = $pp
    $rssi = [int]$p[1]
    if ($rssi -lt [int]$s.podsRssiMin) { $script:podsFiltered++; return }
    $hex = [string]$p[3]
    if ($hex.Length -lt 22) { return }
    $b = New-Object 'int[]' 11
    for ($i = 0; $i -lt 11; $i++) { $b[$i] = [Convert]::ToInt32($hex.Substring($i * 2, 2), 16) }
    $model = ($b[4] -shl 8) -bor $b[3]
    # Bind to a model heard REPEATEDLY at close range, then only accept that
    # model: BLE addresses rotate for privacy, so model id plus signal
    # strength is the best identity this protocol offers. Three consecutive
    # strong packets keep a one-off blip from an apartment neighbour from
    # being adopted; FORGET in the panel unbinds if it ever goes wrong.
    if ([int]$s.podsModel -eq 0) {
        # -70: this rig's adapter reads a worn bud AT THE DESK as -76, and the
        # case held next to the PC as -42..-62 - so binding wants the buds
        # brought close once, without demanding they touch the antenna
        if ($rssi -lt -70) { $script:podsFiltered++; return }
        if ($script:podsLearn -and [int]$script:podsLearn.Model -eq $model) { $script:podsLearn.N++ }
        else { $script:podsLearn = @{ Model = $model; N = 1 } }
        if ([int]$script:podsLearn.N -lt 3) { $script:podsFiltered++; return }
        $s.podsModel = $model
        $script:podsLearn = $null
        if ('VentoNative.Pods' -as [type]) { try { [VentoNative.Pods]::SetModel($model) } catch { } }
        $script:saveTimer.Stop(); $script:saveTimer.Start()
    } elseif ($model -ne [int]$s.podsModel) { $script:podsFiltered++; return }
    $fromLeft = ($b[5] -band 0x20) -ne 0
    $currBat = $b[6] -band 0x0F; $anotBat = ($b[6] -shr 4) -band 0x0F
    $caseBat = $b[7] -band 0x0F
    $chCurr = ($b[7] -band 0x10) -ne 0; $chAnot = ($b[7] -band 0x20) -ne 0
    $inCurr = ($b[5] -band 0x02) -ne 0; $inAnot = ($b[5] -band 0x08) -ne 0
    if (-not $script:pods) {
        $script:pods = @{ Model = 0; L = $null; R = $null; Case = $null
                          ChgL = $false; ChgR = $false; ChgCase = $false
                          InL = $false; InR = $false; Lid = $null
                          Rssi = 0; Seen = $null; LSeen = $null; RSeen = $null; CaseSeen = $null }
    }
    $d = $script:pods
    $d.Model = $model; $d.Rssi = $rssi; $d.Seen = [DateTime]::Now
    $lB = $(if ($fromLeft) { $currBat } else { $anotBat })
    $rB = $(if ($fromLeft) { $anotBat } else { $currBat })
    # Each side keeps its own last-heard stamp: a bud that died or stayed
    # home must not ride the other bud's freshness and read as live data.
    if ($lB -le 10) { $d.L = $lB * 10; $d.LSeen = [DateTime]::Now }
    if ($rB -le 10) { $d.R = $rB * 10; $d.RSeen = [DateTime]::Now }
    if ($caseBat -le 10) { $d.Case = $caseBat * 10; $d.CaseSeen = [DateTime]::Now }
    $d.ChgL = $(if ($fromLeft) { $chCurr } else { $chAnot })
    $d.ChgR = $(if ($fromLeft) { $chAnot } else { $chCurr })
    $d.ChgCase = ($b[7] -band 0x40) -ne 0
    # the in-ear bit reads true while a pod charges - filter it, as the
    # charging pod is definitionally in the case
    $d.InL = $(if ($fromLeft) { $inCurr } else { $inAnot }) -and -not $d.ChgL
    $d.InR = $(if ($fromLeft) { $inAnot } else { $inCurr }) -and -not $d.ChgR
    $d.Lid = ($b[8] -band 0x08) -eq 0   # $true = lid open
    # Low-battery toast per component, re-armed by charging or recovery.
    foreach ($t in @(@('L', $d.L, $d.ChgL, 'Left'), @('R', $d.R, $d.ChgR, 'Right'), @('C', $d.Case, $d.ChgCase, 'Case'))) {
        $k = $t[0]; $v = $t[1]; $chg = $t[2]
        if ($null -eq $v) { continue }
        if ($chg -or $v -ge ([int]$s.podsWarn + 20)) { $script:podsWarned[$k] = $false }
        elseif ([bool]$s.devLowOn -and $v -le [int]$s.podsWarn -and -not $script:podsWarned[$k]) {
            $script:podsWarned[$k] = $true
            [void](Show-Toast 'AirPods battery low' ('{0}: {1}%' -f $t[3], $v) 'vento-pods')
        }
    }
}

function Get-PodsAgeText([DateTime]$t) {
    $sec = [int]([DateTime]::Now - $t).TotalSeconds
    if ($sec -lt 5) { return 'just now' }
    if ($sec -lt 90) { return ('{0}s ago' -f $sec) }
    $min = [int][math]::Round($sec / 60.0)
    if ($min -lt 90) { return ('{0}m ago' -f $min) }
    return ('{0}h ago' -f [int][math]::Round($min / 60.0))
}

function Update-PodsPanel {
    # Most specific state first: a disabled feature or a dead compile must
    # never sit behind a stale 'Starting' line. The dot says it at a glance:
    # green = listening, red = something is in the way, grey = getting there.
    $live = $false; $bad = $false
    if (-not [bool]$script:settings.podsEnabled) { $st = 'Scanning off'; $bad = $true }
    elseif ($sync.PodsErr) { $st = 'No Bluetooth LE'; $bad = $true }
    elseif (-not $sync.PodsReady -or -not ('VentoNative.Pods' -as [type])) { $st = 'Starting' }
    elseif ([VentoNative.Pods]::Running) { $st = 'Listening'; $live = $true }
    elseif ($script:podsStartFailed) { $st = 'Bluetooth off - retrying'; $bad = $true }
    else { $st = 'Starting' }   # compiled, not yet asked to start (next tick will)
    $el.PodsDot.Fill = $(if ($live) { $script:podsDotLive } elseif ($bad) { $script:podsBarWarn } else { $script:podsDotIdle })
    $el.PodsHead.ToolTip = $st
    $d = $script:pods
    if (-not $d -or -not $d.Seen) {
        $el.PodsModelText.Text = 'AIRPODS'
        # Packets are arriving but failing the identity gates - saying
        # 'no broadcasts' would blame the wrong thing.
        if ($script:podsFiltered -gt 0) {
            $el.PodsEmptyText.Text = ('Hearing Apple battery broadcasts nearby ({0} so far), but none close and repeated enough to lock onto. Keep the buds next to the PC for a few seconds.' -f $script:podsFiltered)
        }
        return
    }
    $el.PodsEmpty.Visibility = 'Collapsed'
    $el.PodsBody.Visibility = 'Visible'
    $el.PodsModelText.Text = $(if ($script:podsModels.ContainsKey($d.Model)) { $script:podsModels[$d.Model].ToUpperInvariant() } else { 'AIRPODS 0x{0:X4}' -f $d.Model })
    foreach ($t in @(@('L', $d.L, $d.ChgL), @('R', $d.R, $d.ChgR), @('C', $d.Case, $d.ChgCase))) {
        $k = $t[0]; $v = $t[1]
        # red only while not charging - a charging component is already healing
        $low = ($null -ne $v -and $v -le [int]$script:settings.podsWarn -and -not $t[2])
        $el["Pods${k}Val"].Text = $(if ($null -ne $v) { '{0}%' -f $v } else { '--' })
        $el["Pods${k}Val"].Foreground = $(if ($low) { $script:podsBarWarn } else { $script:podsInk })
        $el["Pods${k}Chg"].Visibility = $(if ($t[2]) { 'Visible' } else { 'Collapsed' })
        $bar = $el["Pods${k}Bar"]
        $bar.Width = [math]::Round($script:podsBarW * $(if ($null -ne $v) { $v / 100.0 } else { 0 }), 1)
        $bar.Background = $(if ($low) { $script:podsBarWarn } else { $script:brushAccent })
    }
    # The face shows battery only; the rest is one hover away on the title.
    $info = '{0} {1} updated {2}' -f $st, $script:mid, (Get-PodsAgeText $d.Seen)
    if ($null -ne $d.Lid) { $info += (' {0} {1}' -f $script:mid, $(if ($d.Lid) { 'lid open' } else { 'lid closed' })) }
    if ($d.InL -or $d.InR) { $info += (' {0} in ear' -f $script:mid) }
    $el.PodsHead.ToolTip = ('{0} {1} {2} dBm' -f $info, $script:mid, $d.Rssi)
    # A component whose own last-heard stamp lags the packet stream is
    # history, not a live reading: its row dims and says how old it is.
    foreach ($t in @(@('L', $d.L, $d.LSeen), @('R', $d.R, $d.RSeen), @('C', $d.Case, $d.CaseSeen))) {
        $row = $el["Pods$($t[0])Row"]
        if ($null -ne $t[1] -and $t[2] -and ([DateTime]::Now - $t[2]).TotalMinutes -gt 3) {
            $row.Opacity = 0.45
            $row.ToolTip = ('As of {0}' -f (Get-PodsAgeText $t[2]))
        } else {
            $row.Opacity = 1.0
            $row.ToolTip = $null
        }
    }
}

# Called every UI tick: decides whether the radio should listen, keeps the
# watcher alive while it should, folds new packets in, and refreshes
# whichever surfaces (flyout, OSD) are showing pods data.
function Update-PodsTick {
    $s = $script:settings
    # The open flyout repaints on EVERY path, including the early returns -
    # otherwise a compile error or a disabled feature leaves whatever status
    # line happened to be there when it opened.
    $vis = ($el.PodsOverlay.Visibility -eq 'Visible')
    $ready = [bool]($sync.PodsReady -and ('VentoNative.Pods' -as [type]))
    if (-not [bool]$s.podsEnabled) {
        if ($ready -and [VentoNative.Pods]::Running) { [VentoNative.Pods]::Stop() }
        $script:podsWant = $false
        if ($vis) { Update-PodsPanel }
        return
    }
    $now = [DateTime]::Now
    # the Devices page AirPods tab counts as a consumer while it is on screen
    $consumer = [bool]($vis -or ([bool]$s.osdPods -and $script:osd -and $script:osd.IsVisible) -or ($script:shell.IsVisible -and (G 'PodsPanel').IsVisible))
    $want = Get-PodsScanWant $consumer ([int]$s.podsModel -ne 0) $now
    if ($want) {
        $script:podsWantAt = $now
        # fresh demand starts the radio on THIS tick, not after a leftover backoff
        if (-not $script:podsWant) { $script:podsRetryAt = [DateTime]::MinValue }
        $script:podsWant = $true
        # The C# watcher is compiled on first demand: a PC that never shows
        # pods data never pays the ~1s compile either.
        if (-not $script:podsCompileStarted) { Start-PodsCompile }
        if (-not $ready) { if ($vis) { Update-PodsPanel }; return }
        if (-not $script:podsModelPushed) {
            # tell the C# filter which model is ours before the first packets land
            try { [VentoNative.Pods]::SetModel([int]$s.podsModel) } catch { }
            $script:podsModelPushed = $true
        }
        if (-not [VentoNative.Pods]::Running -and $now -gt $script:podsRetryAt) {
            # Bluetooth may be off right now; keep trying gently.
            $script:podsRetryAt = $now.AddSeconds(15)
            $script:podsStartFailed = ([VentoNative.Pods]::Start() -ne 0)
        }
    } else {
        $script:podsWant = $false
        if (-not $ready) { if ($vis) { Update-PodsPanel }; return }
        # a short grace so toggling the flyout doesn't thrash the adapter
        if ([VentoNative.Pods]::Running -and ($now - $script:podsWantAt).TotalSeconds -gt $script:podsIdleGrace) {
            [VentoNative.Pods]::Stop()
        }
    }
    Update-PodsData
    if ($vis) { Update-PodsPanel }
}

$el.BtnPods.Add_Click({
    if ($el.PodsOverlay.Visibility -eq 'Visible') { $el.PodsOverlay.Visibility = 'Collapsed' }
    else {
        # one overlay at a time - PodsOverlay is last in the XAML, so anything
        # left open underneath would keep its chip looking dead
        $el.SettingsOverlay.Visibility = 'Collapsed'
        $el.MonitorOverlay.Visibility = 'Collapsed'
        $el.PodsOverlay.Visibility = 'Visible'
        # the flyout is a consumer: start the radio now, not a tick later
        try { Update-PodsTick } catch { }
        Update-PodsPanel
    }
})
# A flyout, not a page: a click anywhere outside the card closes it (so does
# Esc, and the PODS chip itself).
$el.PodsBackdrop.Add_MouseDown({ $el.PodsOverlay.Visibility = 'Collapsed' })
# nothing to forget until a pair is bound - no menu at all then
$el.PodsCard.Add_ContextMenuOpening({ if ([int]$script:settings.podsModel -eq 0) { $_.Handled = $true } })
$el.PodsForgetItem.Add_Click({
    # Unbind: back to learning mode; next model heard 3x at close range wins.
    $script:settings.podsModel = 0
    $sync.Settings.podsModel = 0
    if ('VentoNative.Pods' -as [type]) { try { [VentoNative.Pods]::SetModel(0) } catch { } }
    $script:pods = $null; $script:podsLearn = $null; $script:podsFiltered = 0
    $script:podsWarned = @{ L = $false; R = $false; C = $false }
    $el.PodsBody.Visibility = 'Collapsed'
    $el.PodsEmpty.Visibility = 'Visible'
    $el.PodsEmptyText.Text = 'Forgotten. Keep the AirPods you want next to the PC - the first pair heard a few times up close becomes the new one.'
    $script:saveTimer.Stop(); $script:saveTimer.Start()
    Update-PodsPanel
})

# --- DDC/CI worker ---------------------------------------------------
# DDC calls take 50ms-2s each, so they run in their own runspace fed by a
# command queue. Only this runspace touches the PHYSICAL_MONITOR handles.
# Commands: @{Cmd='Enum'} re-enumerates and publishes a snapshot into
# $sync.Ddc; @{Cmd='SetBri'|'SetCon'|'SetVcp'; Mon=<index|-1 for all>;
# Value=<n>; Code=<vcp>} applies a value.
$script:psDdc = $null
$script:ddcRunspace = $null
$ddcWorker = {
    param($sync)
    $mons = @()                                       # live handles, index-aligned with the snapshot
    # Discovery results per display identity, kept for the worker's lifetime:
    # a display's control set (caps string, which controls answer, which
    # writes stick) does not change while it stays plugged in, so re-opening
    # the panel only needs the current values, not the ~2s re-probe.
    $ddcCache = @{}
    $physSets = New-Object System.Collections.ArrayList
    try {
        while (-not $sync.Exit) {
            $cmds = @()
            while ($sync.DdcQueue.Count -gt 0) { $cmds += $sync.DdcQueue.Dequeue() }
            if ($cmds.Count -gt 0) {
                # Coalesce: only the newest Set per target matters, one Enum at most.
                $seen = @{}; $run = @(); $verify = @{}
                for ($i = $cmds.Count - 1; $i -ge 0; $i--) {
                    $c = $cmds[$i]
                    $key = if ($c.Cmd -eq 'Enum') { 'Enum' } else { '{0}:{1}:{2}' -f $c.Cmd, $c.Mon, $c.Code }
                    if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $run = ,$c + $run }
                }
                foreach ($c in $run) {
                    try {
                        switch ([string]$c.Cmd) {
                            'Enum' {
                                $sync.Ddc.Busy = $true
                                foreach ($p in $physSets) { try { [void][VentoNative.Ddc]::DestroyPhysicalMonitors([uint32]$p.N, $p.Arr) } catch { } }
                                $physSets.Clear(); $mons = @()
                                $out = @()
                                # dxva2 hands back "Generic PnP Monitor" for most displays; the
                                # EDID name Windows keeps is the one the user recognises.
                                $edidNames = @(); $edidIds = @()
                                try {
                                    foreach ($mi0 in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop)) {
                                        $nm0 = -join (@($mi0.UserFriendlyName) | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
                                        $edidNames += ,([string]$nm0).Trim()
                                        # name + serial: the cache key must tell two same-model
                                        # displays apart even if enumeration order ever shifts
                                        $sn0 = -join (@($mi0.SerialNumberID) | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
                                        $edidIds += ,(('{0}#{1}' -f ([string]$nm0).Trim(), ([string]$sn0).Trim()))
                                    }
                                } catch { $edidNames = @(); $edidIds = @() }
                                $slot = 0
                                foreach ($hm in [VentoNative.Ddc]::GetHMonitors()) {
                                    $n = [uint32]0
                                    # A skipped hmonitor must still advance the slot counter:
                                    # otherwise one transiently-failing display shifts every
                                    # later display onto an earlier EDID name AND an earlier
                                    # cache key, handing it the wrong cached control set.
                                    if (-not [VentoNative.Ddc]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm, [ref]$n) -or $n -eq 0) { $slot += [math]::Max(1, [int]$n); continue }
                                    $arr = New-Object 'VentoNative.PHYSICAL_MONITOR[]' $n
                                    if (-not [VentoNative.Ddc]::GetPhysicalMonitorsFromHMONITOR($hm, $n, $arr)) { $slot += [int]$n; continue }
                                    [void]$physSets.Add(@{ N = $n; Arr = $arr })
                                    $bounds = $null
                                    try { $bounds = [VentoNative.Ddc]::GetBounds($hm) } catch { }
                                    foreach ($pm in $arr) {
                                        $r = @{ Desc = [string]$pm.szPhysicalMonitorDescription; Ok = $false
                                                Presets = @(); PreCur = $null; ConCur = $null
                                                Inputs = @(); InCur = $null; VolCur = $null; MuteCur = $null
                                                SharpCur = $null; RCur = $null; GCur = $null; BCur = $null
                                                Hz = $null; PowerOff = $null; PowerCur = $null; PowerHard = $false
                                                Modes = @(); ModeCur = $null
                                                HasColorReset = $false; HasLevelReset = $false; HasFactoryReset = $false
                                                Tech = ''; SubPixel = ''; UsageHours = $null; Mccs = ''
                                                MapX = 0; MapY = 0; MapW = 0; MapH = 0; Primary = $false }
                                        if ($bounds -and $bounds.Length -ge 5) {
                                            $r.MapX = [int]$bounds[0]; $r.MapY = [int]$bounds[1]
                                            $r.MapW = [int]$bounds[2]; $r.MapH = [int]$bounds[3]
                                            $r.Primary = ([int]$bounds[4] -ne 0)
                                        }
                                        $h = $pm.hPhysicalMonitor
                                        $mi = [uint32]0; $cu = [uint32]0; $ma = [uint32]0
                                        if ([VentoNative.Ddc]::GetMonitorBrightness($h, [ref]$mi, [ref]$cu, [ref]$ma)) {
                                            $r.Ok = $true; $r.BriCur = [int]$cu; $r.BriMax = [int]$ma
                                            $mi = [uint32]0; $cu = [uint32]0; $ma = [uint32]0
                                            if ([VentoNative.Ddc]::GetMonitorContrast($h, [ref]$mi, [ref]$cu, [ref]$ma)) {
                                                $r.ConCur = [int]$cu; $r.ConMax = [int]$ma
                                            }
                                            # Show the display the moment its brightness is known: the
                                            # map, the selected strip and the sliders appear at once,
                                            # while the advertised controls fill in when the slow
                                            # per-code probe finishes and the final publish lands.
                                            # Name it from EDID now so it does not flash the generic
                                            # dxva2 description first. This publishes a SHALLOW COPY of
                                            # $r, never the live object: the worker keeps mutating $r
                                            # (adding probe keys, resizing the table) for ~1s after
                                            # this, and the UI thread can write onto a published
                                            # monitor via Apply-MonProfile - two writers on one plain
                                            # Hashtable would corrupt it. The copy is read-only to both.
                                            if (($r.Desc -match '^Generic|^Default|^PnP' -or -not ([string]$r.Desc).Trim()) -and
                                                $slot -lt $edidNames.Count -and $edidNames[$slot]) {
                                                $r.Desc = $edidNames[$slot]
                                            }
                                            $sync.Ddc.Monitors = @($out + ,(@{} + $r))
                                            $sync.Ddc.Gen++
                                            $readVcp = {
                                                param($code)
                                                $vt = [uint32]0; $vc = [uint32]0; $vm = [uint32]0
                                                if ([VentoNative.Ddc]::GetVCPFeatureAndVCPFeatureReply($h, [byte]$code, [ref]$vt, [ref]$vc, [ref]$vm)) {
                                                    return @([int]$vc, [int]$vm)
                                                }
                                                return $null
                                            }
                                            # The capability string lies in both directions - displays
                                            # advertise features they ignore, and accept ones they never
                                            # listed - so a control is offered only when the display
                                            # actually answers a read with a value inside its own range.
                                            $probe = {
                                                param($code)
                                                $v = & $readVcp $code
                                                if (-not $v) { return $null }
                                                if ($v[1] -le 0 -or $v[1] -gt 65535) { return $null }
                                                if ($v[0] -lt 0 -or $v[0] -gt $v[1]) { return $null }
                                                return $v
                                            }
                                            # Discovery is cached per display identity for the session:
                                            # which controls answer and which writes stick cannot change
                                            # while the display stays plugged in, so a re-open only
                                            # re-reads the current values and skips the caps request,
                                            # the write-nudge probes and the static identity codes.
                                            $ckey = '{0}|{1}|{2}' -f $slot, [string]$pm.szPhysicalMonitorDescription,
                                                    $(if ($slot -lt $edidIds.Count) { [string]$edidIds[$slot] } else { '' })
                                            $cc = $ddcCache[$ckey]
                                            if ($cc) {
                                                $r.Desc = [string]$cc.Desc
                                                # Every control is still gated on the display answering
                                                # right now - a read that fails today hides the control
                                                # today, cache or not.
                                                if ($cc.HasPre) {
                                                    $v = & $readVcp 0x14
                                                    if ($v) { $r.PreCur = $v[0]; $r.Presets = @($cc.Presets) }
                                                }
                                                if ($cc.Has60) {
                                                    $v = & $readVcp 0x60
                                                    if ($v) {
                                                        $r.InCur = $v[0]
                                                        if (@($cc.Inputs).Count -gt 1) { $r.Inputs = @($cc.Inputs) }
                                                    }
                                                }
                                                if ($cc.HasVol) {
                                                    $v = & $probe 0x62
                                                    if ($v) { $r.VolCur = $v[0]; $r.VolMax = $v[1] }
                                                }
                                                if ($cc.HasMute) {
                                                    $v = & $readVcp 0x8D
                                                    if ($v -and $v[0] -ge 1 -and $v[0] -le 2) { $r.MuteCur = $v[0] }
                                                }
                                                if ($cc.SharpOk) {
                                                    $v = & $probe 0x87
                                                    if ($v) { $r.SharpCur = $v[0]; $r.SharpMax = $v[1] }
                                                }
                                                if ($cc.HasRgb) {
                                                    $vr = & $probe 0x16; $vg = & $probe 0x18; $vb = & $probe 0x1A
                                                    if ($vr -and $vg -and $vb) {
                                                        $r.RCur = $vr[0]; $r.RMax = $vr[1]
                                                        $r.GCur = $vg[0]; $r.GMax = $vg[1]
                                                        $r.BCur = $vb[0]; $r.BMax = $vb[1]
                                                    }
                                                }
                                                $v = & $readVcp 0xAE
                                                if ($v) {
                                                    $hz = [double]$v[0] / 100.0
                                                    if ($hz -gt 20 -and $hz -lt 500) { $r.Hz = $hz }
                                                }
                                                if ($null -ne $cc.PowerOff) {
                                                    $r.PowerOff = [int]$cc.PowerOff; $r.PowerHard = [bool]$cc.PowerHard
                                                    $v = & $readVcp 0xD6
                                                    if ($v) { $r.PowerCur = [int]$v[0] }
                                                }
                                                if (@($cc.Modes).Count -gt 1) {
                                                    $v = & $readVcp 0xDC
                                                    if ($v) { $r.Modes = @($cc.Modes); $r.ModeCur = [int]$v[0] }
                                                }
                                                $r.HasColorReset   = [bool]$cc.HasColorReset
                                                $r.HasLevelReset   = [bool]$cc.HasLevelReset
                                                $r.HasFactoryReset = [bool]$cc.HasFactoryReset
                                                $r.Tech = [string]$cc.Tech; $r.SubPixel = [string]$cc.SubPixel; $r.Mccs = [string]$cc.Mccs
                                                if ($cc.HasC0) {
                                                    $v = & $readVcp 0xC0
                                                    if ($v -and [int]$v[0] -gt 0) { $r.UsageHours = [int]$v[0] }
                                                }
                                            } else {
                                            # The capabilities string is the contract: only codes the
                                            # display advertises are read, and only those get controls.
                                            $caps = ''
                                            $len = [uint32]0
                                            if ([VentoNative.Ddc]::GetCapabilitiesStringLength($h, [ref]$len) -and $len -gt 1) {
                                                $sb = New-Object System.Text.StringBuilder ([int]$len)
                                                if ([VentoNative.Ddc]::CapabilitiesRequestAndCapabilitiesReply($h, $sb, $len)) { $caps = $sb.ToString() }
                                            }
                                            # Pull the balanced vcp(...) block, then every "XX" or
                                            # "XX(v v v)" token inside it.
                                            $allowed = @{}
                                            $vi = $caps.IndexOf('vcp(')
                                            if ($vi -ge 0) {
                                                $depth = 0; $st = $vi + 4; $en = -1
                                                for ($j = $vi + 3; $j -lt $caps.Length; $j++) {
                                                    if ($caps[$j] -eq '(') { $depth++ }
                                                    elseif ($caps[$j] -eq ')') { $depth--; if ($depth -eq 0) { $en = $j; break } }
                                                }
                                                if ($en -gt $st) {
                                                    $block = $caps.Substring($st, $en - $st)
                                                    foreach ($mm in [regex]::Matches($block, '([0-9A-Fa-f]{2})\s*(?:\(([^)]*)\))?')) {
                                                        $code = [Convert]::ToInt32($mm.Groups[1].Value, 16)
                                                        $vals = @()
                                                        if ($mm.Groups[2].Success) {
                                                            foreach ($tok in ($mm.Groups[2].Value -split '\s+')) {
                                                                if ($tok -match '^[0-9A-Fa-f]{1,2}$') { $vals += [Convert]::ToInt32($tok, 16) }
                                                            }
                                                        }
                                                        $allowed[$code] = $vals
                                                    }
                                                }
                                            }
                                            # colour preset (0x14): the allowed list has to come from
                                            # caps; there is no way to enumerate it over the wire.
                                            $v = & $readVcp 0x14
                                            if ($v) {
                                                $r.PreCur = $v[0]
                                                $codes = @()
                                                if ($allowed.ContainsKey(0x14)) { $codes = @($allowed[0x14]) }
                                                if ($codes.Count -eq 0) { $codes = @(1, 2, 5, 6, 8) }
                                                $r.Presets = $codes
                                            }
                                            # input source (0x60): only ever offer inputs the display
                                            # named, since landing on a dead one can black it out.
                                            if ($allowed.ContainsKey(0x60)) {
                                                $v = & $readVcp 0x60
                                                if ($v) {
                                                    $r.InCur = $v[0]
                                                    $ins = @($allowed[0x60])
                                                    if ($ins.Count -gt 1) { $r.Inputs = $ins }
                                                }
                                            }
                                            # speaker volume (0x62) + mute (0x8D)
                                            $v = & $probe 0x62
                                            if ($v) { $r.VolCur = $v[0]; $r.VolMax = $v[1] }
                                            $vMute = & $readVcp 0x8D
                                            if ($vMute -and $vMute[0] -ge 1 -and $vMute[0] -le 2) { $r.MuteCur = $vMute[0] }
                                            # A read that succeeds is not proof a control works: the
                                            # XG2705 answers sharpness reads and then drops every write.
                                            # So the writable controls are tried once - nudge by one,
                                            # read back, restore - and only offered if the value moved.
                                            $writable = {
                                                param($code, $cur, $max)
                                                if ($max -le 0) { return $false }
                                                $try = if ($cur -lt $max) { $cur + 1 } else { $cur - 1 }
                                                [void][VentoNative.Ddc]::SetVCPFeature($h, [byte]$code, [uint32]$try)
                                                Start-Sleep -Milliseconds 120
                                                $chk = & $readVcp $code
                                                $moved = ($chk -and [int]$chk[0] -eq $try)
                                                if ($moved) {
                                                    [void][VentoNative.Ddc]::SetVCPFeature($h, [byte]$code, [uint32]$cur)
                                                    Start-Sleep -Milliseconds 80
                                                }
                                                return $moved
                                            }
                                            # sharpness (0x87)
                                            $vSharp = & $probe 0x87
                                            if ($vSharp -and (& $writable 0x87 $vSharp[0] $vSharp[1])) { $r.SharpCur = $vSharp[0]; $r.SharpMax = $vSharp[1] }
                                            # video gain R/G/B (0x16 / 0x18 / 0x1A)
                                            $vr = & $probe 0x16; $vg = & $probe 0x18; $vb = & $probe 0x1A
                                            if ($vr -and $vg -and $vb) {
                                                $r.RCur = $vr[0]; $r.RMax = $vr[1]
                                                $r.GCur = $vg[0]; $r.GMax = $vg[1]
                                                $r.BCur = $vb[0]; $r.BMax = $vb[1]
                                            }
                                            # vertical frequency (0xAE), reported in 0.01 Hz
                                            $v = & $readVcp 0xAE
                                            if ($v) {
                                                $hz = [double]$v[0] / 100.0
                                                if ($hz -gt 20 -and $hz -lt 500) { $r.Hz = $hz }
                                            }
                                            # Power mode (0xD6). 0x04 is DPMS Off, which wakes as soon
                                            # as video returns; 0x05 is a real power-down that MCCS warns
                                            # "may require user intervention at the display" to undo. So
                                            # 0x04 wins whenever the display offers it.
                                            if ($allowed.ContainsKey(0xD6)) {
                                                $pv = @($allowed[0xD6])
                                                foreach ($cand in @(4, 3, 2, 5)) { if ($pv -contains $cand) { $r.PowerOff = $cand; break } }
                                                $r.PowerHard = ([int]$r.PowerOff -eq 5)
                                                $v = & $readVcp 0xD6
                                                if ($v) { $r.PowerCur = [int]$v[0] }
                                            }
                                            # Picture mode (0xDC) is offered only when the display can
                                            # report it back. A mode that can be written but never read
                                            # is unverifiable - on the XG2705 all eight writes changed
                                            # nothing measurable - and a control that may be doing
                                            # nothing has no place on the panel.
                                            if ($allowed.ContainsKey(0xDC)) {
                                                $v = & $readVcp 0xDC
                                                if ($v) {
                                                    $modes = @($allowed[0xDC])
                                                    if ($modes.Count -gt 1) { $r.Modes = $modes; $r.ModeCur = [int]$v[0] }
                                                }
                                            }
                                            # Colour temperature (0x0B/0x0C) is deliberately not offered.
                                            # Both displays here advertise it, accept the write and then
                                            # ignore it, reading back out-of-range values - a control that
                                            # does nothing is worse than no control. The colour preset
                                            # chips and the RGB gains cover the same ground and do work.
                                            if ($allowed.ContainsKey(0xB2)) {
                                                $v = & $readVcp 0xB2
                                                if ($v) {
                                                    $r.SubPixel = switch ([int]$v[0]) {
                                                        1 { 'RGB stripe' } 2 { 'RGB horizontal' } 3 { 'BGR stripe' }
                                                        4 { 'BGR horizontal' } 5 { 'quad pixel' } 6 { 'quad pixel' }
                                                        7 { 'delta triad' } 8 { 'mosaic' } default { '' }
                                                    }
                                                }
                                            }
                                            # Name, best source first: the model the display states in
                                            # its own capability string, then the EDID name Windows has,
                                            # then dxva2's generic description.
                                            if ($caps -match 'model\(([^)]+)\)') {
                                                $mdl = ([string]$Matches[1]).Trim()
                                                if ($mdl) { $r.Desc = $mdl }
                                            }
                                            if (($r.Desc -match '^Generic|^Default|^PnP' -or -not ([string]$r.Desc).Trim()) -and
                                                $slot -lt $edidNames.Count -and $edidNames[$slot]) {
                                                $r.Desc = $edidNames[$slot]
                                            }
                                            $r.HasColorReset   = $allowed.ContainsKey(0x08)
                                            $r.HasLevelReset   = $allowed.ContainsKey(0x05)
                                            $r.HasFactoryReset = $allowed.ContainsKey(0x04)
                                            # Read-only identity, for the panel's info line. Only
                                            # values that decode reliably are kept: the horizontal
                                            # frequency (0xAC) came back in vendor-scaled units on
                                            # real hardware, so it is not shown.
                                            if ($allowed.ContainsKey(0xB6)) {
                                                $v = & $readVcp 0xB6
                                                if ($v) {
                                                    $r.Tech = switch ([int]$v[0]) {
                                                        1 { 'CRT' } 2 { 'CRT' } 3 { 'LCD' } 4 { 'LCoS' }
                                                        5 { 'plasma' } 6 { 'OLED' } 7 { 'EL' } 8 { 'MEM' } default { '' }
                                                    }
                                                }
                                            }
                                            # Display usage time: hours live in the low 16 bits.
                                            if ($allowed.ContainsKey(0xC0)) {
                                                $v = & $readVcp 0xC0
                                                if ($v -and [int]$v[0] -gt 0) { $r.UsageHours = [int]$v[0] }
                                            }
                                            if ($allowed.ContainsKey(0xDF)) {
                                                $v = & $readVcp 0xDF
                                                # major in the high byte, minor in the low byte
                                                if ($v) { $r.Mccs = '{0}.{1}' -f ([int]$v[0] -shr 8), ([int]$v[0] -band 0xFF) }
                                            }
                                            # Memorise this discovery ONLY when it looks clean. An empty
                                            # caps string smells like a glitched read; and a control the
                                            # display ADVERTISED that then answered nothing during the
                                            # probe smells like a mid-probe fault (OSD menu open, I2C
                                            # glitch, display dropping to sleep) - caching either would
                                            # hide working controls for the whole session. A discovery
                                            # that is not cached still publishes normally for this open,
                                            # and the next Enum simply probes in full again - worst case
                                            # equals the pre-cache behavior, never less. (A display that
                                            # advertises a code and genuinely never answers it just never
                                            # gets cached: same outcome as no cache at all.)
                                            $suspect = ($allowed.ContainsKey(0x14) -and $null -eq $r.PreCur) -or
                                                       ($allowed.ContainsKey(0x60) -and $null -eq $r.InCur) -or
                                                       ($allowed.ContainsKey(0x62) -and $null -eq $r.VolCur) -or
                                                       ($allowed.ContainsKey(0x8D) -and $null -eq $vMute) -or
                                                       ($allowed.ContainsKey(0x87) -and $null -eq $vSharp) -or
                                                       (($allowed.ContainsKey(0x16) -or $allowed.ContainsKey(0x18) -or $allowed.ContainsKey(0x1A)) -and
                                                        ($null -eq $vr -or $null -eq $vg -or $null -eq $vb)) -or
                                                       (@($allowed[0xDC]).Count -gt 1 -and $null -eq $r.ModeCur)
                                            if ($caps -and -not $suspect) {
                                                $ddcCache[$ckey] = @{
                                                    Desc = [string]$r.Desc
                                                    HasPre = ($null -ne $r.PreCur); Presets = @($r.Presets)
                                                    Has60 = ($null -ne $r.InCur); Inputs = @($r.Inputs)
                                                    HasVol = ($null -ne $r.VolCur); HasMute = ($null -ne $r.MuteCur)
                                                    SharpOk = ($null -ne $r.SharpCur); HasRgb = ($null -ne $r.RCur)
                                                    PowerOff = $r.PowerOff; PowerHard = [bool]$r.PowerHard
                                                    Modes = @($r.Modes)
                                                    HasColorReset = [bool]$r.HasColorReset
                                                    HasLevelReset = [bool]$r.HasLevelReset
                                                    HasFactoryReset = [bool]$r.HasFactoryReset
                                                    Tech = [string]$r.Tech; SubPixel = [string]$r.SubPixel; Mccs = [string]$r.Mccs
                                                    HasC0 = ($null -ne $r.UsageHours)
                                                }
                                            }
                                            }
                                        }
                                        $mons += ,@{ H = $h; Ok = $r.Ok }
                                        $out += ,$r
                                        $slot++
                                    }
                                }
                                $sync.Ddc.Monitors = $out
                                $sync.Ddc.Busy = $false
                                $sync.Ddc.Gen++
                            }
                            default {
                                if ($mons.Count -eq 0) { break }
                                $idx = if ([int]$c.Mon -lt 0) { 0..($mons.Count - 1) } else { ,([int]$c.Mon) }
                                foreach ($i in $idx) {
                                    if ($i -lt 0 -or $i -ge $mons.Count -or -not $mons[$i].Ok) { continue }
                                    # Displays accept commands they then ignore, so every write is
                                    # read back. What the panel shows is what the display really
                                    # did, not what it was asked to do.
                                    $vcode = switch ([string]$c.Cmd) { 'SetBri' { 0x10 } 'SetCon' { 0x12 } default { [int]$c.Code } }
                                    switch ([string]$c.Cmd) {
                                        'SetBri' { [void][VentoNative.Ddc]::SetMonitorBrightness($mons[$i].H, [uint32][int]$c.Value) }
                                        'SetCon' { [void][VentoNative.Ddc]::SetMonitorContrast($mons[$i].H, [uint32][int]$c.Value) }
                                        'SetVcp' {
                                            # Hard deny-list, independent of whatever the UI asks for.
                                            # 0xE0-0xFF is the manufacturer-private range (service
                                            # menus, panel timings, even theft-deterrence PIN locks),
                                            # and 0x15/0x4D/0x4E/0x4F are VESA-reserved codes some
                                            # firmware squats on. Writing into either has bricked
                                            # displays in the wild, so Vento never does.
                                            $code = [int]$c.Code
                                            if ($code -lt 0xE0 -and @(0x15, 0x4D, 0x4E, 0x4F) -notcontains $code) {
                                                [void][VentoNative.Ddc]::SetVCPFeature($mons[$i].H, [byte]$code, [uint32][int]$c.Value)
                                            } else { $vcode = -1 }
                                        }
                                    }
                                    # Remember what to verify once the whole batch is out.
                                    if ($vcode -ge 0) { $verify['{0}:{1}' -f $i, $vcode] = @{ Mon = $i; Code = $vcode; Value = [int]$c.Value } }
                                }
                            }
                        }
                    } catch {
                        # A throw mid-Enum (e.g. a display yanked during a probe) must
                        # not leave Busy stuck true - that would wedge the panel on
                        # "Reading monitors..." and block the night schedule's re-enum.
                        $sync.Ddc.Busy = $false; $sync.Ddc.Gen++
                    }
                }
                # Verification happens once per batch, after every write in it
                # went out. Reading between writes would put ~120 ms of I2C
                # traffic between the two displays' updates; this way both get
                # their new value ~60 ms apart and the read-backs follow.
                foreach ($k in @($verify.Keys)) {
                    $v = $verify[$k]
                    $i = [int]$v.Mon; $vcode = [int]$v.Code
                    if ($i -ge @($sync.Ddc.Monitors).Count) { continue }
                    try {
                        $vt = [uint32]0; $vc = [uint32]0; $vm = [uint32]0
                        $rd = [VentoNative.Ddc]::GetVCPFeatureAndVCPFeatureReply($mons[$i].H, [byte]$vcode, [ref]$vt, [ref]$vc, [ref]$vm)
                        $snap = @($sync.Ddc.Monitors)[$i]
                        if ($rd) {
                            $actual = [int]$vc
                            switch ($vcode) {
                                0x10 { $snap.BriCur = $actual }
                                0x12 { $snap.ConCur = $actual }
                                0x14 { $snap.PreCur = $actual }
                                0x60 { $snap.InCur  = $actual }
                                0x62 { $snap.VolCur = $actual }
                                0x87 { $snap.SharpCur = $actual }
                                0x16 { $snap.RCur = $actual }
                                0x18 { $snap.GCur = $actual }
                                0x1A { $snap.BCur = $actual }
                            }
                            $sync.Ddc.LastWrite = @{ Mon = $i; Code = $vcode; Asked = [int]$v.Value; Actual = $actual
                                                     Took = ($actual -eq [int]$v.Value); Known = $true }
                        } else {
                            $sync.Ddc.LastWrite = @{ Mon = $i; Code = $vcode; Asked = [int]$v.Value; Actual = $null
                                                     Took = $true; Known = $false }
                        }
                        $sync.Ddc.WGen++
                    } catch { }
                }
            }
            # Idle poll: 15 ms keeps a dragged blade's next value from waiting
            # behind a long sleep; the CPU cost of an empty check is nil.
            Start-Sleep -Milliseconds 15
        }
    }
    finally {
        foreach ($p in $physSets) { try { [void][VentoNative.Ddc]::DestroyPhysicalMonitors([uint32]$p.N, $p.Arr) } catch { } }
    }
}
function Start-DdcWorker {
    if ($script:psDdc) { return }
    if (-not ('VentoNative.Ddc' -as [type])) { return }
    $script:ddcRunspace = [runspacefactory]::CreateRunspace()
    $script:ddcRunspace.Open()
    $script:psDdc = [powershell]::Create()
    $script:psDdc.Runspace = $script:ddcRunspace
    [void]$script:psDdc.AddScript($ddcWorker.ToString()).AddArgument($sync)
    [void]$script:psDdc.BeginInvoke()
}

# --- Windows notifications -------------------------------------------
# A tray balloon is the old mechanism: Windows 10 and 11 flash it for a few
# seconds and it never reaches the notification centre, so an update that
# lands while nobody is at the desk is simply missed. Vento posts a real
# toast instead - it survives in the Action Center, carries its own buttons,
# and respects Do Not Disturb. The balloon stays as the fallback for
# machines or policies where toasts refuse.
$script:toastAumid = 'Blakfy.Vento'
$script:toastReady = $null      # $null = not tried yet
$script:toastNotifier = $null
$script:toastKeep = @()         # keeps handlers alive until Windows is done

function Initialize-Toast {
    if ($null -ne $script:toastReady) { return $script:toastReady }
    $script:toastReady = $false
    try {
        # Toasts are attributed to an AppUserModelID. A desktop app registers
        # one under HKCU so notifications show "Vento" and its icon instead of
        # being dropped for an unknown sender.
        $key = Join-Path 'HKCU:\SOFTWARE\Classes\AppUserModelId' $script:toastAumid
        if (-not (Test-Path $key)) { [void](New-Item -Path $key -Force) }
        [void](New-ItemProperty -Path $key -Name 'DisplayName' -Value 'Vento' -PropertyType String -Force)
        $png = Join-Path $script:AppRoot 'assets\logo.png'
        if (Test-Path $png) { [void](New-ItemProperty -Path $key -Name 'IconUri' -Value $png -PropertyType String -Force) }
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $script:toastNotifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:toastAumid)
        $script:toastReady = ($null -ne $script:toastNotifier)
    } catch {
        $script:toastReady = $false
    }
    return $script:toastReady
}

# $Buttons: ordered @(@{ Text = 'Install now'; Arg = 'install' }, ...)
# $OnActivate: script block called on the UI thread with the chosen argument.
function Show-Toast([string]$Title, [string]$Body, [string]$Tag, $Buttons, $OnActivate) {
    # Notifications switched off in Alerts: report it as handled so callers
    # don't fall back to a tray balloon. The test button always goes through.
    if (-not [bool]$script:settings.toastsOn -and $Tag -ne 'vento-test') { return $true }
    if (-not (Initialize-Toast)) { return $false }
    try {
        $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
        $acts = ''
        foreach ($b in @($Buttons)) {
            $acts += '<action content="{0}" arguments="{1}" activationType="foreground"/>' -f
                     (& $esc $b.Text), (& $esc $b.Arg)
        }
        if ($acts) { $acts = '<actions>' + $acts + '</actions>' }
        $xmlStr = '<toast activationType="foreground" launch="open"><visual><binding template="ToastGeneric">' +
                  ('<text>{0}</text><text>{1}</text>' -f (& $esc $Title), (& $esc $Body)) +
                  '</binding></visual>' + $acts + '</toast>'
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($xmlStr)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        if ($Tag) { $toast.Tag = $Tag }
        if ($OnActivate) {
            $handler = {
                param($s0, $e0)
                $arg = 'open'
                try { if ($e0 -and $e0.Arguments) { $arg = [string]$e0.Arguments } } catch { }
                # Activation arrives on a WinRT thread; the UI is not ours to
                # touch from there.
                try { $window.Dispatcher.Invoke([action] { & $OnActivate $arg }) } catch { }
            }.GetNewClosure()
            # Add_Activated hands back a registration token; without [void] it
            # would ride out of the function alongside the return value.
            [void]$toast.Add_Activated($handler)
            $script:toastKeep += ,$handler
            if ($script:toastKeep.Count -gt 8) { $script:toastKeep = $script:toastKeep[-8..-1] }
        }
        $script:toastNotifier.Show($toast)
        return $true
    } catch {
        return $false
    }
}

# --- Window behaviour ------------------------------------------------
$script:reallyExit = $false
$script:trayTipShown = $false

function Show-Main {
    $script:shell.Show()
    $script:shell.WindowState = [System.Windows.WindowState]::Normal
    [void]$script:shell.Activate()
    if ($script:updateNotified) { Show-UpdateBanner }
}
function Hide-ToTray {
    $script:shell.Hide()
    if (-not $script:trayTipShown) {
        $script:trayTipShown = $true
        $script:lastBalloon = 'info'
        $script:notify.ShowBalloonTip(2500, 'Vento', $script:L.TrayStillHere, [System.Windows.Forms.ToolTipIcon]::Info)
    }
}
function Quit-App { $script:reallyExit = $true; $script:shell.Close() }

$el.TitleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$el.BtnMin.Add_Click({ Hide-ToTray })
$el.BtnClose.Add_Click({ $window.Close() })
$el.BtnQuiet.Add_Click({  Set-UserMode 'quiet' })
$el.BtnNormal.Add_Click({ Set-UserMode 'normal' })
$el.BtnPerf.Add_Click({   Set-UserMode 'performance' })
$el.BtnCurve.Add_Click({  Set-UserMode 'curve' })
$el.BtnAuto.Add_Click({   Set-UserMode 'auto' })

$script:shell.Add_Closing({ param($s, $e)
    if (-not $script:reallyExit) {
        if ($script:settings.closeToTray) { $e.Cancel = $true; Hide-ToTray; return }
        $script:reallyExit = $true
    }
})
$script:shell.Add_Closed({
    try { $window.Close() } catch { }
    if ($script:ownsApp) { $script:app.Shutdown() }
    elseif ($script:frame) { $script:frame.Continue = $false }
})
$script:shell.Add_StateChanged({
    if ($script:shell.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $script:shell.WindowState = [System.Windows.WindowState]::Normal
        Hide-ToTray
    }
})
$script:shell.Add_KeyDown({ param($s, $e)
    if ($e.Key -eq 'Escape') {
        # top of the z-order closes first: Pods is the last overlay in XAML
        if ($el.PodsOverlay.Visibility -eq 'Visible') { $el.PodsOverlay.Visibility = 'Collapsed' }
        elseif ($el.MonitorOverlay.Visibility -eq 'Visible') { $el.MonitorOverlay.Visibility = 'Collapsed' }
        elseif ($el.SettingsOverlay.Visibility -eq 'Visible') { $el.SettingsOverlay.Visibility = 'Collapsed' }
    }
})

# --- OSD overlay -----------------------------------------------------
# A second top-level window: click-through, no taskbar/Alt-Tab presence,
# never activated, always on top. Created lazily on first show and NEVER
# owned by the main window (its StateChanged/Hide-ToTray handling would
# drag the overlay along). Thermal brushes live in $window.Resources, so
# the OSD keeps a static dark look plus one accent bar painted each tick.
$script:osdShellXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Vento OSD" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ShowActivated="False" Topmost="True" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" Focusable="False" IsHitTestVisible="False"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Grid x:Name="OsdHost"/>
</Window>
'@

$script:osd = $null
$script:osdHost = $null
$script:osdVals = @{}         # metric id -> value TextBlock, updated each tick
$script:osdAccented = @()     # elements repainted when the thermal state moves
$script:osdThermoDot = $null  # thermo layout: @{ Dot; Host } for the blade position
$script:osdState = 'cool'
$script:osdHeroId = $null
$script:osdBrushCache = @{}

# Base palettes; the thermal state walks each theme's own cool/warm/hot accents.
$script:osdThemes = @{
    sirocco = @{ Acc = '#6FB1FF'; Acc2 = '#4C8DFF'; Warm = '#F5A45C'; Hot = '#F2606B'; Panel = '#DC0A0D13'; Border = '#26FFFFFF'; Ink = '#EDF1F8'; Lab = '#8FA3BC' }
    ember   = @{ Acc = '#FFB25C'; Acc2 = '#F08A3C'; Warm = '#FF8E4F'; Hot = '#F2606B'; Panel = '#DE130D09'; Border = '#38FFB25C'; Ink = '#F8F1E9'; Lab = '#BCA88F' }
    venom   = @{ Acc = '#7CF29B'; Acc2 = '#3FD374'; Warm = '#E8E060'; Hot = '#F2606B'; Panel = '#DE08100B'; Border = '#337CF29B'; Ink = '#EAF8EE'; Lab = '#8FBC9E' }
    violet  = @{ Acc = '#B18CFF'; Acc2 = '#8C5CF0'; Warm = '#F58CD0'; Hot = '#F2606B'; Panel = '#DE0E0A14'; Border = '#38B18CFF'; Ink = '#F2EDF8'; Lab = '#A393BC' }
    crimson = @{ Acc = '#FF6B7E'; Acc2 = '#E0405C'; Warm = '#FF8E4F'; Hot = '#FFB25C'; Panel = '#DE13090B'; Border = '#38FF6B7E'; Ink = '#F8EDEE'; Lab = '#BC8F97' }
    mono    = @{ Acc = '#FFFFFF'; Acc2 = '#C9D2DE'; Warm = '#FFFFFF'; Hot = '#F2606B'; Panel = '#D209090C'; Border = '#2EFFFFFF'; Ink = '#F2F4F7'; Lab = '#9AA3B0' }
}
# Display order; the first enabled metric is the "hero" (accent-colored, larger).
$script:osdMetricDef = @(
    @{ Id = 'fps';  Key = 'osdFps';     Col = 'osdColFps';  Lab = 'FPS' },
    @{ Id = 'cpu';  Key = 'osdCpu';     Col = 'osdColCpu';  Lab = 'CPU' },
    @{ Id = 'gpu';  Key = 'osdGpu';     Col = 'osdColGpu';  Lab = 'GPU' },
    @{ Id = 'load'; Key = 'osdGpuLoad'; Col = 'osdColLoad'; Lab = 'LOAD' },
    @{ Id = 'ram';  Key = 'osdRam';     Col = 'osdColRam';  Lab = 'RAM' },
    @{ Id = 'ssd';  Key = 'osdSsd';     Col = 'osdColSsd';  Lab = 'SSD' },
    @{ Id = 'mb';   Key = 'osdMb';      Col = 'osdColMb';   Lab = 'BOARD' },
    @{ Id = 'fan';  Key = 'osdFans';    Col = 'osdColFan';  Lab = 'FAN' },
    @{ Id = 'pods'; Key = 'osdPods';    Col = 'osdColPods'; Lab = 'PODS' }
)

function Get-OsdTheme {
    $t = $script:osdThemes[[string]$script:settings.osdTheme]
    if (-not $t) { $t = $script:osdThemes.sirocco }
    $t
}
function Get-OsdBrush([string]$hex) {
    if (-not $script:osdBrushCache.ContainsKey($hex)) {
        $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
        $b.Freeze()
        $script:osdBrushCache[$hex] = $b
    }
    $script:osdBrushCache[$hex]
}
function Get-OsdAccent($t) {
    switch ($script:osdState) { 'hot' { $t.Hot } 'warm' { $t.Warm } default { $t.Acc } }
}
function New-OsdGradient([string]$h1, [string]$h2, [bool]$vertical) {
    $g = New-Object System.Windows.Media.LinearGradientBrush
    $g.StartPoint = New-Object System.Windows.Point 0, 0
    $g.EndPoint = $(if ($vertical) { New-Object System.Windows.Point 0, 1 } else { New-Object System.Windows.Point 1, 0 })
    $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($h1)), 0))
    $g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($h2)), 1))
    $g.Freeze()
    $g
}
function New-OsdText([string]$text, [string]$hex, [double]$size, [string]$weight) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.Foreground = Get-OsdBrush $hex
    $tb.FontSize = $size
    $tb.FontWeight = $weight
    $tb.VerticalAlignment = 'Center'
    [System.Windows.Documents.Typography]::SetNumeralAlignment($tb, 'Tabular')
    $tb
}
function New-OsdShadow {
    $e = New-Object System.Windows.Media.Effects.DropShadowEffect
    $e.ShadowDepth = 1; $e.BlurRadius = 7; $e.Opacity = 0.85
    $e.Color = [System.Windows.Media.Colors]::Black
    $e
}
function New-OsdPanel($t, [double]$radius) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-OsdBrush $t.Panel
    $b.BorderBrush = Get-OsdBrush $t.Border
    $b.BorderThickness = New-Object System.Windows.Thickness 1
    $b.CornerRadius = New-Object System.Windows.CornerRadius $radius
    $b
}
# Value textblock for one metric: hero gets the accent (unless overridden) and a
# bigger size; a per-metric color override always wins and stays fixed.
function New-OsdVal($m, $t, [double]$size, [double]$heroSize) {
    $ov = [string]$script:settings[$m.Col]
    $isHero = ($m.Id -eq $script:osdHeroId)
    $hex = if ($ov) { $ov } elseif ($isHero) { Get-OsdAccent $t } else { $t.Ink }
    $tb = New-OsdText '--' $hex $(if ($isHero) { $heroSize } else { $size }) 'Bold'
    $script:osdVals[$m.Id] = $tb
    if (-not $ov -and $isHero) { $script:osdAccented += ,@{ El = $tb; Kind = 'fg' } }
    $tb
}

function Build-OsdContent {
    if (-not $script:osdHost) { return }
    $s = $script:settings
    $t = Get-OsdTheme
    $script:osdVals = @{}
    $script:osdAccented = @()
    $script:osdThermoDot = $null
    $ms = @($script:osdMetricDef | Where-Object { [bool]$s[$_.Key] })
    if (-not $ms.Count) { $ms = @($script:osdMetricDef[0]) }
    $script:osdHeroId = $ms[0].Id
    $acc = Get-OsdAccent $t
    $root = $null

    switch ([string]$s.osdLayout) {
        'strip' {
            # NOTE: WPF does not clamp CornerRadius; an oversized value warps the
            # border into an ellipse, so keep it at half the rendered height.
            $root = New-OsdPanel $t 16
            $root.Padding = New-Object System.Windows.Thickness 16, 8, 16, 8
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $first = $true
            foreach ($m in $ms) {
                if (-not $first) {
                    $sep = New-OsdText ([string][char]183) $t.Lab 12 'SemiBold'
                    $sep.Margin = New-Object System.Windows.Thickness 10, 0, 10, 0
                    $sep.Opacity = 0.55
                    [void]$sp.Children.Add($sep)
                }
                $first = $false
                $item = New-Object System.Windows.Controls.StackPanel
                $item.Orientation = 'Horizontal'
                if ($m.Id -eq $script:osdHeroId) {
                    [void]$item.Children.Add((New-OsdVal $m $t 12.5 16))
                    $lb = New-OsdText $m.Lab $t.Lab 9 'Bold'
                    $lb.Margin = New-Object System.Windows.Thickness 3, 0, 0, 0
                    [void]$item.Children.Add($lb)
                } else {
                    $lb = New-OsdText $m.Lab $t.Lab 9 'Bold'
                    $lb.Margin = New-Object System.Windows.Thickness 0, 0, 4, 0
                    [void]$item.Children.Add($lb)
                    [void]$item.Children.Add((New-OsdVal $m $t 12.5 16))
                }
                [void]$sp.Children.Add($item)
            }
            $root.Child = $sp
        }
        'hero' {
            $root = New-OsdPanel $t 10
            $root.Padding = New-Object System.Windows.Thickness 16, 12, 16, 11
            $col = New-Object System.Windows.Controls.StackPanel
            $big = New-Object System.Windows.Controls.StackPanel
            $big.Orientation = 'Horizontal'
            $big.HorizontalAlignment = 'Right'
            $hm = $ms[0]
            [void]$big.Children.Add((New-OsdVal $hm $t 12 34))
            $hl = New-OsdText $hm.Lab $t.Lab 10 'Bold'
            $hl.Margin = New-Object System.Windows.Thickness 5, 0, 0, 5
            $hl.VerticalAlignment = 'Bottom'
            [void]$big.Children.Add($hl)
            [void]$col.Children.Add($big)
            $rest = @($ms | Select-Object -Skip 1)
            if ($rest.Count) {
                $rule = New-Object System.Windows.Shapes.Rectangle
                $rule.Height = 1
                $rule.Margin = New-Object System.Windows.Thickness 0, 9, 0, 8
                $rule.Fill = New-OsdGradient ('#00' + $acc.TrimStart('#')) $acc $false
                $script:osdAccented += ,@{ El = $rule; Kind = 'rule' }
                [void]$col.Children.Add($rule)
                $minis = New-Object System.Windows.Controls.StackPanel
                $minis.Orientation = 'Horizontal'
                $minis.HorizontalAlignment = 'Right'
                $firstMini = $true
                foreach ($m in $rest) {
                    $item = New-Object System.Windows.Controls.StackPanel
                    $item.Orientation = 'Horizontal'
                    if (-not $firstMini) { $item.Margin = New-Object System.Windows.Thickness 13, 0, 0, 0 }
                    $firstMini = $false
                    $lb = New-OsdText $m.Lab $t.Lab 8.5 'Bold'
                    $lb.Margin = New-Object System.Windows.Thickness 0, 0, 3, 0
                    [void]$item.Children.Add($lb)
                    [void]$item.Children.Add((New-OsdVal $m $t 12 12))
                    [void]$minis.Children.Add($item)
                }
                [void]$col.Children.Add($minis)
            }
            $root.Child = $col
        }
        'pills' {
            $root = New-Object System.Windows.Controls.StackPanel
            $root.HorizontalAlignment = 'Right'
            $first = $true
            foreach ($m in $ms) {
                $pill = New-OsdPanel $t 13
                $pill.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5
                $pill.HorizontalAlignment = 'Right'
                if (-not $first) { $pill.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0 }
                $first = $false
                if ($m.Id -eq $script:osdHeroId) {
                    $pill.Background = Get-OsdBrush ('#38' + $acc.TrimStart('#'))
                    $pill.BorderBrush = Get-OsdBrush $acc
                    $script:osdAccented += ,@{ El = $pill; Kind = 'pill' }
                }
                $row = New-Object System.Windows.Controls.StackPanel
                $row.Orientation = 'Horizontal'
                $lb = New-OsdText $m.Lab $t.Lab 9 'Bold'
                $lb.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
                [void]$row.Children.Add($lb)
                [void]$row.Children.Add((New-OsdVal $m $t 14 15))
                $pill.Child = $row
                [void]$root.Children.Add($pill)
            }
        }
        'ghost' {
            $root = New-Object System.Windows.Controls.StackPanel
            $root.HorizontalAlignment = 'Right'
            $root.Effect = New-OsdShadow
            $hm = $ms[0]
            $big = New-Object System.Windows.Controls.StackPanel
            $big.Orientation = 'Horizontal'
            $big.HorizontalAlignment = 'Right'
            [void]$big.Children.Add((New-OsdVal $hm $t 12.5 26))
            $hl = New-OsdText $hm.Lab $t.Lab 10 'Bold'
            $hl.Opacity = 0.7
            $hl.Margin = New-Object System.Windows.Thickness 4, 0, 0, 3
            $hl.VerticalAlignment = 'Bottom'
            [void]$big.Children.Add($hl)
            [void]$root.Children.Add($big)
            $rest = @($ms | Select-Object -Skip 1)
            if ($rest.Count) {
                $row = New-Object System.Windows.Controls.StackPanel
                $row.Orientation = 'Horizontal'
                $row.HorizontalAlignment = 'Right'
                $row.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
                $firstR = $true
                foreach ($m in $rest) {
                    $item = New-Object System.Windows.Controls.StackPanel
                    $item.Orientation = 'Horizontal'
                    if (-not $firstR) { $item.Margin = New-Object System.Windows.Thickness 9, 0, 0, 0 }
                    $firstR = $false
                    $lb = New-OsdText $m.Lab $t.Lab 9 'Bold'
                    $lb.Opacity = 0.7
                    $lb.Margin = New-Object System.Windows.Thickness 0, 0, 3, 0
                    [void]$item.Children.Add($lb)
                    [void]$item.Children.Add((New-OsdVal $m $t 12.5 12.5))
                    [void]$row.Children.Add($item)
                }
                [void]$root.Children.Add($row)
            }
        }
        'micro' {
            $root = New-Object System.Windows.Controls.StackPanel
            $root.Orientation = 'Horizontal'
            $root.HorizontalAlignment = 'Right'
            $root.Opacity = 0.85
            $root.Effect = New-OsdShadow
            $first = $true
            foreach ($m in $ms) {
                $item = New-Object System.Windows.Controls.StackPanel
                $item.Orientation = 'Horizontal'
                if (-not $first) { $item.Margin = New-Object System.Windows.Thickness 9, 0, 0, 0 }
                [void]$item.Children.Add((New-OsdVal $m $t 13 13))
                if ($first) {
                    $lb = New-OsdText $m.Lab $t.Lab 8 'SemiBold'
                    $lb.Opacity = 0.55
                    $lb.Margin = New-Object System.Windows.Thickness 2, 0, 0, 0
                    [void]$item.Children.Add($lb)
                }
                $first = $false
                [void]$root.Children.Add($item)
            }
        }
        'thermo' {
            $root = New-OsdPanel $t 10
            $root.Padding = New-Object System.Windows.Thickness 10, 9, 13, 9
            $h = New-Object System.Windows.Controls.StackPanel
            $h.Orientation = 'Horizontal'
            $edge = New-Object System.Windows.Controls.Border
            $edge.Width = 7
            $edge.CornerRadius = New-Object System.Windows.CornerRadius 4
            $eg = New-Object System.Windows.Media.LinearGradientBrush
            $eg.StartPoint = New-Object System.Windows.Point 0, 0
            $eg.EndPoint = New-Object System.Windows.Point 0, 1
            $eg.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($t.Hot)), 0))
            $eg.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($t.Warm)), 0.45))
            $eg.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($t.Acc)), 1))
            $eg.Freeze()
            $edge.Background = $eg
            $edge.Margin = New-Object System.Windows.Thickness 0, 2, 10, 2
            $edgeGrid = New-Object System.Windows.Controls.Grid
            $dot = New-Object System.Windows.Shapes.Rectangle
            $dot.Width = 11; $dot.Height = 3
            $dot.RadiusX = 2; $dot.RadiusY = 2
            $dot.Fill = Get-OsdBrush '#FFFFFF'
            $dot.HorizontalAlignment = 'Center'
            $dot.VerticalAlignment = 'Top'
            $dot.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
            [void]$edgeGrid.Children.Add($dot)
            $edge.Child = $edgeGrid
            $script:osdThermoDot = @{ Dot = $dot; Host = $edgeGrid }
            [void]$h.Children.Add($edge)
            $col = New-Object System.Windows.Controls.StackPanel
            $firstRow = $true
            foreach ($m in $ms) {
                $row = New-Object System.Windows.Controls.Grid
                [void]$row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
                [void]$row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
                $row.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength 52
                $row.ColumnDefinitions[1].Width = [System.Windows.GridLength]::Auto
                if (-not $firstRow) { $row.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0 }
                $firstRow = $false
                $lb = New-OsdText $m.Lab $t.Lab 9 'Bold'
                [void]$row.Children.Add($lb)
                $tb = New-OsdVal $m $t 14 19
                [System.Windows.Controls.Grid]::SetColumn($tb, 1)
                [void]$row.Children.Add($tb)
                [void]$col.Children.Add($row)
            }
            [void]$h.Children.Add($col)
            $root.Child = $h
        }
        default {   # blade
            $root = New-OsdPanel $t 10
            $root.Padding = New-Object System.Windows.Thickness 12, 9, 12, 9
            $h = New-Object System.Windows.Controls.StackPanel
            $h.Orientation = 'Horizontal'
            $bar = New-Object System.Windows.Shapes.Rectangle
            $bar.Width = 3
            $bar.RadiusX = 1.5; $bar.RadiusY = 1.5
            $bar.Fill = New-OsdGradient $acc $t.Acc2 $true
            $bar.Margin = New-Object System.Windows.Thickness 0, 2, 9, 2
            $script:osdAccented += ,@{ El = $bar; Kind = 'bar' }
            [void]$h.Children.Add($bar)
            $col = New-Object System.Windows.Controls.StackPanel
            $firstRow = $true
            foreach ($m in $ms) {
                $row = New-Object System.Windows.Controls.Grid
                [void]$row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
                [void]$row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
                $row.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength 52
                $row.ColumnDefinitions[1].Width = [System.Windows.GridLength]::Auto
                if (-not $firstRow) { $row.Margin = New-Object System.Windows.Thickness 0, 3, 0, 0 }
                $firstRow = $false
                $lb = New-OsdText $m.Lab $t.Lab 9 'Bold'
                [void]$row.Children.Add($lb)
                $tb = New-OsdVal $m $t 14 19
                [System.Windows.Controls.Grid]::SetColumn($tb, 1)
                [void]$row.Children.Add($tb)
                [void]$col.Children.Add($row)
            }
            [void]$h.Children.Add($col)
            $root.Child = $h
        }
    }

    $fontDir = Join-Path $script:AppRoot 'fonts'
    $ff = New-Object System.Windows.Media.FontFamily(('file:///' + ($fontDir -replace '\\', '/') + '/#Sora, Segoe UI'))
    $root.SetValue([System.Windows.Documents.TextElement]::FontFamilyProperty, $ff)
    $k = [double]$s.osdScale / 100.0
    $root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $k, $k
    $script:osdHost.Children.Clear()
    [void]$script:osdHost.Children.Add($root)
}

# Repaint accent-bound elements after a thermal state change.
function Update-OsdAccent {
    $t = Get-OsdTheme
    $acc = Get-OsdAccent $t
    foreach ($a in $script:osdAccented) {
        switch ($a.Kind) {
            'fg'   { $a.El.Foreground = Get-OsdBrush $acc }
            'bar'  { $a.El.Fill = New-OsdGradient $acc $t.Acc2 $true }
            'rule' { $a.El.Fill = New-OsdGradient ('#00' + $acc.TrimStart('#')) $acc $false }
            'pill' { $a.El.Background = Get-OsdBrush ('#38' + $acc.TrimStart('#')); $a.El.BorderBrush = Get-OsdBrush $acc }
        }
    }
}

function New-Osd {
    $script:osd = [System.Windows.Markup.XamlReader]::Parse($script:osdShellXaml)
    $script:osdHost = $script:osd.FindName('OsdHost')
    $script:osd.Add_SourceInitialized({
        if (-not ('VentoNative.Osd' -as [type])) { return }
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:osd).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        # WS_EX_TRANSPARENT (0x20) + WS_EX_TOOLWINDOW (0x80) + WS_EX_NOACTIVATE (0x8000000)
        $ex = [long][VentoNative.Osd]::GetWindowLongPtr($h, -20)
        [void][VentoNative.Osd]::SetWindowLongPtr($h, -20, [IntPtr]($ex -bor 0x20 -bor 0x80 -bor 0x8000000))
        Set-OsdCapSafe   # apply the capture-hide state to the fresh handle
    })
    $script:osd.Add_SizeChanged({ Position-Osd })   # SizeToContent moves right/bottom anchors
    # Drag + wheel only bite in edit mode, when the click-through style is off.
    $script:osd.Add_MouseLeftButtonDown({
        if (-not $script:osdEditing) { return }
        try { $script:osd.DragMove() } catch { return }
        $script:settings.osdFree = $true
        $script:settings.osdX = [double]$script:osd.Left
        $script:settings.osdY = [double]$script:osd.Top
        $sync.Settings.osdFree = $true
        $script:saveTimer.Stop(); $script:saveTimer.Start()
    })
    $script:osd.Add_MouseWheel({ param($s0, $e0)
        if (-not $script:osdEditing) { return }
        $step = if ($e0.Delta -gt 0) { 5 } else { -5 }
        $script:settings.osdOpacity = [int](Limit ([int]$script:settings.osdOpacity + $step) 30 100)
        $script:osd.Opacity = $script:settings.osdOpacity / 100.0
        if ($el.SettingsOverlay.Visibility -eq 'Visible') { $el.S_OsdOpacity.Value = [double]$script:settings.osdOpacity }
        $script:saveTimer.Stop(); $script:saveTimer.Start()
    })
    $script:osd.Opacity = ([int]$script:settings.osdOpacity) / 100.0
    Build-OsdContent
}

# WDA_EXCLUDEFROMCAPTURE (0x11) keeps the window on screen but out of every
# screen grab, recorder and share surface - a streamer's temps never leak to
# the audience. It needs Windows 10 2004+; on older builds it fails and we fall
# back to WDA_MONITOR (0x1), which still hides the content (renders black in the
# capture). WDA_NONE (0) restores normal capturing. Best-effort: a failure just
# means the overlay stays visible in captures, never a crash.
function Set-OsdCapSafe {
    if (-not $script:osd -or -not ('VentoNative.Osd' -as [type])) { return }
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:osd).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        if ([bool]$script:settings.osdCapSafe) {
            $ok = [VentoNative.Osd]::SetWindowDisplayAffinity($h, [uint32]0x11)
            if (-not $ok) { [void][VentoNative.Osd]::SetWindowDisplayAffinity($h, [uint32]0x1) }
        } else {
            [void][VentoNative.Osd]::SetWindowDisplayAffinity($h, [uint32]0x0)
        }
    } catch { }
}

function Update-OsdLayout {
    if (-not $script:osd) { return }
    Build-OsdContent
    $script:osd.Opacity = ([int]$script:settings.osdOpacity) / 100.0
    Set-OsdCapSafe
    Position-Osd
}

function Position-Osd {
    if (-not $script:osd -or -not $script:osd.IsVisible) { return }
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen
    if ([bool]$script:settings.osdOnSecondary) {
        $alt = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
        if ($alt) { $scr = $alt }
    }
    # Screen.WorkingArea is physical pixels; window Left/Top are DIPs.
    $k = 1.0
    $src = [System.Windows.PresentationSource]::FromVisual($script:osd)
    if ($src) { $k = $src.CompositionTarget.TransformFromDevice.M11 }
    $wa = $scr.WorkingArea
    $L = $wa.Left * $k; $T = $wa.Top * $k; $R = $wa.Right * $k; $B = $wa.Bottom * $k
    $w = $script:osd.ActualWidth; $h = $script:osd.ActualHeight; $m = 12
    # A dragged overlay stays where the user parked it, clamped so at least
    # a grabbable sliver is always on some screen.
    if ([bool]$script:settings.osdFree) {
        $va = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $vL = $va.Left * $k; $vT = $va.Top * $k
        $vR = ($va.Left + $va.Width) * $k; $vB = ($va.Top + $va.Height) * $k
        $script:osd.Left = [math]::Min([math]::Max([double]$script:settings.osdX, $vL - $w + 60), $vR - 60)
        $script:osd.Top  = [math]::Min([math]::Max([double]$script:settings.osdY, $vT), $vB - 40)
        return
    }
    switch ([string]$script:settings.osdCorner) {
        'tl' { $script:osd.Left = $L + $m;      $script:osd.Top = $T + $m }
        'bl' { $script:osd.Left = $L + $m;      $script:osd.Top = $B - $h - $m }
        'br' { $script:osd.Left = $R - $w - $m; $script:osd.Top = $B - $h - $m }
        default { $script:osd.Left = $R - $w - $m; $script:osd.Top = $T + $m }   # 'tr'
    }
}

function Show-Osd {
    if (-not $script:osd) {
        try { New-Osd; $script:osdFail = 0 } catch {
            $script:osd = $null
            # The tick retries this every 500ms forever; an overlay that never
            # comes up should say why somewhere. First failure and then one
            # per ~minute go to error.log, so the file can't balloon either.
            $script:osdFail = [int]$script:osdFail + 1
            if ($script:osdFail -eq 1 -or ($script:osdFail % 120) -eq 0) {
                try {
                    ('{0:yyyy-MM-dd HH:mm:ss} overlay create failed (try #{1}): {2}' -f [DateTime]::Now, $script:osdFail, $_) |
                        Out-File -FilePath (Join-Path $script:AppRoot 'error.log') -Encoding utf8 -Append
                } catch { }
            }
            return
        }
    }
    if (-not $script:osd.IsVisible) { $script:osd.Show(); $script:osd.UpdateLayout(); Position-Osd }
}
# The FPS tracer is started once, the first time an FPS-enabled overlay needs
# it, and kept alive for the session so it survives across game launches. If
# the ETW session can't start (another tracer holds all 8 slots, or an
# anti-cheat blocked it), FPS quietly reads "--".
$script:fpsTried = $false
$script:fpsOn = $false
function Ensure-FpsTracer {
    if ($script:fpsTried) { return }
    $script:fpsTried = $true
    if (-not ('VentoNative.Fps' -as [type])) { return }
    try { $script:fpsOn = ([VentoNative.Fps]::Start('Vento-PresentTrace') -eq 0) } catch { $script:fpsOn = $false }
}
function Stop-FpsTracer {
    if ($script:fpsOn -and ('VentoNative.Fps' -as [type])) { try { [VentoNative.Fps]::Stop() } catch { } }
    $script:fpsOn = $false
}
function Hide-Osd { if ($script:osd -and $script:osd.IsVisible) { $script:osd.Hide() } }
function Close-Osd { if ($script:osd) { try { Set-OsdEdit $false } catch { }; try { $script:osd.Close() } catch { }; $script:osd = $null } }

# --- OSD edit mode ---------------------------------------------------
# The overlay's own controls live on the overlay: unlock it and it grows a
# dashed frame, drags with the mouse, and the wheel sets its opacity. Lock
# it and the click-through style comes back.
$script:osdEditing = $false
$script:osdEditChrome = $null
function Set-OsdEdit([bool]$on) {
    if ($on -eq $script:osdEditing) { return }
    $script:osdEditing = $on
    if ($on) { Hide-OsdPin; Show-Osd }
    if (-not $script:osd) { $script:osdEditing = $false; return }
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:osd).Handle
    if ($h -ne [IntPtr]::Zero -and ('VentoNative.Osd' -as [type])) {
        $ex = [long][VentoNative.Osd]::GetWindowLongPtr($h, -20)
        # WS_EX_TRANSPARENT (0x20) off while editing so the mouse lands here.
        $ex = if ($on) { $ex -band (-bnot 0x20) } else { $ex -bor 0x20 }
        [void][VentoNative.Osd]::SetWindowLongPtr($h, -20, [IntPtr]$ex)
    }
    $script:osd.IsHitTestVisible = $on
    if ($on) {
        $chrome = New-Object System.Windows.Controls.Grid
        $frame = New-Object System.Windows.Controls.Border
        $frame.BorderThickness = New-Object System.Windows.Thickness 1.5
        $bb = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#B06FB1FF'))
        $bb.Freeze()
        $frame.BorderBrush = $bb
        $frame.CornerRadius = New-Object System.Windows.CornerRadius 12
        $frame.IsHitTestVisible = $false
        [void]$chrome.Children.Add($frame)
        # DONE pill, top-right over the content
        $pill = New-Object System.Windows.Controls.Border
        $pill.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#F06FB1FF'))
        $pill.CornerRadius = New-Object System.Windows.CornerRadius 9
        $pill.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
        $pill.HorizontalAlignment = 'Right'; $pill.VerticalAlignment = 'Top'
        $pill.Margin = New-Object System.Windows.Thickness 0, 6, 6, 0
        $pill.Cursor = [System.Windows.Input.Cursors]::Hand
        $pt = New-Object System.Windows.Controls.TextBlock
        $pt.Text = [string][char]0x2713 + ' DONE'
        $pt.FontSize = 11; $pt.FontWeight = 'Bold'
        $pt.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#0B0E14'))
        $pill.Child = $pt
        $pill.Add_MouseLeftButtonDown({ param($s0, $e0) $e0.Handled = $true; Set-OsdEdit $false })
        [void]$chrome.Children.Add($pill)
        $hint = New-Object System.Windows.Controls.Border
        $hint.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#D00A0E14'))
        $hint.CornerRadius = New-Object System.Windows.CornerRadius 8
        $hint.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
        $hint.HorizontalAlignment = 'Center'; $hint.VerticalAlignment = 'Bottom'
        $hint.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
        $hint.IsHitTestVisible = $false
        $ht = New-Object System.Windows.Controls.TextBlock
        $ht.Text = 'drag to move  {0}  wheel = opacity' -f $script:mid
        $ht.FontSize = 10
        $ht.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#C9D2E2'))
        $hint.Child = $ht
        [void]$chrome.Children.Add($hint)
        $script:osdEditChrome = $chrome
        [void]$script:osdHost.Children.Add($chrome)
    } else {
        if ($script:osdEditChrome) {
            try { $script:osdHost.Children.Remove($script:osdEditChrome) } catch { }
            $script:osdEditChrome = $null
        }
        $script:saveTimer.Stop(); $script:saveTimer.Start()
    }
    if ($script:miOsdMove) { $script:miOsdMove.Text = $(if ($on) { 'Lock overlay' } else { 'Move overlay' }) }
}

# --- Hover pin -------------------------------------------------------
# A locked overlay cannot take a click, so the tick watches the OS cursor
# instead: rest the mouse on the HUD and a small pin fades in (the window
# turns clickable just for that moment); the pin opens edit mode. Games
# hide or capture the cursor, so this never triggers mid-game.
$script:osdPin = $null
$script:osdHoverTicks = 0
$script:osdAwayTicks = 0
function Show-OsdPin {
    if ($script:osdPin -or -not $script:osd) { return }
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:osd).Handle
    if ($h -ne [IntPtr]::Zero -and ('VentoNative.Osd' -as [type])) {
        $ex = [long][VentoNative.Osd]::GetWindowLongPtr($h, -20)
        [void][VentoNative.Osd]::SetWindowLongPtr($h, -20, [IntPtr]($ex -band (-bnot 0x20)))
    }
    $script:osd.IsHitTestVisible = $true
    # Only the pin itself takes hits; the readout stays inert.
    if ($script:osdHost.Children.Count -gt 0) { $script:osdHost.Children[0].IsHitTestVisible = $false }
    $pin = New-Object System.Windows.Controls.Border
    $pin.Width = 26; $pin.Height = 26
    $pin.CornerRadius = New-Object System.Windows.CornerRadius 13
    $pin.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E8101720'))
    $pin.BorderThickness = New-Object System.Windows.Thickness 1
    $pin.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#B06FB1FF'))
    $pin.HorizontalAlignment = 'Right'; $pin.VerticalAlignment = 'Top'
    $pin.Margin = New-Object System.Windows.Thickness 0, 4, 4, 0
    $pin.Cursor = [System.Windows.Input.Cursors]::Hand
    $pin.ToolTip = 'Move or fade the overlay'
    $g = New-Object System.Windows.Controls.TextBlock
    $g.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
    $g.FontSize = 12
    $g.Text = [string][char]0xE718
    $g.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#6FB1FF'))
    $g.HorizontalAlignment = 'Center'; $g.VerticalAlignment = 'Center'
    $pin.Child = $g
    $pin.Add_MouseLeftButtonDown({ param($s0, $e0)
        $e0.Handled = $true
        Hide-OsdPin
        Set-OsdEdit $true
    })
    $script:osdPin = $pin
    [void]$script:osdHost.Children.Add($pin)
}
function Hide-OsdPin {
    if (-not $script:osdPin) { return }
    try { $script:osdHost.Children.Remove($script:osdPin) } catch { }
    $script:osdPin = $null
    if ($script:osdHost.Children.Count -gt 0) { $script:osdHost.Children[0].IsHitTestVisible = $true }
    if ($script:osdEditing) { return }   # edit mode keeps the window clickable
    if ($script:osd) {
        $script:osd.IsHitTestVisible = $false
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:osd).Handle
        if ($h -ne [IntPtr]::Zero -and ('VentoNative.Osd' -as [type])) {
            $ex = [long][VentoNative.Osd]::GetWindowLongPtr($h, -20)
            [void][VentoNative.Osd]::SetWindowLongPtr($h, -20, [IntPtr]($ex -bor 0x20))
        }
    }
}
function Update-OsdHover {
    if (-not $script:osd -or -not $script:osd.IsVisible -or $script:osdEditing) {
        if ($script:osdPin) { Hide-OsdPin }
        $script:osdHoverTicks = 0
        return
    }
    $over = $false
    try {
        $p = [System.Windows.Forms.Control]::MousePosition
        $src = [System.Windows.PresentationSource]::FromVisual($script:osd)
        if ($src) {
            $kd = $src.CompositionTarget.TransformToDevice.M11
            $x0 = $script:osd.Left * $kd; $y0 = $script:osd.Top * $kd
            $x1 = $x0 + $script:osd.ActualWidth * $kd; $y1 = $y0 + $script:osd.ActualHeight * $kd
            $over = ($p.X -ge $x0 -and $p.X -le $x1 -and $p.Y -ge $y0 -and $p.Y -le $y1)
        }
    } catch { }
    if ($over) {
        $script:osdHoverTicks++
        $script:osdAwayTicks = 0
        if ($script:osdHoverTicks -ge 2 -and -not $script:osdPin) { Show-OsdPin }
    } else {
        $script:osdHoverTicks = 0
        if ($script:osdPin) {
            $script:osdAwayTicks++
            if ($script:osdAwayTicks -ge 2) { Hide-OsdPin }
        }
    }
}

# --- Tray menu -------------------------------------------------------
$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = New-TrayIcon '#6FB1FF'
$script:notify.Text = 'Vento'
$script:notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add($script:L.TrayOpen)
$miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
$miOpen.add_Click({ Show-Main })
[void]$menu.Items.Add('-')
$script:trayMode = @{}
foreach ($m in 'quiet','normal','performance','curve','auto') {
    $mi = $menu.Items.Add($script:modeNames[$m])
    $mi.Tag = $m   # carried on the item - see the swatch note about closures
    $script:trayMode[$m] = $mi
    $mi.add_Click({ param($s, $e) Set-UserMode ([string]$s.Tag) })
}
[void]$menu.Items.Add('-')
$script:trayProfileMenu = New-Object System.Windows.Forms.ToolStripMenuItem 'Profiles'
[void]$menu.Items.Add($script:trayProfileMenu)
Update-TrayProfiles
try { Update-GlassProfiles } catch { }
[void]$menu.Items.Add('-')
$script:miOsd = $menu.Items.Add('Overlay (OSD)')
$script:osdModePrev = $null
$script:miOsd.add_Click({ Toggle-Overlay })
$script:miOsdMove = $menu.Items.Add('Move overlay')
$script:miOsdMove.add_Click({ Set-OsdEdit (-not $script:osdEditing) })
# Opens Settings on the About row and checks right away; the row says the result.
$script:miCheckUpd = $menu.Items.Add('Check for updates')
$script:miCheckUpd.add_Click({ Show-Main; (G 'NavSettings').IsChecked = $true; Request-GUpdateCheck })
$script:miUpdate = $menu.Items.Add('Install update')
$script:miUpdate.Visible = $false
$script:miUpdate.add_Click({ Install-Update })
$miExit = $menu.Items.Add($script:L.TrayExit)
$miExit.add_Click({ Quit-App })
$script:notify.ContextMenuStrip = $menu
$script:notify.add_MouseClick({ param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-GFlyout }
})
$script:notify.add_BalloonTipClicked({
    if ($script:lastBalloon -eq 'update' -and $sync.Update) { Start-Process $sync.Update.Url }
})

Init-Sirocco
Update-ModePanel ([string]$sync.Data.ActiveMode)
# Bind global hotkeys now the window (and its handle) exist. Any the OS refuses
# are simply skipped; the settings panel reports them when the user next saves.
[void](Register-Hotkeys)

# --- Update check (GitHub releases, once per launch) -----------------
$script:psUpd = $null
$script:updRunspace = $null
# Once per launch when enabled, and on demand (Settings > Check for updates,
# the tray). $sync.UpdChecked flips when a pass ends, found or not.
$script:updAr = $null
function Start-UpdateCheck {
    if (-not $script:settings.updateRepo) { return }
    if ($script:updAr -and -not $script:updAr.IsCompleted) { return }
    if ($script:psUpd) { try { $script:psUpd.Dispose(); $script:updRunspace.Dispose() } catch { } }
    $sync.UpdChecked = $false; $sync.UpdFailed = $false
    $updWorker = {
        param($sync, $repo, $current)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $r = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $repo) -Headers @{ 'User-Agent' = 'Vento' } -TimeoutSec 15
            $latest = ([string]$r.tag_name).TrimStart('v').TrimStart('V')
            if ([version]$latest -gt [version]$current) {
                $asset = $r.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1
                # SHA256SUMS.txt (added in 1.6.2) lets the download be verified
                # before it runs. Best-effort: if it is missing or unreadable
                # the update still proceeds, it just isn't hash-checked.
                $sha = $null
                if ($asset) {
                    $sumAsset = $r.assets | Where-Object { $_.name -match 'SHA256|\.sha256$' } | Select-Object -First 1
                    if ($sumAsset) {
                        try {
                            $txt = (Invoke-WebRequest -Uri $sumAsset.browser_download_url -Headers @{ 'User-Agent' = 'Vento' } -UseBasicParsing -TimeoutSec 15).Content
                            foreach ($line in ($txt -split "`n")) {
                                if ($line -match ('([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($asset.name))) { $sha = $Matches[1].ToLower(); break }
                            }
                        } catch { }
                    }
                }
                $sync.Update = @{
                    Version   = $latest
                    Url       = [string]$r.html_url
                    AssetUrl  = $(if ($asset) { [string]$asset.browser_download_url } else { $null })
                    AssetName = $(if ($asset) { [string]$asset.name } else { $null })
                    Sha256    = $sha
                }
            }
        } catch { $sync.UpdFailed = $true }
        $sync.UpdChecked = $true
    }
    $script:updRunspace = [runspacefactory]::CreateRunspace()
    $script:updRunspace.Open()
    $script:psUpd = [powershell]::Create()
    $script:psUpd.Runspace = $script:updRunspace
    [void]$script:psUpd.AddScript($updWorker.ToString()).AddArgument($sync).AddArgument($script:settings.updateRepo).AddArgument($script:AppVersion)
    $script:updAr = $script:psUpd.BeginInvoke()
}
if ($script:settings.checkUpdates -and $script:settings.updateRepo) { Start-UpdateCheck }

# --- UI refresh timer ------------------------------------------------
$script:histCpu = New-Object 'System.Collections.Generic.List[double]'
$script:histGpu = New-Object 'System.Collections.Generic.List[double]'
$script:histSsd = New-Object 'System.Collections.Generic.List[double]'
$script:histMb  = New-Object 'System.Collections.Generic.List[double]'
$script:histFanCpu  = New-Object 'System.Collections.Generic.List[double]'
$script:histFanCase = New-Object 'System.Collections.Generic.List[double]'
$script:histTick = 0
$script:fanMax = 864.0
function Update-Spark($list, $poly, $box, $fillPoly = $null) {
    # maps 20..100 deg C onto the host box, newest sample at the right edge
    if ($list.Count -lt 2) { return }
    $w = $box.ActualWidth; $h = $box.ActualHeight
    if ($w -lt 10 -or $h -lt 5) { return }
    $pc = New-Object System.Windows.Media.PointCollection
    $n = $list.Count
    for ($i = 0; $i -lt $n; $i++) {
        $t = [math]::Min([math]::Max($list[$i], 20), 100)
        $x = $i * ($w / ($n - 1))
        $y = $h - (($t - 20) / 80 * $h)
        $pc.Add([System.Windows.Point]::new($x, $y))
    }
    $poly.Points = $pc
    if ($fillPoly) {
        # same trace closed down to the bottom edge = gradient area fill
        $fpc = New-Object System.Windows.Media.PointCollection
        foreach ($p in $pc) { $fpc.Add($p) }
        $fpc.Add([System.Windows.Point]::new($w, $h))
        $fpc.Add([System.Windows.Point]::new(0, $h))
        $fillPoly.Points = $fpc
    }
}

function Update-FanSpark($list, $poly, $box, [double]$maxV, $fillPoly = $null) {
    # maps 0..maxV RPM onto the host box, newest sample at the right edge.
    # Long histories are decimated to ~400 drawn points; the newest sample
    # is always drawn so the right edge stays live.
    if ($list.Count -lt 2) { return }
    $w = $box.ActualWidth; $h = $box.ActualHeight
    if ($w -lt 10 -or $h -lt 5) { return }
    if ($maxV -lt 1) { $maxV = 1 }
    $pc = New-Object System.Windows.Media.PointCollection
    $n = $list.Count
    $step = [int][math]::Ceiling($n / 400.0)
    $xs = $w / ($n - 1)
    for ($i = 0; $i -lt $n; $i += $step) {
        $y = ($h - 1) - ([math]::Min($list[$i], $maxV) / $maxV * ($h - 2))
        $pc.Add([System.Windows.Point]::new($i * $xs, $y))
    }
    $yLast = ($h - 1) - ([math]::Min($list[$n - 1], $maxV) / $maxV * ($h - 2))
    $pc.Add([System.Windows.Point]::new($w, $yLast))
    $poly.Points = $pc
    if ($fillPoly) {
        $fpc = New-Object System.Windows.Media.PointCollection
        foreach ($p in $pc) { $fpc.Add($p) }
        $fpc.Add([System.Windows.Point]::new($w, $h))
        $fpc.Add([System.Windows.Point]::new(0, $h))
        $fillPoly.Points = $fpc
    }
}

function Update-WarnFlag([string]$p, [double]$m) {
    # over its threshold: show the "+N deg" chip and let the value wear the
    # thermal accent; otherwise plain ink and no chip
    if ($m -gt 0) {
        $el["${p}WarnText"].Text = '+{0:0.#}{1}' -f $m, $script:deg
        $el["${p}WarnFlag"].Visibility = 'Visible'
        $el["${p}TempVal"].Foreground = $script:brushAccentB
    } else {
        $el["${p}WarnFlag"].Visibility = 'Collapsed'
        $el["${p}TempVal"].Foreground = $script:brushInk
    }
}

# Hardware model strings arrive as marketing names too wide for the cards
# ("NVIDIA GeForce RTX 2060", "Samsung SSD 980 PRO 1TB"). Drop the noise
# the card already implies, keep the full name reachable as a tooltip.
function Set-ModelLabel($tb, [string]$raw) {
    $n = $raw -replace '\((R|TM|C)\)', ''
    $n = $n -replace '^\s*(NVIDIA|AMD|Intel)\s+', ''
    $n = $n -replace '^GeForce\s+(?=[RG]TX?\s)', ''
    $n = $n -replace '^Samsung SSD\s+', 'Samsung '
    $n = $n -replace '\s+\d+-Core Processor\s*$', ''
    $n = $n -replace '\s+(CPU|Processor)\s*$', ''
    $n = ($n -replace '\s{2,}', ' ').Trim()
    if (-not $n) { $n = $raw }
    if ($tb.Text -ne $n) { $tb.Text = $n; $tb.ToolTip = $raw }
}

$script:lastWarn = $null
$script:lastTickErr = $null
$script:lastBalloon = $null
$script:updateNotified = $false
$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:timer.Add_Tick({
    # a second launch asked us to come forward
    if ($script:showMe.WaitOne(0)) { Show-Main }
    if ($sync.Status -eq 'error') {
        $script:timer.Stop()
        [void][System.Windows.MessageBox]::Show($script:L.SensorFail, 'Vento', 'OK', 'Error')
        Quit-App
        return
    }
    if ($sync.SetupFile -and -not $script:pendingSetup) {
        # update downloaded: exit and let the finally block run the installer
        $script:pendingSetup = $sync.SetupFile
        Quit-App
        return
    }
    $d = $sync.Data

    if ($null -ne $d.CpuName) { Set-ModelLabel $el.CpuNameText $d.CpuName }
    if ($null -ne $d.GpuName) { Set-ModelLabel $el.GpuNameText $d.GpuName }

    # unit is a separate small RPM label in the XAML now
    $el.CpuFanVal.Text  = if ($null -ne $d.CpuFan)  { '{0}' -f $d.CpuFan }  else { '--' }
    $el.CaseFanVal.Text = if ($null -ne $d.CaseFan) { '{0}' -f $d.CaseFan } else { '--' }
    if (($null -ne $d.GpuFan1) -and ($null -ne $d.GpuFan2)) {
        $el.GpuFanVal.Text = '{0} / {1}' -f $d.GpuFan1, $d.GpuFan2
    } elseif ($null -ne $d.GpuFan1) {
        $el.GpuFanVal.Text = '{0}' -f $d.GpuFan1
    } else {
        $el.GpuFanVal.Text = '--'
    }

    # rotor icons spin at the real fan speed; rails show RPM headroom
    Set-RotorSpeed 'RotorCpu' $d.CpuFan
    Set-RotorSpeed 'RotorCase' $d.CaseFan
    Set-RotorSpeed 'RotorGpu' $d.GpuFan1
    if ($el.CpuFanRailTrack.ActualWidth -gt 0) {
        $cw = if ($null -ne $d.CpuFan)  { [math]::Min(1.0, $d.CpuFan / 2000.0) }  else { 0 }
        $kw = if ($null -ne $d.CaseFan) { [math]::Min(1.0, $d.CaseFan / 2000.0) } else { 0 }
        $gw = if ($null -ne $d.GpuFan1) { [math]::Min(1.0, $d.GpuFan1 / 3200.0) } else { 0 }
        $el.CpuFanRail.Width  = $el.CpuFanRailTrack.ActualWidth * $cw
        $el.CaseFanRail.Width = $el.CaseFanRailTrack.ActualWidth * $kw
        $el.GpuFanRail.Width  = $el.GpuFanRailTrack.ActualWidth * $gw
    }

    if ($null -ne $d.CpuTemp) {
        $el.CpuTempVal.Text = '{0}' -f [int]$d.CpuTemp
        Update-WarnFlag 'Cpu' ($d.CpuTemp - $script:settings.warnCpu)
    } else { $el.CpuTempVal.Text = '--'; Update-WarnFlag 'Cpu' -99 }

    if ($null -ne $d.GpuTemp) {
        $el.GpuTempVal.Text = '{0}' -f [int]$d.GpuTemp
        Update-WarnFlag 'Gpu' ($d.GpuTemp - $script:settings.warnGpu)
    } else { $el.GpuTempVal.Text = '--'; Update-WarnFlag 'Gpu' -99 }

    if ($null -ne $d.SsdName) { Set-ModelLabel $el.SsdNameText $d.SsdName }
    if ($null -ne $d.MbName)  { Set-ModelLabel $el.MbNameText  $d.MbName }

    # These two sensors can legitimately vanish mid-run (drive unplugged,
    # SuperIO diode going implausible), so '--' also clears the value color
    # and empties the bar instead of freezing them at the last reading.
    if ($null -ne $d.SsdTemp) {
        $el.SsdTempVal.Text = '{0}' -f [int]$d.SsdTemp
        Update-WarnFlag 'Ssd' ($d.SsdTemp - $script:settings.warnSsd)
    } else { $el.SsdTempVal.Text = '--'; Update-WarnFlag 'Ssd' -99 }

    if ($null -ne $d.MbTemp) {
        $el.MbTempVal.Text = '{0}' -f [int]$d.MbTemp
        Update-WarnFlag 'Mb' ($d.MbTemp - $script:settings.warnMb)
    } else { $el.MbTempVal.Text = '--'; Update-WarnFlag 'Mb' -99 }

    # Sirocco: thermal position = the hottest sensor's distance to its own
    # warning threshold; it drives the palette, the halo and the hero copy
    $margin = -20.0; $hotName = $null; $hotVal = $null
    foreach ($probe in @(
        @($d.CpuTemp, $script:settings.warnCpu, 'CPU'), @($d.GpuTemp, $script:settings.warnGpu, 'GPU'),
        @($d.SsdTemp, $script:settings.warnSsd, 'SSD'), @($d.MbTemp, $script:settings.warnMb, 'BOARD'))) {
        if ($null -ne $probe[0]) {
            $m = [double]$probe[0] - $probe[1]
            if ($m -gt $margin) { $margin = $m; $hotName = $probe[2]; $hotVal = $probe[0] }
        }
    }
    if ($null -ne $hotName) {
        Apply-Thermal (Get-ThermalMix $margin)
        $el.OrbVal.Text = '{0}{1}' -f [int]$hotVal, $script:deg
        $el.OrbLabel.Text = ($hotName.ToCharArray() -join $script:thin)
        if ($margin -le -4) {
            $el.HeroTitle.Text = 'System cool'
            $el.HeroSub.Text = 'all sensors comfortably under target'
        } elseif ($margin -le 0) {
            $el.HeroTitle.Text = '{0} nearing target' -f $hotName
            $el.HeroSub.Text = '{0:0.#}{1} below its comfort target' -f (-$margin), $script:deg
        } elseif ($margin -le 4) {
            $el.HeroTitle.Text = '{0} running warm' -f $hotName
            $el.HeroSub.Text = '{0:0.#}{1} over its comfort target {2} fans compensating' -f $margin, $script:deg, $script:mid
        } else {
            $el.HeroTitle.Text = 'Running hot'
            $el.HeroSub.Text = '{0} at {1}{2} {3} fans working hard' -f $hotName, [int]$hotVal, $script:deg, $script:mid
        }
    }

    $mode = $d.ActiveMode
    foreach ($pair in @(@('quiet','BtnQuiet'), @('normal','BtnNormal'), @('performance','BtnPerf'), @('curve','BtnCurve'), @('auto','BtnAuto'))) {
        $btn = $el[$pair[1]]
        if ($pair[0] -eq $mode) { $btn.Background = $script:brushAccentPill; $btn.Foreground = $script:brushDark }
        else                    { $btn.Background = $script:brushClear;      $btn.Foreground = $script:brushDim }
    }
    foreach ($k in @($script:trayMode.Keys)) { $script:trayMode[$k].Checked = ($k -eq $mode) }
    $script:miOsd.Checked = ([string]$script:settings.osdMode -ne 'off')
    # defer panel rebuilds while a slider is held, so a worker-driven mode
    # switch can't retarget the thumb the user is dragging
    if ($mode -ne $script:panelMode -and -not $el.ModeSlots.IsMouseCaptureWithin) { Update-ModePanel $mode }

    if ($sync.Status -eq 'ready') {
        if ($sync.DlState -eq 'downloading') {
            $el.StatusDot.Fill = $script:brushAccent
            $el.StatusText.Text = $script:L.Downloading
        } elseif ($sync.DlState -eq 'badhash') {
            $el.StatusDot.Fill = $script:brushRed
            $el.StatusText.Text = "Update download didn't verify - open the release page to update by hand"
            if ($el.UpdatePill.Visibility -eq 'Visible') { $el.UpdatePillText.Text = 'UPDATE {0}' -f $sync.Update.Version }
        } elseif ($d.GameBoost) {
            $el.StatusDot.Fill = $script:brushYellow
            $el.StatusText.Text = $(if ([string]$d.GameMode -eq 'curve') { $script:L.GameActiveCurve } else { $script:L.GameActive })
        } elseif ($d.CoolDown) {
            $el.StatusDot.Fill = $script:brushYellow
            $el.StatusText.Text = $script:L.CoolDown -f [int][math]::Ceiling([double]$d.CoolLeft / 1000), $script:modeNames[[string]$d.CoolTo]
        } elseif ($d.BoostActive) {
            $el.StatusDot.Fill = $script:brushYellow
            $el.StatusText.Text = $script:L.BoostActive -f $script:settings.boostCase, $script:settings.boostLow, $script:deg
        } elseif ($mode -eq 'curve' -and $null -ne $d.CurveTarget) {
            $el.StatusDot.Fill = $script:brushGreen
            $el.StatusText.Text = $script:L.CurveActive -f $d.CurveTarget
        } else {
            $el.StatusDot.Fill = $script:brushGreen
            $el.StatusText.Text = $script:L.Connected -f ($script:settings.updateIntervalMs / 1000)
        }
    } else {
        $el.StatusDot.Fill = $script:brushMuted
        $el.StatusText.Text = $script:L.Starting
    }
    $el.WarnText.Text = if ($d.Warning) { $d.Warning } else { '' }

    # A worker that hit a transient fault survived it (it no longer takes the
    # app down); record the fault here where the app folder is reachable.
    if ($sync.TickError -and $sync.TickError -ne $script:lastTickErr) {
        $script:lastTickErr = $sync.TickError
        try { $sync.TickError | Out-File -FilePath (Join-Path $script:AppRoot 'error.log') -Encoding utf8 -Append } catch { }
    }

    if ($d.Warning -and $d.Warning -ne $script:lastWarn) {
        $script:lastWarn = $d.Warning
        # A heat warning is worth keeping in the notification centre, not
        # flashing for four seconds while the user is in a game.
        $shown = Show-Toast 'Vento - temperature warning' ([string]$d.Warning) 'warn' $null { param($arg) Show-Main }
        if (-not $shown) {
            $script:lastBalloon = 'warn'
            $script:notify.ShowBalloonTip(4000, 'Vento', $d.Warning, [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
    if (-not $d.Warning) { $script:lastWarn = $null }

    if ($sync.Update -and -not $script:updateNotified) {
        $script:updateNotified = $true
        $script:miUpdate.Text = $script:L.InstallItem -f $sync.Update.Version
        $script:miUpdate.Visible = $true
        $el.UpdatePillText.Text = 'UPDATE {0}' -f $sync.Update.Version
        $el.UpdatePill.Visibility = 'Visible'
        if ($script:shell.IsVisible) { Show-UpdateBanner }
        Show-GlassUpdate ([string]$sync.Update.Version)
        $ver = [string]$sync.Update.Version
        $shown = Show-Toast ('Vento {0} is available' -f $ver) `
                            'Install it now and Vento restarts itself when it is done.' `
                            'update' `
                            @(@{ Text = 'Install now'; Arg = 'install' }, @{ Text = 'Later'; Arg = 'later' }) `
                            {
                                param($arg)
                                Show-Main
                                if ($arg -eq 'install') { Install-Update }
                            }
        if (-not $shown) {
            $script:lastBalloon = 'update'
            $script:notify.ShowBalloonTip(6000, 'Vento', ($script:L.UpdateBalloon -f $ver), [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
    if ($sync.DlState -eq 'downloading' -and $el.UpdatePill.Visibility -eq 'Visible') {
        $el.UpdatePillText.Text = 'DOWNLOADING...'
    }

    # Temperature history sparklines (one sample every 2s, 10 minutes kept)
    $script:histTick++
    if ($script:histTick % 4 -eq 0) {
        if ($null -ne $d.CpuTemp) { [void]$script:histCpu.Add([double]$d.CpuTemp); if ($script:histCpu.Count -gt 300) { $script:histCpu.RemoveAt(0) } }
        if ($null -ne $d.GpuTemp) { [void]$script:histGpu.Add([double]$d.GpuTemp); if ($script:histGpu.Count -gt 300) { $script:histGpu.RemoveAt(0) } }
        if ($null -ne $d.SsdTemp) { [void]$script:histSsd.Add([double]$d.SsdTemp); if ($script:histSsd.Count -gt 300) { $script:histSsd.RemoveAt(0) } }
        if ($null -ne $d.MbTemp)  { [void]$script:histMb.Add([double]$d.MbTemp);   if ($script:histMb.Count  -gt 300) { $script:histMb.RemoveAt(0) } }
        Update-Spark $script:histCpu $el.CpuSpark $el.CpuSparkHost $el.CpuSparkFill
        Update-Spark $script:histGpu $el.GpuSpark $el.GpuSparkHost $el.GpuSparkFill
        Update-Spark $script:histSsd $el.SsdSpark $el.SsdSparkHost $el.SsdSparkFill
        Update-Spark $script:histMb  $el.MbSpark  $el.MbSparkHost  $el.MbSparkFill
    }

    # Fan activity graph: sampled every tick (500ms) through a light
    # exponential smoothing so the traces flow instead of stepping.
    # 1200 samples = 10 minutes; both lists advance in lockstep and a
    # briefly-null channel repeats its last sample.
    if (($null -ne $d.CpuFan) -or ($null -ne $d.CaseFan)) {
        $lastC = if ($script:histFanCpu.Count)  { $script:histFanCpu[$script:histFanCpu.Count - 1] }   else { $null }
        $lastK = if ($script:histFanCase.Count) { $script:histFanCase[$script:histFanCase.Count - 1] } else { $null }
        $vc = if ($null -ne $d.CpuFan)  { [double]$d.CpuFan }  elseif ($null -ne $lastC) { [double]$lastC } else { 0.0 }
        $vk = if ($null -ne $d.CaseFan) { [double]$d.CaseFan } elseif ($null -ne $lastK) { [double]$lastK } else { 0.0 }
        if ($null -ne $lastC) { $vc = $lastC * 0.72 + $vc * 0.28 }
        if ($null -ne $lastK) { $vk = $lastK * 0.72 + $vk * 0.28 }
        [void]$script:histFanCpu.Add($vc);  if ($script:histFanCpu.Count  -gt 1200) { $script:histFanCpu.RemoveAt(0) }
        [void]$script:histFanCase.Add($vk); if ($script:histFanCase.Count -gt 1200) { $script:histFanCase.RemoveAt(0) }
        if ($script:histTick % 4 -eq 0 -or ($vc * 1.08) -gt $script:fanMax -or ($vk * 1.08) -gt $script:fanMax) {
            $fmax = 800.0
            if ($script:histFanCpu.Count)  { $fmax = [math]::Max($fmax, ($script:histFanCpu  | Measure-Object -Maximum).Maximum) }
            if ($script:histFanCase.Count) { $fmax = [math]::Max($fmax, ($script:histFanCase | Measure-Object -Maximum).Maximum) }
            $script:fanMax = $fmax * 1.08
            $el.AxR0.Text = '{0}' -f [int]($script:fanMax * 0.75)
            $el.AxR1.Text = '{0}' -f [int]($script:fanMax * 0.5)
            $el.AxR2.Text = '{0}' -f [int]($script:fanMax * 0.25)
        }
        Update-FanSpark $script:histFanCpu  $el.CpuFanSpark  $el.FanSparkHost $script:fanMax $el.CpuFanSparkFill
        Update-FanSpark $script:histFanCase $el.CaseFanSpark $el.FanSparkHost $script:fanMax $el.CaseFanSparkFill
    }

    # --- AirPods battery: fold in new packets, keep the watcher alive ---
    try { Update-PodsTick } catch { }

    # --- the Glass window draws from the same data ---
    try { Update-Glass $d } catch { }
    try { Update-DevTick } catch { }
    try { Update-DriverWatch } catch { }
    try { Update-GFlyout $d } catch { }

    # --- OSD overlay ---
    $osdWant = if ($script:osdEditing) { $true } else {
        switch ([string]$script:settings.osdMode) {
            'on'  { $true }
            'off' { $false }
            default { [bool]$d.GameDetected -or [bool]$d.GameBoost }
        }
    }
    if ($osdWant) {
        Show-Osd
        if ($script:osd) {
            # Thermal state from the hottest-sensor margin computed above; each
            # theme walks its own cool/warm/hot accents.
            $newState = 'cool'
            if ($null -ne $margin) {
                if ($margin -gt 2.5) { $newState = 'hot' } elseif ($margin -gt 0) { $newState = 'warm' }
            }
            if ($newState -ne $script:osdState) { $script:osdState = $newState; Update-OsdAccent }
            # FPS comes from the ETW present tracer, started lazily the first
            # time the overlay actually needs it.
            $fpsTxt = '--'
            if ([bool]$script:settings.osdFps) {
                Ensure-FpsTracer
                if ($script:fpsOn) {
                    $f = [VentoNative.Fps]::Current($PID)
                    if ($f -gt 0) { $fpsTxt = '{0}' -f $f }
                }
            }
            $ovals = @{
                fps  = $fpsTxt
                cpu  = $(if ($null -ne $d.CpuTemp) { '{0}{1}' -f [int]$d.CpuTemp, $script:deg } else { '--' })
                gpu  = $(if ($null -ne $d.GpuTemp) { '{0}{1}' -f [int]$d.GpuTemp, $script:deg } else { '--' })
                load = $(if ($null -ne $d.GpuLoad) { '{0}%' -f [int]$d.GpuLoad } else { '--' })
                ram  = $(if ($null -ne $d.RamLoad -and $null -ne $d.RamTemp) { '{0}% {1} {2}{3}' -f [int]$d.RamLoad, $script:mid, [int]$d.RamTemp, $script:deg }
                         elseif ($null -ne $d.RamLoad) { '{0}%' -f [int]$d.RamLoad } else { '--' })
                ssd  = $(if ($null -ne $d.SsdTemp) { '{0}{1}' -f [int]$d.SsdTemp, $script:deg } else { '--' })
                mb   = $(if ($null -ne $d.MbTemp)  { '{0}{1}' -f [int]$d.MbTemp,  $script:deg } else { '--' })
                fan  = '{0} {1} {2}' -f $(if ($null -ne $d.CpuFan) { $d.CpuFan } else { '--' }),
                                        $script:mid,
                                        $(if ($null -ne $d.CaseFan) { $d.CaseFan } else { '--' })
                pods = $(
                    $pd = $script:pods
                    # per-side staleness: every number rides its OWN last-heard
                    # stamp, so a bud that died or stayed home can't borrow the
                    # other bud's freshness - a frozen number is a quiet lie
                    $now0 = [DateTime]::Now
                    $lF = ($pd -and $pd.LSeen -and ($now0 - $pd.LSeen).TotalSeconds -lt 60)
                    $rF = ($pd -and $pd.RSeen -and ($now0 - $pd.RSeen).TotalSeconds -lt 60)
                    if ($lF -or $rF) {
                        $txt = '{0}{1}{2}' -f $(if ($lF) { $pd.L } else { '-' }), $script:mid, $(if ($rF) { $pd.R } else { '-' })
                        if ($null -ne $pd.Case -and $pd.CaseSeen -and ($now0 - $pd.CaseSeen).TotalMinutes -lt 10) { $txt += ('{0}{1}' -f $script:mid, $pd.Case) }
                        $txt
                    } else { '--' })
            }
            foreach ($id in @($script:osdVals.Keys)) { $script:osdVals[$id].Text = $ovals[$id] }
            if ($script:osdThermoDot) {
                $hh = $script:osdThermoDot.Host.ActualHeight
                if ($hh -gt 10) {
                    $pct = switch ($script:osdState) { 'hot' { 0.12 } 'warm' { 0.45 } default { 0.74 } }
                    $script:osdThermoDot.Dot.Margin = New-Object System.Windows.Thickness 0, ([math]::Max(1.0, ($hh - 3) * $pct)), 0, 0
                }
            }
            # Borderless games reorder the z stack; re-assert topmost every ~5s.
            if (($script:histTick % 10) -eq 0 -and ('VentoNative.Osd' -as [type]) -and $script:osd.IsVisible) {
                $h = (New-Object System.Windows.Interop.WindowInteropHelper $script:osd).Handle
                if ($h -ne [IntPtr]::Zero) { [void][VentoNative.Osd]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13) }
            }
        }
        Update-OsdHover
    } else { Hide-Osd }

    # --- Monitor panel refresh: a new DDC snapshot bumps Gen ---
    if ($el.MonitorOverlay.Visibility -eq 'Visible' -and $sync.Ddc.Gen -ne $script:monGen) {
        $script:monGen = $sync.Ddc.Gen
        Update-MonitorPanel
    }
    # A write that the display quietly ignored is worth saying out loud - the
    # alternative is a control that looks like it works and does not.
    if ($el.MonitorOverlay.Visibility -eq 'Visible' -and $sync.Ddc.WGen -ne $script:monWGen) {
        $script:monWGen = $sync.Ddc.WGen
        Show-MonWriteResult $sync.Ddc.LastWrite
    }
    # Night schedule: checked about once a minute, and it re-checks after
    # sleep/wake because it compares against the wall clock, not a countdown.
    if ([bool]$script:settings.monNight) {
        $nowMin = [int][math]::Floor(([datetime]::Now - [datetime]::Today).TotalMinutes)
        if ($nowMin -ne $script:nightLastMin) {
            $script:nightLastMin = $nowMin
            # The schedule can only drive displays the DDC worker has enumerated.
            if (@($sync.Ddc.Monitors).Count -eq 0) {
                if ($script:psDdc -and -not $sync.Ddc.Busy) { $sync.DdcQueue.Enqueue(@{ Cmd = 'Enum' }) }
                else { Start-DdcWorker }
            } else {
                Test-NightShift
                if ($el.MonitorOverlay.Visibility -eq 'Visible') { Build-MonTimeline }
            }
        }
    }

    $tip = 'Vento'
    if ($null -ne $d.CpuTemp) { $tip += ('  CPU {0}{1}C' -f [int]$d.CpuTemp, $script:deg) }
    if ($null -ne $d.GpuTemp) { $tip += ('  GPU {0}{1}C' -f [int]$d.GpuTemp, $script:deg) }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $script:notify.Text = $tip
})
$script:timer.Start()

# --- Run -------------------------------------------------------------
if (-not $script:settings.startMinimized) { $script:shell.Show() }
if ($script:ownsApp) {
    [void]$script:app.Run()
} else {
    # Hosted in a process that already owns the Application: pump a nested
    # dispatcher frame until the window really closes (see Add_Closed).
    $script:frame = New-Object System.Windows.Threading.DispatcherFrame
    [System.Windows.Threading.Dispatcher]::PushFrame($script:frame)
}

}
catch {
    $_ | Out-String | Out-File -FilePath (Join-Path $script:AppRoot 'error.log') -Encoding utf8
    try { [void][System.Windows.MessageBox]::Show("Application error: $($_.Exception.Message)", 'Vento', 'OK', 'Error') } catch { }
}
finally {
    # Flush a pending debounced mode-panel save - the dispatcher is gone, so
    # its 800ms tick will never fire.
    if ($script:saveTimer -and $script:saveTimer.IsEnabled) {
        try { $script:saveTimer.Stop(); Export-Settings $script:settings } catch { }
    }
    # The OSD is a second top-level window; in the hosted DispatcherFrame path
    # nothing else would close it and it could strand the process.
    try { Close-Osd } catch { }
    # Worker shutdown lives here, not after Run: even if the UI dies from an
    # unhandled exception, the worker's finally must hand fans back to the BIOS.
    if ($sync) {
        $sync.Exit = $true
        $deadline = (Get-Date).AddSeconds(5)
        while (-not $sync.Stopped -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if ($sync.Error) { try { $sync.Error | Out-File -FilePath (Join-Path $script:AppRoot 'error.log') -Encoding utf8 -Append } catch { } }
    }
    if ($script:psWorker) { try { $script:psWorker.Dispose() } catch { } }
    if ($script:runspace) { try { $script:runspace.Dispose() } catch { } }
    if ($script:psUpd) { try { $script:psUpd.Dispose() } catch { } }
    if ($script:updRunspace) { try { $script:updRunspace.Dispose() } catch { } }
    if ($script:psDl) { try { $script:psDl.Dispose() } catch { } }
    if ($script:dlRunspace) { try { $script:dlRunspace.Dispose() } catch { } }
    if ($script:psDdc) { try { $script:psDdc.Dispose() } catch { } }
    if ($script:ddcRunspace) { try { $script:ddcRunspace.Dispose() } catch { } }
    Stop-FpsTracer   # tears down the real-time ETW session so it doesn't outlive the app
    if ('VentoNative.Pods' -as [type]) { try { [VentoNative.Pods]::Stop() } catch { } }
    if ($script:psPods) { try { $script:psPods.Dispose() } catch { } }
    if ($script:podsRunspace) { try { $script:podsRunspace.Dispose() } catch { } }
    if ($script:notify) {
        try { $script:notify.Visible = $false; $script:notify.Dispose() } catch { }
    }
    try { $script:mutex.ReleaseMutex() } catch { }
    try { $script:mutex.Dispose() } catch { }
    # Silent update: run the downloaded installer after we have fully let go
    # of the mutex and the lib DLLs. The installer relaunches Vento when done.
    if ($script:pendingSetup -and (Test-Path $script:pendingSetup)) {
        try { Start-Process -FilePath $script:pendingSetup -ArgumentList '/SILENT' } catch { }
    }
}
