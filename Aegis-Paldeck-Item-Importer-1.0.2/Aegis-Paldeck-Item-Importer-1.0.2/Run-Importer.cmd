@echo off
setlocal
cd /d "%~dp0"
title Aegis Paldeck Item Importer

echo ============================================================
echo  Aegis Paldeck Item Importer 1.0.2
echo ============================================================
echo.
echo This run will import every URL in Input\Items.txt and
echo download item icons. Existing page cache will be reused.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Paldeck-Database.ps1" -DownloadIcons
if errorlevel 1 (
    echo.
    echo Importer exited with an error.
    pause
)
endlocal
