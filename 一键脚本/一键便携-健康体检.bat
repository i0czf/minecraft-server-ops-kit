@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included).
rem Health check entry: run tools\health-check.ps1 with optional diagnostic pack.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  Server Health Check'; Write-Host '========================================'; Write-Host 'Read-only diagnostics + risk score. Optional sanitized diagnostic pack.'; Write-Host ''"

if /I "%~1"=="-Pack" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\health-check.ps1" -Pack
) else if /I "%~1"=="pack" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\health-check.ps1" -Pack
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\health-check.ps1"
)
set "code=%ERRORLEVEL%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host 'Tip: pass -Pack to also build a sanitized diagnostic zip under tmp\health-check\'; Write-Host 'Press Enter to close...'"
pause >nul
exit /b %code%
