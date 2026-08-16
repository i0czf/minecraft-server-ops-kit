@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only.
rem Read-only incident postmortem. Args: 1h / 6h / 24h / 7d

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  Incident Postmortem'; Write-Host '========================================'; Write-Host 'Read-only correlation of timeline/perf/lag/audit/crash/backup evidence.'; Write-Host ''"

set "WIN=24h"
if /I "%~1"=="1h" set "WIN=1h"
if /I "%~1"=="6h" set "WIN=6h"
if /I "%~1"=="24h" set "WIN=24h"
if /I "%~1"=="1d" set "WIN=1d"
if /I "%~1"=="7d" set "WIN=7d"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\incident-postmortem.ps1" -Window %WIN%
set "code=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Tip: report.md and summary-qq.txt are under tmp\incident-postmortem\'; Write-Host 'Press Enter to close...'"
pause >nul
exit /b %code%
