@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem Full backup restore smoke (extract + optional boot). Prefer when no players online.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  Backup Restore Smoke'; Write-Host '========================================'; Write-Host 'Extract latest world zip to isolated dir; -Boot starts shadow server to Done.'; Write-Host 'Does NOT touch live world. Prefer when no players online.'; Write-Host ''"

set "EXTRA=-Boot"
if /I "%~1"=="extract" set "EXTRA="
if /I "%~1"=="noboot" set "EXTRA="

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\backup-restore-smoke.ps1" %EXTRA% -QqSummary
set "code=%ERRORLEVEL%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Tip: arg extract = no boot. Output tmp\backup-restore-smoke\'; Write-Host 'Press Enter...'"
pause >nul
exit /b %code%