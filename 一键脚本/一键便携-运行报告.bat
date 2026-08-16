@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; ASCII-only rem lines.
rem Generate weekly/daily ops report (read-only).

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  Server Ops Report'; Write-Host '========================================'; Write-Host 'Read-only summary from perf box / backups / crashes / fingerprints.'; Write-Host ''"

set "WIN=7d"
if /I "%~1"=="1d" set "WIN=1d"
if /I "%~1"=="7d" set "WIN=7d"
if /I "%~1"=="30d" set "WIN=30d"
if /I "%~1"=="day" set "WIN=1d"
if /I "%~1"=="week" set "WIN=7d"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\weekly-report.ps1" -Window %WIN%
set "code=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Tip: pass 1d / 7d / 30d as argument. Output under tmp\weekly-report\'; Write-Host 'Press Enter to close...'"
pause >nul
exit /b %code%
