@echo off
setlocal EnableExtensions

REM ============================================================
REM  Migrator launcher
REM  Uses a portable PowerShell 7 from Tools\pwsh when present,
REM  otherwise the installed one. When there is none, explains
REM  what is missing and installs nothing without a typed "Y".
REM ============================================================

set "BASE=%~dp0"
call :FIND_PWSH
REM MIGRATOR_TEST_NO_PWSH lets the tests reach the branch below on a PC
REM that has PowerShell 7.
if defined MIGRATOR_TEST_NO_PWSH set "PWSH="
if defined PWSH goto :RUN

chcp 65001 >nul
echo.
echo  PowerShell 7 was not found on this PC. Migrator needs two free programs:
echo.
echo    PowerShell 7   Microsoft, MIT license       https://aka.ms/powershell
echo    7-Zip          Igor Pavlov, GNU LGPL        https://www.7-zip.org
echo.
echo  Migrator can install the missing ones now with winget, the package
echo  manager built into Windows. They are downloaded from the internet and
echo  installed on this PC for all users; Windows will ask for administrator
echo  rights. You will be asked about each program separately.
echo.
echo  Do not want to install anything? Answer N. On a PC without internet use
echo  a Migrator folder with the Tools folder filled: on the old PC choose the
echo  "restore kit" when you make the backup.
echo.
echo  ------------------------------------------------------------------
echo.
echo  PowerShell 7 на этом компьютере не найден. Migrator нужны две
echo  бесплатные программы:
echo.
echo    PowerShell 7   Microsoft, лицензия MIT      https://aka.ms/powershell
echo    7-Zip          Игорь Павлов, GNU LGPL       https://www.7-zip.org
echo.
echo  Migrator может установить недостающие сейчас через winget, встроенный
echo  в Windows менеджер пакетов. Они будут скачаны из интернета и
echo  установлены на этот компьютер для всех пользователей; Windows запросит
echo  права администратора. О каждой программе будет отдельный вопрос.
echo.
echo  Не хотите ничего устанавливать? Ответьте N. На компьютере без интернета
echo  возьмите папку Migrator с заполненной папкой Tools: на старом компьютере
echo  выберите «комплект для восстановления» при создании копии.
echo.
set "ANSWER="
set /p "ANSWER= Continue? Type Y and press Enter / Продолжить? Введите Y и нажмите Enter [y/N]: "
if not defined ANSWER goto :DECLINED
set "ANSWER=%ANSWER:"=%"
if /i "%ANSWER%"=="y" goto :INSTALL
if /i "%ANSWER%"=="yes" goto :INSTALL
goto :DECLINED

:INSTALL
REM No -Yes here: Get-Tools.ps1 asks about every program on its own.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE%Get-Tools.ps1"
call :FIND_PWSH
if defined PWSH goto :RUN

echo.
echo  PowerShell 7 is still missing. Install it from https://aka.ms/powershell
echo  and start Migrator.bat again.
echo.
pause
exit /b 1

:DECLINED
echo.
echo  Nothing was installed. / Ничего не установлено.
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
