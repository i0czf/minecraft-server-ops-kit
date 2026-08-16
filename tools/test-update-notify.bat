@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ========================================
echo   测试更新通知发送（Discord/QQ）
echo ========================================
echo.

if not exist "tmp\update-change-summary-test.txt" (
    echo [错误] 测试摘要文件不存在：tmp\update-change-summary-test.txt
    echo 请先运行脚本生成测试摘要文件。
    pause
    exit /b 1
)

echo 测试摘要内容：
type "tmp\update-change-summary-test.txt"
echo.
echo ========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tools\send-update-notify.ps1" -SummaryFile "tmp\update-change-summary-test.txt" -ConfigPath "tools\ops-config.json"
set "code=%ERRORLEVEL%"

echo.
if "%code%"=="0" (
    echo [完成] 测试通知已发送。
) else (
    echo [失败] 测试通知发送失败。错误码：%code%
)

echo.
pause
exit /b %code%