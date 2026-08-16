@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included). Chinese in a rem line
rem desyncs cmd byte reader under chcp 65001 and half the comment gets executed as a command.
rem This script lives in the scripts subfolder; server root is one level up. Prefer the control panel.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[提示] 此入口已合并到 一键便携-启动所有运维.bat，现在将自动转入。'; Write-Host ''"
call "%~dp0一键便携-启动所有运维.bat" %*
exit /b %ERRORLEVEL%
