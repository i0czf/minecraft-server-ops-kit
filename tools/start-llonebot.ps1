param(
    [switch]$NoBanner,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '启动 LLBot（QQ 机器人本体）' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$llbotDir = Join-Path $Root "tools\LLBot-CLI-win-x64"
$exe = Join-Path $llbotDir "llbot.exe"
$configDir = Join-Path $llbotDir "bin\llbot\data"
$configs = @(Get-ChildItem -LiteralPath $configDir -Filter "config_*.json" -File -ErrorAction SilentlyContinue)

function Wait-Exit([int]$Code) { if (-not $NoPause) { pause }; exit $Code }

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host "[错误] 未找到 LLBot：$exe" -ForegroundColor Red
    Write-Host "你拿到的可能是精简版工具包（不含 LLBot 本体），两种补齐方式：" -ForegroundColor Yellow
    Write-Host "  方式一（推荐）：找作者要完整版工具包，解压覆盖到本目录——LLBot 已内置在 tools\LLBot-CLI-win-x64。" -ForegroundColor Yellow
    Write-Host "  方式二（自装）：到 LLOneBot 官方发布页 https://github.com/LLOneBot/LLOneBot/releases 下载" -ForegroundColor Yellow
    Write-Host "           LLBot CLI（Windows x64）压缩包，解压到 tools\LLBot-CLI-win-x64\，确保该目录下有 llbot.exe。" -ForegroundColor Yellow
    Write-Host "  另外本机需安装 QQ（NT 版）客户端供机器人登录。放好后重新双击本入口即可。" -ForegroundColor Yellow
    Wait-Exit 1
}

# QQ 本体检查：LLBot 通过 pmhq 拉起 NTQQ，QQ 客户端体积太大（约 2GB）不随工具包分发。
$pmhqCfgPath = Join-Path $llbotDir 'bin\pmhq\pmhq_config.json'
if (Test-Path -LiteralPath $pmhqCfgPath -PathType Leaf) {
    try {
        $pmhqCfg = Get-Content -LiteralPath $pmhqCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $qqPath = [string]$pmhqCfg.qq_path
        if (-not [string]::IsNullOrWhiteSpace($qqPath) -and -not (Test-Path -LiteralPath $qqPath -PathType Leaf)) {
            Write-Host "[提示] pmhq_config.json 里的 qq_path 在本机不存在：$qqPath" -ForegroundColor Yellow
            Write-Host "       请安装 QQ（NT 版）后把该字段改成本机 QQ.exe 路径，或留空让 pmhq 自动探测已安装的 QQ。" -ForegroundColor Yellow
        }
    } catch { }
}

if (-not $NoBanner) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  启动 LLBot QQ 机器人" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "当前方案使用 LLBot，不使用 NapCat。" -ForegroundColor Yellow
    Write-Host "请确认 LLBot 配置中已启用：" -ForegroundColor Yellow
    Write-Host "  WebUI： http://127.0.0.1:3080/ 或 http://127.0.0.1:3081/" -ForegroundColor Yellow
    Write-Host "  OneBot HTTP：127.0.0.1:3001" -ForegroundColor Yellow
    Write-Host "  OneBot WS：  127.0.0.1:3002" -ForegroundColor Yellow
    if ($configs.Count -gt 0) {
        Write-Host "已找到 LLBot 账号配置：$($configs.Name -join ', ')" -ForegroundColor Green
    } else {
        Write-Host "未找到 LLBot 账号配置。首次启动后请按提示登录并保存配置。" -ForegroundColor Yellow
    }
    Write-Host ""
}

Push-Location $llbotDir
try { & $exe } finally { Pop-Location }
Wait-Exit $LASTEXITCODE
