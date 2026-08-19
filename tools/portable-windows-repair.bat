@echo off
setlocal EnableExtensions
chcp 65001 >nul
rem Standalone fixer for the Windows updater flash-exit (LF in Windows-sync.bat).
rem Keep CRLF + UTF-8 no BOM; keep every cmd-parsed line ASCII-only.
cd /d "%~dp0"
set "PORTABLE_REPAIR_HOME=%~dp0"
if "%PORTABLE_REPAIR_HOME:~-1%"=="\" set "PORTABLE_REPAIR_HOME=%PORTABLE_REPAIR_HOME:~0,-1%"
set "PORTABLE_REPAIR_PS1="
if exist "%~dp0portable-windows-repair.ps1" set "PORTABLE_REPAIR_PS1=%~dp0portable-windows-repair.ps1"
if not defined PORTABLE_REPAIR_PS1 if exist "%~dp0_updater\portable-windows-repair.ps1" set "PORTABLE_REPAIR_PS1=%~dp0_updater\portable-windows-repair.ps1"
if defined PORTABLE_REPAIR_PS1 goto :Run
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[错误] 未找到 portable-windows-repair.ps1。请使用群里发的完整修复包（不要只拷这一个 bat）。'; Write-Host '按回车键关闭窗口...'"
pause >nul
exit /b 1
:Run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PORTABLE_REPAIR_PS1%" -RepairHome "%PORTABLE_REPAIR_HOME%" -StartDir "%PORTABLE_REPAIR_HOME%"
exit /b %ERRORLEVEL%
