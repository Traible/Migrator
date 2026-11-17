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
call :SETUP_COLORS

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
if defined RU echo  %C_WARN%[!]  PowerShell 7 по-прежнему не найден.%C_OFF%
if defined RU echo  %C_OK%-^>   Установите его с https://aka.ms/powershell и запустите Migrator.bat снова.%C_OFF%
if not defined RU echo  %C_WARN%[!]  PowerShell 7 is still missing.%C_OFF%
if not defined RU echo  %C_OK%-^>   Install it from https://aka.ms/powershell and start Migrator.bat again.%C_OFF%
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

:SETUP_COLORS
REM Problems are shown in orange, the way out in green. Escape sequences
REM work in the console of Windows 10 1511 and later; older systems and
REM NO_COLOR get plain text.
set "C_WARN="
set "C_OK="
set "C_OFF="
if defined NO_COLOR exit /b 0
set "WINBUILD="
for /f "tokens=2 delims=[]" %%V in ('ver') do for /f "tokens=4 delims=. " %%B in ("%%V") do set "WINBUILD=%%B"
if not defined WINBUILD exit /b 0
if %WINBUILD% LSS 10586 exit /b 0
set "ESC="
for /f %%E in ('echo prompt $E^| cmd') do set "ESC=%%E"
if not defined ESC exit /b 0
set "C_WARN=%ESC%[38;5;208m"
set "C_OK=%ESC%[92m"
set "C_OFF=%ESC%[0m"
exit /b 0

:MSG_UNPACK
echo.
if defined RU goto :MSG_UNPACK_RU
echo  %C_WARN%[!]  Migrator cannot start: its files are not next to Migrator.bat.%C_OFF%
echo       This happens when Migrator.bat is opened inside the downloaded ZIP archive.
echo.
echo  %C_OK%-^>   Unpack the whole archive first (right-click the ZIP, "Extract All"),%C_OFF%
echo  %C_OK%     then run Migrator.bat from the unpacked folder.%C_OFF%
echo.
exit /b 0
:MSG_UNPACK_RU
echo  %C_WARN%[!]  Migrator не может запуститься: рядом с Migrator.bat нет его файлов.%C_OFF%
echo       Так бывает, если открыть Migrator.bat прямо в скачанном ZIP-архиве.
echo.
echo  %C_OK%-^>   Сначала распакуйте весь архив (правой кнопкой по ZIP, «Извлечь все»),%C_OFF%
echo  %C_OK%     затем запустите Migrator.bat из распакованной папки.%C_OFF%
echo.
exit /b 0

:MSG_NEED_TOOLS
echo.
if defined RU goto :MSG_NEED_TOOLS_RU
echo  %C_WARN%[!]  PowerShell 7 was not found on this PC.%C_OFF%
echo       Migrator needs two free programs:
echo.
echo         PowerShell 7   Microsoft, MIT license       https://aka.ms/powershell
echo         7-Zip          Igor Pavlov, GNU LGPL        https://www.7-zip.org
echo.
echo  %C_OK%-^>   Type Y and press Enter: Migrator gets the missing ones from the internet.%C_OFF%
echo       You are asked about each program separately and choose how:
echo         - install it in Windows with winget, the Windows package manager
echo           (for all users; Windows asks for administrator rights), or
echo         - download a portable copy into the Migrator folder
echo           (nothing is installed in Windows).
echo       Nothing is downloaded or installed without your answer.
echo.
echo  %C_OK%-^>   No internet on this PC? Take a Migrator folder with the Tools folder filled.%C_OFF%
echo       On the old PC choose the "restore kit" when you make the backup.
echo.
exit /b 0
:MSG_NEED_TOOLS_RU
echo  %C_WARN%[!]  PowerShell 7 на этом компьютере не найден.%C_OFF%
echo       Migrator нужны две бесплатные программы:
echo.
echo         PowerShell 7   Microsoft, лицензия MIT      https://aka.ms/powershell
echo         7-Zip          Игорь Павлов, GNU LGPL       https://www.7-zip.org
echo.
echo  %C_OK%-^>   Введите Y и нажмите Enter: Migrator получит недостающие из интернета.%C_OFF%
echo       О каждой программе будет отдельный вопрос, и можно выбрать способ:
echo         - установить в Windows через winget, менеджер пакетов Windows
echo           (для всех пользователей; Windows запросит права администратора), или
echo         - скачать переносную копию в папку Migrator
echo           (в Windows ничего не устанавливается).
echo       Без вашего ответа ничего не скачивается и не устанавливается.
echo.
echo  %C_OK%-^>   Нет интернета? Возьмите папку Migrator с заполненной папкой Tools.%C_OFF%
echo       На старом компьютере выберите «комплект для восстановления» при создании копии.
echo.
exit /b 0
