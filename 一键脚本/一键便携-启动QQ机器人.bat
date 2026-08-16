@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included). Chinese in a rem line
rem desyncs cmd byte reader under chcp 65001 and half the comment gets executed as a command.
rem This script lives in the scripts subfolder; server root is one level up. Prefer the control panel.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  启动 QQ 机器人运行时（LLBot）'; Write-Host '========================================'; Write-Host '当前方案使用 LLBot，不自动启动 NapCat。'; Write-Host 'LLBot WebUI 通常为 http://127.0.0.1:3080/ 或 http://127.0.0.1:3081/。'; Write-Host 'OneBot HTTP/WS 端口应为 3001/3002。'; Write-Host ''"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\start-qq-bot.ps1" -NoBanner -NoPause
set "code=%ERRORLEVEL%"

if "%code%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '[完成] QQ 机器人运行时已退出。'"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host ('[失败] QQ 机器人启动失败。错误码：' + $env:code)"
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '按回车键关闭窗口...'"
pause >nul
exit /b %code%
