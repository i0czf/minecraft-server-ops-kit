@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "net session >nul 2>&1; if($LASTEXITCODE -ne 0){$p=Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path (Get-Location) 'tools\reload-qq-console.ps1'),'-NoPause'); exit $p.ExitCode}; & (Join-Path (Get-Location) 'tools\reload-qq-console.ps1') -NoPause"
set "code=%ERRORLEVEL%"
if not "%code%"=="0" (
  echo QQ桥重载失败，查看 logs\qq-console-start.err
)
pause
exit /b %code%
