@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
rem Client self-repair: run inside player instance root (or next to this bat).

if exist "%~dp0_updater\player-self-repair.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_updater\player-self-repair.ps1" -InstanceDir "%~dp0." -NoPause
) else if exist "%~dp0player-self-repair.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0player-self-repair.ps1" -InstanceDir "%~dp0." -NoPause
) else if exist "%~dp0..\tools\player-self-repair.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\player-self-repair.ps1" -InstanceDir "%~dp0." -NoPause
) else (
  echo [ERROR] player-self-repair.ps1 not found. Put it in _updater\ or re-sync the pack.
  pause
  exit /b 1
)
set "code=%ERRORLEVEL%"
echo.
echo Tip: to auto-fix mismatches run:
echo   powershell -File _updater\player-self-repair.ps1 -Fix
echo.
pause
exit /b %code%