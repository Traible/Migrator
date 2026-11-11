@echo off
setlocal EnableExtensions

REM ============================================================
REM  Migrator launcher
REM  Uses a portable PowerShell 7 from Tools\pwsh when present,
REM  otherwise the installed one. When there is none, offers to
REM  install it (needs internet).
REM ============================================================

set "BASE=%~dp0"
call :FIND_PWSH
if defined PWSH goto :RUN

chcp 65001 >nul
echo.
echo  PowerShell 7 was not found on this PC.
echo  Migrator can install PowerShell 7 and 7-Zip now (internet is required).
echo  No internet? Use a Migrator folder with the Tools folder filled: on the
echo  old PC choose the "restore kit" when you make the backup.
echo.
echo  PowerShell 7 на этом компьютере не найден.
echo  Migrator может установить PowerShell 7 и 7-Zip сейчас (нужен интернет).
echo  Нет интернета? Возьмите папку Migrator с заполненной папкой Tools: на
echo  старом компьютере выберите «комплект для восстановления» при создании копии.
echo.
set "ANSWER="
set /p "ANSWER= Install now? / Установить сейчас? [Y/n]: "
if /i "%ANSWER%"=="n" exit /b 1
if /i "%ANSWER%"=="no" exit /b 1

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE%Get-Tools.ps1" -Yes
call :FIND_PWSH
if defined PWSH goto :RUN

echo.
echo  PowerShell 7 is still missing. Install it from https://aka.ms/powershell
echo  and start Migrator.bat again.
echo.
pause
exit /b 1

:RUN
set "POWERSHELL_UPDATECHECK=Off"
start "" "%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE%src\main.ps1" %*
exit /b 0

:FIND_PWSH
set "PWSH=%BASE%Tools\pwsh\pwsh.exe"
if exist "%PWSH%" exit /b 0
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%PWSH%" exit /b 0
set "PWSH="
for %%I in (pwsh.exe) do set "PWSH=%%~$PATH:I"
exit /b 0
