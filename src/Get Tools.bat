@echo off
setlocal EnableExtensions

REM Checks / installs PowerShell 7 and 7-Zip. Runs under the built-in
REM Windows PowerShell, so it works on a clean Windows.
REM   "Get Tools.bat"            - use installed copies or install with winget
REM   "Get Tools.bat" -Portable  - put portable copies into the Tools folder

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Get-Tools.ps1" %*
echo.
pause
exit /b %ERRORLEVEL%
