@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included). Chinese in a rem line
rem desyncs cmd byte reader under chcp 65001 and half the comment gets executed as a command.
rem This script lives in the scripts subfolder; server root is one level up. Prefer the control panel.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  同步 DDNS 解析（DNSPod）'; Write-Host '========================================'; Write-Host '把域名 A/AAAA 记录同步成本机当前公网 IP。'; Write-Host '需要先在 tools\ops-config.json 的 ddns 段填好 loginToken 并把 enabled 改为 true。'; Write-Host ''"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\ddns-update.ps1"
set "code=%ERRORLEVEL%"

if "%code%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '[完成] DDNS 同步已完成。'"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host ('[提示] 未完成同步。返回码：' + $env:code + '（1=未配置/未启用，2=同步失败，详见上方输出）')"
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '按回车键关闭窗口...'"
pause >nul
exit /b %code%
