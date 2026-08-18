@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
if not exist "%~dp0..\tools\stop-portable-web-panel.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[Web] missing tools\stop-portable-web-panel.ps1'; pause"
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\stop-portable-web-panel.ps1"
set "code=%ERRORLEVEL%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Press Enter to close...'"
pause >nul
exit /b %code%
