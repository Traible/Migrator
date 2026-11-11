@echo off
setlocal EnableExtensions

set "BASE=%~dp0"
set "PWSH=%BASE%Tools\pwsh\pwsh.exe"
if not exist "%PWSH%" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" set "PWSH=pwsh.exe"

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE%Create-Shortcuts.ps1"
echo.
pause
exit /b 0
