# Builds Vento.exe from build/launcher.cs using the .NET Framework compiler
# that ships with Windows (no SDK required).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe not found - .NET Framework 4.x is required.' }

& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
    /out:"$root\Vento.exe" `
    /win32icon:"$root\assets\vento.ico" `
    /win32manifest:"$PSScriptRoot\app.manifest" `
    /r:System.Windows.Forms.dll `
    "$PSScriptRoot\launcher.cs"
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
Write-Output ("Built {0} ({1} bytes)" -f "$root\Vento.exe", (Get-Item "$root\Vento.exe").Length)
