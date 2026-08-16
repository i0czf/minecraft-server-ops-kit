@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\build-recipe-index.ps1" -Force
echo.
pause