@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem Verify world backup zip integrity (read-only).

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  Backup Verify'; Write-Host '========================================'; Write-Host 'Read-only zip structure + level.dat sample.'; Write-Host ''"

set "EXTRA="
if /I "%~1"=="deep" set "EXTRA=-Deep"
if /I "%~1"=="3" set "EXTRA=-Count 3"
if /I "%~1"=="deep3" set "EXTRA=-Deep -Count 3"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\verify-backup.ps1" %EXTRA%
set "code=%ERRORLEVEL%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Tip: args deep / 3 / deep3. Output under tmp\backup-verify\'; Write-Host 'Press Enter to close...'"
pause >nul
exit /b %code%