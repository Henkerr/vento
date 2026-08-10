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
$script:AppVersion = '1.3.0'

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
        Title="Vento" Width="700" Height="890"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="Segoe UI Variable Display, Segoe UI">
  <Window.Resources>
    <Style x:Key="TitleBtn" TargetType="Button">
      <Setter Property="Width" Value="44"/>
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
                <Setter TargetName="bg" Property="Background" Value="#1B2130"/>
                <Setter Property="Foreground" Value="#E6EAF2"/>
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
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#12161F"/>
      <Setter Property="BorderBrush" Value="#1E2430"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="18,14"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A93A6"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BigValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="FontSize" Value="40"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="MidValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,8,0,0"/>
    </Style>
    <Style x:Key="CardSub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#566073"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,5,0,0"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="SegBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#8A93A6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="9" Padding="0,9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#1B2130"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SetLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#AEB6C6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="SetValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
    </Style>
    <Style x:Key="SetCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#AEB6C6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,10,0,0"/>
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
            <Grid VerticalAlignment="Center" Height="18">
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton IsTabStop="False" Command="Slider.DecreaseLarge">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" CornerRadius="2"
                                Background="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Slider}}"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton IsTabStop="False" Command="Slider.IncreaseLarge">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" CornerRadius="2" Background="#242B3A"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="14" Height="14">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Fill="#E6EAF2" StrokeThickness="2"
                                 Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Slider}}"/>
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
  </Window.Resources>

  <Border CornerRadius="16" Background="#0B0E14" BorderBrush="#1E2430" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="46"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Title bar -->
      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" Margin="18,0,0,0" VerticalAlignment="Center">
          <Grid Width="16" Height="16">
            <Ellipse x:Name="LogoOuter" Fill="#4C8DFF"/>
            <Ellipse Width="6" Height="6" Fill="#0B0E14"/>
          </Grid>
          <TextBlock Text="VENTO" FontSize="13" FontWeight="Bold" Foreground="#E6EAF2" Margin="9,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0">
          <Button x:Name="BtnSettings" Style="{StaticResource TitleBtn}" Content="&#xE713;" ToolTip="Settings"/>
          <Button x:Name="BtnMin" Style="{StaticResource TitleBtn}" Content="&#xE921;" ToolTip="Minimize to tray"/>
          <Button x:Name="BtnClose" Style="{StaticResource TitleBtnClose}" Content="&#xE8BB;" ToolTip="Close"/>
        </StackPanel>
      </Grid>

      <!-- Main content -->
      <Grid Grid.Row="1" Margin="16,2,16,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Temperatures -->
        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="CPU TEMPERATURE"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="CpuTempVal" Style="{StaticResource BigValue}" Text="--"/>
                <TextBlock Text="&#176;C" Foreground="#566073" FontSize="16" VerticalAlignment="Bottom" Margin="4,0,0,8"/>
              </StackPanel>
              <Border x:Name="CpuBarTrack" Height="5" CornerRadius="2.5" Background="#1C2230" Margin="0,4,0,0">
                <Border x:Name="CpuBarFill" Height="5" CornerRadius="2.5" Background="#3DD68C" HorizontalAlignment="Left" Width="0"/>
              </Border>
              <Grid x:Name="CpuSparkHost" Height="26" Margin="0,8,0,0" ClipToBounds="True">
                <Polyline x:Name="CpuSpark" Stroke="#3DD68C" StrokeThickness="1.5" StrokeLineJoin="Round" Opacity="0.8"/>
              </Grid>
              <TextBlock x:Name="CpuNameText" Style="{StaticResource CardSub}" Text="Processor"/>
            </StackPanel>
          </Border>
          <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="GPU TEMPERATURE"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="GpuTempVal" Style="{StaticResource BigValue}" Text="--"/>
                <TextBlock Text="&#176;C" Foreground="#566073" FontSize="16" VerticalAlignment="Bottom" Margin="4,0,0,8"/>
              </StackPanel>
              <Border x:Name="GpuBarTrack" Height="5" CornerRadius="2.5" Background="#1C2230" Margin="0,4,0,0">
                <Border x:Name="GpuBarFill" Height="5" CornerRadius="2.5" Background="#3DD68C" HorizontalAlignment="Left" Width="0"/>
              </Border>
              <Grid x:Name="GpuSparkHost" Height="26" Margin="0,8,0,0" ClipToBounds="True">
                <Polyline x:Name="GpuSpark" Stroke="#3DD68C" StrokeThickness="1.5" StrokeLineJoin="Round" Opacity="0.8"/>
              </Grid>
              <TextBlock x:Name="GpuNameText" Style="{StaticResource CardSub}" Text="Graphics card"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- Storage / board temperatures -->
        <Grid Grid.Row="1" Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="SSD TEMPERATURE"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="SsdTempVal" Style="{StaticResource BigValue}" Text="--"/>
                <TextBlock Text="&#176;C" Foreground="#566073" FontSize="16" VerticalAlignment="Bottom" Margin="4,0,0,8"/>
              </StackPanel>
              <Border x:Name="SsdBarTrack" Height="5" CornerRadius="2.5" Background="#1C2230" Margin="0,4,0,0">
                <Border x:Name="SsdBarFill" Height="5" CornerRadius="2.5" Background="#3DD68C" HorizontalAlignment="Left" Width="0"/>
              </Border>
              <Grid x:Name="SsdSparkHost" Height="26" Margin="0,8,0,0" ClipToBounds="True">
                <Polyline x:Name="SsdSpark" Stroke="#3DD68C" StrokeThickness="1.5" StrokeLineJoin="Round" Opacity="0.8"/>
              </Grid>
              <TextBlock x:Name="SsdNameText" Style="{StaticResource CardSub}" Text="Drive"/>
            </StackPanel>
          </Border>
          <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="BOARD TEMPERATURE"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="MbTempVal" Style="{StaticResource BigValue}" Text="--"/>
                <TextBlock Text="&#176;C" Foreground="#566073" FontSize="16" VerticalAlignment="Bottom" Margin="4,0,0,8"/>
              </StackPanel>
              <Border x:Name="MbBarTrack" Height="5" CornerRadius="2.5" Background="#1C2230" Margin="0,4,0,0">
                <Border x:Name="MbBarFill" Height="5" CornerRadius="2.5" Background="#3DD68C" HorizontalAlignment="Left" Width="0"/>
              </Border>
              <Grid x:Name="MbSparkHost" Height="26" Margin="0,8,0,0" ClipToBounds="True">
                <Polyline x:Name="MbSpark" Stroke="#3DD68C" StrokeThickness="1.5" StrokeLineJoin="Round" Opacity="0.8"/>
              </Grid>
              <TextBlock x:Name="MbNameText" Style="{StaticResource CardSub}" Text="Motherboard"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- Fans -->
        <Grid Grid.Row="2" Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="CPU FAN"/>
              <TextBlock x:Name="CpuFanVal" Style="{StaticResource MidValue}" Text="--"/>
              <TextBlock Style="{StaticResource CardSub}" Text="Cooler speed"/>
            </StackPanel>
          </Border>
          <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="CASE FANS"/>
              <TextBlock x:Name="CaseFanVal" Style="{StaticResource MidValue}" Text="--"/>
              <TextBlock Style="{StaticResource CardSub}" Text="Hub speed"/>
            </StackPanel>
          </Border>
          <Border Grid.Column="2" Style="{StaticResource Card}" Margin="5,0,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="GPU FANS"/>
              <TextBlock x:Name="GpuFanVal" Style="{StaticResource MidValue}" Text="--"/>
              <TextBlock Style="{StaticResource CardSub}" Text="Graphics card"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- Mode selector -->
        <StackPanel Grid.Row="3" Margin="0,14,0,0">
          <TextBlock Style="{StaticResource CardTitle}" Text="FAN MODE" Margin="2,0,0,6"/>
          <Border Background="#10141E" BorderBrush="#1E2430" BorderThickness="1" CornerRadius="12" Padding="3">
            <UniformGrid Columns="5">
              <Button x:Name="BtnQuiet"  Style="{StaticResource SegBtn}" Content="Quiet"/>
              <Button x:Name="BtnNormal" Style="{StaticResource SegBtn}" Content="Normal"/>
              <Button x:Name="BtnPerf"   Style="{StaticResource SegBtn}" Content="Performance"/>
              <Button x:Name="BtnCurve"  Style="{StaticResource SegBtn}" Content="Curve"/>
              <Button x:Name="BtnAuto"   Style="{StaticResource SegBtn}" Content="Auto"/>
            </UniformGrid>
          </Border>
        </StackPanel>

        <!-- Mode panel: live settings for the active mode + fan activity -->
        <Border Grid.Row="4" Style="{StaticResource Card}" Margin="0,10,0,2">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0">
              <TextBlock x:Name="ModeSetTitle" Style="{StaticResource CardTitle}" Text="MODE" VerticalAlignment="Center"/>
              <Button x:Name="BtnModeReset" Style="{StaticResource SegBtn}" Content="Reset" FontSize="11" Width="64"
                      HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,-8,0,-8"
                      ToolTip="Restore this mode's default settings"/>
            </Grid>
            <TextBlock Grid.Row="1" x:Name="ModeSetHint" Style="{StaticResource CardSub}" Text="" TextWrapping="Wrap" Visibility="Collapsed"/>
            <Grid Grid.Row="2" x:Name="ModeSlots" Margin="0,10,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="22"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <Grid x:Name="Slot1" Grid.Row="0" Grid.Column="0" Margin="0,0,0,7" Visibility="Collapsed">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="84"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="ML1" Style="{StaticResource SetLabel}"/>
                <Slider Grid.Column="1" x:Name="MS1" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                <TextBlock Grid.Column="2" x:Name="MV1" Style="{StaticResource SetValue}"/>
              </Grid>
              <Grid x:Name="Slot2" Grid.Row="0" Grid.Column="2" Margin="0,0,0,7" Visibility="Collapsed">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="84"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="ML2" Style="{StaticResource SetLabel}"/>
                <Slider Grid.Column="1" x:Name="MS2" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                <TextBlock Grid.Column="2" x:Name="MV2" Style="{StaticResource SetValue}"/>
              </Grid>
              <Grid x:Name="Slot3" Grid.Row="1" Grid.Column="0" Visibility="Collapsed">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="84"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="ML3" Style="{StaticResource SetLabel}"/>
                <Slider Grid.Column="1" x:Name="MS3" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                <TextBlock Grid.Column="2" x:Name="MV3" Style="{StaticResource SetValue}"/>
              </Grid>
              <Grid x:Name="Slot4" Grid.Row="1" Grid.Column="2" Visibility="Collapsed">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="84"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="ML4" Style="{StaticResource SetLabel}"/>
                <Slider Grid.Column="1" x:Name="MS4" Style="{StaticResource SetSlider}" Minimum="20" Maximum="100"/>
                <TextBlock Grid.Column="2" x:Name="MV4" Style="{StaticResource SetValue}"/>
              </Grid>
            </Grid>
            <Grid Grid.Row="3" Margin="0,10,0,0">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Grid>
                <TextBlock Style="{StaticResource CardTitle}" Text="FAN ACTIVITY"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Ellipse x:Name="LegCpuDot" Width="7" Height="7" Fill="#4C8DFF" VerticalAlignment="Center"/>
                  <TextBlock Text="CPU fan" Foreground="#566073" FontSize="10" Margin="5,0,10,0" VerticalAlignment="Center"/>
                  <Ellipse x:Name="LegCaseDot" Width="7" Height="7" Fill="#3DD68C" VerticalAlignment="Center"/>
                  <TextBlock Text="Case fans" Foreground="#566073" FontSize="10" Margin="5,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Grid>
              <Grid x:Name="FanSparkHost" Grid.Row="1" MinHeight="30" Margin="0,8,0,0" ClipToBounds="True">
                <Polyline x:Name="CaseFanSpark" Stroke="#3DD68C" StrokeThickness="1.5" StrokeLineJoin="Round" Opacity="0.8"/>
                <Polyline x:Name="CpuFanSpark" Stroke="#4C8DFF" StrokeThickness="1.5" StrokeLineJoin="Round" Opacity="0.8"/>
              </Grid>
            </Grid>
          </Grid>
        </Border>
      </Grid>

      <!-- Footer -->
      <Grid Grid.Row="2" Margin="18,12,18,14">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="StatusDot" Width="7" Height="7" Fill="#566073" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusText" Foreground="#566073" FontSize="11" Margin="7,0,0,0" Text="Starting sensors..."/>
        </StackPanel>
        <TextBlock x:Name="WarnText" Foreground="#F26D78" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center" Text=""/>
      </Grid>

      <!-- Settings overlay -->
      <Border x:Name="SettingsOverlay" Grid.Row="1" Grid.RowSpan="2" Background="#F00B0E14" Visibility="Collapsed">
        <Border.Resources>
          <Style x:Key="Swatch" TargetType="Button">
            <Setter Property="Width" Value="22"/>
            <Setter Property="Height" Value="22"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="Button">
                  <Border Background="{TemplateBinding Background}" CornerRadius="11"
                          BorderBrush="#E6EAF2" BorderThickness="{TemplateBinding BorderThickness}"/>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Border.Resources>
        <Border Style="{StaticResource Card}" Margin="16,6,16,14">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Style="{StaticResource CardTitle}" Text="SETTINGS"/>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,6,0,0">
              <StackPanel Margin="0,0,6,0">
                <TextBlock Style="{StaticResource CardTitle}" Text="FAN SPEEDS" Foreground="#4C8DFF" x:Name="SecFans" Margin="0,6,0,2"/>
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

                <TextBlock Style="{StaticResource CardTitle}" Text="COOLING BOOST" Foreground="#4C8DFF" x:Name="SecBoost" Margin="0,16,0,2"/>
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

                <TextBlock Style="{StaticResource CardTitle}" Text="CURVE MODE" Foreground="#4C8DFF" x:Name="SecCurve" Margin="0,16,0,2"/>
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

                <TextBlock Style="{StaticResource CardTitle}" Text="GAME BOOST" Foreground="#4C8DFF" x:Name="SecGame" Margin="0,16,0,2"/>
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

                <TextBlock Style="{StaticResource CardTitle}" Text="SAFETY" Foreground="#4C8DFF" x:Name="SecSafety" Margin="0,16,0,2"/>
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

                <TextBlock Style="{StaticResource CardTitle}" Text="GENERAL" Foreground="#4C8DFF" x:Name="SecGeneral" Margin="0,16,0,2"/>
                <Grid Margin="0,6,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/><ColumnDefinition Width="52"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource SetLabel}" Text="Update interval"/>
                  <Slider Grid.Column="1" x:Name="S_Interval" Style="{StaticResource SetSlider}" Minimum="1" Maximum="10"/>
                  <TextBlock Grid.Column="2" x:Name="V_Interval" Style="{StaticResource SetValue}"/>
                </Grid>
                <Grid Margin="0,12,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="200"/><ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Style="{StaticResource SetLabel}" Text="Accent color"/>
                  <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="12,0">
                    <Button x:Name="Sw0" Style="{StaticResource Swatch}" Background="#4C8DFF" ToolTip="Blue"/>
                    <Button x:Name="Sw1" Style="{StaticResource Swatch}" Background="#A78BFA" ToolTip="Purple"/>
                    <Button x:Name="Sw2" Style="{StaticResource Swatch}" Background="#3DD68C" ToolTip="Green"/>
                    <Button x:Name="Sw3" Style="{StaticResource Swatch}" Background="#F5C359" ToolTip="Amber"/>
                    <Button x:Name="Sw4" Style="{StaticResource Swatch}" Background="#F26D78" ToolTip="Red"/>
                  </StackPanel>
                </Grid>
                <CheckBox x:Name="S_StartMin" Style="{StaticResource SetCheck}" Content="Start minimized to tray"/>
                <CheckBox x:Name="S_CloseTray" Style="{StaticResource SetCheck}" Content="Close button hides to tray"/>
                <CheckBox x:Name="S_Updates" Style="{StaticResource SetCheck}" Content="Notify me when a new version is available"/>
                <CheckBox x:Name="S_AutoStart" Style="{StaticResource SetCheck}" Content="Start with Windows (scheduled task, no UAC prompt)"/>
              </StackPanel>
            </ScrollViewer>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
              <Button x:Name="BtnSetCancel" Style="{StaticResource SegBtn}" Content="Cancel" Padding="16,0" Width="90"/>
              <Button x:Name="BtnSetSave" Style="{StaticResource SegBtn}" Content="Save" Width="90" Margin="8,2,2,2"/>
            </StackPanel>
          </Grid>
        </Border>
      </Border>
    </Grid>
  </Border>
</Window>
'@

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
    'CpuTempVal','GpuTempVal','CpuBarTrack','CpuBarFill','GpuBarTrack','GpuBarFill',
    'CpuSpark','GpuSpark','CpuSparkHost','GpuSparkHost',
    'CpuNameText','GpuNameText','CpuFanVal','CaseFanVal','GpuFanVal',
    'SsdTempVal','SsdBarTrack','SsdBarFill','SsdSpark','SsdSparkHost','SsdNameText',
    'MbTempVal','MbBarTrack','MbBarFill','MbSpark','MbSparkHost','MbNameText',
    'BtnQuiet','BtnNormal','BtnPerf','BtnCurve','BtnAuto',
    'StatusDot','StatusText','WarnText','TitleBar','BtnSettings','BtnMin','BtnClose','LogoOuter',
    'SettingsOverlay','SecFans','SecBoost','SecCurve','SecGame','SecSafety','SecGeneral',
    'S_QuietCase','S_NormalCase','S_PerfCase','S_PerfCpu',
    'S_BoostEnabled','S_BoostHigh','S_BoostLow','S_BoostCase',
    'S_C40','S_C55','S_C70','S_C80','S_Game','S_GameLoad','S_GameCool',
    'S_CpuMax','S_GpuMax','S_Interval','S_StartMin','S_CloseTray','S_Updates','S_AutoStart',
    'V_QuietCase','V_NormalCase','V_PerfCase','V_PerfCpu',
    'V_BoostHigh','V_BoostLow','V_BoostCase','V_C40','V_C55','V_C70','V_C80','V_GameLoad','V_GameCool',
    'V_CpuMax','V_GpuMax','V_Interval',
    'ModeSetTitle','ModeSetHint','ModeSlots','BtnModeReset',
    'Slot1','Slot2','Slot3','Slot4','ML1','ML2','ML3','ML4','MS1','MS2','MS3','MS4','MV1','MV2','MV3','MV4',
    'FanSparkHost','CpuFanSpark','CaseFanSpark','LegCpuDot','LegCaseDot',
    'Sw0','Sw1','Sw2','Sw3','Sw4','BtnSetSave','BtnSetCancel')) {
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

$script:deg = [char]176
$script:modeNames    = @{ quiet = 'Quiet'; normal = 'Normal'; performance = 'Performance'; curve = 'Curve'; auto = 'Auto' }
$script:swatchColors = @('#4C8DFF','#A78BFA','#3DD68C','#F5C359','#F26D78')
$script:sliderNames  = @('S_QuietCase','S_NormalCase','S_PerfCase','S_PerfCpu','S_BoostHigh','S_BoostLow','S_BoostCase',
                         'S_C40','S_C55','S_C70','S_C80','S_GameLoad','S_GameCool','S_CpuMax','S_GpuMax','S_Interval')

# All code-generated UI strings live here so a future language option is a
# table swap (XAML labels move here in the same pass).
$script:L = @{
    Starting      = 'Starting sensors...'
    Connected     = 'Connected - updating every {0:0.#}s'
    BoostActive   = 'Cooling boost active - case fans at {0}% until below {1}{2}C'
    CurveActive   = 'Curve mode - case fans at {0}%'
    GameActive    = 'Game detected - Performance until the GPU goes idle'
    CoolDown      = 'Post-game cooldown - {0}s, then back to {1}'
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

function Set-Accent([string]$hex) {
    $script:brushAccent = New-Brush $hex
    $el.LogoOuter.Fill = $script:brushAccent
    foreach ($sec in 'SecFans','SecBoost','SecCurve','SecGame','SecSafety','SecGeneral') { $el[$sec].Foreground = $script:brushAccent }
    foreach ($sn in $script:sliderNames) { $el[$sn].Foreground = $script:brushAccent }
    foreach ($i in 1..4) { $el["MS$i"].Foreground = $script:brushAccent }
    $el.CpuFanSpark.Stroke = $script:brushAccent
    $el.LegCpuDot.Fill = $script:brushAccent
    # keep the two fan-graph lines distinguishable when the accent IS the
    # case-fan green
    $caseHex = if ($hex -eq '#3DD68C') { '#4C8DFF' } else { '#3DD68C' }
    $script:brushCaseFan = New-Brush $caseHex
    $el.CaseFanSpark.Stroke = $script:brushCaseFan
    $el.LegCaseDot.Fill = $script:brushCaseFan
    $el.BtnSetSave.Foreground = $script:brushAccent
    if ($script:notify) { $script:notify.Icon = New-TrayIcon $hex }
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
    @('S_GpuMax',     'V_GpuMax',     'gpuMaxTemp', "$script:deg")
)
foreach ($row in $script:sliderMap) {
    $sName = $row[0]; $vName = $row[1]; $suffix = $row[3]
    $el[$sName].Add_ValueChanged({
        $el[$vName].Text = '{0}{1}' -f [int]$el[$sName].Value, $suffix
    }.GetNewClosure())
}
$el.S_Interval.Add_ValueChanged({ $el.V_Interval.Text = '{0}s' -f [int]$el.S_Interval.Value })

function Update-SwatchRing {
    for ($i = 0; $i -lt 5; $i++) {
        if ($script:swatchColors[$i] -eq $script:pendingAccent) {
            $el["Sw$i"].BorderThickness = New-Object System.Windows.Thickness 2
        } else {
            $el["Sw$i"].BorderThickness = New-Object System.Windows.Thickness 0
        }
    }
}
for ($i = 0; $i -lt 5; $i++) {
    # No GetNewClosure here: a closure's $script: scope is the dynamic module,
    # not this script, so the color is carried on the button's Tag instead.
    $el["Sw$i"].Tag = $script:swatchColors[$i]
    $el["Sw$i"].Add_Click({ param($s, $e) $script:pendingAccent = [string]$s.Tag; Update-SwatchRing })
}

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
    $el.ModeSetTitle.Text = '{0} MODE' -f $script:modeNames[$mode].ToUpper()
    for ($i = 1; $i -le 4; $i++) {
        if ($i -le $def.Count) {
            $row = $def[$i - 1]
            $sl = $el["MS$i"]
            $sl.Tag = $null      # mute the apply handler while reconfiguring
            $sl.Minimum = [double]$row[2]
            $sl.Maximum = [double]$row[3]
            $sl.Value = [double]$script:settings[$row[1]]
            $sl.Tag = $row
            $el["ML$i"].Text = $row[0]
            $el["MV$i"].Text = '{0}{1}' -f [int]$sl.Value, $row[4]
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
        $el[($s.Name -replace '^MS', 'MV')].Text = '{0}{1}' -f [int]$s.Value, $row[4]
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
    $script:pendingAccent = $s.accentColor
    Update-SwatchRing
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
    $s.accentColor    = $script:pendingAccent
    Export-Settings $s
    foreach ($k in $s.Keys) { $sync.Settings[$k] = $s[$k] }
    $sync.SettingsChanged = $true
    Set-Accent $s.accentColor
    if ($script:panelMode) { Update-ModePanel $script:panelMode }
    $el.SettingsOverlay.Visibility = 'Collapsed'
}

$el.BtnSetSave.Add_Click({ Save-Settings })
$el.BtnSetCancel.Add_Click({ $el.SettingsOverlay.Visibility = 'Collapsed' })
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

Set-Accent $script:settings.accentColor
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
function Update-Spark($list, $poly, $box) {
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
        $pc.Add((New-Object System.Windows.Point $x, $y))
    }
    $poly.Points = $pc
}

function Update-FanSpark($list, $poly, $box, [double]$maxV) {
    # maps 0..maxV RPM onto the host box, newest sample at the right edge
    if ($list.Count -lt 2) { return }
    $w = $box.ActualWidth; $h = $box.ActualHeight
    if ($w -lt 10 -or $h -lt 5) { return }
    if ($maxV -lt 1) { $maxV = 1 }
    $pc = New-Object System.Windows.Media.PointCollection
    $n = $list.Count
    for ($i = 0; $i -lt $n; $i++) {
        $x = $i * ($w / ($n - 1))
        $y = ($h - 1) - ([math]::Min($list[$i], $maxV) / $maxV * ($h - 2))
        $pc.Add((New-Object System.Windows.Point $x, $y))
    }
    $poly.Points = $pc
}

function Get-TempBrush([double]$t, [int]$warn, [int]$hot) {
    if ($t -ge $hot)  { return $script:brushRed }
    if ($t -ge $warn) { return $script:brushYellow }
    return $script:brushGreen
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

    if ($null -ne $d.CpuName) { $el.CpuNameText.Text = $d.CpuName }
    if ($null -ne $d.GpuName) { $el.GpuNameText.Text = $d.GpuName }

    $el.CpuFanVal.Text  = if ($null -ne $d.CpuFan)  { '{0} RPM' -f $d.CpuFan }  else { '--' }
    $el.CaseFanVal.Text = if ($null -ne $d.CaseFan) { '{0} RPM' -f $d.CaseFan } else { '--' }
    if (($null -ne $d.GpuFan1) -and ($null -ne $d.GpuFan2)) {
        $el.GpuFanVal.Text = '{0} / {1}' -f $d.GpuFan1, $d.GpuFan2
    } elseif ($null -ne $d.GpuFan1) {
        $el.GpuFanVal.Text = '{0} RPM' -f $d.GpuFan1
    } else {
        $el.GpuFanVal.Text = '--'
    }

    if ($null -ne $d.CpuTemp) {
        $el.CpuTempVal.Text = '{0}' -f [int]$d.CpuTemp
        $b = Get-TempBrush $d.CpuTemp 65 80
        $el.CpuTempVal.Foreground = $b
        $el.CpuBarFill.Background = $b
        $el.CpuBarFill.Width = [math]::Max(0, $el.CpuBarTrack.ActualWidth * ([math]::Min($d.CpuTemp, 100) / 100))
    } else { $el.CpuTempVal.Text = '--' }

    if ($null -ne $d.GpuTemp) {
        $el.GpuTempVal.Text = '{0}' -f [int]$d.GpuTemp
        $b = Get-TempBrush $d.GpuTemp 65 78
        $el.GpuTempVal.Foreground = $b
        $el.GpuBarFill.Background = $b
        $el.GpuBarFill.Width = [math]::Max(0, $el.GpuBarTrack.ActualWidth * ([math]::Min($d.GpuTemp, 100) / 100))
    } else { $el.GpuTempVal.Text = '--' }

    if ($null -ne $d.SsdName) { $el.SsdNameText.Text = $d.SsdName }
    if ($null -ne $d.MbName)  { $el.MbNameText.Text  = $d.MbName }

    # These two sensors can legitimately vanish mid-run (drive unplugged,
    # SuperIO diode going implausible), so '--' also clears the value color
    # and empties the bar instead of freezing them at the last reading.
    if ($null -ne $d.SsdTemp) {
        $el.SsdTempVal.Text = '{0}' -f [int]$d.SsdTemp
        $b = Get-TempBrush $d.SsdTemp 60 70
        $el.SsdTempVal.Foreground = $b
        $el.SsdBarFill.Background = $b
        $el.SsdBarFill.Width = [math]::Max(0, $el.SsdBarTrack.ActualWidth * ([math]::Min($d.SsdTemp, 100) / 100))
    } else {
        $el.SsdTempVal.Text = '--'; $el.SsdTempVal.Foreground = $script:brushText
        $el.SsdBarFill.Width = 0
    }

    if ($null -ne $d.MbTemp) {
        $el.MbTempVal.Text = '{0}' -f [int]$d.MbTemp
        $b = Get-TempBrush $d.MbTemp 50 60
        $el.MbTempVal.Foreground = $b
        $el.MbBarFill.Background = $b
        $el.MbBarFill.Width = [math]::Max(0, $el.MbBarTrack.ActualWidth * ([math]::Min($d.MbTemp, 100) / 100))
    } else {
        $el.MbTempVal.Text = '--'; $el.MbTempVal.Foreground = $script:brushText
        $el.MbBarFill.Width = 0
    }

    $mode = $d.ActiveMode
    foreach ($pair in @(@('quiet','BtnQuiet'), @('normal','BtnNormal'), @('performance','BtnPerf'), @('curve','BtnCurve'), @('auto','BtnAuto'))) {
        $btn = $el[$pair[1]]
        if ($pair[0] -eq $mode) { $btn.Background = $script:brushAccent; $btn.Foreground = $script:brushDark }
        else                    { $btn.Background = $script:brushClear;  $btn.Foreground = $script:brushDim }
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
        $script:lastBalloon = 'update'
        $script:notify.ShowBalloonTip(6000, 'Vento', ($script:L.UpdateBalloon -f $sync.Update.Version), [System.Windows.Forms.ToolTipIcon]::Info)
    }

    # Temperature history sparklines (one sample every 2s, 10 minutes kept)
    $script:histTick++
    if ($script:histTick % 4 -eq 0) {
        if ($null -ne $d.CpuTemp) { [void]$script:histCpu.Add([double]$d.CpuTemp); if ($script:histCpu.Count -gt 300) { $script:histCpu.RemoveAt(0) } }
        if ($null -ne $d.GpuTemp) { [void]$script:histGpu.Add([double]$d.GpuTemp); if ($script:histGpu.Count -gt 300) { $script:histGpu.RemoveAt(0) } }
        if ($null -ne $d.SsdTemp) { [void]$script:histSsd.Add([double]$d.SsdTemp); if ($script:histSsd.Count -gt 300) { $script:histSsd.RemoveAt(0) } }
        if ($null -ne $d.MbTemp)  { [void]$script:histMb.Add([double]$d.MbTemp);   if ($script:histMb.Count  -gt 300) { $script:histMb.RemoveAt(0) } }
        Update-Spark $script:histCpu $el.CpuSpark $el.CpuSparkHost
        Update-Spark $script:histGpu $el.GpuSpark $el.GpuSparkHost
        Update-Spark $script:histSsd $el.SsdSpark $el.SsdSparkHost
        Update-Spark $script:histMb  $el.MbSpark  $el.MbSparkHost
        $el.CpuSpark.Stroke = $el.CpuTempVal.Foreground
        $el.GpuSpark.Stroke = $el.GpuTempVal.Foreground
        $el.SsdSpark.Stroke = $el.SsdTempVal.Foreground
        $el.MbSpark.Stroke  = $el.MbTempVal.Foreground

        # Fan activity graph (same cadence, shared 0..max RPM scale).
        # Both lists advance in lockstep so the two lines share one time
        # axis; a briefly-null channel repeats its last sample.
        if (($null -ne $d.CpuFan) -or ($null -ne $d.CaseFan)) {
            $vc = if ($null -ne $d.CpuFan)  { [double]$d.CpuFan }  elseif ($script:histFanCpu.Count)  { $script:histFanCpu[$script:histFanCpu.Count - 1] }   else { 0.0 }
            $vk = if ($null -ne $d.CaseFan) { [double]$d.CaseFan } elseif ($script:histFanCase.Count) { $script:histFanCase[$script:histFanCase.Count - 1] } else { 0.0 }
            [void]$script:histFanCpu.Add($vc);  if ($script:histFanCpu.Count  -gt 300) { $script:histFanCpu.RemoveAt(0) }
            [void]$script:histFanCase.Add($vk); if ($script:histFanCase.Count -gt 300) { $script:histFanCase.RemoveAt(0) }
        }
        $fmax = 800.0
        if ($script:histFanCpu.Count)  { $fmax = [math]::Max($fmax, ($script:histFanCpu  | Measure-Object -Maximum).Maximum) }
        if ($script:histFanCase.Count) { $fmax = [math]::Max($fmax, ($script:histFanCase | Measure-Object -Maximum).Maximum) }
        $fmax *= 1.08
        Update-FanSpark $script:histFanCpu  $el.CpuFanSpark  $el.FanSparkHost $fmax
        Update-FanSpark $script:histFanCase $el.CaseFanSpark $el.FanSparkHost $fmax
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
