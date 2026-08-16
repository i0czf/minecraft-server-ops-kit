param(
    [string]$Provider = "",
    [switch]$List,
    [switch]$NoRestart,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '切换 QQ AI 后端' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
$ConfigPath = Join-Path $Root "tools\ops-config.json"

function Wait-Exit([int]$Code) {
    if (-not $NoPause) { Read-Host "按回车键关闭窗口" | Out-Null }
    exit $Code
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Host "未找到 tools\ops-config.json。" -ForegroundColor Red
    Wait-Exit 1
}

$raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
try {
    $config = $raw | ConvertFrom-Json
} catch {
    Write-Host "ops-config.json 不是有效 JSON：$($_.Exception.Message)" -ForegroundColor Red
    Wait-Exit 1
}

if (-not $config.ai -or -not $config.ai.providers) {
    Write-Host "配置中没有 ai.providers，无法切换。" -ForegroundColor Red
    Wait-Exit 1
}

$providerNames = @($config.ai.providers.PSObject.Properties |
    Where-Object { $_.Name -notmatch '^_' } |
    ForEach-Object { [string]$_.Name })

if ($List) {
    Write-Host "可用 AI 后端：" -ForegroundColor Cyan
    foreach ($name in $providerNames) {
        $p = $config.ai.providers.$name
        $mode = if ($p.mode) { [string]$p.mode } else { 'http' }
        $model = if ($p.model) { [string]$p.model } else { '(未填写模型)' }
        $mark = if ([string]$name -ieq [string]$config.ai.provider) { '*' } else { ' ' }
        Write-Host (" {0} {1,-14} [{2}] {3}" -f $mark, $name, $mode, $model)
    }
    Write-Host "带 * 的是当前后端。"
    Wait-Exit 0
}

if ([string]::IsNullOrWhiteSpace($Provider)) {
    Write-Host "可用 AI 后端：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $providerNames.Count; $i++) {
        $name = $providerNames[$i]
        $p = $config.ai.providers.$name
        $mode = if ($p.mode) { [string]$p.mode } else { 'http' }
        $model = if ($p.model) { [string]$p.model } else { '(未填写模型)' }
        Write-Host (" {0}. {1} [{2}] {3}" -f ($i + 1), $name, $mode, $model)
    }
    $choice = Read-Host "输入名称或序号"
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $providerNames.Count) {
        $Provider = $providerNames[[int]$choice - 1]
    } else {
        $Provider = $choice.Trim()
    }
}

$selected = $providerNames | Where-Object { $_ -ieq $Provider } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($selected)) {
    Write-Host "未找到后端 '$Provider'。可用名称：$($providerNames -join ', ')" -ForegroundColor Red
    Wait-Exit 1
}

$match = [regex]::Match($raw, '(?s)("ai"\s*:\s*\{.*?"provider"\s*:\s*")([^"]*)(")')
if (-not $match.Success) {
    Write-Host "未能定位 ai.provider 字段，未修改文件。" -ForegroundColor Red
    Wait-Exit 1
}

$oldProvider = $match.Groups[2].Value
if ($oldProvider -ieq $selected) {
    Write-Host "当前已经是 $selected，无需切换。" -ForegroundColor Yellow
    if (-not $NoRestart) { Write-Host "如需强制刷新，请加 -NoRestart 后手动运行一键便携-启动所有运维.bat。" }
    Wait-Exit 0
}

$backupDir = Join-Path (Join-Path $Root "backups") ("qq-ai-switch-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupDir "ops-config.json") -Force

$newRaw = $raw.Substring(0, $match.Groups[2].Index) + $selected +
    $raw.Substring($match.Groups[2].Index + $match.Groups[2].Length)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ConfigPath, $newRaw, $utf8NoBom)

try {
    $verify = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$verify.ai.provider -ine $selected) { throw "写入后的 provider 校验不一致" }
} catch {
    Copy-Item -LiteralPath (Join-Path $backupDir "ops-config.json") -Destination $ConfigPath -Force
    Write-Host "切换校验失败，已从备份恢复：$($_.Exception.Message)" -ForegroundColor Red
    Wait-Exit 1
}

Write-Host "AI 后端已切换：$oldProvider -> $selected" -ForegroundColor Green
Write-Host "备份：$backupDir\ops-config.json" -ForegroundColor Gray

if (-not $NoRestart) {
    $monitor = Join-Path $Root "tools\start-ops-monitor.ps1"
    if (Test-Path -LiteralPath $monitor -PathType Leaf) {
        Write-Host "正在刷新 QQ/Discord 运维桥（不会重启 Minecraft 服务端）..." -ForegroundColor Cyan
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $monitor -Restart -NoPause
        if ($LASTEXITCODE -ne 0) {
            Write-Host "运维桥刷新返回错误码 $LASTEXITCODE；请查看 logs\qq-console.log。" -ForegroundColor Yellow
            Wait-Exit 1
        }
    } else {
        Write-Host "未找到 start-ops-monitor.ps1，请手动运行一键便携-启动所有运维.bat 刷新。" -ForegroundColor Yellow
    }
}

Wait-Exit 0
