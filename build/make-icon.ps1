# Generates assets/vento.ico (16..256, BMP+PNG entries) and assets/logo.png.
# Design: three swept vortex blades (comma crescents) chasing each other
# around a hub dot, blue gradient on a dark rounded square with a soft glow.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root   = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets'
if (-not (Test-Path $assets)) { New-Item -ItemType Directory -Path $assets | Out-Null }

$D2R = [math]::PI / 180.0

function New-RoundedRectPath([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Pt([double]$k, [double]$angDeg, [double]$r) {
    # design space is 256, center (128,128); screen y grows downward
    $a = $angDeg * $D2R
    New-Object System.Drawing.PointF ((128 + $r * [math]::Cos($a)) * $k), ((128 - $r * [math]::Sin($a)) * $k)
}

function New-SwirlBlade([double]$k) {
    # slim comma crescent in the outer ring, sweeping 120deg to a curled tip
    $sweep = 120.0; $rOut = 100.0; $rIn = 52.0; $tipR = 86.0; $t0 = 90.0
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    # rounded head cap
    $pts.Add((Pt $k $t0 $rIn))
    $pts.Add((Pt $k ($t0 + 6) ($rIn + ($rOut - $rIn) * 0.25)))
    $pts.Add((Pt $k ($t0 + 8) ($rIn + ($rOut - $rIn) * 0.5)))
    $pts.Add((Pt $k ($t0 + 6) ($rIn + ($rOut - $rIn) * 0.78)))
    $pts.Add((Pt $k $t0 $rOut))
    # outer edge: constant radius, then a C1-smooth ease toward the tip
    for ($i = 1; $i -le 22; $i++) {
        $t = $i / 22.0
        $u = if ($t -lt 0.3) { 0.0 } else { ($t - 0.3) / 0.7 }
        $ease = $u * $u * (3 - 2 * $u)   # smoothstep
        $pts.Add((Pt $k ($t0 - $sweep * $t) ($rOut - ($rOut - ($tipR + 5)) * $ease)))
    }
    # swept tip: curl past the sweep end so the blade ends in a point
    $pts.Add((Pt $k ($t0 - $sweep - 8) ($tipR - 2)))
    # inner edge back to the head
    for ($i = 22; $i -ge 0; $i--) {
        $t = $i / 22.0
        $pts.Add((Pt $k ($t0 - $sweep * $t) ($rIn + (($tipR - 7) - $rIn) * [math]::Pow($t, 1.5))))
    }
    return $pts.ToArray()
}

function Draw-Logo([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $k = $size / 256.0

    # dark rounded square with a vertical blue-tinted gradient
    $rr = New-RoundedRectPath (4 * $k) (4 * $k) (248 * $k) (248 * $k) (58 * $k)
    $bgGrad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF(0, $size)),
        [System.Drawing.Color]::FromArgb(21, 27, 43), [System.Drawing.Color]::FromArgb(8, 10, 16))
    $g.FillPath($bgGrad, $rr)

    # soft accent glow behind the mark
    $glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $glowPath.AddEllipse(23 * $k, 23 * $k, 210 * $k, 210 * $k)
    $glow = New-Object System.Drawing.Drawing2D.PathGradientBrush($glowPath)
    $glow.CenterColor = [System.Drawing.Color]::FromArgb(80, 76, 141, 255)
    $glow.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 76, 141, 255))
    $g.FillPath($glow, $glowPath)

    # three vortex blades with a soft drop shadow
    $blade = New-SwirlBlade $k
    $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60, 0, 0, 0))
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF((60 * $k), (40 * $k))), (New-Object System.Drawing.PointF((190 * $k), (200 * $k))),
        [System.Drawing.Color]::FromArgb(158, 197, 255), [System.Drawing.Color]::FromArgb(47, 105, 255))
    for ($i = 0; $i -lt 3; $i++) {
        $g.ResetTransform()
        $g.TranslateTransform(128 * $k, 128 * $k); $g.RotateTransform(120 * $i); $g.TranslateTransform(-128 * $k, -128 * $k)
        $g.TranslateTransform(0, 3 * $k)
        $g.FillPolygon($shadow, $blade)
        $g.TranslateTransform(0, -3 * $k)
        $g.FillPolygon($grad, $blade)
    }
    $g.ResetTransform()

    # hub: dark punch + accent gradient dot
    $bgB = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(10, 13, 20))
    $g.FillEllipse($bgB, 102 * $k, 102 * $k, 52 * $k, 52 * $k)
    $dotG = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF(0, (114 * $k))), (New-Object System.Drawing.PointF(0, (144 * $k))),
        [System.Drawing.Color]::FromArgb(158, 197, 255), [System.Drawing.Color]::FromArgb(47, 105, 255))
    $g.FillEllipse($dotG, 114 * $k, 114 * $k, 28 * $k, 28 * $k)

    $g.Dispose(); $bgGrad.Dispose(); $glow.Dispose(); $glowPath.Dispose()
    $shadow.Dispose(); $grad.Dispose(); $bgB.Dispose(); $dotG.Dispose(); $rr.Dispose()
    return $bmp
}

# --- logo.png (512, for README) --------------------------------------
$png = Draw-Logo 512
$png.Save((Join-Path $assets 'logo.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$png.Dispose()

# --- vento.ico -------------------------------------------------------
# BMP-encoded entries for small sizes, PNG-encoded for 256.
$bmpSizes = 16, 24, 32, 48, 64
$entries = @()   # array of @{ Size; Bytes; IsPng }

foreach ($s in $bmpSizes) {
    $bmp = Draw-Logo $s
    $rect = New-Object System.Drawing.Rectangle(0, 0, $s, $s)
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $pixels = New-Object byte[] ($bd.Stride * $s)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $pixels, 0, $pixels.Length)
    $bmp.UnlockBits($bd)
    $bmp.Dispose()

    $maskRow = [int]([math]::Ceiling($s / 32.0) * 4)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    # BITMAPINFOHEADER, height doubled (XOR + AND masks)
    $bw.Write([int32]40); $bw.Write([int32]$s); $bw.Write([int32]($s * 2))
    $bw.Write([int16]1);  $bw.Write([int16]32); $bw.Write([int32]0)
    $bw.Write([int32]($s * $s * 4 + $maskRow * $s))
    $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0)
    for ($y = $s - 1; $y -ge 0; $y--) { $bw.Write($pixels, $y * $bd.Stride, $s * 4) }  # bottom-up XOR
    $bw.Write((New-Object byte[] ($maskRow * $s)))                                     # empty AND mask (alpha used)
    $bw.Flush()
    $entries += @{ Size = $s; Bytes = $ms.ToArray(); IsPng = $false }
    $bw.Dispose(); $ms.Dispose()
}

$bmp256 = Draw-Logo 256
$ms = New-Object System.IO.MemoryStream
$bmp256.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$entries += @{ Size = 256; Bytes = $ms.ToArray(); IsPng = $true }
$bmp256.Dispose(); $ms.Dispose()

$icoPath = Join-Path $assets 'vento.ico'
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int32]$e.Bytes.Length); $bw.Write([int32]$offset)
    $offset += $e.Bytes.Length
}
foreach ($e in $entries) { $bw.Write($e.Bytes) }
$bw.Dispose(); $fs.Dispose()

# --- installer wizard small image (BMP, shown top-right in setup) ----
$wiz = New-Object System.Drawing.Bitmap 110, 116
$gw = [System.Drawing.Graphics]::FromImage($wiz)
$gw.SmoothingMode = 'AntiAlias'
$gw.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$gw.Clear([System.Drawing.Color]::White)
$src = Draw-Logo 192
$gw.DrawImage($src, 7, 10, 96, 96)
$src.Dispose(); $gw.Dispose()
$wiz.Save((Join-Path $assets 'wizard-small.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp)
$wiz.Dispose()

Write-Output ("Wrote {0} ({1} bytes), logo.png and wizard-small.bmp" -f $icoPath, (Get-Item $icoPath).Length)
