@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only.
rem Read-only BlueMap snapshot. Default metadata mode; pass deep for tile statistics.

set "SCAN="
if /I "%~1"=="deep" set "SCAN=-Deep"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\bluemap-timemachine.ps1" %SCAN%
set "code=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Tip: report.md and summary-qq.txt are under tmp\bluemap-timemachine\'; Write-Host 'Press Enter to close...'"
pause >nul
exit /b %code%
