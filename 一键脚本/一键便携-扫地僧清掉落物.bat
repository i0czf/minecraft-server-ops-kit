@echo off
chcp 65001 >nul
cd /d "%~dp0.."
echo [扫地僧] 立即清扫一轮（安全模式：只清远离玩家且够旧的掉落物；身边的不碰）
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\item-sweeper.ps1" -Once -Force -MinAgeTicks 400
echo.
pause
