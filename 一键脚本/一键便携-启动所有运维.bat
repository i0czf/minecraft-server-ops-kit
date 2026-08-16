@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
rem NOTE: keep CRLF; keep every cmd-parsed line ASCII-only (rem included). Chinese in a rem line
rem desyncs cmd byte reader under chcp 65001 and half the comment gets executed as a command.
rem This script lives in the scripts subfolder; server root is one level up. Prefer the control panel.

if /i not "%~1"=="--elevated" (
    net session >nul 2>&1
    if errorlevel 1 (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[提示] 正在请求管理员权限，请在弹出的窗口中确认。'"
        set "OPS_ELEVATE_TARGET=%~f0"
        set "OPS_ELEVATE_WORKDIR=%~dp0"
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; Start-Process -FilePath $env:ComSpec -WorkingDirectory $env:OPS_ELEVATE_WORKDIR -ArgumentList @('/d','/c', ($q + $env:OPS_ELEVATE_TARGET + $q + ' --elevated')) -Verb RunAs"
        if errorlevel 1 (
            powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '[失败] 未能打开管理员窗口。请右键本脚本，选择以管理员身份运行。'; Write-Host ''; Write-Host '按回车键关闭窗口...'"
            pause >nul
            exit /b 1
        )
        exit /b 0
    )
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '========================================'; Write-Host '  启动所有运维监控'; Write-Host '========================================'; Write-Host '启动或刷新 Discord 通知、QQ 通知与反控、备份调度。'; Write-Host '不会启动或重启 Minecraft 服务端。'; Write-Host ''"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\start-ops-monitor.ps1" -Restart -NoPause
set "code=%ERRORLEVEL%"

if "%code%"=="0" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '[完成] 全部运维监控已启动或刷新。'"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host ('[警告] 有运维组件启动失败或启动后退出。错误码：' + $env:code); Write-Host '请检查 logs\discord-watch.log、logs\discord-console.log、logs\qq-console.log。'"
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '按回车键关闭窗口...'"
pause >nul
exit /b %code%
