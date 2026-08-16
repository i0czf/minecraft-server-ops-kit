@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem Ops timeline (read-only). Args: 1h / 6h / 24h / 7d

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  Ops Timeline'; Write-Host '========================================'; Write-Host 'Read-only event timeline from audits/backups/lag/crashes.'; Write-Host ''"

set "WIN=6h"
if /I "%~1"=="1h" set "WIN=1h"
if /I "%~1"=="6h" set "WIN=6h"
if /I "%~1"=="24h" set "WIN=24h"
if /I "%~1"=="1d" set "WIN=24h"
if /I "%~1"=="7d" set "WIN=7d"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\ops-timeline.ps1" -Window %WIN%
set "code=%ERRORLEVEL%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Tip: pass 1h / 6h / 24h / 7d. Output under tmp\ops-timeline\'; Write-Host 'Press Enter to close...'"
pause >nul
exit /b %code%