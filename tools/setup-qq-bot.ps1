param(
    [string]$QQGroupId = "",
    [string]$AdminQQ = "",
    [switch]$Enable,
    [switch]$NoBanner,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '配置 QQ 机器人' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

function Wait-Exit([int]$Code) {
    if (-not $NoPause) { pause }
    exit $Code
}

function Write-Title([string]$Text) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

if (-not $NoBanner) { Write-Title "QQ 群机器人配置检查" }

$configPath = Join-Path $Root "tools\ops-config.json"
$templatePath = Join-Path $Root "tools\portable-ops-config.example.json"
if (-not (Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $templatePath)) {
    Copy-Item -LiteralPath $templatePath -Destination $configPath -Force
    Write-Host "[配置] 已根据模板创建 tools\ops-config.json。" -ForegroundColor Green
}
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host "[错误] 未找到 tools\ops-config.json。请先运行“一键便携-初始化配置.bat”。" -ForegroundColor Red
    Wait-Exit 1
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $config.PSObject.Properties['qq']) {
    $qq = [pscustomobject]@{
        enabled = $false
        onebotUrl = "http://127.0.0.1:3001"
        groupId = ""
        commandPrefix = "!"
        adminIds = ""
        pollIntervalSeconds = 5
        wsPort = 3002
        events = [pscustomobject]@{
            join = $true; quit = $true; chat = $true; death = $true; advancement = $true
            startup = $true; shutdown = $true; command = $true; backup = $true; crash = $true; ip = $false
        }
    }
    $config | Add-Member -MemberType NoteProperty -Name qq -Value $qq
    Write-Host "[配置] 已补齐 qq 配置节。" -ForegroundColor Green
}

if ($QQGroupId) { $config.qq.groupId = $QQGroupId }
if ($AdminQQ) { $config.qq.adminIds = $AdminQQ }
if ($Enable -or $QQGroupId -or $AdminQQ) { $config.qq.enabled = $true }
if (-not $config.qq.onebotUrl) { $config.qq.onebotUrl = "http://127.0.0.1:3001" }
if (-not $config.qq.commandPrefix) { $config.qq.commandPrefix = "!" }
if (-not $config.qq.wsPort) { $config.qq.wsPort = 3002 }

$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
Write-Host "[配置] 已保存 tools\ops-config.json。" -ForegroundColor Green

$llbot = Join-Path $Root "tools\LLBot-CLI-win-x64\llbot.exe"
$onebot = [string]$config.qq.onebotUrl
$group = [string]$config.qq.groupId
$admins = [string]$config.qq.adminIds

Write-Host ""
Write-Host "当前配置" -ForegroundColor White
Write-Host "  QQ 桥接启用 : $($config.qq.enabled)"
Write-Host "  OneBot 地址 : $onebot"
Write-Host "  QQ 群号     : $group"
Write-Host "  反控白名单 : $admins（群主自动允许）"
Write-Host "  LLBot       : $(if (Test-Path -LiteralPath $llbot) { '已找到（默认使用）' } else { '未找到' })"
if (-not (Test-Path -LiteralPath $llbot)) {
    Write-Host ""
    Write-Host "[提示] 本机还没有 LLBot 程序本体（QQ 机器人的运行核心）。你拿到的可能是精简版工具包，两种补齐方式：" -ForegroundColor Yellow
    Write-Host "  方式一（推荐）：找作者要完整版工具包，解压覆盖到本目录即可——LLBot 已内置在 tools\LLBot-CLI-win-x64。" -ForegroundColor Yellow
    Write-Host "  方式二（自装）：到 LLOneBot 官方发布页 https://github.com/LLOneBot/LLOneBot/releases 下载" -ForegroundColor Yellow
    Write-Host "           LLBot CLI（Windows x64）压缩包，解压到 tools\LLBot-CLI-win-x64\，确保该目录下有 llbot.exe。" -ForegroundColor Yellow
    Write-Host "  另外无论哪种方式，本机都需要安装 QQ（NT 版）客户端供机器人登录使用。" -ForegroundColor Yellow
    Write-Host "  放好后重新运行本配置即可继续。" -ForegroundColor Yellow
}

$classesDir = Join-Path $Root "tmp\java-classes"
New-Item -ItemType Directory -Force $classesDir | Out-Null
try {
    & javac -encoding UTF-8 -d $classesDir (Join-Path $Root "tools\QQConsoleBridge.java") | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "[检查] QQConsoleBridge.java 编译通过。" -ForegroundColor Green }
    else { Write-Host "[检查] QQConsoleBridge.java 编译失败，请确认已安装 JDK 17。" -ForegroundColor Yellow }
} catch {
    Write-Host "[检查] 未找到 javac；启动运维监控时会再次尝试编译。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "建议流程" -ForegroundColor Cyan
Write-Host "  1. 运行：一键脚本\一键便携-启动QQ机器人.bat（首次会弹二维码，用机器人 QQ 扫码登录）"
Write-Host "  2. LLBot WebUI 是 http://127.0.0.1:3080/ 或 http://127.0.0.1:3081/；确认 OneBot HTTP=3001、WebSocket=3002。群主自动有反控权，其他管理员请填入 adminIds。"
Write-Host "  3. 运行：一键脚本\一键便携-测试QQ机器人.bat"
Write-Host "  4. 运行：一键脚本\一键便携-启动所有运维.bat（或面板「重启运维监控」）"

Wait-Exit 0


