@echo off
setlocal EnableExtensions
title System Restore Tools

REM ============================================================
REM  Small menu of Windows recovery tools.
REM  No destructive actions; everything opens a standard dialog.
REM ============================================================

:MAIN
cls
echo ============================================================
echo   System Restore Tools
echo ============================================================
echo.
echo   [1] Windows System Restore (rstrui.exe)
echo   [2] Create a restore point
echo   [3] Windows Recovery settings
echo   [4] Open the Migrator Backups folder
echo   [Q] Quit
echo.
set "CHOICE="
set /p "CHOICE=Choose an option: "
if /i "%CHOICE%"=="1" goto :SYSTEMRESTORE
if /i "%CHOICE%"=="2" goto :RESTOREPOINT
if /i "%CHOICE%"=="3" goto :RECOVERY
if /i "%CHOICE%"=="4" goto :BACKUPS
if /i "%CHOICE%"=="Q" exit /b 0
if /i "%CHOICE%"=="quit" exit /b 0
goto :MAIN

:SYSTEMRESTORE
start "" rstrui.exe
goto :MAIN

:RESTOREPOINT
echo.
echo Creating a restore point. This can take a minute...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Checkpoint-Computer -Description 'Migrator manual restore point' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop; Write-Host 'Restore point created.' -ForegroundColor Green } catch { Write-Host ('Could not create a restore point: ' + $_.Exception.Message) -ForegroundColor Yellow }; Read-Host 'Press Enter'"
goto :MAIN

:RECOVERY
start "" control.exe /name Microsoft.Recovery
goto :MAIN

:BACKUPS
if not exist "%~dp0Backups" mkdir "%~dp0Backups"
start "" explorer.exe "%~dp0Backups"
goto :MAIN
