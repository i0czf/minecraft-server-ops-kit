@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included).
rem This script lives in the scripts subfolder; server root is one level up.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\set-ai-provider.ps1" %*
set "code=%ERRORLEVEL%"
if not "%code%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host ('[FAIL] AI switch failed. Code: ' + $env:code)"
)
pause >nul
exit /b %code%
