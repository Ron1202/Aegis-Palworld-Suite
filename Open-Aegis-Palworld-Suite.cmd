@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "APP=%ROOT%App\Aegis-Palworld-Suite.ps1"
set "LOGDIR=%ROOT%Logs"
set "LOGFILE=%LOGDIR%\Launcher-Error.txt"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

cd /d "%ROOT%"

if not exist "%APP%" (
    echo.
    echo ERROR: The Aegis application script is missing.
    echo.
    echo Expected:
    echo %APP%
    echo.
    echo Extract the complete ZIP and keep the App, Engine, Database,
    echo Icons, and Logs folders together.
    echo.
    pause
    exit /b 1
)

if not exist "%ROOT%Engine\Update-PaldeckDatabase.ps1" (
    echo.
    echo ERROR: The Aegis database engine is missing.
    echo.
    echo Expected:
    echo %ROOT%Engine\Update-PaldeckDatabase.ps1
    echo.
    echo This launcher must remain in the Suite root folder.
    echo.
    pause
    exit /b 1
)

if not exist "%LOGDIR%" mkdir "%LOGDIR%"

rem Run directly with -File. The PowerShell application already handles
rem its own startup exceptions and writes Suite-Startup-Error.txt.
"%POWERSHELL%" ^
    -NoLogo ^
    -NoProfile ^
    -STA ^
    -ExecutionPolicy Bypass ^
    -File "%APP%" 1>>"%LOGFILE%" 2>>&1

set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
    echo.
    echo Aegis Palworld Suite exited with code %EXITCODE%.
    echo.
    echo Review:
    echo %LOGFILE%
    echo.
    echo Also review:
    echo %LOGDIR%\Suite-Startup-Error.txt
    echo.
    pause
)

exit /b %EXITCODE%
