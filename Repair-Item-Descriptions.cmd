@echo off
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Engine\Repair-ItemDescriptions.ps1"
echo.
echo Reopen Aegis Palworld Suite to load repaired descriptions.
pause
