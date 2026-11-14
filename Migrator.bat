@echo off
setlocal EnableExtensions

REM ============================================================
REM  Migrator launcher
REM  Uses a portable PowerShell 7 from Tools\pwsh when present,
REM  otherwise the installed one. When there is none, explains
REM  what is missing and installs nothing without a typed "Y".
REM
REM  Messages are shown in one language. Russian text needs a
REM  console font with Cyrillic letters, which an English Windows
REM  with the classic console does not have: there it would be a
REM  row of question marks.
REM ============================================================

set "BASE=%~dp0"
call :DETECT_LANGUAGE

REM Started from inside the ZIP (Explorer unpacks only this file to a
REM temporary folder) or from an incomplete copy: say so instead of closing.
if exist "%BASE%src\main.ps1" goto :FILES_OK
call :MSG_UNPACK
pause
exit /b 1

:FILES_OK
call :FIND_PWSH
REM MIGRATOR_TEST_NO_PWSH lets the tests reach the branch below on a PC
REM that has PowerShell 7.
if defined MIGRATOR_TEST_NO_PWSH set "PWSH="
if defined PWSH goto :RUN

call :MSG_NEED_TOOLS
set "ANSWER="
if defined RU set /p "ANSWER= Продолжить? Введите Y и нажмите Enter [y/N]: "
if not defined RU set /p "ANSWER= Continue? Type Y and press Enter [y/N]: "
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
if defined RU echo  PowerShell 7 по-прежнему не найден. Установите его с https://aka.ms/powershell
if defined RU echo  и запустите Migrator.bat снова.
if not defined RU echo  PowerShell 7 is still missing. Install it from https://aka.ms/powershell
if not defined RU echo  and start Migrator.bat again.
echo.
pause
exit /b 1

:DECLINED
echo.
if defined RU echo  Ничего не установлено.
if not defined RU echo  Nothing was installed.
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

:DETECT_LANGUAGE
REM RU is defined when the messages should be in Russian: MIGRATOR_LANG
REM says so, or the display language of Windows is Russian.
set "RU="
if /i "%MIGRATOR_LANG%"=="en" exit /b 0
if /i "%MIGRATOR_LANG%"=="ru" goto :LANGUAGE_RU
set "UILANG="
for /f "tokens=2,*" %%A in ('reg query "HKCU\Control Panel\Desktop" /v PreferredUILanguages 2^>nul ^| findstr /i "PreferredUILanguages"') do set "UILANG=%%B"
if defined UILANG goto :LANGUAGE_CHECK
REM No per-user choice: the language Windows was installed in (0419 = Russian).
for /f "tokens=2,*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\Language" /v InstallLanguage 2^>nul ^| findstr /i "InstallLanguage"') do set "UILANG=%%B"
if "%UILANG%"=="0419" goto :LANGUAGE_RU
exit /b 0
:LANGUAGE_CHECK
if /i "%UILANG:~0,2%"=="ru" goto :LANGUAGE_RU
exit /b 0
:LANGUAGE_RU
set "RU=1"
chcp 65001 >nul
exit /b 0

:MSG_UNPACK
echo.
if defined RU goto :MSG_UNPACK_RU
echo  Migrator cannot start: its files are not next to Migrator.bat.
echo  If you opened Migrator.bat inside the downloaded ZIP archive, unpack the
echo  whole archive first (right-click the ZIP, "Extract All"), then run
echo  Migrator.bat from the unpacked folder.
echo.
exit /b 0
:MSG_UNPACK_RU
echo  Migrator не может запуститься: рядом с Migrator.bat нет его файлов.
echo  Если вы открыли Migrator.bat прямо в скачанном ZIP-архиве, сначала
echo  распакуйте весь архив (правой кнопкой по ZIP, «Извлечь все»), затем
echo  запустите Migrator.bat из распакованной папки.
echo.
exit /b 0

:MSG_NEED_TOOLS
echo.
if defined RU goto :MSG_NEED_TOOLS_RU
echo  PowerShell 7 was not found on this PC. Migrator needs two free programs:
echo.
echo    PowerShell 7   Microsoft, MIT license       https://aka.ms/powershell
echo    7-Zip          Igor Pavlov, GNU LGPL        https://www.7-zip.org
echo.
echo  Migrator can get the missing ones from the internet now. You will be
echo  asked about each program separately and can choose how:
echo.
echo    - install it in Windows with winget, the Windows package manager
echo      (for all users; Windows will ask for administrator rights), or
echo    - download a portable copy into the Migrator folder
echo      (nothing is installed in Windows).
echo.
echo  Nothing is downloaded or installed without your answer.
echo.
echo  No internet on this PC? Use a Migrator folder with the Tools folder
echo  filled: on the old PC choose the "restore kit" when you make the backup.
echo.
exit /b 0
:MSG_NEED_TOOLS_RU
echo  PowerShell 7 на этом компьютере не найден. Migrator нужны две
echo  бесплатные программы:
echo.
echo    PowerShell 7   Microsoft, лицензия MIT      https://aka.ms/powershell
echo    7-Zip          Игорь Павлов, GNU LGPL       https://www.7-zip.org
echo.
echo  Migrator может получить недостающие из интернета сейчас. О каждой
echo  программе будет отдельный вопрос, и можно выбрать способ:
echo.
echo    - установить в Windows через winget, менеджер пакетов Windows
echo      (для всех пользователей; Windows запросит права администратора), или
echo    - скачать переносную копию в папку Migrator
echo      (в Windows ничего не устанавливается).
echo.
echo  Без вашего ответа ничего не скачивается и не устанавливается.
echo.
echo  На компьютере нет интернета? Возьмите папку Migrator с заполненной
echo  папкой Tools: на старом компьютере выберите «комплект для
echo  восстановления» при создании копии.
echo.
exit /b 0
