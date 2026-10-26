# Vento - Windows 11 glass design preview.
# Opens Vento redesigned as a Fluent app with fake live data. It does not
# touch the installed app, its settings or any hardware.
#
#   Glass.cmd                                        double-click to open
#   Glass.ps1 -Snap out.png [-Page Fans] [-Mode Curve]   render one page offline (no glass, no motion)
#   Glass.ps1 -Capture out.png [-Page Flyout]        open on screen, capture with the real glass, exit
#   Glass.ps1 -Material Mica                         start with Mica instead of acrylic
param(
    [string]$Snap,
    [string]$Capture,
    [ValidateSet('Home', 'Fans', 'Alerts', 'Profiles', 'Displays', 'Pods', 'Overlay', 'Settings', 'Flyout')][string]$Page = 'Home',
    [ValidateSet('Quiet', 'Normal', 'Perf', 'Curve', 'Auto')][string]$Mode = 'Quiet',
    [ValidateSet('Acrylic', 'Mica', 'MicaAlt')][string]$Material = 'Mica',
    [double]$Delay = 2.4,
    [switch]$ExampleDevices,
    [ValidateSet('Pods', 'Other')][string]$DeviceTab = 'Pods',
    [int]$HomeDevPage = 0,
    [switch]$NoDriver,
    [switch]$TestToast,
    [string]$AccentTest
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms
Add-Type -Namespace VentoGlass -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct MARGINS { public int l, r, t, b; }
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(System.IntPtr hwnd, ref MARGINS m);
'@

$root = $PSScriptRoot
$inv = [Globalization.CultureInfo]::InvariantCulture
$deg = [char]0xB0; $dot = [char]0xB7
$script:motion = -not $Snap   # offline renders are still frames

# --- the user's Windows accent (Settings > Personalization > Colors) --------
# Windows keeps 8 shades of the accent; dark mode uses Light 2 for fills and
# Light 3 for text. Read again whenever Windows says the color changed.
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
$acc = Read-AccentPalette
$accSoft = '#24' + $acc.Light2.Substring(1)

# the logo lives next door in design\logo (vento-logo.svg + rendered PNGs + vento.ico)
$logoDir = (Resolve-Path (Join-Path $root '..\logo')).Path
$logoUri = ('file:///' + ((Join-Path $logoDir 'png') -replace '\\', '/') + '/') -replace ' ', '%20'
function Read-Xaml([string]$name) {
    $x = [IO.File]::ReadAllText((Join-Path $root $name))
    $x = $x.Replace('__LOGO__', $logoUri)
    $x = $x.Replace('__ACCENTLIGHT__', $acc.Light3).Replace('__ACCENTSOFT__', $accSoft).Replace('__ACCENTBASE__', $acc.Base).Replace('__ACCENT__', $acc.Light2)
    [Windows.Markup.XamlReader]::Parse($x)
}

$app = [System.Windows.Application]::Current
if (-not $app) { $app = New-Object System.Windows.Application; $app.ShutdownMode = 'OnExplicitShutdown' }
$app.Resources = Read-Xaml 'Glass.Theme.xaml'
$win = Read-Xaml 'Glass.xaml'
$fly = Read-Xaml 'Flyout.xaml'
$ui = @{}
function E([string]$n) {
    if (-not $ui.ContainsKey($n)) { $o = $win.FindName($n); if (-not $o) { $o = $fly.FindName($n) }; $ui[$n] = $o }
    $ui[$n]
}
function Brush([string]$hex) { $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)); $b.Freeze(); $b }
function Pt([double]$x, [double]$y) { $x.ToString('0.##', $inv) + ',' + $y.ToString('0.##', $inv) }
function Col([string]$hex, [byte]$a) { $c = [Windows.Media.ColorConverter]::ConvertFromString($hex); [Windows.Media.Color]::FromArgb($a, $c.R, $c.G, $c.B) }
function Ease { $e = New-Object Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'; $e }
function Anim([double]$from, [double]$to, [int]$ms, [int]$delay = 0) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    if (-not [double]::IsNaN($from)) { $a.From = $from }
    $a.To = $to; $a.Duration = [Windows.Duration][TimeSpan]::FromMilliseconds($ms)
    $a.BeginTime = [TimeSpan]::FromMilliseconds($delay); $a.EasingFunction = Ease
    $a
}

(E 'PcName').Text = $env:COMPUTERNAME
(E 'AccentHex').Text = $acc.Light2

# Real monitor names (EDID) and sizes, so the Displays page shows this desk.
try {
    $names = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
        (($_.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join '')
    })
    $scr = [System.Windows.Forms.Screen]::AllScreens
    $prim = $scr | Where-Object Primary | Select-Object -First 1
    $sec = $scr | Where-Object { -not $_.Primary } | Select-Object -First 1
    # EDID order isn't screen order. Good enough for a preview: an
    # "ultrawide" name belongs to the screen with the wider aspect ratio.
    if ($names.Count -ge 2 -and $prim -and $sec) {
        $ratio = { param($s) $s.Bounds.Width / [double]$s.Bounds.Height }
        $wide = @($names | Where-Object { $_ -match 'WIDE' })
        if ($wide.Count -eq 1 -and (& $ratio $sec) -gt (& $ratio $prim)) {
            $names = @(($names | Where-Object { $_ -ne $wide[0] } | Select-Object -First 1), $wide[0])
        }
    }
    if ($names.Count -ge 1) { (E 'Mon1Name').Text = $names[0] }
    if ($names.Count -ge 2) { (E 'Mon2Name').Text = $names[1] }
    if ($prim) { (E 'Mon1Info').Text = ('Primary {0} {1} x {2}' -f $dot, $prim.Bounds.Width, $prim.Bounds.Height) }
    if ($sec) { (E 'Mon2Info').Text = ('Second display {0} {1} x {2}' -f $dot, $sec.Bounds.Width, $sec.Bounds.Height) }
} catch { }

# --- the glass: DWM system backdrop behind a transparent WPF surface ---------
$materials = @{ Acrylic = 3; Mica = 2; MicaAlt = 4 }
function Get-Hwnd($w) { (New-Object Windows.Interop.WindowInteropHelper $w).Handle }
function Enable-Glass($w) {
    $h = Get-Hwnd $w
    [Windows.Interop.HwndSource]::FromHwnd($h).CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
    $m = New-Object VentoGlass.Dwm+MARGINS; $m.l = -1; $m.r = -1; $m.t = -1; $m.b = -1
    [void][VentoGlass.Dwm]::DwmExtendFrameIntoClientArea($h, [ref]$m)
    $one = 1; [void][VentoGlass.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$one, 4)    # dark frame
    $round = 2; [void][VentoGlass.Dwm]::DwmSetWindowAttribute($h, 33, [ref]$round, 4) # rounded corners
}
function Set-Material($w, $tint, [int]$kind) {
    $h = Get-Hwnd $w
    if ($h -eq [IntPtr]::Zero) { return }
    $v = $kind
    $hr = [VentoGlass.Dwm]::DwmSetWindowAttribute($h, 38, [ref]$v, 4)
    # Acrylic over a busy desktop gets a light dark veil for contrast; Mica is
    # already calm. No backdrop at all (transparency off) -> a solid fill.
    $tint.Background = $(if ($hr -ne 0) { Brush '#202020' } elseif ($kind -eq 3) { Brush '#59101216' } else { [Windows.Media.Brushes]::Transparent })
}
$win.Add_SourceInitialized({ Enable-Glass $win; Set-Material $win (E 'Tint') $materials[$Material] })
$fly.Add_SourceInitialized({ Enable-Glass $fly; Set-Material $fly (E 'FTint') 3 })
foreach ($n in 'MatAcrylic', 'MatMica', 'MatMicaAlt') {
    (E $n).Add_Checked({ param($s, $e) Set-Material $win (E 'Tint') ([int]$s.Tag) })
}
(E @{ Acrylic = 'MatAcrylic'; Mica = 'MatMica'; MicaAlt = 'MatMicaAlt' }[$Material]).IsChecked = $true

# --- navigation: sliding selection pill + staggered page entrance ------------
$pages = 'PageHome', 'PageFans', 'PageAlerts', 'PageProfiles', 'PageDisplays', 'PagePods', 'PageOverlay', 'PageSettings'
$script:reveal = $true
function Move-NavPill($item, [bool]$animate) {
    if (-not $item -or $item.ActualHeight -le 0) { return }
    $p = $item.TranslatePoint((New-Object Windows.Point 0, ($item.ActualHeight / 2 - 8)), (E 'NavGrid'))
    [Windows.Controls.Canvas]::SetLeft((E 'NavPill'), $p.X)
    $t = E 'NavPillT'
    if ($animate -and $script:motion) {
        $t.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Anim ([double]::NaN) $p.Y 280))
        # the pill stretches mid-flight, like NavigationView's indicator
        $k = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        [void]$k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame 16, ([Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero))))
        [void]$k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame 26, ([Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(120)))))
        [void]$k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame 16, ([Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(280)))))
        (E 'NavPill').BeginAnimation([Windows.FrameworkElement]::HeightProperty, $k)
    } else {
        $t.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null); $t.Y = $p.Y
    }
}
function Show-Page([string]$name, [bool]$animate = $true) {
    foreach ($p in $pages) { (E $p).Visibility = $(if ($p -eq $name) { 'Visible' } else { 'Collapsed' }) }
    $pg = E $name
    $pg.ScrollToTop()
    $i = 0
    foreach ($child in $pg.Content.Children) {
        $tt = New-Object Windows.Media.TranslateTransform
        $child.RenderTransform = $tt
        if ($animate -and $script:motion) {
            # base values sit at the start state so nothing flashes during the stagger
            $child.Opacity = 0; $tt.Y = 18
            $d = [math]::Min(7, $i) * 35
            $child.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 0 1 300 $d))
            $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Anim 18 0 420 $d))
        } else {
            $child.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $child.Opacity = 1
        }
        $i++
    }
    $script:reveal = $true
    [void]$pg.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [action]{ Draw-All })
}
foreach ($n in 'NavHome', 'NavFans', 'NavAlerts', 'NavProfiles', 'NavDisplays', 'NavPods', 'NavOverlay', 'NavSettings') {
    (E $n).Add_Checked({ param($s, $e) Show-Page ([string]$s.Tag); Move-NavPill $s $true })
}

# "Find a setting": as you type, jump to the page that owns the word.
$searchMap = [ordered]@{
    Fans     = 'fans fan curve quiet normal performance auto boost speed rpm mode cooling'
    Alerts   = 'alerts alert warning warnings limit limits safety target targets game detection notification notifications'
    Profiles = 'profiles profile gaming movie work'
    Displays = 'displays display monitor brightness contrast input hdmi preset night screen'
    Pods     = 'devices device airpods battery bluetooth headphones earbuds keyboard mouse controller wireless'
    Overlay  = 'overlay osd fps layout blade strip hero pills ghost micro thermo color position corner capture obs'
    Settings = 'settings startup windows tray shortcut shortcuts hotkey keyboard update material acrylic mica accent about version'
    Home     = 'home sensors sensor temperature cpu gpu ssd board'
}
(E 'Search').Add_TextChanged({
    param($s, $e)
    $q = $s.Text.Trim().ToLowerInvariant()
    if ($q.Length -lt 2) { return }
    foreach ($k in $searchMap.Keys) {
        if (@($searchMap[$k].Split(' ') | Where-Object { $_.StartsWith($q) }).Count) {
            if (-not (E "Nav$k").IsChecked) { (E "Nav$k").IsChecked = $true }
            break
        }
    }
})

# --- drawing helpers ---------------------------------------------------------
function Get-Smooth([double[]]$v, [double]$w, [double]$h, [double]$lo, [double]$hi) {
    $n = $v.Count; $pts = New-Object 'System.Collections.Generic.List[Windows.Point]'
    for ($i = 0; $i -lt $n; $i++) {
        $pts.Add((New-Object Windows.Point ($w * $i / ($n - 1)), (2 + ($h - 4) * (1 - (($v[$i] - $lo) / [math]::Max(0.001, $hi - $lo))))))
    }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('M ' + (Pt $pts[0].X $pts[0].Y))
    for ($i = 0; $i -lt $n - 1; $i++) {
        $p0 = $pts[[math]::Max(0, $i - 1)]; $p1 = $pts[$i]; $p2 = $pts[$i + 1]; $p3 = $pts[[math]::Min($n - 1, $i + 2)]
        [void]$sb.Append(' C ' + (Pt ($p1.X + ($p2.X - $p0.X) / 6) ($p1.Y + ($p2.Y - $p0.Y) / 6)) + ' ' +
            (Pt ($p2.X - ($p3.X - $p1.X) / 6) ($p2.Y - ($p3.Y - $p1.Y) / 6)) + ' ' + (Pt $p2.X $p2.Y))
    }
    @{ Line = $sb.ToString(); Last = $pts[$n - 1] }
}
function Add-Series($canvas, [double[]]$v, [string]$hex, [double]$lo, [double]$hi, [byte]$fillTop, [double]$thick, [switch]$Pulse) {
    $w = $canvas.ActualWidth; $h = $canvas.ActualHeight
    if ($w -le 0 -or $h -le 0) { return }
    $s = Get-Smooth $v $w $h $lo $hi
    if ($fillTop -gt 0) {
        $g = New-Object Windows.Media.LinearGradientBrush
        $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop (Col $hex $fillTop), 0))
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop (Col $hex 0), 1))
        $f = New-Object Windows.Shapes.Path
        $f.Data = [Windows.Media.Geometry]::Parse($s.Line + ' L ' + (Pt $w $h) + ' L ' + (Pt 0 $h) + ' Z'); $f.Fill = $g
        [void]$canvas.Children.Add($f)
    }
    $l = New-Object Windows.Shapes.Path
    $l.Data = [Windows.Media.Geometry]::Parse($s.Line); $l.Stroke = Brush $hex; $l.StrokeThickness = $thick; $l.StrokeLineJoin = 'Round'
    [void]$canvas.Children.Add($l)
    if ($Pulse -and $script:motion) {
        # a heartbeat on the live end of the line
        $halo = New-Object Windows.Shapes.Ellipse
        $halo.Width = 20; $halo.Height = 20; $halo.Fill = Brush $hex; $halo.RenderTransformOrigin = '0.5,0.5'
        $st = New-Object Windows.Media.ScaleTransform 0.4, 0.4; $halo.RenderTransform = $st
        [Windows.Controls.Canvas]::SetLeft($halo, $s.Last.X - 12); [Windows.Controls.Canvas]::SetTop($halo, $s.Last.Y - 10)
        [void]$canvas.Children.Add($halo)
        $halo.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 0.45 0 1500))
        $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, (Anim 0.4 1.4 1500))
        $st.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, (Anim 0.4 1.4 1500))
    }
    $d = New-Object Windows.Shapes.Ellipse
    $d.Width = 8; $d.Height = 8; $d.Fill = Brush $hex; $d.Stroke = Brush '#2B2B2B'; $d.StrokeThickness = 2
    [Windows.Controls.Canvas]::SetLeft($d, $s.Last.X - 6); [Windows.Controls.Canvas]::SetTop($d, $s.Last.Y - 4)
    [void]$canvas.Children.Add($d)
}
function Add-HLine($canvas, [double]$y, [string]$hex, [switch]$Dashed) {
    $gl = New-Object Windows.Shapes.Line
    $gl.X1 = 0; $gl.X2 = $canvas.ActualWidth; $gl.Y1 = [math]::Round($y) + 0.5; $gl.Y2 = $gl.Y1
    $gl.Stroke = Brush $hex; $gl.StrokeThickness = 1
    if ($Dashed) { $gl.StrokeDashArray = New-Object Windows.Media.DoubleCollection (, [double[]]@(4, 3)) }
    [void]$canvas.Children.Add($gl)
}
function Add-Text($canvas, [string]$text, [double]$x, [double]$y, [string]$style = 'CaptionTertiary', [switch]$Right) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $text; $t.Style = $app.Resources[$style]; $t.FontSize = 11
    if ($Right) { [Windows.Controls.Canvas]::SetRight($t, $x) } else { [Windows.Controls.Canvas]::SetLeft($t, $x) }
    [Windows.Controls.Canvas]::SetTop($t, $y)
    [void]$canvas.Children.Add($t)
    $t
}
# Charts reveal left to right when a page opens.
function Start-Reveal($canvas) {
    if (-not $script:motion) { $canvas.Clip = $null; return }
    $w = $canvas.ActualWidth; $h = $canvas.ActualHeight + 30
    $rg = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect -20, -20, 0, ($h + 20))
    $canvas.Clip = $rg
    $ra = New-Object Windows.Media.Animation.RectAnimation (New-Object Windows.Rect -20, -20, 0, ($h + 20)), (New-Object Windows.Rect -20, -20, ($w + 40), ($h + 20)), ([Windows.Duration][TimeSpan]::FromMilliseconds(900))
    $ra.EasingFunction = Ease
    $rg.BeginAnimation([Windows.Media.RectangleGeometry]::RectProperty, $ra)
}
# Battery ring: a dashed ellipse whose single dash is the charge, rotated to
# start at 12 o'clock; animating the dash offset fills it like a gauge.
function Draw-Ring($canvas, [double]$pct, [double]$thick, [string]$hex, [bool]$animate, [bool]$charging = $false) {
    $canvas.Children.Clear()
    $sz = $canvas.Width
    $t = New-Object Windows.Shapes.Ellipse
    $t.Width = $sz; $t.Height = $sz; $t.Stroke = Brush '#1FFFFFFF'; $t.StrokeThickness = $thick
    [void]$canvas.Children.Add($t)
    $a = New-Object Windows.Shapes.Ellipse
    $a.Width = $sz; $a.Height = $sz; $a.Stroke = Brush $hex; $a.StrokeThickness = $thick
    $a.StrokeDashCap = 'Round'
    $a.RenderTransform = New-Object Windows.Media.RotateTransform -90, ($sz / 2), ($sz / 2)
    $len = [math]::PI * ($sz - $thick) * $pct / 100 / $thick
    $a.StrokeDashArray = New-Object Windows.Media.DoubleCollection (, [double[]]@($len, 1000))
    [void]$canvas.Children.Add($a)
    if ($animate -and $script:motion) { $a.BeginAnimation([Windows.Shapes.Shape]::StrokeDashOffsetProperty, (Anim $len 0 900 120)) }
    if ($charging) {
        # charging: the ring breathes a soft glow and a bright spark runs round it
        $glow = New-Object Windows.Media.Effects.DropShadowEffect
        $glow.ShadowDepth = 0; $glow.BlurRadius = $thick * 2.2; $glow.Color = (Col $hex 255); $glow.Opacity = 0.6
        $a.Effect = $glow
        $spark = New-Object Windows.Shapes.Ellipse
        $spark.Width = $sz; $spark.Height = $sz; $spark.StrokeThickness = $thick
        $spark.StrokeDashCap = 'Round'
        $sg = New-Object Windows.Media.LinearGradientBrush; $sg.StartPoint = '0,0'; $sg.EndPoint = '1,1'
        $sg.GradientStops.Add((New-Object Windows.Media.GradientStop (Col '#FFFFFF' 0xE6), 0))
        $sg.GradientStops.Add((New-Object Windows.Media.GradientStop (Col $hex 0xE6), 1))
        $spark.Stroke = $sg
        $spark.StrokeDashArray = New-Object Windows.Media.DoubleCollection (, [double[]]@(0.6, 1000))
        $rot = New-Object Windows.Media.RotateTransform -90, ($sz / 2), ($sz / 2)
        $spark.RenderTransform = $rot
        [void]$canvas.Children.Add($spark)
        if ($script:motion) {
            $run = New-Object Windows.Media.Animation.DoubleAnimation -90, 270, ([Windows.Duration][TimeSpan]::FromSeconds(1.8))
            $run.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $rot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $run)
            $br = New-Object Windows.Media.Animation.DoubleAnimation 0.25, 0.9, ([Windows.Duration][TimeSpan]::FromSeconds(1.1))
            $br.AutoReverse = $true; $br.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $br.EasingFunction = New-Object Windows.Media.Animation.SineEase
            $glow.BeginAnimation([Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $br)
        }
    }
}
# the little bolt beside "Charging" blinks gently while it is true
function Start-BoltPulse($el) {
    if (-not $script:motion -or -not $el) { return }
    $p = New-Object Windows.Media.Animation.DoubleAnimation 1, 0.35, ([Windows.Duration][TimeSpan]::FromSeconds(0.9))
    $p.AutoReverse = $true; $p.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $p)
}

# --- fake live data: slow sines + a pinch of noise ---------------------------
$rnd = New-Object Random 11
$gen = @{
    Mb = @{ B = 59; A = 0.9; P1 = 1.2; P2 = 3.3 }; Cpu = @{ B = 60; A = 2.4; P1 = 0.3; P2 = 1.9 }
    Gpu = @{ B = 54; A = 1.6; P1 = 2.1; P2 = 0.4 }; Ssd = @{ B = 42; A = 0.7; P1 = 4.0; P2 = 2.6 }
    CpuFan = @{ B = 1950; A = 70; P1 = 0.7; P2 = 2.2 }; CaseFan = @{ B = 720; A = 26; P1 = 3.1; P2 = 0.9 }
}
function Val([string]$k, [int]$i) {
    $g = $gen[$k]; $g.B + $g.A * (0.6 * [math]::Sin($i * 0.42 + $g.P1) + 0.4 * [math]::Sin($i * 0.15 + $g.P2)) + ($rnd.NextDouble() - 0.5) * $g.A * 0.2
}
$series = @{}
foreach ($k in $gen.Keys) { $series[$k] = [double[]](0..47 | ForEach-Object { Val $k $_ }) }
$script:tick = 48
function Push([string]$k, [double]$v) {
    $a = $series[$k]; $n = $a.Count; $b = New-Object 'double[]' $n
    [Array]::Copy($a, 1, $b, 0, $n - 1); $b[$n - 1] = $v; $series[$k] = $b
}

# --- thermal state: glow, chip and chart follow the board ----------------
$thermal = [ordered]@{
    cool = @{ Hex = $acc.Light2; Text = $acc.Light3; Temp = 59 }
    warm = @{ Hex = '#FFB547'; Text = '#FFD08A'; Temp = 66; Chip = "Over target $dot fans ramping"; Status = "The board is 4$deg over its target. Case fans are ramping up." }
    hot  = @{ Hex = '#FF8A80'; Text = '#FFB4AD'; Temp = 74; Chip = "Hot $dot boost is on"; Status = 'The board is running hot. Boost is on at 80%.' }
}
$script:state = 'cool'
function Set-Thermal([string]$name) {
    $script:state = $name; $s = $thermal[$name]
    (E 'HeroGlowStop').Color = Col $s.Hex 0x2E
    (E 'HeroGlowEnd').Color = Col $s.Hex 0
    (E 'HeroChip').Background = Brush ('#26' + $s.Hex.Substring(1))
    (E 'HeroChipText').Foreground = Brush $s.Text
    (E 'FDot').Fill = Brush $s.Hex
    $gen.Mb.B = $s.Temp
    $series['Mb'] = [double[]](0..47 | ForEach-Object { Val 'Mb' ($script:tick - 47 + $_) })
    Update-Readouts
}
(E 'HeroTempHost').Add_MouseLeftButtonUp({
    $order = @($thermal.Keys); Set-Thermal $order[($order.IndexOf($script:state) + 1) % $order.Count]
    $script:reveal = $true; Draw-All
})

function Update-Readouts {
    $mb = $series.Mb[-1]
    (E 'HeroTemp').Text = ('{0:0}' -f $mb)
    (E 'FBoard').Text = ('Board {0:0}{1}' -f $mb, $deg)
    if ($script:state -eq 'cool') {
        $under = [math]::Max(1, [math]::Round(62 - $mb))
        (E 'HeroChipText').Text = "Nearing target $dot $under$deg below"
        (E 'HomeStatus').Text = "All quiet. The board is $under$deg under its target."
    } else {
        (E 'HeroChipText').Text = $thermal[$script:state].Chip
        (E 'HomeStatus').Text = $thermal[$script:state].Status
    }
    (E 'TCpu').Text = ('{0:0}{1}' -f $series.Cpu[-1], $deg); (E 'QCpu').Text = (E 'TCpu').Text
    (E 'TGpu').Text = ('{0:0}{1}' -f $series.Gpu[-1], $deg); (E 'QGpu').Text = (E 'TGpu').Text
    (E 'TSsd').Text = ('{0:0}{1}' -f $series.Ssd[-1], $deg)
    (E 'RCpu').Text = ('{0:0}' -f $series.CpuFan[-1]); (E 'QRpm').Text = (E 'RCpu').Text
    (E 'RCase').Text = ('{0:0}' -f $series.CaseFan[-1])
}

function Draw-Meter([bool]$animate) {
    $m = E 'MeterMarks'; $m.Children.Clear()
    $w = (E 'MeterHost').ActualWidth; if ($w -le 0) { return }
    $x = { param($d) $w * ([math]::Min(85, [math]::Max(40, $d)) - 40) / 45.0 }
    $tick = New-Object Windows.Shapes.Rectangle
    $tick.Width = 2; $tick.Height = 14; $tick.Fill = Brush '#CCFFFFFF'; $tick.RadiusX = 1; $tick.RadiusY = 1
    [Windows.Controls.Canvas]::SetLeft($tick, (& $x 62) - 1); [Windows.Controls.Canvas]::SetTop($tick, 1)
    [void]$m.Children.Add($tick)
    [void](Add-Text $m "62$deg target" ((& $x 62) - 26) 17)
    $dotEl = New-Object Windows.Shapes.Ellipse
    $dotEl.Width = 16; $dotEl.Height = 16; $dotEl.Fill = Brush '#FFFFFF'; $dotEl.Stroke = Brush '#2B2B2B'; $dotEl.StrokeThickness = 3
    [Windows.Controls.Canvas]::SetTop($dotEl, 0)
    [void]$m.Children.Add($dotEl)
    $to = (& $x $series.Mb[-1]) - 8
    if ($animate -and $script:motion) { $dotEl.BeginAnimation([Windows.Controls.Canvas]::LeftProperty, (Anim -8 $to 900 100)) }
    else { [Windows.Controls.Canvas]::SetLeft($dotEl, $to) }
}

function Draw-HeroChart([bool]$reveal) {
    $c = E 'HeroChart'; $c.Children.Clear()
    $h = $c.ActualHeight; if ($h -le 0) { return }
    $s = $thermal[$script:state]
    $lo = $s.Temp - 6; $hi = $s.Temp + 6
    $y = { param($v) 2 + ($h - 4) * (1 - (($v - $lo) / ($hi - $lo))) }
    Add-HLine $c (& $y $hi) '#10FFFFFF'; Add-HLine $c (& $y $lo) '#10FFFFFF'
    if (62 -gt $lo -and 62 -lt $hi) {
        Add-HLine $c (& $y 62) '#40FFFFFF' -Dashed
        [void](Add-Text $c "Target 62$deg" 0 ((& $y 62) - 17) -Right)
    }
    Add-Series $c $series.Mb $s.Hex $lo $hi 0x55 2 -Pulse
    if ($reveal) { Start-Reveal $c }
}

# Each airflow line is drawn from nothing, left to right (a widening clip),
# one fan after another, then the icon stays put.
function Draw-AirflowIn {
    $i = 0
    foreach ($n in 'SpinCpu', 'SpinCase', 'SpinGpu') {
        $el = E $n
        if (-not $script:motion) { $el.Clip = $null; continue }
        $rg = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect 0, 0, 0, 24)
        $el.Clip = $rg
        $ra = New-Object Windows.Media.Animation.RectAnimation (New-Object Windows.Rect 0, 0, 0, 24), (New-Object Windows.Rect 0, 0, 24, 24), ([Windows.Duration][TimeSpan]::FromMilliseconds(650))
        $ra.BeginTime = [TimeSpan]::FromMilliseconds(250 + 140 * $i); $ra.EasingFunction = Ease
        $rg.BeginAnimation([Windows.Media.RectangleGeometry]::RectProperty, $ra)
        $i++
    }
}

function Draw-All {
    $rv = $script:reveal; $script:reveal = $false
    $a2 = $acc.Light2
    if ((E 'PageHome').Visibility -eq 'Visible') {
        if ($rv) { Draw-AirflowIn }
        Draw-HeroChart $rv
        Draw-Meter $rv
    }
    if ((E 'PageFans').Visibility -eq 'Visible') {
        $c = E 'FansChart'; $c.Children.Clear()
        if ($c.ActualHeight -gt 0) {
            foreach ($f in 0, 0.5, 1) { Add-HLine $c (2 + ($c.ActualHeight - 4) * $f) '#12FFFFFF' }
            Add-Series $c $series.CaseFan $a2 0 2800 0x50 2 -Pulse
            Add-Series $c $series.CpuFan '#E6FFFFFF' 0 2800 0 1.6
            if ($rv) { Start-Reveal $c }
        }
        if ((E 'CurvePanel').Visibility -eq 'Visible') { Draw-Curve }
    }
    if ($rv -and (E 'PagePods').Visibility -eq 'Visible') { Show-PodRings }
}

function Tick {
    $script:tick++
    foreach ($k in $gen.Keys) { Push $k (Val $k $script:tick) }
    Update-Readouts
    (E 'RGpu').Text = [string](1018 + $rnd.Next(-4, 5))
    if ($script:osdFpsTb) { $script:osdFpsTb.Text = [string](144 - $rnd.Next(0, 4)) }
    Update-CheckedLabel; if (Get-Command Update-PodsUpdated -ErrorAction SilentlyContinue) { Update-PodsUpdated }
    Draw-All
}

# --- spinning fans: each icon turns at its fan's speed ----------------------
function Set-Spin($el, [double]$rpm) {
    # the airflow glyphs hold still; they draw themselves in when Home opens
    # (Draw-AirflowIn), so nothing here moves anymore
    return
}

# --- fan curve editor (the real curve from this PC's settings) ---------------
$curveKeys = 40, 55, 70, 80
$curveDefault = @{ 40 = 25; 55 = 40; 70 = 65; 80 = 100 }
$script:curve = @{} + $curveDefault
$script:dragT = $null
$cv = @{ L = 44; R = 18; T = 34; B = 26 }
function CurveX([double]$t) { $w = (E 'CurveCanvas').ActualWidth; $cv.L + ($t - 30) / 60.0 * ($w - $cv.L - $cv.R) }
function CurveY([double]$d) { $h = (E 'CurveCanvas').ActualHeight; $cv.T + (1 - $d / 100.0) * ($h - $cv.T - $cv.B) }
function Get-CurveDuty([double]$t) {
    if ($t -le 40) { return $script:curve[40] }
    if ($t -ge 80) { return $script:curve[80] }
    for ($i = 0; $i -lt 3; $i++) {
        $a = $curveKeys[$i]; $b = $curveKeys[$i + 1]
        if ($t -le $b) { return $script:curve[$a] + ($script:curve[$b] - $script:curve[$a]) * ($t - $a) / ($b - $a) }
    }
}
function Draw-Curve {
    $c = E 'CurveCanvas'; $c.Children.Clear()
    $w = $c.ActualWidth; $h = $c.ActualHeight; if ($w -le 0) { return }
    foreach ($d in 0, 25, 50, 75, 100) {
        $y = CurveY $d
        $gl = New-Object Windows.Shapes.Line
        $gl.X1 = $cv.L; $gl.X2 = $w - $cv.R; $gl.Y1 = [math]::Round($y) + 0.5; $gl.Y2 = $gl.Y1; $gl.Stroke = Brush '#12FFFFFF'
        [void]$c.Children.Add($gl)
        [void](Add-Text $c "$d%" 0 ($y - 8))
    }
    for ($t = 30; $t -le 90; $t += 10) { [void](Add-Text $c "$t$deg" ((CurveX $t) - 9) ($h - $cv.B + 8)) }
    # flat before the first point and after the last; the leading comma keeps
    # each pair a pair instead of letting @() flatten it
    $pts = @(, @(30, $script:curve[40])) + @($curveKeys | ForEach-Object { , @($_, $script:curve[$_]) }) + @(, @(90, $script:curve[80]))
    $line = 'M ' + (($pts | ForEach-Object { Pt (CurveX $_[0]) (CurveY $_[1]) }) -join ' L ')
    $g = New-Object Windows.Media.LinearGradientBrush
    $g.StartPoint = '0,0'; $g.EndPoint = '0,1'
    $g.GradientStops.Add((New-Object Windows.Media.GradientStop (Col $acc.Light2 0x46), 0))
    $g.GradientStops.Add((New-Object Windows.Media.GradientStop (Col $acc.Light2 0x05), 1))
    $f = New-Object Windows.Shapes.Path
    $f.Data = [Windows.Media.Geometry]::Parse($line + ' L ' + (Pt (CurveX 90) (CurveY 0)) + ' L ' + (Pt (CurveX 30) (CurveY 0)) + ' Z'); $f.Fill = $g
    [void]$c.Children.Add($f)
    $l = New-Object Windows.Shapes.Path
    $l.Data = [Windows.Media.Geometry]::Parse($line); $l.Stroke = Brush $acc.Light2; $l.StrokeThickness = 2; $l.StrokeLineJoin = 'Round'
    [void]$c.Children.Add($l)
    # where the board is right now, and the speed that buys
    $mb = $series.Mb[-1]; $now = Get-CurveDuty $mb; $bx = CurveX $mb
    $vl = New-Object Windows.Shapes.Line
    $vl.X1 = $bx; $vl.X2 = $bx; $vl.Y1 = CurveY 100; $vl.Y2 = CurveY 0; $vl.Stroke = Brush '#55FFFFFF'
    $vl.StrokeDashArray = New-Object Windows.Media.DoubleCollection (, [double[]]@(3, 3))
    [void]$c.Children.Add($vl)
    $bd = New-Object Windows.Shapes.Ellipse
    $bd.Width = 10; $bd.Height = 10; $bd.Fill = Brush '#FFFFFF'
    [Windows.Controls.Canvas]::SetLeft($bd, $bx - 5); [Windows.Controls.Canvas]::SetTop($bd, (CurveY $now) - 5)
    [void]$c.Children.Add($bd)
    $lbl = Add-Text $c ('Board {0:0}{1}  {2}  {3:0}%' -f $mb, $deg, [char]0x2192, $now) ($bx + 8) ((CurveY 100) - 26) 'Caption'
    $lbl.Foreground = Brush '#FFFFFF'
    foreach ($k in $curveKeys) {
        $x = CurveX $k; $y = CurveY $script:curve[$k]
        $th = New-Object Windows.Controls.Grid
        $th.Width = 22; $th.Height = 22; $th.Cursor = [Windows.Input.Cursors]::SizeNS
        $o = New-Object Windows.Shapes.Ellipse; $o.Fill = Brush '#454545'; $o.Stroke = Brush '#33FFFFFF'
        $i = New-Object Windows.Shapes.Ellipse; $i.Width = $(if ($script:dragT -eq $k) { 10 } else { 12 }); $i.Height = $i.Width; $i.Fill = Brush $acc.Light2
        [void]$th.Children.Add($o); [void]$th.Children.Add($i)
        [Windows.Controls.Canvas]::SetLeft($th, $x - 11); [Windows.Controls.Canvas]::SetTop($th, $y - 11)
        [void]$c.Children.Add($th)
        $v = Add-Text $c ('{0}%' -f $script:curve[$k]) ($x - 13) ($y - 30) 'BodyStrong'
        $v.FontSize = 12; $v.Width = 26; $v.TextAlignment = 'Center'
    }
}
$cc = E 'CurveCanvas'
$cc.Add_MouseLeftButtonDown({
    param($s, $e)
    $p = $e.GetPosition($cc)
    foreach ($k in $curveKeys) {
        if ([math]::Abs($p.X - (CurveX $k)) -lt 16 -and [math]::Abs($p.Y - (CurveY $script:curve[$k])) -lt 16) {
            $script:dragT = $k; [void]$cc.CaptureMouse(); Draw-Curve; break
        }
    }
})
$cc.Add_MouseMove({
    param($s, $e)
    if ($null -eq $script:dragT) { return }
    $p = $e.GetPosition($cc)
    $h = $cc.ActualHeight
    $d = [math]::Round((1 - ($p.Y - $cv.T) / ($h - $cv.T - $cv.B)) * 100)
    # a curve never dips: each point stays between its neighbours
    $i = [array]::IndexOf($curveKeys, $script:dragT)
    $min = $(if ($i -gt 0) { $script:curve[$curveKeys[$i - 1]] } else { 0 })
    $max = $(if ($i -lt 3) { $script:curve[$curveKeys[$i + 1]] } else { 100 })
    $script:curve[$script:dragT] = [int][math]::Max($min, [math]::Min($max, $d))
    Draw-Curve
})
$cc.Add_MouseLeftButtonUp({ $script:dragT = $null; $cc.ReleaseMouseCapture(); Draw-Curve; Set-Mode 'Curve' })
(E 'CurveReset').Add_Click({ $script:curve = @{} + $curveDefault; Draw-Curve; Set-Mode 'Curve' })

# --- modes: Home cards, the Fans segmented control and the flyout tiles agree
$modeData = @{
    Quiet  = @{ Title = 'Quiet mode'; Name = 'Quiet'; V = 30, 75, 65, 80; Case = 30; Cpu = 62 }
    Normal = @{ Title = 'Normal mode'; Name = 'Normal'; V = 50, 75, 65, 80; Case = 50; Cpu = 70 }
    Perf   = @{ Title = 'Performance mode'; Name = 'Performance'; V = 100, 70, 60, 100; Case = 100; Cpu = 100 }
    Curve  = @{ Title = 'Curve mode'; Name = 'Curve'; V = 30, 75, 65, 80; Case = -1; Cpu = 62 }
    Auto   = @{ Title = 'Auto mode'; Name = 'Auto'; V = 50, 75, 65, 80; Case = 50; Cpu = 70 }
}
$script:syncing = $false
function Set-Mode([string]$m) {
    if ($script:syncing) { return }
    $script:syncing = $true
    try {
        (E "M$m").IsChecked = $true; (E "F$m").IsChecked = $true; (E "Q$m").IsChecked = $true
        $d = $modeData[$m]; $script:mode = $m
        (E 'FansSection').Text = $d.Title
        (E 'HomeFansMode').Text = $(if ((E 'DriverBar').Visibility -eq 'Visible') { 'Paused' } else { $d.Name })
        (E 'SlidersPanel').Visibility = $(if ($m -eq 'Curve') { 'Collapsed' } else { 'Visible' })
        (E 'CurvePanel').Visibility = $(if ($m -eq 'Curve') { 'Visible' } else { 'Collapsed' })
        for ($i = 1; $i -le 4; $i++) { (E "S$i").Value = $d.V[$i - 1] }
        # the numbers and the spinning icons follow the new duty
        $case = $(if ($d.Case -lt 0) { [math]::Round((Get-CurveDuty $series.Mb[-1])) } else { $d.Case })
        (E 'DutyCase').Text = "$case% duty"; (E 'DutyCpu').Text = "$($d.Cpu)% duty"
        $gen.CaseFan.B = 300 + 14 * $case; $gen.CpuFan.B = 700 + 20 * $d.Cpu
        Set-Spin (E 'SpinCase') $gen.CaseFan.B; Set-Spin (E 'SpinCpu') $gen.CpuFan.B
        (E 'QCase').Value = $case
        if ((E 'CurvePanel').Visibility -eq 'Visible') { [void]$win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [action]{ Draw-Curve }) }
    } finally { $script:syncing = $false }
}
foreach ($m in $modeData.Keys) {
    foreach ($pre in 'M', 'F', 'Q') { (E "$pre$m").Add_Checked({ param($s, $e) Set-Mode ([string]$s.Tag) }) }
}
$fmt = @{ S1 = '{0:0}%'; S2 = "{0:0}$deg"; S3 = "{0:0}$deg"; S4 = '{0:0}%' }
for ($i = 1; $i -le 4; $i++) {
    $v = E "V$i"; $f = $fmt["S$i"]
    (E "S$i").Add_ValueChanged({ param($s, $e) $v.Text = ($f -f $s.Value) }.GetNewClosure())
}
(E 'QCase').Add_ValueChanged({ param($s, $e) (E 'QCaseV').Text = ('{0:0}%' -f $s.Value) })
foreach ($p in @(@('B1', 'B1V'), @('C1', 'C1V'), @('B2', 'B2V'), @('C2', 'C2V'))) {
    $v = E $p[1]
    (E $p[0]).Add_ValueChanged({ param($s, $e) $v.Text = ('{0:0}' -f $s.Value) }.GetNewClosure())
}

# --- display presets ---------------------------------------------------------
function Set-Preset($rb) {
    $v = ([string]$rb.Tag).Split(',')
    $i = 0
    foreach ($n in 'B1', 'C1', 'B2', 'C2') {
        $sl = E $n; $to = [double]$v[$i]; $i++
        # glide there, then let go so the slider stays draggable
        $from = $sl.Value; $sl.Value = $to
        if ($script:motion) {
            $a = Anim $from $to 450; $a.FillBehavior = 'Stop'
            $sl.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $a)
        }
    }
}
foreach ($n in 'PresetDay', 'PresetGame', 'PresetCinema') { (E $n).Add_Checked({ param($s, $e) Set-Preset $s }) }

# --- profiles (this PC's real three) ---------------------------------------
$profiles = @{
    Gaming = @{ Mode = 'Perf'; Overlay = $true; Preset = 'PresetGame' }
    Movie  = @{ Mode = 'Quiet'; Overlay = $false; Preset = 'PresetCinema' }
    Work   = @{ Mode = 'Normal'; Overlay = $false; Preset = 'PresetDay' }
}
$script:profSync = $false
function Set-Profile([string]$name) {
    if ($script:profSync) { return }
    $script:profSync = $true
    try {
        $p = $profiles[$name]
        (E "Chip$name").IsChecked = $true
        foreach ($k in $profiles.Keys) { (E "Badge$k").Visibility = $(if ($k -eq $name) { 'Visible' } else { 'Collapsed' }) }
        Set-Mode $p.Mode
        (E 'QOverlay').IsChecked = $p.Overlay
        (E $p.Preset).IsChecked = $true
        (E 'QProfile').Text = "$name profile"
    } finally { $script:profSync = $false }
}
foreach ($n in 'Gaming', 'Movie', 'Work') {
    (E "Chip$n").Add_Checked({ param($s, $e) Set-Profile ([string]$s.Tag) })
    (E "Apply$n").Add_Click({ param($s, $e) Set-Profile ([string]$s.Tag) })
}
(E 'GoHotkeys').Add_Click({
    (E 'NavSettings').IsChecked = $true
    [void]$win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [action]{ (E 'ShortcutsTitle').BringIntoView() })
})

# --- overlay: color themes (the app's six) and corner -----------------------
$osdThemes = @{
    sirocco = @{ Acc = '#6FB1FF'; Panel = '#DC0A0D13'; Border = '#26FFFFFF'; Ink = '#EDF1F8'; Lab = '#8FA3BC' }
    ember   = @{ Acc = '#FFB25C'; Panel = '#DE130D09'; Border = '#38FFB25C'; Ink = '#F8F1E9'; Lab = '#BCA88F' }
    venom   = @{ Acc = '#7CF29B'; Panel = '#DE08100B'; Border = '#337CF29B'; Ink = '#EAF8EE'; Lab = '#8FBC9E' }
    violet  = @{ Acc = '#B18CFF'; Panel = '#DE0E0A14'; Border = '#38B18CFF'; Ink = '#F2EDF8'; Lab = '#A393BC' }
    crimson = @{ Acc = '#FF6B7E'; Panel = '#DE13090B'; Border = '#38FF6B7E'; Ink = '#F8EDEE'; Lab = '#BC8F97' }
    mono    = @{ Acc = '#FFFFFF'; Panel = '#D209090C'; Border = '#2EFFFFFF'; Ink = '#F2F4F7'; Lab = '#9AA3B0' }
}
foreach ($n in 'ThSirocco', 'ThEmber', 'ThVenom', 'ThViolet', 'ThCrimson', 'ThMono') {
    (E $n).Add_Checked({
        param($s, $e)
        $t = $osdThemes[[string]$s.Tag]
        $win.Resources['OsdAccentBrush'] = Brush $t.Acc; $win.Resources['OsdPanelBrush'] = Brush $t.Panel
        $win.Resources['OsdBorderBrush'] = Brush $t.Border; $win.Resources['OsdInkBrush'] = Brush $t.Ink
        $win.Resources['OsdLabBrush'] = Brush $t.Lab
        (E 'OsdThemeName').Text = (Get-Culture).TextInfo.ToTitleCase([string]$s.Tag)
    })
}
foreach ($n in 'CorTL', 'CorTR', 'CorBL', 'CorBR') {
    (E $n).Add_Checked({
        param($s, $e)
        $o = E 'OsdMock'
        $o.HorizontalAlignment = $(if ($s.Name -like '*L') { 'Left' } else { 'Right' })
        $o.VerticalAlignment = $(if ($s.Name -like 'CorT*') { 'Top' } else { 'Bottom' })
        (E 'OsdCornerName').Text = [string]$s.Tag
    })
}

# --- shortcuts: rows built here; Record listens for the next combination ----
$hotkeys = 'Show or hide the overlay', 'Quiet mode', 'Normal mode', 'Performance mode', 'Auto mode', 'Next profile'
$script:rec = $null
function New-Keycap([string]$text) {
    $b = New-Object Windows.Controls.Border; $b.Style = $app.Resources['Keycap']
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.Style = $app.Resources['Caption']; $t.Foreground = $app.Resources['TextPrimaryBrush']
    $b.Child = $t; $b
}
function Set-Keys($panel, $items) {
    $panel.Children.Clear()
    if (-not $items) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = 'Not set'; $t.Style = $app.Resources['CaptionTertiary']; $t.VerticalAlignment = 'Center'
        [void]$panel.Children.Add($t); return
    }
    foreach ($k in $items) { [void]$panel.Children.Add((New-Keycap $k)) }
}
$rows = E 'HotkeyRows'
for ($i = 0; $i -lt $hotkeys.Count; $i++) {
    $g = New-Object Windows.Controls.Grid; $g.MinHeight = 54
    foreach ($w in '*', 'Auto', 'Auto') {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = $(if ($w -eq '*') { New-Object Windows.GridLength 1, 'Star' } else { [Windows.GridLength]::Auto }); $g.ColumnDefinitions.Add($cd)
    }
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $hotkeys[$i]; $t.Style = $app.Resources['Body']; $t.VerticalAlignment = 'Center'
    $kp = New-Object Windows.Controls.StackPanel; $kp.Orientation = 'Horizontal'; $kp.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($kp, 1); Set-Keys $kp $null
    $btn = New-Object Windows.Controls.Button; $btn.Style = $app.Resources['FluentButton']; $btn.Content = 'Record'
    $btn.FontSize = 13; $btn.MinHeight = 28; $btn.Padding = '12,3'; $btn.Margin = '14,0,0,0'; $btn.VerticalAlignment = 'Center'; $btn.MinWidth = 96
    [Windows.Controls.Grid]::SetColumn($btn, 2)
    [void]$g.Children.Add($t); [void]$g.Children.Add($kp); [void]$g.Children.Add($btn)
    # the button carries its key panel, so one handler serves every row
    $btn.Tag = $kp
    $btn.Add_Click({
        param($s, $e)
        $kp = $s.Tag
        if ($script:rec) { $script:rec.Btn.Content = $script:rec.Prev; Set-Keys $script:rec.Panel $script:rec.Old }
        $script:rec = @{ Panel = $kp; Btn = $s; Prev = $s.Content; Old = $kp.Tag }
        $s.Content = 'Press keys...'
        $kp.Children.Clear()
        $w = New-Object Windows.Controls.TextBlock; $w.Text = 'Listening'; $w.Style = $app.Resources['Caption']; $w.Foreground = $app.Resources['AccentTextBrush']
        [void]$kp.Children.Add($w)
    })
    [void]$rows.Children.Add($g)
    if ($i -lt $hotkeys.Count - 1) {
        $dv = New-Object Windows.Controls.Border; $dv.Height = 1; $dv.Background = $app.Resources['DividerBrush']; $dv.Margin = '0'
        [void]$rows.Children.Add($dv)
    }
}
$win.Add_PreviewKeyDown({
    param($s, $e)
    if (-not $script:rec) { return }
    $e.Handled = $true
    $k = $(if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key })
    if ($k -eq 'Escape') { $script:rec.Btn.Content = $script:rec.Prev; Set-Keys $script:rec.Panel $script:rec.Old; $script:rec = $null; return }
    if ('LeftCtrl', 'RightCtrl', 'LeftShift', 'RightShift', 'LeftAlt', 'RightAlt', 'LWin', 'RWin' -contains [string]$k) { return }
    $mods = [Windows.Input.Keyboard]::Modifiers
    $items = @()
    if ($mods -band [Windows.Input.ModifierKeys]::Control) { $items += 'Ctrl' }
    if ($mods -band [Windows.Input.ModifierKeys]::Alt) { $items += 'Alt' }
    if ($mods -band [Windows.Input.ModifierKeys]::Shift) { $items += 'Shift' }
    if ($mods -band [Windows.Input.ModifierKeys]::Windows) { $items += 'Win' }
    $name = [string]$k
    if ($name -match '^D(\d)$') { $name = $Matches[1] } elseif ($name -match '^NumPad(\d)$') { $name = 'Num ' + $Matches[1] }
    $items += $name
    Set-Keys $script:rec.Panel $items; $script:rec.Panel.Tag = $items
    $script:rec.Btn.Content = 'Change'
    $script:rec = $null
})

# --- devices: only what is connected right now, refreshed in the background --
# Paired-but-away devices never show. Windows says whether a Bluetooth device
# is connected, and publishes battery for many of them (headsets over
# Hands-Free, BLE mice and keyboards) on a child node of the device. AirPods
# don't publish one; Vento reads theirs from the BLE broadcasts (fake here).
$batteryKey = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2'
$connectedKey = '{83DA6326-97A6-4088-9453-A1923F573B29} 15'
function Get-DeviceGlyph([string]$n) {
    if ($n -match 'airpods|buds|head|arctis|nova|earbud|wh-|wf-|jabra|beats') { return [string][char]0xE7F6 }
    if ($n -match 'keyboard|keys') { return [string][char]0xE765 }
    if ($n -match 'mouse|mx master|viper|g pro') { return [string][char]0xE962 }
    if ($n -match 'controller|xbox|dualsense|gamepad') { return [string][char]0xE7FC }
    [string][char]0xE702
}
$script:devices = @()
$script:scanned = $false
$script:example = $false
$script:hadPods = $false

function New-DeviceIcon([string]$glyph) {
    $b = New-Object Windows.Controls.Border; $b.Style = $app.Resources['IconTile']
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $glyph; $t.Style = $app.Resources['Glyph']; $t.HorizontalAlignment = 'Center'
    $b.Child = $t; $b
}
function New-Text([string]$text, [string]$style) {
    $t = New-Object Windows.Controls.TextBlock; $t.Text = $text; $t.Style = $app.Resources[$style]; $t.VerticalAlignment = 'Center'; $t
}
function New-Row3([int]$minH, [string]$margin) {
    $g = New-Object Windows.Controls.Grid; $g.MinHeight = $minH; $g.Margin = $margin
    foreach ($w in 36, -1, -2) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = $(if ($w -gt 0) { New-Object Windows.GridLength $w } elseif ($w -eq -1) { New-Object Windows.GridLength 1, 'Star' } else { [Windows.GridLength]::Auto })
        $g.ColumnDefinitions.Add($cd)
    }
    $g
}
function Get-BatteryBrush($v) { if ($null -ne $v -and $v -le 20) { Brush '#FF99A4' } else { $app.Resources['AccentBrush'] } }

# Home card pages: one battery page per connected device (AirPods first),
# then the compact list. The arrows in the card header step through them.
$script:homePage = 0
function Get-HomePages {
    $pages = @()
    foreach ($d in ($script:devices | Sort-Object { -not $_.Apple })) { $pages += , @{ Kind = 'battery'; Dev = $d } }
    if ($script:devices.Count -gt 1) { $pages += , @{ Kind = 'list' } }
    , $pages
}
function New-RingTile([double]$size, [double]$thick, $pct, [string]$hex, [string]$label, [bool]$charging) {
    $sp = New-Object Windows.Controls.StackPanel; $sp.HorizontalAlignment = 'Center'
    $g = New-Object Windows.Controls.Grid; $g.Width = $size; $g.Height = $size
    $c = New-Object Windows.Controls.Canvas; $c.Width = $size; $c.Height = $size
    Draw-Ring $c $(if ($null -eq $pct) { 0 } else { $pct }) $thick $hex $true $charging
    $txt = New-Text $(if ($null -eq $pct) { [string][char]0x2014 } else { "$pct" }) 'BodyStrong'
    $txt.FontSize = [math]::Round($size / 4.2); $txt.HorizontalAlignment = 'Center'
    if ($null -ne $pct -and $pct -le 20) { $txt.Foreground = Brush '#FF99A4' }
    [void]$g.Children.Add($c); [void]$g.Children.Add($txt)
    [void]$sp.Children.Add($g)
    $lb = New-Object Windows.Controls.StackPanel; $lb.Orientation = 'Horizontal'; $lb.HorizontalAlignment = 'Center'; $lb.Margin = '0,6,0,0'
    if ($charging) { $bolt = New-Text ([string][char]0xE945) 'Glyph'; $bolt.FontSize = 10; $bolt.Foreground = $app.Resources['SuccessBrush']; $bolt.Margin = '0,0,4,0'; [void]$lb.Children.Add($bolt); Start-BoltPulse $bolt }
    [void]$lb.Children.Add((New-Text $label 'Caption'))
    [void]$sp.Children.Add($lb)
    $sp
}
function Render-HomeDevices([int]$dir = 0) {
    $home_ = E 'HomeDevices'; $home_.Children.Clear()
    $pages = Get-HomePages
    (E 'DevPager').Visibility = $(if ($pages.Count -gt 1) { 'Visible' } else { 'Collapsed' })
    if (-not $pages.Count) {
        $t = New-Text $(if ($script:scanned) { 'No wireless devices connected' } else { 'Looking for devices...' }) 'Caption'
        $t.Margin = '0,12,0,0'; [void]$home_.Children.Add($t); return
    }
    if ($script:homePage -ge $pages.Count) { $script:homePage = 0 }
    (E 'DevPageText').Text = '{0} / {1}' -f ($script:homePage + 1), $pages.Count
    $p = $pages[$script:homePage]
    if ($p.Kind -eq 'battery') {
        $d = $p.Dev
        $hd = New-Object Windows.Controls.StackPanel; $hd.Orientation = 'Horizontal'; $hd.Margin = '0,6,0,12'
        $gl = New-Text $d.Glyph 'Glyph'; $gl.FontSize = 14; $gl.Foreground = $app.Resources['TextSecondaryBrush']
        $nm = New-Text $d.Name 'Caption'; $nm.Margin = '8,0,0,0'; $nm.MaxWidth = 200
        [void]$hd.Children.Add($gl); [void]$hd.Children.Add($nm)
        [void]$home_.Children.Add($hd)
        if ($d.Apple) {
            $ug = New-Object Windows.Controls.Primitives.UniformGrid; $ug.Columns = 3
            [void]$ug.Children.Add((New-RingTile 56 5 100 '#6CCB5F' 'Left' $true))
            [void]$ug.Children.Add((New-RingTile 56 5 90 $acc.Light2 'Right' $false))
            [void]$ug.Children.Add((New-RingTile 56 5 30 $acc.Light2 'Case' $false))
            [void]$home_.Children.Add($ug)
        } else {
            $lbl = $(if ($null -eq $d.Battery) { 'Not reported' } else { 'Battery' })
            [void]$home_.Children.Add((New-RingTile 72 6 $d.Battery $(if ($null -ne $d.Battery -and $d.Battery -le 20) { '#FF99A4' } else { $acc.Light2 }) $lbl $false))
        }
    } else {
        foreach ($d in ($script:devices | Sort-Object { -not $_.Apple } | Select-Object -First 3)) { Add-HomeRow $d }
    }
    if ($dir -ne 0 -and $script:motion) {
        $tt = New-Object Windows.Media.TranslateTransform; $home_.RenderTransform = $tt
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (Anim (40 * $dir) 0 320))
        $home_.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 0 1 260))
    }
}
(E 'DevPrev').Add_Click({ $n = (Get-HomePages).Count; if ($n) { $script:homePage = ($script:homePage - 1 + $n) % $n; Render-HomeDevices -1 } })
(E 'DevNext').Add_Click({ $n = (Get-HomePages).Count; if ($n) { $script:homePage = ($script:homePage + 1) % $n; Render-HomeDevices 1 } })

function Render-Devices {
    $rows = E 'DeviceRows'
    $rows.Children.Clear()
    Render-HomeDevices
    # Devices page, "Other devices" tab: everything but the AirPods, with a bar
    $others = @($script:devices | Where-Object { -not $_.Apple })
    if (-not $others.Count) { $t = New-Text 'Nothing else is connected right now.' 'Caption'; $t.Margin = '0,18'; [void]$rows.Children.Add($t) }
    for ($i = 0; $i -lt $others.Count; $i++) {
        $d = $others[$i]
        $g = New-Row3 62 '0'
        $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = '16,0'; $sp.VerticalAlignment = 'Center'
        [void]$sp.Children.Add((New-Text $d.Name 'Body'))
        [void]$sp.Children.Add((New-Text $(if ($null -eq $d.Battery) { "$($d.Note) $dot doesn't share its battery with Windows" } else { "$($d.Note) $dot connected" }) 'Caption'))
        [Windows.Controls.Grid]::SetColumn($sp, 1)
        $right = New-Object Windows.Controls.StackPanel; $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
        if ($null -ne $d.Battery) {
            $track = New-Object Windows.Controls.Border; $track.Width = 90; $track.Height = 6; $track.CornerRadius = 3; $track.Background = Brush '#1FFFFFFF'; $track.VerticalAlignment = 'Center'
            $fill = New-Object Windows.Controls.Border; $fill.Width = [math]::Max(6, 90 * $d.Battery / 100); $fill.CornerRadius = 3; $fill.HorizontalAlignment = 'Left'; $fill.Background = Get-BatteryBrush $d.Battery
            $track.Child = $fill
            $pct = New-Text ('{0}%' -f $d.Battery) 'Body'; $pct.Width = 46; $pct.TextAlignment = 'Right'
            if ($d.Battery -le 20) { $pct.Foreground = Brush '#FF99A4' }
            [void]$right.Children.Add($track); [void]$right.Children.Add($pct)
        } else { [void]$right.Children.Add((New-Text 'Not reported' 'CaptionTertiary')) }
        [Windows.Controls.Grid]::SetColumn($right, 2)
        [void]$g.Children.Add((New-DeviceIcon $d.Glyph)); [void]$g.Children.Add($sp); [void]$g.Children.Add($right)
        [void]$rows.Children.Add($g)
        if ($i -lt $others.Count - 1) { $dv = New-Object Windows.Controls.Border; $dv.Height = 1; $dv.Background = $app.Resources['DividerBrush']; [void]$rows.Children.Add($dv) }
    }
}

# one line of the Home list page: icon, name + detail, battery number
function Add-HomeRow($d) {
        $home_ = E 'HomeDevices'
        $g = New-Row3 0 '0,10,0,0'
        $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = '12,0,8,0'; $sp.VerticalAlignment = 'Center'
        $nm = New-Text $d.Name 'BodyStrong'; $nm.FontSize = 13; $nm.TextTrimming = 'CharacterEllipsis'
        [void]$sp.Children.Add($nm)
        [void]$sp.Children.Add((New-Text $(if ($d.Apple) { "Left 100 $dot Right 90" } else { $d.Note }) 'Caption'))
        [Windows.Controls.Grid]::SetColumn($sp, 1)
        if ($null -eq $d.Battery) {
            $val = New-Text ([string][char]0x2014) 'CaptionTertiary'; $val.ToolTip = "This device doesn't share its battery with Windows"
        } else {
            $val = New-Text ('{0}%' -f $d.Battery) 'Metric'; $val.FontSize = 16
            if ($d.Battery -le 20) { $val.Foreground = Brush '#FF99A4' }
        }
        [Windows.Controls.Grid]::SetColumn($val, 2)
        [void]$g.Children.Add((New-DeviceIcon $d.Glyph)); [void]$g.Children.Add($sp); [void]$g.Children.Add($val)
        [void]$home_.Children.Add($g)
    }
function Update-DeviceViews {
    $pods = $script:devices | Where-Object { $_.Apple } | Select-Object -First 1
    $any = $script:devices.Count -gt 0
    (E 'TabPods').Visibility = $(if ($pods) { 'Visible' } else { 'Collapsed' })
    if (-not $pods -and (E 'TabPods').IsChecked) { (E 'TabOther').IsChecked = $true }
    if ($pods -and -not $script:hadPods) { (E 'TabPods').IsChecked = $true }
    $script:hadPods = [bool]$pods
    (E 'DevTabs').Visibility = $(if ($any) { 'Visible' } else { 'Collapsed' })
    (E 'NoDevices').Visibility = $(if ($any) { 'Collapsed' } else { 'Visible' })
    (E 'NoDevTitle').Text = $(if ($script:scanned) { 'No wireless devices connected' } else { 'Looking for devices...' })
    (E 'PodsPanel').Visibility = $(if ($pods -and (E 'TabPods').IsChecked) { 'Visible' } else { 'Collapsed' })
    (E 'OtherPanel').Visibility = $(if ($any -and (E 'TabOther').IsChecked) { 'Visible' } else { 'Collapsed' })
    if ($pods) { (E 'PodName').Text = $pods.Name; (E 'QPodName').Text = $pods.Name }
    Render-Devices
}
function Show-PodRings {
    if ((E 'PodsPanel').Visibility -ne 'Visible') { return }
    Draw-Ring (E 'PRingL') 100 10 '#6CCB5F' $true $true; Start-BoltPulse (E 'PodBolt')
    Draw-Ring (E 'PRingR') 90 10 $acc.Light2 $true
    Draw-Ring (E 'PRingC') 30 10 $acc.Light2 $true
}
(E 'TabPods').Add_Checked({ Update-DeviceViews; Show-PodRings })
(E 'TabOther').Add_Checked({ Update-DeviceViews })
(E 'DevExample').Add_Click({
    $script:example = $true
    $script:devices = @(
        @{ Name = 'AirPods'; Glyph = Get-DeviceGlyph 'airpods'; Apple = $true; Battery = 90; Note = 'Example' }
        @{ Name = 'MX Keys'; Glyph = Get-DeviceGlyph 'keyboard'; Apple = $false; Battery = 64; Note = 'Example' }
        @{ Name = 'MX Master 3S'; Glyph = Get-DeviceGlyph 'mouse'; Apple = $false; Battery = 18; Note = 'Example' }
        @{ Name = 'Xbox Wireless Controller'; Glyph = Get-DeviceGlyph 'controller'; Apple = $false; Battery = $null; Note = 'Example' }
    )
    $script:hadPods = $false
    Update-DeviceViews; Show-PodRings
    $script:lastScan = [DateTime]::Now; Set-CheckInterval $script:checkMin
})

# The scan runs in its own runspace every few seconds: connected flags first,
# then battery only for what is connected (the slow part).
$script:scanPs = [PowerShell]::Create()
[void]$script:scanPs.AddScript({
    param($bk, $ck)
    $all = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
    $out = New-Object System.Collections.ArrayList
    foreach ($d in ($all | Where-Object { $_.Class -eq 'Bluetooth' -and ($_.InstanceId -like 'BTHENUM\DEV_*' -or $_.InstanceId -like 'BTHLE\DEV_*') })) {
        if (-not (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $ck -ErrorAction SilentlyContinue).Data) { continue }
        $bat = $null
        if ($d.InstanceId -match 'DEV_([0-9A-F]{12})') {
            $addr = $Matches[1]
            foreach ($c in ($all | Where-Object { $_.InstanceId -like "*$addr*" })) {
                $v = (Get-PnpDeviceProperty -InstanceId $c.InstanceId -KeyName $bk -ErrorAction SilentlyContinue).Data
                if ($null -ne $v) { $bat = [int]$v; break }
            }
        }
        [void]$out.Add(@{ Name = $d.FriendlyName; Battery = $bat })
    }
    , $out.ToArray()
}).AddArgument($batteryKey).AddArgument($connectedKey)
$script:scanAr = $null
function Start-DeviceScan { if (-not $script:scanAr) { $script:scanAr = $script:scanPs.BeginInvoke() } }
# Battery is not polled constantly: one look at start, then on the schedule
# picked under Devices > Check battery (Manual = only when Refresh is pressed).
$script:nextScanAt = [DateTime]::MinValue
$script:lastScan = $null
$script:checkMin = 30
$script:lowNotified = @{}
function Get-CheckedText {
    if ($script:scanAr) { return 'Checking...' }
    if (-not $script:lastScan) { return 'Not checked yet' }
    $m = [int]([DateTime]::Now - $script:lastScan).TotalMinutes
    $ago = $(if ($m -lt 1) { 'Checked just now' } elseif ($m -eq 1) { 'Checked 1 min ago' } else { "Checked $m min ago" })
    if ($script:checkMin -le 0) { return $ago }
    $next = [math]::Max(0, [int][math]::Ceiling(($script:nextScanAt - [DateTime]::Now).TotalMinutes))
    "$ago $dot next in $next min"
}
function Update-CheckedLabel { (E 'DevChecked').Text = Get-CheckedText }
function Set-CheckInterval([int]$min) {
    $script:checkMin = $min
    $base = $(if ($script:lastScan) { $script:lastScan } else { [DateTime]::Now })
    $script:nextScanAt = $(if ($min -le 0) { [DateTime]::MaxValue } else { $base.AddMinutes($min) })
    Update-CheckedLabel; if (Get-Command Update-PodsUpdated -ErrorAction SilentlyContinue) { Update-PodsUpdated }
}
foreach ($n in 'ChkManual', 'Chk15', 'Chk30', 'Chk60') { (E $n).Add_Checked({ param($s, $e) Set-CheckInterval ([int]$s.Tag) }) }
(E 'DevRefresh').Add_Click({ Start-DeviceScan; Update-CheckedLabel })
# A device that drops to the threshold gets one notification per charge.
function Test-LowBattery {
    $lim = [int](E 'LowBat').Value
    foreach ($d in $script:devices) {
        $v = $d.Battery
        if ($null -eq $v) { continue }
        if ($v -le $lim -and -not $script:lowNotified[$d.Name]) {
            $script:lowNotified[$d.Name] = $true
            Send-Toast "$($d.Name) battery is low" "$v% left. Time to put it on charge."
        } elseif ($v -gt $lim + 5) { $script:lowNotified.Remove($d.Name) }
    }
}
$script:scanTimer = New-Object Windows.Threading.DispatcherTimer
$script:scanTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$script:scanTimer.Add_Tick({
    if (-not $script:scanAr) {
        if ([DateTime]::Now -ge $script:nextScanAt) { Start-DeviceScan; Update-CheckedLabel }
        return
    }
    if (-not $script:scanAr.IsCompleted) { return }
    $res = @()
    try { $res = @($script:scanPs.EndInvoke($script:scanAr) | ForEach-Object { $_ }) } catch { }
    $script:scanAr = $null
    $script:lastScan = [DateTime]::Now
    Set-CheckInterval $script:checkMin
    if (-not $script:example) {
        $script:devices = @($res | Where-Object { $_ -is [hashtable] } | ForEach-Object {
            $apple = $_.Name -match 'AirPods'
            @{ Name = $_.Name; Glyph = Get-DeviceGlyph $_.Name; Apple = $apple; Note = 'Bluetooth'
               Battery = $(if ($apple) { 90 } else { $_.Battery }) }
        })
        $script:scanned = $true
        Update-DeviceViews
        Test-LowBattery
    }
})
Update-DeviceViews
if (-not $Snap) { $script:scanTimer.Start() }
if ($ExampleDevices) {
    (E 'DevExample').RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    if ($DeviceTab -eq 'Other') { (E 'TabOther').IsChecked = $true }
    $script:homePage = $HomeDevPage; Render-HomeDevices
}

# --- Windows notifications --------------------------------------------------
# Same mechanism as the app's Show-Toast, under a separate AppUserModelID so
# the installed Vento's notification settings and icon stay untouched.
$script:toastAumid = 'Blakfy.VentoPreview'
$script:toastNotifier = $null
function Send-Toast([string]$title, [string]$body) {
    try {
        if (-not $script:toastNotifier) {
            $key = Join-Path 'HKCU:\SOFTWARE\Classes\AppUserModelId' $script:toastAumid
            if (-not (Test-Path $key)) { [void](New-Item -Path $key -Force) }
            [void](New-ItemProperty -Path $key -Name 'DisplayName' -Value 'Vento (preview)' -PropertyType String -Force)
            [void](New-ItemProperty -Path $key -Name 'IconUri' -Value (Join-Path $logoDir 'png\vento-128.png') -PropertyType String -Force)
            [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
            $script:toastNotifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:toastAumid)
        }
        $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>' + (& $esc $title) + '</text><text>' + (& $esc $body) + '</text></binding></visual></toast>')
        $script:toastNotifier.Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
    } catch { }
}
function Send-TempToast { Send-Toast "CPU is at 72$deg" "That's above your 65$deg comfort target. Case fans are ramping up." }
(E 'TestToast').Add_Click({ Send-TempToast })
(E 'PrevToastTemp').Add_Click({ Send-TempToast })
(E 'PrevToastBat').Add_Click({ Send-Toast 'MX Master 3S battery is low' '18% left. Time to put it on charge.' })
(E 'PrevToastDrv').Add_Click({ Send-Toast 'Fan control is paused' "The PawnIO driver is missing, so your fans are on their BIOS settings. Open Vento to install it again." })

# --- Alerts page: values beside their sliders --------------------------------
foreach ($p in @(@('WCpu', "{0:0}$deg"), @('WGpu', "{0:0}$deg"), @('WSsd', "{0:0}$deg"), @('WMb', "{0:0}$deg"),
                 @('LimCpu', "{0:0}$deg"), @('LimGpu', "{0:0}$deg"), @('GameLoad', '{0:0}%'), @('GameCool', '{0:0} s'),
                 @('OsdScale', '{0:0}%'), @('OsdOpacity', '{0:0}%'), @('LowBat', '{0:0}%'))) {
    $v = E "$($p[0])V"; $f = $p[1]
    (E $p[0]).Add_ValueChanged({ param($s, $e) $v.Text = ($f -f $s.Value) }.GetNewClosure())
}
function Set-GameRows { $on = [bool](E 'GameOn').IsChecked; (E 'GameRows').IsEnabled = $on; (E 'GameRows').Opacity = $(if ($on) { 1 } else { 0.45 }) }
(E 'GameOn').Add_Checked({ Set-GameRows }); (E 'GameOn').Add_Unchecked({ Set-GameRows })

# --- Overlay: which metrics, their colors, size and opacity -------------------
# Matches this PC's settings: everything on except CPU load.
$metrics = @(
    @{ Key = 'fps'; Name = 'FPS'; Lab = 'FPS'; Val = '144'; On = $true }
    @{ Key = 'cpu'; Name = 'CPU temperature'; Lab = 'CPU'; Val = "60$deg"; On = $true }
    @{ Key = 'gpu'; Name = 'GPU temperature'; Lab = 'GPU'; Val = "54$deg"; On = $true }
    @{ Key = 'gpuload'; Name = 'GPU load'; Lab = 'LOAD'; Val = '97%'; On = $true }
    @{ Key = 'load'; Name = 'CPU load'; Lab = 'CPU'; Val = '38%'; On = $false }
    @{ Key = 'ram'; Name = 'Memory'; Lab = 'RAM'; Val = '62%'; On = $true }
    @{ Key = 'fans'; Name = 'Fan speed'; Lab = 'FAN'; Val = '1951'; On = $true }
    @{ Key = 'ssd'; Name = 'SSD temperature'; Lab = 'SSD'; Val = "42$deg"; On = $true }
    @{ Key = 'mb'; Name = 'Board temperature'; Lab = 'MB'; Val = "59$deg"; On = $true }
    @{ Key = 'pods'; Name = 'Headphone battery'; Lab = 'PODS'; Val = '90%'; On = $true }
)
# '' = follow the overlay theme; a click on the dot walks through these
$metricColors = '', '#7CF29B', '#FFB25C', '#FF6B7E', '#B18CFF', '#6FB1FF'
foreach ($m in $metrics) { $m.Col = '' }
$script:osdFpsTb = $null
function Build-Osd {
    $host_ = E 'OsdItems'; $host_.Children.Clear(); $script:osdFpsTb = $null
    $on = @($metrics | Where-Object { $_.On })
    for ($i = 0; $i -lt $on.Count; $i++) {
        $m = $on[$i]; $hero = ($i -eq 0)
        $v = New-Object Windows.Controls.TextBlock; $v.Text = $m.Val; $v.FontWeight = 'Bold'; $v.FontSize = $(if ($hero) { 16 } else { 13 }); $v.VerticalAlignment = 'Center'
        if ($m.Col) { $v.Foreground = Brush $m.Col }
        elseif ($hero) { $v.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'OsdAccentBrush') }
        else { $v.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'OsdInkBrush') }
        [Windows.Documents.Typography]::SetNumeralAlignment($v, 'Tabular')
        $l = New-Object Windows.Controls.TextBlock; $l.Text = $m.Lab; $l.FontWeight = 'Bold'; $l.FontSize = 10; $l.VerticalAlignment = 'Center'
        $l.Margin = $(if ($i -lt $on.Count - 1) { '4,2,12,0' } else { '4,2,0,0' })
        $l.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'OsdLabBrush')
        [void]$host_.Children.Add($v); [void]$host_.Children.Add($l)
        if ($m.Key -eq 'fps') { $script:osdFpsTb = $v }
    }
}
function Build-MetricRows {
    $rows = E 'MetricRows'; $rows.Children.Clear()
    foreach ($m in $metrics) {
        $g = New-Object Windows.Controls.Grid; $g.MinHeight = 50; $g.Margin = '0,0,16,0'
        foreach ($w in -2, -1, -2) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = $(if ($w -eq -1) { New-Object Windows.GridLength 1, 'Star' } else { [Windows.GridLength]::Auto }); $g.ColumnDefinitions.Add($cd)
        }
        $dotB = New-Object Windows.Controls.Border; $dotB.Width = 14; $dotB.Height = 14; $dotB.CornerRadius = 7; $dotB.VerticalAlignment = 'Center'
        $dotB.BorderBrush = Brush '#40FFFFFF'; $dotB.BorderThickness = 1; $dotB.Cursor = [Windows.Input.Cursors]::Hand; $dotB.ToolTip = 'Click to change its color'
        if ($m.Col) { $dotB.Background = Brush $m.Col } else { $dotB.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'OsdInkBrush') }
        $dotB.Tag = $m
        $dotB.Add_MouseLeftButtonUp({
            param($s, $e)
            $mm = $s.Tag; $i = [array]::IndexOf($metricColors, $mm.Col); $mm.Col = $metricColors[($i + 1) % $metricColors.Count]
            Build-MetricRows; Build-Osd
        })
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $m.Name; $t.Style = $app.Resources['Body']; $t.VerticalAlignment = 'Center'; $t.Margin = '12,0,0,0'
        [Windows.Controls.Grid]::SetColumn($t, 1)
        $sw = New-Object Windows.Controls.CheckBox; $sw.Style = $app.Resources['ToggleSwitch']; $sw.IsChecked = $m.On; $sw.Tag = $m
        $sw.Add_Click({ param($s, $e) $s.Tag.On = [bool]$s.IsChecked; Build-Osd })
        [Windows.Controls.Grid]::SetColumn($sw, 2)
        [void]$g.Children.Add($dotB); [void]$g.Children.Add($t); [void]$g.Children.Add($sw)
        [void]$rows.Children.Add($g)
    }
}
Build-MetricRows; Build-Osd
(E 'OsdScale').Add_ValueChanged({ param($s, $e) (E 'OsdMock').LayoutTransform = New-Object Windows.Media.ScaleTransform ($s.Value / 100), ($s.Value / 100) })
(E 'OsdOpacity').Add_ValueChanged({ param($s, $e) (E 'OsdMock').Opacity = $s.Value / 100 })

# --- Fan driver missing: an error bar instead of a silent failure -------------
function Set-DriverMissing([bool]$missing) {
    (E 'DriverBar').Visibility = $(if ($missing) { 'Visible' } else { 'Collapsed' })
    (E 'HomeFansMode').Text = $(if ($missing) { 'Paused' } else { $modeData[$script:mode].Name })
    (E 'HomeFansMode').Foreground = $(if ($missing) { Brush '#FF99A4' } else { $app.Resources['TextTertiaryBrush'] })
    (E 'DriverFix').Content = 'Install driver'; (E 'DriverFix').IsEnabled = $true
}
(E 'PrevNoDriver').Add_Checked({ Set-DriverMissing $true; (E 'NavHome').IsChecked = $true })
(E 'PrevNoDriver').Add_Unchecked({ Set-DriverMissing $false })
(E 'DriverClose').Add_Click({ (E 'DriverBar').Visibility = 'Collapsed' })
(E 'DriverFix').Add_Click({
    (E 'DriverFix').Content = 'Installing...'; (E 'DriverFix').IsEnabled = $false
    $tm = New-Object Windows.Threading.DispatcherTimer; $tm.Interval = [TimeSpan]::FromSeconds(2)
    $tm.Add_Tick({ param($s, $e) $s.Stop(); (E 'PrevNoDriver').IsChecked = $false; Send-Toast 'Fan control is back' 'The PawnIO driver is installed and your fan mode is applied again.' })
    $tm.Start()
})
if ($NoDriver) { (E 'PrevNoDriver').IsChecked = $true }
if ($TestToast) { Send-TempToast }

# --- AirPods "Check now": an on-demand read between scheduled checks ---------
# In the app this opens the BLE listener for a few seconds and takes the next
# battery broadcast; here it plays that out and stamps the time.
$script:podsReadAt = [DateTime]::Now.AddMinutes(-12)
function Update-PodsUpdated {
    $m = [int]([DateTime]::Now - $script:podsReadAt).TotalMinutes
    (E 'PodsUpdated').Text = $(if ($m -lt 1) { 'Updated just now' } else { "Updated $m min ago" })
}
(E 'PodsCheck').Add_Click({
    $b = E 'PodsCheck'; $b.IsEnabled = $false
    (E 'PodsCheckText').Text = 'Listening...'
    $spin = New-Object Windows.Media.Animation.DoubleAnimation 0, 360, ([Windows.Duration][TimeSpan]::FromSeconds(0.9))
    $spin.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    (E 'PodsCheckIcon').RenderTransform.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $spin)
    $tm = New-Object Windows.Threading.DispatcherTimer; $tm.Interval = [TimeSpan]::FromSeconds(2.5)
    $tm.Add_Tick({
        param($s, $e) $s.Stop()
        (E 'PodsCheckIcon').RenderTransform.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
        (E 'PodsCheckText').Text = 'Check now'; (E 'PodsCheck').IsEnabled = $true
        $script:podsReadAt = [DateTime]::Now; Update-PodsUpdated
        Show-PodRings
    })
    $tm.Start()
})
Update-PodsUpdated

# --- live Windows accent ------------------------------------------------------
# Mica follows the Windows theme on its own (DWM paints it). The accent is
# ours to repaint: Windows broadcasts WM_DWMCOLORIZATIONCOLORCHANGED (0x320) /
# WM_SETTINGCHANGE (0x1A, "ImmersiveColorSet") when it changes; we re-read the
# palette a beat later (the registry lands slightly after the message) and
# recolor the shared brushes in place, so every control using them follows.
function Apply-Accent($a) {
    $acc.Light3 = $a.Light3; $acc.Light2 = $a.Light2; $acc.Base = $a.Base
    foreach ($k in @(@('AccentBrush', $a.Light2, 255), @('AccentTextBrush', $a.Light3, 255), @('AccentSoftBrush', $a.Light2, 0x24))) {
        $c = Col $k[1] $k[2]
        # brushes from XAML come back frozen: swap in a new one; every
        # {DynamicResource} reference picks it up
        $nb = New-Object Windows.Media.SolidColorBrush $c; $nb.Freeze()   # styles only accept frozen brushes
        # pass the raw brush: through the object-typed indexer PowerShell
        # would hand WPF its PSObject wrapper, which no Background accepts
        $app.Resources[$k[0]] = $nb.psobject.BaseObject
    }
    (E 'MeterStop0').Color = Col $a.Light2 255; (E 'MeterStop1').Color = Col $a.Light2 255
    $thermal.cool.Hex = $a.Light2; $thermal.cool.Text = $a.Light3
    if ($script:state -eq 'cool') { Set-Thermal 'cool' }
    (E 'AccentHex').Text = $a.Light2
    # charts, rings and the curve are drawn in code with the accent: redraw
    $script:reveal = $false; Draw-All; Render-Devices
    if ((E 'PagePods').Visibility -eq 'Visible') { Show-PodRings }
    Build-MetricRows; Build-Osd
}
$script:accentTimer = New-Object Windows.Threading.DispatcherTimer
$script:accentTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$script:accentTimer.Add_Tick({
    param($s, $e) $s.Stop()
    $n = Read-AccentPalette
    if ($n.Light2 -ne $acc.Light2 -or $n.Light3 -ne $acc.Light3) { Apply-Accent $n }
})
$win.Add_SourceInitialized({
    $src = [Windows.Interop.HwndSource]::FromHwnd((Get-Hwnd $win))
    $script:accentHook = [System.Windows.Interop.HwndSourceHook]{
        # args: hwnd, msg, wParam, lParam, handled
        $m = [int]$args[1]
        if ($m -eq 0x0320 -or $m -eq 0x001A) { $script:accentTimer.Stop(); $script:accentTimer.Start() }
        return [IntPtr]::Zero
    }
    $src.AddHook($script:accentHook)
})
# -AccentTest '#FFB547' fakes a Windows accent change (Light 2 = given color)
if ($AccentTest) { Apply-Accent @{ Light2 = $AccentTest; Light3 = $AccentTest; Base = $AccentTest } }

# --- InfoBar: restart turns it into a success note, then it folds away ------
function Close-InfoBar {
    $ib = E 'InfoBar'
    if (-not $script:motion) { $ib.Visibility = 'Collapsed'; return }
    $sc = New-Object Windows.Media.ScaleTransform 1, 1; $ib.LayoutTransform = $sc
    $a = Anim 1 0 260; $a.Add_Completed({ (E 'InfoBar').Visibility = 'Collapsed' })
    $ib.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 1 0 180))
    $sc.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $a)
}
(E 'InfoClose').Add_Click({ Close-InfoBar })
(E 'InfoRestart').Add_Click({
    (E 'InfoIconBg').Background = $app.Resources['SuccessBrush']; (E 'InfoIcon').Text = [string][char]0xE73E
    (E 'InfoTitle').Text = "You're on Vento 1.8.0"; (E 'InfoMsg').Text = 'Restarted in two seconds. The fans never noticed.'
    (E 'InfoRestart').Visibility = 'Collapsed'
    $tm = New-Object Windows.Threading.DispatcherTimer; $tm.Interval = [TimeSpan]::FromSeconds(3.5)
    $tm.Add_Tick({ param($s, $e) $s.Stop(); Close-InfoBar }); $tm.Start()
})

# --- tray flyout + a real tray icon -----------------------------------------
$script:flyHiddenAt = [DateTime]::MinValue
function Show-Flyout {
    $wa = [System.Windows.SystemParameters]::WorkArea
    (E 'FBody').Measure((New-Object Windows.Size 360, ([double]::PositiveInfinity)))
    $fly.Left = $wa.Right - 360 - 12
    $fly.Top = $wa.Bottom - (E 'FBody').DesiredSize.Height - 12
    $fly.Show(); [void]$fly.Activate()
    if ($script:motion) {
        $b = E 'FBody'; $tt = New-Object Windows.Media.TranslateTransform; $b.RenderTransform = $tt
        $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (Anim 40 0 360))
        $b.BeginAnimation([Windows.UIElement]::OpacityProperty, (Anim 0 1 220))
    }
}
function Hide-Flyout { if ($fly.IsVisible) { $fly.Hide(); $script:flyHiddenAt = [DateTime]::Now } }
function Toggle-Flyout {
    # a click on the tray icon first deactivates (hides) the flyout; don't reopen it
    if ($fly.IsVisible) { Hide-Flyout; return }
    if (([DateTime]::Now - $script:flyHiddenAt).TotalMilliseconds -lt 400) { return }
    Show-Flyout
}
$fly.Add_Deactivated({ if (-not $Capture) { Hide-Flyout } })
(E 'BtnFlyout').Add_Click({ Show-Flyout })
function Open-Main {
    Hide-Flyout
    if (-not $win.IsVisible) { $win.Show() }
    if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
    [void]$win.Activate()
}
(E 'QOpen').Add_Click({ Open-Main })
(E 'QSettings').Add_Click({ Open-Main; (E 'NavSettings').IsChecked = $true })

$script:tray = $null
if (-not $Snap -and -not $Capture) {
    try {
        $script:tray = New-Object System.Windows.Forms.NotifyIcon
        $script:tray.Icon = New-Object System.Drawing.Icon (Join-Path $logoDir 'vento.ico')
        $script:tray.Text = 'Vento (design preview)'
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        [void]$menu.Items.Add('Open Vento preview', $null, { Open-Main })
        [void]$menu.Items.Add('Exit preview', $null, { $win.Close() })
        $script:tray.ContextMenuStrip = $menu
        $script:tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Toggle-Flyout } })
        $script:tray.Visible = $true
    } catch { $script:tray = $null }
}

# --- start --------------------------------------------------------------------
$navFor = @{ Home = 'NavHome'; Fans = 'NavFans'; Alerts = 'NavAlerts'; Profiles = 'NavProfiles'; Displays = 'NavDisplays'; Pods = 'NavPods'; Overlay = 'NavOverlay'; Settings = 'NavSettings' }
Set-Thermal 'cool'
Set-Mode $Mode

if ($Snap) {
    # Offline render: same layout, composited over a neutral dark backdrop
    # since the real glass only exists on screen.
    $win.WindowStartupLocation = 'Manual'; $win.Left = -6000; $win.Top = 0; $win.ShowActivated = $false
    $win.Show()
    if ($Page -ne 'Home') { (E $navFor[$Page]).IsChecked = $true } else { Show-Page 'PageHome' $false }
    $win.UpdateLayout(); $win.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::ContextIdle, [action]{ })
    Move-NavPill (E $navFor[$Page]) $false
    $script:reveal = $true; Draw-All; $win.UpdateLayout(); $win.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::ContextIdle, [action]{ })
    # template animations (toggle knobs) run on the clock - let them land
    $until = [DateTime]::Now.AddMilliseconds(450)
    while ([DateTime]::Now -lt $until) { $win.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Background, [action]{ }); Start-Sleep -Milliseconds 15 }
    $sc = 1.25; $wd = $win.ActualWidth; $ht = $win.ActualHeight
    $dv = New-Object Windows.Media.DrawingVisual
    $ctx = $dv.RenderOpen()
    $bg = New-Object Windows.Media.LinearGradientBrush ((Col '#2A2D33' 255)), ((Col '#1E1F24' 255)), 45
    $ctx.DrawRectangle($bg, $null, (New-Object Windows.Rect 0, 0, $wd, $ht))
    $vb = New-Object Windows.Media.VisualBrush $win.Content
    $vb.Stretch = 'None'; $vb.AlignmentX = 'Left'; $vb.AlignmentY = 'Top'
    $ctx.DrawRectangle($vb, $null, (New-Object Windows.Rect 0, 0, $win.Content.ActualWidth, $win.Content.ActualHeight))
    $ctx.Close()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]($wd * $sc)), ([int]($ht * $sc)), (96 * $sc), (96 * $sc), ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($Snap); $enc.Save($fs); $fs.Close()
    $win.Close(); $fly.Close()
    return
}

Set-Spin (E 'SpinGpu') 1018
$avatar = New-Object Windows.Media.Animation.DoubleAnimation 0, 360, ([Windows.Duration][TimeSpan]::FromSeconds(14))
$avatar.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
# the avatar glyph stays still: airflow doesn't rotate
$pulse = New-Object Windows.Media.Animation.DoubleAnimation 1, 0.3, ([Windows.Duration][TimeSpan]::FromSeconds(1.2))
$pulse.AutoReverse = $true; $pulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
(E 'LiveDot').BeginAnimation([Windows.UIElement]::OpacityProperty, $pulse)

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ try { Tick } catch { } })
$timer.Start()

$win.Add_ContentRendered({
    if ($Page -ne 'Home' -and $Page -ne 'Flyout') { (E $navFor[$Page]).IsChecked = $true } else { Show-Page 'PageHome' }
    Move-NavPill (E $(if ($navFor.ContainsKey($Page)) { $navFor[$Page] } else { 'NavHome' })) $false
    # launched from a background shell: hop above the foreground window once
    if (-not $Capture) { $win.Topmost = $true; $win.Topmost = $false; [void]$win.Activate() }
})
$win.Add_Closed({
    $timer.Stop()
    if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() }
    $fly.Close(); $app.Shutdown()
})

if ($Capture) {
    # Real on-screen capture (the glass is composed by DWM, not WPF), then exit.
    $target = $(if ($Page -eq 'Flyout') { $fly } else { $win })
    $target.Topmost = $true
    $cap = New-Object Windows.Threading.DispatcherTimer
    $cap.Interval = [TimeSpan]::FromSeconds($Delay)
    $cap.Add_Tick({
        $cap.Stop()
        $k = [Windows.PresentationSource]::FromVisual($target).CompositionTarget.TransformToDevice.M11
        $bmp = New-Object Drawing.Bitmap ([int]($target.ActualWidth * $k)), ([int]($target.ActualHeight * $k))
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen([int]($target.Left * $k), [int]($target.Top * $k), 0, 0, $bmp.Size); $g.Dispose()
        $bmp.Save($Capture); $bmp.Dispose()
        $win.Close()
    })
    $cap.Start()
}

if ($Page -eq 'Flyout') {
    $win.WindowStartupLocation = 'Manual'; $win.Left = -6000; $win.ShowActivated = $false
    $win.Show(); Show-Flyout
} else {
    $win.Show()
}
[void]$app.Run()
