@echo off
setlocal
cd /d "%~dp0"
title Aegis Palworld Suite 2.1.5 Diagnostics

echo Aegis Palworld Suite 2.1.5
echo Visible startup diagnostics
echo =========================
echo.

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" ^
  -NoLogo -NoProfile -STA -ExecutionPolicy Bypass ^
  -Command "$ErrorActionPreference='Stop'; try { & '%~dp0App\Aegis-Palworld-Suite.ps1' } catch { Write-Host ''; Write-Host 'STARTUP ERROR' -ForegroundColor Red; Write-Host $_.Exception.Message -ForegroundColor Red; Write-Host ''; Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Yellow; Write-Host $_.ScriptStackTrace -ForegroundColor DarkYellow; $_ | Out-String | Set-Content -Path '%~dp0Logs\Visible-Diagnostic-Error.txt' -Encoding UTF8; exit 1 }"

echo.
echo Exit code: %ERRORLEVEL%
echo Diagnostic log: Logs\Visible-Diagnostic-Error.txt
pause
