@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included). Chinese in a rem line
rem desyncs cmd byte reader under chcp 65001 and half the comment gets executed as a command.
rem This script lives in the scripts subfolder; server root is one level up. Prefer the control panel.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  生成规范导入包'; Write-Host '========================================'; Write-Host '生成标准导入包（如 mrpack）和 PCL 导入包。'; Write-Host ''"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\build-portable-import-packs.ps1" -ConfigPath "%~dp0..\tools\portable-pack.json"
set "code=%ERRORLEVEL%"

if "%code%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '[完成] 规范导入包已生成。'"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host ('[失败] 执行失败。错误码：' + $env:code)"
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '按回车键关闭窗口...'"
pause >nul
exit /b %code%
