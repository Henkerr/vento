' Vento launcher: requests admin rights and hides the console window.
' Works from any folder - resolves app.ps1 next to this script.
Set fso = CreateObject("Scripting.FileSystemObject")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("Shell.Application")
sh.ShellExecute "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & appDir & "\app.ps1""", "", "runas", 0
