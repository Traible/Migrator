@echo off
setlocal EnableExtensions

REM ============================================================
REM  Migrator launcher
REM  Uses a portable PowerShell 7 from Tools\pwsh when present,
REM  otherwise the installed one.
REM ============================================================

set "BASE=%~dp0"
set "PWSH=%BASE%Tools\pwsh\pwsh.exe"
if exist "%PWSH%" goto :RUN

set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%PWSH%" goto :RUN

set "PWSH="
for %%I in (pwsh.exe) do set "PWSH=%%~$PATH:I"
if defined PWSH goto :RUN

echo.
echo  PowerShell 7 was not found.
echo  Run "Get Tools.bat" in this folder (it installs PowerShell 7 and 7-Zip),
echo  or install PowerShell 7 from https://aka.ms/powershell
echo.
pause
exit /b 1

:RUN
set "POWERSHELL_UPDATECHECK=Off"
start "" "%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE%src\main.ps1" %*
exit /b 0
