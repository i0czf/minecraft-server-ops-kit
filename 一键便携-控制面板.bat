@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
rem NOTE: keep CRLF + UTF-8 no BOM; keep cmd-parsed lines (rem included) ASCII-only.
rem Chinese output goes via powershell Write-Host (cmd echo garbles CJK under chcp 65001).
rem AV note: never launch powershell via start + -WindowStyle Hidden (Huorong heuristic
rem HEUR:TrojanDownloader/PS.NetLoader.am deletes the bat on sight, seen 2026-07-06).
rem Run powershell synchronously in a visible window; the panel minimizes its own console.

if not exist "%~dp0tools\portable-control-panel.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[失败] 缺少 tools\portable-control-panel.ps1，请确认工具包完整后重试。'; Write-Host ''; Write-Host '按回车键关闭窗口...'"
    pause >nul
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0tools\portable-control-panel.ps1"
exit /b %ERRORLEVEL%
