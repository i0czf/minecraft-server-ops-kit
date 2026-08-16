param(
    [string]$OnebotUrl = "",
    [string]$GroupId = "",
    [switch]$SendMessage,
    [switch]$NoBanner,
    [switch]$NoPause
)

$ErrorActionPreference = "Continue"
try { $Host.UI.RawUI.WindowTitle = '测试 QQ 机器人' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $Root "tools\ops-config.json"

function Wait-Exit([int]$Code) {
    if (-not $NoPause) { pause }
    exit $Code
}
function Format-Reason($ErrorRecord) {
    $msg = [string]$ErrorRecord.Exception.Message
    if ($msg -match 'Unable to connect|无法连接|连接.*失败|No connection could be made|actively refused|Connection refused') {
        return '无法连接 OneBot。请先启动 QQ 机器人，并确认 HTTP 端口为 127.0.0.1:3001。'
    }
    if ($msg -match 'timed out|超时') { return '连接 OneBot 超时，请确认机器人已经登录且端口未被防火墙拦截。' }
    if ([string]::IsNullOrWhiteSpace($msg)) { return '未知错误。' }
    return $msg
}
function Test-Step([string]$Name, [scriptblock]$Body) {
    Write-Host -NoNewline ("[测试] {0} ... " -f $Name)
    try {
        $ok = & $Body
        if ($ok) { Write-Host "通过" -ForegroundColor Green; return $true }
        Write-Host "未通过" -ForegroundColor Red
        return $false
    } catch {
        Write-Host ("未通过：{0}" -f (Format-Reason $_)) -ForegroundColor Red
        return $false
    }
}

function Get-QQGroupIds {
    param($Raw)
    $result = @()
    foreach ($value in @($Raw)) {
        if ($null -eq $value) { continue }
        foreach ($part in ([string]$value -split '[\s,;，；]+')) {
            $clean = $part.Trim()
            if ($clean -match '^\d{5,15}$' -and -not ($result -contains $clean)) {
                $result += $clean
            }
        }
    }
    return $result
}

if (-not $NoBanner) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  测试 QQ 群机器人" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Host "[错误] 未找到 tools\ops-config.json，请先运行“一键便携-配置QQ机器人.bat”。" -ForegroundColor Red
    Wait-Exit 1
}
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $OnebotUrl) { $OnebotUrl = [string]$config.qq.onebotUrl }
if (-not $OnebotUrl) { $OnebotUrl = "http://127.0.0.1:3001" }
$OnebotUrl = $OnebotUrl.TrimEnd('/')
if (-not $GroupId) { $GroupId = [string]$config.qq.groupId }
$groupIds = @(Get-QQGroupIds -Raw $GroupId)

$passed = 0; $total = 0
$total++; if (Test-Step 'QQ 桥接已启用' { $config.qq.enabled -eq $true }) { $passed++ }
$total++; if (Test-Step 'QQ 群号已填写' { -not [string]::IsNullOrWhiteSpace($GroupId) }) { $passed++ }
$total++; if (Test-Step '管理员 QQ 已填写' { -not [string]::IsNullOrWhiteSpace([string]$config.qq.adminIds) }) { $passed++ }

$login = $null
$total++; if (Test-Step "连接 OneBot：$OnebotUrl" {
    $script:login = Invoke-RestMethod -Uri "$OnebotUrl/get_login_info" -Method Post -Body "{}" -ContentType "application/json" -TimeoutSec 5
    $script:login.status -eq 'ok' -or $script:login.data.user_id
}) { $passed++ }
if ($login) { Write-Host "[信息] 机器人账号：$($login.data.user_id)" -ForegroundColor Gray }

if ($GroupId) {
    $total++; if (Test-Step "机器人已加入目标群：$GroupId" {
        $groups = Invoke-RestMethod -Uri "$OnebotUrl/get_group_list" -Method Post -Body "{}" -ContentType "application/json" -TimeoutSec 5
        $present = @($groups.data | ForEach-Object { [string]$_.group_id })
        @($groupIds | Where-Object { $present -notcontains [string]$_ }).Count -eq 0
    }) { $passed++ }

    if ($SendMessage) {
        $total++; if (Test-Step '发送群测试消息' {
            $okCount = 0
            foreach ($targetGroup in $groupIds) {
                $body = @{ group_id = [Int64]$targetGroup; message = '[QQ 桥接测试] 如果你看到这条消息，说明 OneBot 群消息发送正常。' } | ConvertTo-Json -Compress
                $r = Invoke-RestMethod -Uri "$OnebotUrl/send_group_msg" -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 5
                if ($r.status -eq 'ok' -or $r.retcode -eq 0) { $okCount++ }
            }
            $okCount -eq $groupIds.Count
        }) { $passed++ }
    }
}

$total++; if (Test-Step 'QQ 控制桥可编译' {
    $classesDir = Join-Path $Root "tmp\java-classes"
    New-Item -ItemType Directory -Force $classesDir | Out-Null
    & javac -encoding UTF-8 -d $classesDir (Join-Path $Root "tools\QQConsoleBridge.java") 2>$null
    $LASTEXITCODE -eq 0
}) { $passed++ }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  测试结果：{0} / {1} 项通过" -f $passed, $total) -ForegroundColor $(if ($passed -eq $total) { 'Green' } else { 'Yellow' })
Write-Host "========================================" -ForegroundColor Cyan
if ($passed -ne $total) {
    Write-Host "提示：截图里的 OneBot 连接失败通常表示 QQ 机器人运行时还没启动，或 HTTP 端口不是 3001。" -ForegroundColor Yellow
}

if ($passed -eq $total) { Wait-Exit 0 } else { Wait-Exit 1 }


