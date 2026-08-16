param(
    [switch]$NoBanner,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = 'QQ 机器人启动器' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$llbot = Join-Path $Root "tools\LLBot-CLI-win-x64\llbot.exe"

if (Test-Path -LiteralPath $llbot) {
    Write-Host "[QQ] 检测到 LLBot，正在启动。" -ForegroundColor Green
    & (Join-Path $Root "tools\start-llonebot.ps1") -NoBanner:$NoBanner -NoPause:$NoPause
    exit $LASTEXITCODE
}

Write-Host "[错误] 未找到 LLBot 运行时（QQ 机器人的核心程序）：" -ForegroundColor Red
Write-Host "  tools\LLBot-CLI-win-x64\llbot.exe"
Write-Host ""
Write-Host "你拿到的可能是精简版工具包（为了体积小没带 LLBot 本体），两种补齐方式：" -ForegroundColor Yellow
Write-Host "  方式一（推荐）：找作者要完整版工具包，解压覆盖到本目录——LLBot 已内置在 tools\LLBot-CLI-win-x64。" -ForegroundColor Yellow
Write-Host "  方式二（自装）：到 LLOneBot 官方发布页 https://github.com/LLOneBot/LLOneBot/releases 下载" -ForegroundColor Yellow
Write-Host "           LLBot CLI（Windows x64）压缩包，解压到 tools\LLBot-CLI-win-x64\，确保该目录下有 llbot.exe。" -ForegroundColor Yellow
Write-Host "  另外本机需安装 QQ（NT 版）客户端供机器人登录。" -ForegroundColor Yellow
Write-Host ""
Write-Host "放好 LLBot 后：先双击 一键脚本\一键便携-配置QQ机器人.bat 填群号，再回来点「启动 QQ 机器人」扫码登录。" -ForegroundColor Yellow
if (-not $NoPause) { pause }
exit 1