@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included). Chinese in a rem line
rem desyncs cmd byte reader under chcp 65001 and half the comment gets executed as a command.
rem This script lives in the scripts subfolder; server root is one level up. Prefer the control panel.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  更新便携工具包'; Write-Host '========================================'; Write-Host '从主工具包 zip 拉取最新版；本服 pack/ops 配置不会被覆盖。'; Write-Host ''"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\update-toolkit.ps1"
exit /b %ERRORLEVEL%
