@echo off
rem Opens the Windows 11 glass design preview. Does not touch the installed Vento.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Glass.ps1"
