@echo off
setlocal
cd /d "%~dp0"
title Aegis Palworld Suite 2.1.2 Update
echo.
echo Aegis Palworld Suite 2.1.2
echo Step 1 of 2: Updating the verified Paldeck database...
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Engine\Update-PaldeckDatabase.ps1"
set "DB_RESULT=%ERRORLEVEL%"
echo.
if "%DB_RESULT%"=="0" (
  echo Step 2 of 2: Converting item artwork to WPF-compatible PNG...
  echo.
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Engine\Repair-ItemIcons.ps1" -Force
  echo.
  echo Repairing item descriptions...
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Engine\Repair-ItemDescriptions.ps1"
) else (
  echo Database update failed with exit code %DB_RESULT%.
  echo Existing verified data will be used when available.
  pause
)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0App\Aegis-Palworld-Suite.ps1"
exit /b 0
