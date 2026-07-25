@echo off
setlocal
cd /d "%~dp0"
title Aegis Palworld Suite - Rebuild and De-matte Item Icons
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Engine\Repair-ItemIcons.ps1" -Force
echo.
echo Close and reopen Aegis Palworld Suite to reload the cleaned thumbnails.
pause
