# Generates assets/social-preview.png - the 1280x640 card GitHub shows when a
# link to the repo is pasted somewhere, and the og:image for docs/index.html.
# Same palette as the project page: near-black card, blue glow, blue accent.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root   = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets'
$logo   = Join-Path $assets 'logo.png'
$out    = Join-Path $assets 'social-preview.png'
if (-not (Test-Path $logo)) { throw "assets/logo.png is missing - run build\make-icon.ps1 first." }

$W = 1280; $H = 640
$bg     = [System.Drawing.Color]::FromArgb(0x0A, 0x0B, 0x0D)
$glow   = [System.Drawing.Color]::FromArgb(0x1A, 0x29, 0x49)
$accent = [System.Drawing.Color]::FromArgb(0x4C, 0x8D, 0xFF)
$fg     = [System.Drawing.Color]::FromArgb(0xF4, 0xF6, 0xF9)
$fg2    = [System.Drawing.Color]::FromArgb(0x94, 0x99, 0xA6)
$fg3    = [System.Drawing.Color]::FromArgb(0x6D, 0x72, 0x80)

$bmp = New-Object System.Drawing.Bitmap $W, $H
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = 'AntiAlias'
$g.InterpolationMode = 'HighQualityBicubic'
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.Clear($bg)

# Glow: an oversized ellipse centred above the canvas, fading outward - the
# CSS radial-gradient from the page, done with a path gradient brush.
$halo = New-Object System.Drawing.Drawing2D.GraphicsPath
$halo.AddEllipse(($W / 2 - 700), -560, 1400, 1120)
$pg = New-Object System.Drawing.Drawing2D.PathGradientBrush $halo
$pg.CenterColor    = $glow
$pg.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $glow))
$g.FillPath($pg, $halo)
$pg.Dispose(); $halo.Dispose()

# Logo, left half, with a soft blue drop shadow underneath it.
$img = [System.Drawing.Image]::FromFile($logo)
$LS = 260; $lx = 108; $ly = [int](($H - $LS) / 2)
$sh = New-Object System.Drawing.Drawing2D.GraphicsPath
$sh.AddEllipse(($lx + 20), ($ly + $LS - 46), ($LS - 40), 86)
$pgs = New-Object System.Drawing.Drawing2D.PathGradientBrush $sh
$pgs.CenterColor    = [System.Drawing.Color]::FromArgb(70, $accent)
$pgs.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $accent))
$g.FillPath($pgs, $sh)
$pgs.Dispose(); $sh.Dispose()
$g.DrawImage($img, $lx, $ly, $LS, $LS)
$img.Dispose()

# Type block, right of the logo.
$tx = $lx + $LS + 76
$fTitle = New-Object System.Drawing.Font 'Segoe UI', 88, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$fTag   = New-Object System.Drawing.Font 'Segoe UI Semibold', 30, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$fBody  = New-Object System.Drawing.Font 'Segoe UI', 23, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$fFoot  = New-Object System.Drawing.Font 'Segoe UI', 21, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)

$bTitle = New-Object System.Drawing.SolidBrush $fg
$bTag   = New-Object System.Drawing.SolidBrush $accent
$bBody  = New-Object System.Drawing.SolidBrush $fg2
$bFoot  = New-Object System.Drawing.SolidBrush $fg3

$y = 186
$g.DrawString('Vento', $fTitle, $bTitle, $tx, $y);            $y += 112
$g.DrawString('Fan control for Windows', $fTag, $bTag, ($tx + 4), $y); $y += 56
$g.DrawString("Quiet when the PC is idle, loud only when", $fBody, $bBody, ($tx + 4), $y); $y += 34
$g.DrawString("it needs to be. Five modes, in your tray.", $fBody, $bBody, ($tx + 4), $y); $y += 60

# Accent rule, then the footer line.
$pen = New-Object System.Drawing.Pen $accent, 3
$g.DrawLine($pen, ($tx + 5), $y, ($tx + 69), $y)
$pen.Dispose()
# Built from the code point: PS 5.1 reads a BOM-less .ps1 as ANSI, which turns
# a literal U+00B7 in the source into mojibake on the rendered card.
$dot = [char]0x00B7
$g.DrawString("MIT licensed  $dot  Windows 10/11  $dot  free and open source", $fFoot, $bFoot, ($tx + 4), ($y + 20))

foreach ($d in @($fTitle,$fTag,$fBody,$fFoot,$bTitle,$bTag,$bBody,$bFoot)) { $d.Dispose() }

$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "Wrote $out ($W x $H)"
