@echo off
setlocal
cd /d "%~dp0"
title Aegis Palworld Suite Diagnostics
echo Aegis Palworld Suite 2.0.1 Diagnostics
echo =======================================
echo Root: %CD%
echo.
for %%F in (
  "App\Aegis-Palworld-Suite.ps1"
  "Engine\Update-PaldeckDatabase.ps1"
  "Database"
  "Icons\_fallback.svg"
) do (
  if exist "%%~F" (echo [OK] %%~F) else (echo [MISSING] %%~F)
)
echo.
echo Launching the Suite visibly so PowerShell errors remain on screen...
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0App\Aegis-Palworld-Suite.ps1"
echo.
echo Process exit code: %ERRORLEVEL%
pause
