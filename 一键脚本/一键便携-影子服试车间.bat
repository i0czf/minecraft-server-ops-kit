@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem Shadow server smoke: boot current pack in isolated dir until Done.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  Shadow Server Workshop'; Write-Host '========================================'; Write-Host 'Boot current modpack in isolated dir until Done.'; Write-Host 'Does NOT touch live world. Prefer no players online.'; Write-Host ''"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\shadow-smoke.ps1" -QqSummary
set "code=%ERRORLEVEL%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Output: tmp\shadow-smoke\  Press Enter...'"
pause >nul
exit /b %code%