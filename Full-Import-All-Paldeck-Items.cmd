@echo off
setlocal
cd /d "%~dp0"
title Aegis Palworld Suite - Full Paldeck Import
echo.
echo Aegis Palworld Suite 2.3.0 - Full Paldeck Import
echo =================================================
echo.
echo This importer scans:
echo   - Raw Paldeck HTML and embedded application data
echo   - Next.js serialized payloads
echo   - Paldeck sitemaps
echo   - Fully rendered and infinitely scrolled item lists
echo   - Every category in ascending and descending order
echo   - JSON/API resources observed by the browser
echo.
echo Your current verified database is merged as a safety net.
echo The database will not be replaced unless required items,
echo including Paloxite Ingot [WorldTreeIngot], are verified.
echo.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" ^
  -NoLogo -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0Engine\Update-PaldeckDatabase.ps1"
echo.
pause
