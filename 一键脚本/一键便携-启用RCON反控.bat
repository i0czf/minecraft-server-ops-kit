@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included). Chinese in a rem line
rem desyncs cmd byte reader under chcp 65001 and half the comment gets executed as a command.
rem This script lives in the scripts subfolder; server root is one level up. Prefer the control panel.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  启用 RCON 反控'; Write-Host '========================================'; Write-Host '自动检查并启用本地 RCON，供 Discord/QQ 控制台使用。'; Write-Host '注意：修改 server.properties 后通常需要重启服务端。'; Write-Host ''"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\enable-local-rcon.ps1"
set "code=%ERRORLEVEL%"

if "%code%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '[完成] RCON 配置已处理。'"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host ('[失败] 执行失败。错误码：' + $env:code)"
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '按回车键关闭窗口...'"
pause >nul
exit /b %code%
