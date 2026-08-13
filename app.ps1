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
$script:AppVersion = '1.4.0'

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

# Own taskbar identity: without this the window is grouped under
# powershell.exe and the taskbar shows the PowerShell icon.
try {
    Add-Type -Namespace VentoNative -Name Shell -MemberDefinition '[DllImport("shell32.dll", SetLastError=true)] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);'
    [void][VentoNative.Shell]::SetCurrentProcessExplicitAppUserModelID('Blakfy.Vento')
} catch { }

# --- Single instance -------------------------------------------------
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Global\VentoSingleInstance', [ref]$created)
if (-not $created) {
    [void][System.Windows.MessageBox]::Show('Vento is already running.', 'Vento', 'OK', 'Information')
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
        gameBoost        = $true       # auto Performance while the GPU is under load
        gameOnLoad       = 80          # % GPU load that counts as gaming
        gameCooldownSec  = 15          # extra full-speed seconds after a game ends (0 = off)
        curve40          = 25          # Curve mode: case fan % at 40/55/70/80 deg C
        curve55          = 40
        curve70          = 65
        curve80          = 100
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
        $s.gameBoost        = [bool]$s.gameBoost
        $s.gameOnLoad       = [int](Limit $s.gameOnLoad 50 100)
        $s.gameCooldownSec  = [int](Limit $s.gameCooldownSec 0 60)
        $s.curve40          = [int](Limit $s.curve40 20 100)
        $s.curve55          = [int](Limit $s.curve55 20 100)
        $s.curve70          = [int](Limit $s.curve70 20 100)
        $s.curve80          = [int](Limit $s.curve80 20 100)
    } catch {
        $s = Get-DefaultSettings
    }
    if (@('quiet','normal','performance','curve','auto') -notcontains [string]$s.lastMode) { $s.lastMode = 'auto' }
    # Settings files written before the GitHub username was final point the
    # updater at a repo that never existed - migrate them.
    if ([string]$s.updateRepo -eq 'blakfy/vento') { $s.updateRepo = 'Henkerr/vento' }
    try { [void][System.Windows.Media.ColorConverter]::ConvertFromString([string]$s.accentColor) }
    catch { $s.accentColor = '#4C8DFF' }
    return $s
}

function Export-Settings($s) {
    $s | ConvertTo-Json | Out-File -FilePath $script:settingsPath -Encoding utf8
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

        $gpuHw = $pc.Hardware | Where-Object { $_.HardwareType.ToString() -like 'Gpu*' } | Select-Object -First 1
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
        $coolMs = 0; $coolHot = 0
        $lastCurve = -100
        $sinceUpdate = 999999
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $lastLoopMs = [long]0
        $lastPassMs = [long](-1)
        while (-not $sync.Exit) {
            # real elapsed time this iteration - Start-Sleep overshoots, so
            # fixed increments would drift
            $nowMs = $clock.ElapsedMilliseconds
            $tickMs = [int][math]::Max(0, [math]::Min(5000, $nowMs - $lastLoopMs))
            $lastLoopMs = $nowMs
            $s = $sync.Settings
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
                if ($sync.Data.ActiveMode -ne 'performance') {
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
                if ($sio)   { $sio.Update() }
                if ($cpuHw) { $cpuHw.Update() }
                if ($gpuHw) { $gpuHw.Update() }
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
                # Near the safety limits, never (re)arm game boost - otherwise
                # the guard's forced Auto and the boost would fight in a loop.
                $tooHot = ((($null -ne $d.CpuTemp) -and ($d.CpuTemp -gt ($s.cpuMaxTemp - 4))) -or
                           (($null -ne $d.GpuTemp) -and ($d.GpuTemp -gt ($s.gpuMaxTemp - 4))))
                if ($s.gameBoost -and $null -ne $load) {
                    if ($gameOn) {
                        if ($d.ActiveMode -ne 'performance') {
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
                        if (($load -ge $s.gameOnLoad) -and ($d.ActiveMode -ne 'performance') -and (-not $tooHot)) { $gameHot += $passMs } else { $gameHot = 0 }
                        if ($gameHot -ge 30000) {
                            $preGame = $d.ActiveMode
                            Set-Mode 'performance'
                            $gameOn = $true; $d.GameBoost = $true
                            $gameHot = 0; $gameIdle = 0
                            $boostOn = $false; $d.BoostActive = $false
                        }
                    }
                } elseif ($gameOn -or $coolMs -gt 0) {
                    # tracking lost (sensor vanished or feature disabled) -
                    # don't strand the fans in Performance
                    $gameOn = $false; $d.GameBoost = $false
                    $coolMs = 0; $coolHot = 0; $d.CoolDown = $false
                    if ($d.ActiveMode -eq 'performance') { Set-Mode $preGame; $lastCurve = -100 }
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
    <Style x:Key="SetSlider" TargetType="Slider">
      <Setter Property="Foreground" Value="#4C8DFF"/>
      <Setter Property="IsSnapToTickEnabled" Value="True"/>
      <Setter Property="TickFrequency" Value="1"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="12,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center" Height="20">
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton IsTabStop="False" Command="Slider.DecreaseLarge">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="5" CornerRadius="2.5"
                                Background="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Slider}}"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton IsTabStop="False" Command="Slider.IncreaseLarge">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <!-- constant-alpha black so the empty track reads on any
                             thermal tile tone -->
                        <Border Height="5" CornerRadius="2.5" Background="#3D000000"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <!-- fader-style pill handle instead of the stock ball -->
                  <Thumb Width="10" Height="20">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="knob" CornerRadius="5" Background="#ECF0F7"
                                BorderBrush="#59000000" BorderThickness="1">
                          <Border.Effect>
                            <DropShadowEffect ShadowDepth="1.5" Direction="270" BlurRadius="5" Opacity="0.45" Color="#000000"/>
                          </Border.Effect>
                        </Border>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="knob" Property="Background" Value="#FFFFFF"/>
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
              <Button x:Name="BtnSettings" Style="{StaticResource TitleBtn}" Content="&#xE713;" ToolTip="Settings" Margin="0,0,4,0"/>
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
                      <CheckBox x:Name="S_Game" Style="{StaticResource SetCheck}" Content="Switch to Performance during games (GPU load based)"/>
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
    'SettingsOverlay','SecFans','SecBoost','SecCurve','SecGame','SecSafety','SecTargets','SecGeneral',
    'S_WarnCpu','S_WarnGpu','S_WarnSsd','S_WarnMb',
    'V_WarnCpu','V_WarnGpu','V_WarnSsd','V_WarnMb',
    'S_QuietCase','S_NormalCase','S_PerfCase','S_PerfCpu',
    'S_BoostEnabled','S_BoostHigh','S_BoostLow','S_BoostCase',
    'S_C40','S_C55','S_C70','S_C80','S_Game','S_GameLoad','S_GameCool',
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
                         'S_WarnCpu','S_WarnGpu','S_WarnSsd','S_WarnMb','S_Interval')

# All code-generated UI strings live here so a future language option is a
# table swap (XAML labels move here in the same pass).
$script:mid = [char]183   # middot separator; kept out of literals so the file stays ASCII
$script:L = @{
    Starting      = 'Starting sensors...'
    Connected     = "Connected $script:mid updating every {0:0.#}s"
    BoostActive   = "Cooling boost active $script:mid case fans at {0}% until below {1}{2}C"
    CurveActive   = "Curve mode $script:mid case fans at {0}%"
    GameActive    = "Game detected $script:mid Performance until the GPU goes idle"
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
    if ($margin -le -8)    { $a = 'cool'; $b = 'cool'; $u = 0.0; $pos = 0.02 }
    elseif ($margin -lt 0) { $a = 'cool'; $b = 'warm'; $u = ($margin + 8) / 8.0; $pos = 0.55 * $u }
    elseif ($margin -lt 4) { $a = 'warm'; $b = 'hot';  $u = $margin / 4.0; $pos = 0.55 + 0.45 * $u }
    else                   { $a = 'hot';  $b = 'hot';  $u = 0.0; $pos = 1.0 }
    $pal = @{}
    $pa = $script:thAnchor[$a]; $pb = $script:thAnchor[$b]
    foreach ($n in @($pa.Keys)) { $pal[$n] = Mix-Color $pa[$n] $pb[$n] $u }
    return @{ pal = $pal; pos = [math]::Max(0.02, [math]::Min(1.0, $pos)) }
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
    $el.UpdateBanner.BorderBrush = New-SolidBrushC (New-AlphaColor $acc 0x66)
    $el.StateBadgeText.Text = @('COOL', 'WARM', 'HOT')[$onIdx]
    $sectBrush = New-SolidBrushC (New-AlphaColor $acc 0x22)
    $el.SectLine1.Background = $sectBrush
    $el.SectLine2.Background = $sectBrush
    $el.ModeShell.BorderBrush  = New-SolidBrushC (New-AlphaColor $acc 0x24)
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
    foreach ($sec in 'SecFans', 'SecBoost', 'SecCurve', 'SecGame', 'SecSafety', 'SecTargets', 'SecGeneral') { $el[$sec].Foreground = $script:brushAccent }
    # slider fills: accent -> bright-accent gradient across the filled side
    $sgb = New-Object System.Windows.Media.LinearGradientBrush
    $sgb.StartPoint = New-Object System.Windows.Point 0, 0.5
    $sgb.EndPoint   = New-Object System.Windows.Point 1, 0.5
    $sgb.GradientStops.Add((New-Object System.Windows.Media.GradientStop $acc, 0))
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

function Open-Settings {
    $s = $script:settings
    foreach ($row in $script:sliderMap) { $el[$row[0]].Value = [double]$s[$row[2]] }
    $el.S_Interval.Value = [math]::Round($s.updateIntervalMs / 1000)
    Update-SliderLabels
    $el.S_BoostEnabled.IsChecked = [bool]$s.boostEnabled
    $el.S_Game.IsChecked         = [bool]$s.gameBoost
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
    $s.gameBoost      = [bool]$el.S_Game.IsChecked
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
    $el.SettingsOverlay.Visibility = 'Collapsed'
}

$el.BtnSetSave.Add_Click({ Save-Settings })
$el.BtnSetCancel.Add_Click({ $el.SettingsOverlay.Visibility = 'Collapsed' })
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
    else { Open-Settings }
})

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
        param($sync, $url, $dst)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 300
            $sync.SetupFile = $dst
        } catch {
            $sync.DlState = $null
        }
    }
    $script:dlRunspace = [runspacefactory]::CreateRunspace()
    $script:dlRunspace.Open()
    $script:psDl = [powershell]::Create()
    $script:psDl.Runspace = $script:dlRunspace
    [void]$script:psDl.AddScript($dl.ToString()).AddArgument($sync).AddArgument($u.AssetUrl).AddArgument($dst)
    [void]$script:psDl.BeginInvoke()
}

# --- Window behaviour ------------------------------------------------
$script:reallyExit = $false
$script:trayTipShown = $false

function Show-Main {
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    [void]$window.Activate()
    if ($script:updateNotified) { Show-UpdateBanner }
}
function Hide-ToTray {
    $window.Hide()
    if (-not $script:trayTipShown) {
        $script:trayTipShown = $true
        $script:lastBalloon = 'info'
        $script:notify.ShowBalloonTip(2500, 'Vento', $script:L.TrayStillHere, [System.Windows.Forms.ToolTipIcon]::Info)
    }
}
function Quit-App { $script:reallyExit = $true; $window.Close() }

$el.TitleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$el.BtnMin.Add_Click({ Hide-ToTray })
$el.BtnClose.Add_Click({ $window.Close() })
$el.BtnQuiet.Add_Click({  Set-UserMode 'quiet' })
$el.BtnNormal.Add_Click({ Set-UserMode 'normal' })
$el.BtnPerf.Add_Click({   Set-UserMode 'performance' })
$el.BtnCurve.Add_Click({  Set-UserMode 'curve' })
$el.BtnAuto.Add_Click({   Set-UserMode 'auto' })

$window.Add_Closing({ param($s, $e)
    if (-not $script:reallyExit) {
        if ($script:settings.closeToTray) { $e.Cancel = $true; Hide-ToTray; return }
        $script:reallyExit = $true
    }
})
$window.Add_Closed({
    if ($script:ownsApp) { $script:app.Shutdown() }
    elseif ($script:frame) { $script:frame.Continue = $false }
})
$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $window.WindowState = [System.Windows.WindowState]::Normal
        Hide-ToTray
    }
})
$window.Add_KeyDown({ param($s, $e)
    if ($e.Key -eq 'Escape' -and $el.SettingsOverlay.Visibility -eq 'Visible') {
        $el.SettingsOverlay.Visibility = 'Collapsed'
    }
})

# --- Tray menu -------------------------------------------------------
$script:notify = New-Object System.Windows.Forms.NotifyIcon
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
$script:miUpdate = $menu.Items.Add('Install update')
$script:miUpdate.Visible = $false
$script:miUpdate.add_Click({ Install-Update })
$miExit = $menu.Items.Add($script:L.TrayExit)
$miExit.add_Click({ Quit-App })
$script:notify.ContextMenuStrip = $menu
$script:notify.add_MouseClick({ param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main }
})
$script:notify.add_BalloonTipClicked({
    if ($script:lastBalloon -eq 'update' -and $sync.Update) { Start-Process $sync.Update.Url }
})

Init-Sirocco
Update-ModePanel ([string]$sync.Data.ActiveMode)

# --- Update check (GitHub releases, once per launch) -----------------
$script:psUpd = $null
$script:updRunspace = $null
if ($script:settings.checkUpdates -and $script:settings.updateRepo) {
    $updWorker = {
        param($sync, $repo, $current)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $r = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $repo) -Headers @{ 'User-Agent' = 'Vento' } -TimeoutSec 15
            $latest = ([string]$r.tag_name).TrimStart('v').TrimStart('V')
            if ([version]$latest -gt [version]$current) {
                $asset = $r.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1
                $sync.Update = @{
                    Version   = $latest
                    Url       = [string]$r.html_url
                    AssetUrl  = $(if ($asset) { [string]$asset.browser_download_url } else { $null })
                    AssetName = $(if ($asset) { [string]$asset.name } else { $null })
                }
            }
        } catch { }
    }
    $script:updRunspace = [runspacefactory]::CreateRunspace()
    $script:updRunspace.Open()
    $script:psUpd = [powershell]::Create()
    $script:psUpd.Runspace = $script:updRunspace
    [void]$script:psUpd.AddScript($updWorker.ToString()).AddArgument($sync).AddArgument($script:settings.updateRepo).AddArgument($script:AppVersion)
    [void]$script:psUpd.BeginInvoke()
}

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
$script:lastBalloon = $null
$script:updateNotified = $false
$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:timer.Add_Tick({
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
    # defer panel rebuilds while a slider is held, so a worker-driven mode
    # switch can't retarget the thumb the user is dragging
    if ($mode -ne $script:panelMode -and -not $el.ModeSlots.IsMouseCaptureWithin) { Update-ModePanel $mode }

    if ($sync.Status -eq 'ready') {
        if ($sync.DlState -eq 'downloading') {
            $el.StatusDot.Fill = $script:brushAccent
            $el.StatusText.Text = $script:L.Downloading
        } elseif ($d.GameBoost) {
            $el.StatusDot.Fill = $script:brushYellow
            $el.StatusText.Text = $script:L.GameActive
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

    if ($d.Warning -and $d.Warning -ne $script:lastWarn) {
        $script:lastWarn = $d.Warning
        $script:lastBalloon = 'warn'
        $script:notify.ShowBalloonTip(4000, 'Vento', $d.Warning, [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    if (-not $d.Warning) { $script:lastWarn = $null }

    if ($sync.Update -and -not $script:updateNotified) {
        $script:updateNotified = $true
        $script:miUpdate.Text = $script:L.InstallItem -f $sync.Update.Version
        $script:miUpdate.Visible = $true
        $el.UpdatePillText.Text = 'UPDATE {0}' -f $sync.Update.Version
        $el.UpdatePill.Visibility = 'Visible'
        if ($window.IsVisible) { Show-UpdateBanner }
        $script:lastBalloon = 'update'
        $script:notify.ShowBalloonTip(6000, 'Vento', ($script:L.UpdateBalloon -f $sync.Update.Version), [System.Windows.Forms.ToolTipIcon]::Info)
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

    $tip = 'Vento'
    if ($null -ne $d.CpuTemp) { $tip += ('  CPU {0}{1}C' -f [int]$d.CpuTemp, $script:deg) }
    if ($null -ne $d.GpuTemp) { $tip += ('  GPU {0}{1}C' -f [int]$d.GpuTemp, $script:deg) }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $script:notify.Text = $tip
})
$script:timer.Start()

# --- Run -------------------------------------------------------------
if (-not $script:settings.startMinimized) { $window.Show() }
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
