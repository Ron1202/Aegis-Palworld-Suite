@echo off
setlocal
cd /d "%~dp0"
title Aegis Paldeck Item Importer - Retry Failures
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Paldeck-Database.ps1" -DownloadIcons -RetryFailuresOnly
if errorlevel 1 pause
endlocal
