@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
if not exist "%~dp0tools\portable-web-panel.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[Web] missing tools\portable-web-panel.ps1'; pause"
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\portable-web-panel.ps1" %*
exit /b %ERRORLEVEL%
