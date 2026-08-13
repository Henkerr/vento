; Vento installer script (Inno Setup 6)
; Build: ISCC.exe installer\vento.iss  ->  dist\VentoSetup-1.0.0.exe

#define AppName "Vento"
; CI can override with: ISCC /DAppVersion=x.y.z  (keep in sync with app.ps1)
#ifndef AppVersion
#define AppVersion "1.3.0"
#endif
#define AppPublisher "Blakfy"
#define AppURL "https://github.com/Henkerr/vento"

[Setup]
AppId={{7E4A2C1B-9D63-4F1A-B6E8-C0FFEE100001}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\dist
; Version-less on purpose: the app's updater picks the .exe asset off the
; latest release, so a stable asset name keeps every release consistent.
OutputBaseFilename=VentoSetup
SetupIconFile=..\assets\vento.ico
WizardSmallImageFile=..\assets\wizard-small.bmp
UninstallDisplayIcon={app}\Vento.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "startup"; Description: "&Start Vento automatically when Windows starts"
Name: "desktopicon"; Description: "Create a &desktop icon"; Flags: unchecked

[Files]
Source: "..\Vento.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\app.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\vento.ico"; DestDir: "{app}\assets"; Flags: ignoreversion
Source: "..\lib\*.dll"; DestDir: "{app}\lib"; Flags: ignoreversion
Source: "..\fonts\*.ttf"; DestDir: "{app}\fonts"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\THIRD-PARTY-NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\Vento.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\Vento.exe"; Tasks: desktopicon

[Run]
; Autostart is a highest-privilege scheduled task, so logon skips UAC.
; app.ps1 owns that registration (same code path as Settings -> "Start with
; Windows"), so the wizard checkbox just calls it. skipifsilent keeps the
; app's own silent updater from re-enabling autostart a user switched off.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\app.ps1"" -RegisterAutostart"; StatusMsg: "Registering the startup task..."; Flags: runhidden skipifsilent; Tasks: startup

; shellexec is required: Vento.exe's manifest demands elevation and plain
; CreateProcess cannot elevate (error 740). No skipifsilent: silent updates
; relaunch the app when they finish.
Filename: "{app}\Vento.exe"; Description: "Launch {#AppName}"; Flags: nowait postinstall shellexec

[UninstallRun]
; Remove the autostart task if the user enabled it in-app
Filename: "schtasks.exe"; Parameters: "/Delete /F /TN ""{#AppName}"""; Flags: runhidden; RunOnceId: "DelVentoTask"

[UninstallDelete]
; Runtime state the app writes next to itself
Type: files; Name: "{app}\settings.json"
Type: files; Name: "{app}\error.log"
