param(
    [ValidateSet('1d', '7d', '30d')][string]$Window = '7d',
    [switch]$QqSummary,
    [switch]$Quiet,
    [switch]$Json,
    [string]$OutDir = ''
)

# 每日/每周服务器报告：只读汇总黑匣子、备份、崩溃、指纹告警、审计与运行痕迹。
# 设计：不改配置、不停服；可被 discord-watch 定时调用，也可 QQ !周报 / 一键 bat。

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $Root ('tmp\weekly-report\' + $Stamp)
}

function Parse-Window([string]$W) {
    switch ($W.ToLowerInvariant()) {
        '1d' { return [TimeSpan]::FromDays(1) }
        '30d' { return [TimeSpan]::FromDays(30) }
        default { return [TimeSpan]::FromDays(7) }
    }
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KiB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Read-JsonlSince([string]$Path, [datetime]$Since) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $rows }
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $o = $line | ConvertFrom-Json
                $ts = $null
                if ($o.psobject.Properties['ts']) {
                    try { $ts = [datetime]::Parse([string]$o.ts) } catch { }
                }
                if ($null -eq $ts -or $ts -ge $Since) { $rows.Add($o) | Out-Null }
            } catch { }
        }
    } catch { }
    return $rows
}

function Avg($arr, $prop) {
    $vals = @($arr | ForEach-Object {
            if ($null -ne $_.$prop) { [double]$_.$prop }
        })
    if ($vals.Count -eq 0) { return $null }
    return [math]::Round((($vals | Measure-Object -Average).Average), 2)
}
function MaxV($arr, $prop) {
    $vals = @($arr | ForEach-Object {
            if ($null -ne $_.$prop) { [double]$_.$prop }
        })
    if ($vals.Count -eq 0) { return $null }
    return [math]::Round((($vals | Measure-Object -Maximum).Maximum), 2)
}
function MinV($arr, $prop) {
    $vals = @($arr | ForEach-Object {
            if ($null -ne $_.$prop) { [double]$_.$prop }
        })
    if ($vals.Count -eq 0) { return $null }
    return [math]::Round((($vals | Measure-Object -Minimum).Minimum), 2)
}

$span = Parse-Window $Window
$since = (Get-Date) - $span
$label = switch ($Window) {
    '1d' { '最近 24 小时' }
    '30d' { '最近 30 天' }
    default { '最近 7 天' }
}

# --- server name ---
$serverName = '服务器'
$serverAddress = ''
try {
    $ops = Get-Content -LiteralPath (Join-Path $Root 'tools\ops-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ops.serverName) { $serverName = [string]$ops.serverName }
    if ($ops.serverAddress) { $serverAddress = [string]$ops.serverAddress }
} catch { }

# --- perf samples ---
$perfPath = Join-Path $Root 'logs\perf\samples.jsonl'
$perfRows = @(Read-JsonlSince $perfPath $since)
$upRows = @($perfRows | Where-Object { $_.serverUp -eq $true -or $_.serverUp -eq 'True' })
$tpsRows = @($upRows | Where-Object { $null -ne $_.tps })
$msptRows = @($upRows | Where-Object { $null -ne $_.mspt })
$playerRows = @($upRows | Where-Object { $null -ne $_.players })
$lagRows = @($msptRows | Where-Object { [double]$_.mspt -ge 50 })

# --- error fingerprints ---
$fpPath = Join-Path $Root 'logs\error-fingerprints.jsonl'
$fpRows = @(Read-JsonlSince $fpPath $since)
$fpAlerts = @($fpRows | Where-Object { $_.action -in @('first', 'alert') })
$fpFirst = @($fpRows | Where-Object { $_.action -eq 'first' }).Count
$fpAlert = @($fpRows | Where-Object { $_.action -eq 'alert' }).Count

# --- audit ---
$auditPath = Join-Path $Root 'logs\ops-audit.jsonl'
$auditRows = @(Read-JsonlSince $auditPath $since)
$auditStop = @($auditRows | Where-Object { $_.action -eq 'stop' }).Count
$auditRisk = @($auditRows | Where-Object { $_.action -match 'risk_' }).Count
$auditRcon = @($auditRows | Where-Object { $_.action -eq 'rcon' }).Count

# --- crashes ---
$crashDir = Join-Path $Root 'crash-reports'
$crashes = @()
if (Test-Path -LiteralPath $crashDir) {
    $crashes = @(Get-ChildItem -LiteralPath $crashDir -File -Filter 'crash-*.txt' -EA SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since } |
            Sort-Object LastWriteTime -Descending)
}

# --- backups ---
$backupDir = Join-Path $Root 'backups\world'
$zips = @()
if (Test-Path -LiteralPath $backupDir) {
    $zips = @(Get-ChildItem -LiteralPath $backupDir -Recurse -File -Filter '*.zip' -EA SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
}
$zipsInWindow = @($zips | Where-Object { $_.LastWriteTime -ge $since })
$latestZip = $zips | Select-Object -First 1
$backupBytes = 0.0
foreach ($z in $zips) { $backupBytes += [double]$z.Length }

# --- restarts from wrapper ---
$wrapperPath = Join-Path $Root 'logs\server-wrapper.log'
$restartCount = 0
$startCount = 0
if (Test-Path -LiteralPath $wrapperPath) {
    try {
        foreach ($line in [System.IO.File]::ReadLines($wrapperPath)) {
            # wrapper lines like [2026/08/06 WRAP 20:27:00.83]
            if ($line -match '\[(\d{4}/\d{2}/\d{2}).*?(\d{2}:\d{2}:\d{2})') {
                try {
                    $ts = [datetime]::ParseExact(($matches[1] + ' ' + $matches[2]), 'yyyy/MM/dd HH:mm:ss', $null)
                    if ($ts -lt $since) { continue }
                } catch { continue }
            } else { continue }
            if ($line -match 'PortableKit server starting|TFCR server starting') { $startCount++ }
            if ($line -match 'Restarting in') { $restartCount++ }
            if ($line -match 'Java exited with code') { } # count via restart
        }
    } catch { }
}

# --- join/quit from latest.log (best effort, current session may dominate) ---
$joinCount = 0; $quitCount = 0; $keepUp = 0
$logPath = Join-Path $Root 'logs\latest.log'
if (Test-Path -LiteralPath $logPath) {
    try {
        $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            while (-not $sr.EndOfStream) {
                $line = $sr.ReadLine()
                if ($line -match 'joined the game') { $joinCount++ }
                if ($line -match 'left the game') { $quitCount++ }
                if ($line -match "Can'?t keep up") { $keepUp++ }
            }
        } finally { $fs.Dispose() }
    } catch { }
}

# --- disk ---
$diskFree = $null; $diskTotal = $null
try {
    $di = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Root))
    $diskFree = [double]$di.AvailableFreeSpace
    $diskTotal = [double]$di.TotalSize
} catch { }

# --- live ---
$livePlayers = '?'
$liveTps = $null; $liveMspt = $null
try {
    $rcon = Join-Path $Root 'tools\rcon-command.ps1'
    if (Test-Path $rcon) {
        $listOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rcon -Command 'list' 2>$null | Out-String
        if ($listOut -match '(?i)there are\s+(\d+)\s+of') {
            $livePlayers = $matches[1]
        } elseif ($listOut -match '(?i)(\d+)\s*(?:of|/)\s*\d+') {
            $livePlayers = $matches[1]
        } elseif ($listOut -match '当前有\s*(\d+)|在线[：:]\s*(\d+)|共\s*(\d+)\s*人') {
            $livePlayers = if ($matches[1]) { $matches[1] } elseif ($matches[2]) { $matches[2] } else { $matches[3] }
        }
        $tpsCmd = 'tps'
        if (Test-Path (Join-Path $Root 'libraries\net\neoforged\neoforge')) { $tpsCmd = 'neoforge tps' }
        elseif (Test-Path (Join-Path $Root 'libraries\net\minecraftforge\forge')) { $tpsCmd = 'forge tps' }
        $tpsOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rcon -Command $tpsCmd 2>$null | Out-String
        if ($tpsOut -match '([\d.]+)\s*TPS\s*\(([\d.]+)\s*ms/tick\)') {
            $liveTps = [double]$matches[1]; $liveMspt = [double]$matches[2]
        }
    }
} catch { }

# --- build report ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("【$serverName · 运行报告】$label")
if ($serverAddress) { [void]$sb.AppendLine("地址：$serverAddress") }
[void]$sb.AppendLine("生成：$(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$sb.AppendLine('')

[void]$sb.AppendLine('◆ 实时')
[void]$sb.AppendLine(("在线 {0} · TPS {1} · MSPT {2}" -f $livePlayers,
        $(if ($null -ne $liveTps) { $liveTps } else { '?' }),
        $(if ($null -ne $liveMspt) { $liveMspt } else { '?' })))
[void]$sb.AppendLine('')

[void]$sb.AppendLine('◆ 性能黑匣子')
if ($perfRows.Count -eq 0) {
    [void]$sb.AppendLine('（无样本：确认 perf-sampler 随运维在跑）')
} else {
    [void]$sb.AppendLine(("样本 {0} 条（在线片段 {1}）" -f $perfRows.Count, $upRows.Count))
    if ($tpsRows.Count -gt 0) {
        [void]$sb.AppendLine(("TPS  均 {0} / 最低 {1}" -f (Avg $tpsRows 'tps'), (MinV $tpsRows 'tps')))
    }
    if ($msptRows.Count -gt 0) {
        [void]$sb.AppendLine(("MSPT 均 {0} / 最高 {1}" -f (Avg $msptRows 'mspt'), (MaxV $msptRows 'mspt')))
    }
    if ($playerRows.Count -gt 0) {
        [void]$sb.AppendLine(("在线 均 {0} / 峰值 {1}" -f (Avg $playerRows 'players'), (MaxV $playerRows 'players')))
    }
    [void]$sb.AppendLine(("卡顿样本 MSPT≥50：{0} 次" -f $lagRows.Count))
}
[void]$sb.AppendLine('')

[void]$sb.AppendLine('◆ 启停与日志（本 latest.log 会话）')
[void]$sb.AppendLine(("包装器启动 {0} 次 · 计划重启标记 {1} 次" -f $startCount, $restartCount))
[void]$sb.AppendLine(("进服 {0} · 退服 {1} · Can't keep up {2}" -f $joinCount, $quitCount, $keepUp))
[void]$sb.AppendLine('')

[void]$sb.AppendLine('◆ 可靠性')
[void]$sb.AppendLine(("崩溃报告（窗口内）{0} 份" -f $crashes.Count))
if ($crashes.Count -gt 0) {
    [void]$sb.AppendLine(('  最近：' + $crashes[0].Name))
}
[void]$sb.AppendLine(("备份 窗口内新增 {0} 份 · 库内共 {1} 份 · {2}" -f $zipsInWindow.Count, $zips.Count, (Format-Bytes $backupBytes)))
if ($latestZip) {
    $ageH = [math]::Round(((Get-Date) - $latestZip.LastWriteTime).TotalHours, 1)
    [void]$sb.AppendLine(("  最近：{0}（{1} 小时前）" -f $latestZip.Name, $ageH))
}
[void]$sb.AppendLine(("指纹告警 新 {0} · 重复推送 {1}" -f $fpFirst, $fpAlert))
[void]$sb.AppendLine(("审计 停服 {0} · 高危请求/确认 {1} · 普通RCON {2}" -f $auditStop, $auditRisk, $auditRcon))
[void]$sb.AppendLine('')

[void]$sb.AppendLine('◆ 存储')
if ($null -ne $diskFree) {
    $pct = if ($diskTotal -gt 0) { [math]::Round(100.0 * $diskFree / $diskTotal, 1) } else { 0 }
    [void]$sb.AppendLine(("磁盘剩余 {0} / 共 {1}（{2}% 空闲）" -f (Format-Bytes $diskFree), (Format-Bytes $diskTotal), $pct))
} else {
    [void]$sb.AppendLine('磁盘：无法读取')
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('提示：!体检 看风险评分 · !性能 7d 看黑匣子 · 详细报告见 tmp\weekly-report\')

$fullText = $sb.ToString().TrimEnd()

# shorter QQ version (limit ~900 chars for comfort)
$qq = New-Object System.Text.StringBuilder
[void]$qq.AppendLine("【周报】$serverName · $label")
[void]$qq.AppendLine(("实时 在线{0} TPS{1} MSPT{2}" -f $livePlayers,
        $(if ($null -ne $liveTps) { $liveTps } else { '?' }),
        $(if ($null -ne $liveMspt) { $liveMspt } else { '?' })))
if ($tpsRows.Count -gt 0) {
    [void]$qq.AppendLine(("性能 样本{0} TPS均{1}低{2} 卡顿{3}" -f $perfRows.Count, (Avg $tpsRows 'tps'), (MinV $tpsRows 'tps'), $lagRows.Count))
} else {
    [void]$qq.AppendLine('性能 无黑匣子样本')
}
if ($playerRows.Count -gt 0) {
    [void]$qq.AppendLine(("在线 均{0} 峰{1}" -f (Avg $playerRows 'players'), (MaxV $playerRows 'players')))
}
[void]$qq.AppendLine(("启停 启动{0}/重启标{1} · 进{2}退{3}" -f $startCount, $restartCount, $joinCount, $quitCount))
[void]$qq.AppendLine(("可靠 崩{0} 备份+{1}/{2} 指纹告警{3}" -f $crashes.Count, $zipsInWindow.Count, $zips.Count, ($fpFirst + $fpAlert)))
if ($null -ne $diskFree) {
    [void]$qq.AppendLine(('磁盘 剩 ' + (Format-Bytes $diskFree)))
}
[void]$qq.AppendLine('详情 !体检 · 完整报告 tmp\weekly-report\')
$qqText = $qq.ToString().TrimEnd()

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$reportPath = Join-Path $OutDir 'weekly-report.txt'
$qqPath = Join-Path $OutDir 'weekly-qq.txt'
$jsonPath = Join-Path $OutDir 'weekly-report.json'
[System.IO.File]::WriteAllText($reportPath, $fullText, (New-Object System.Text.UTF8Encoding $true))
[System.IO.File]::WriteAllText($qqPath, $qqText, (New-Object System.Text.UTF8Encoding $true))

$meta = [ordered]@{
    window       = $Window
    since        = $since.ToString('o')
    serverName   = $serverName
    perfSamples  = $perfRows.Count
    lagSamples   = $lagRows.Count
    crashes      = $crashes.Count
    backupsNew   = $zipsInWindow.Count
    backupsTotal = $zips.Count
    fpFirst      = $fpFirst
    fpAlert      = $fpAlert
    restarts     = $restartCount
    starts       = $startCount
    joinCount    = $joinCount
    quitCount    = $quitCount
    keepUp       = $keepUp
    livePlayers  = $livePlayers
    liveTps      = $liveTps
    liveMspt     = $liveMspt
    generatedAt  = (Get-Date).ToString('o')
    reportPath   = $reportPath
}
[System.IO.File]::WriteAllText($jsonPath, ($meta | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false))

# also drop a stable "latest" copy for bots
$latestDir = Join-Path $Root 'tmp\weekly-report\latest'
New-Item -ItemType Directory -Path $latestDir -Force | Out-Null
Copy-Item -LiteralPath $reportPath -Destination (Join-Path $latestDir 'weekly-report.txt') -Force
Copy-Item -LiteralPath $qqPath -Destination (Join-Path $latestDir 'weekly-qq.txt') -Force
Copy-Item -LiteralPath $jsonPath -Destination (Join-Path $latestDir 'weekly-report.json') -Force

if ($QqSummary) {
    Write-Output $qqText
} elseif (-not $Quiet) {
    Write-Host $fullText
    Write-Host ''
    Write-Host ("报告目录：{0}" -f $OutDir) -ForegroundColor Cyan
} else {
    Write-Output $fullText
}

if ($Json) {
    Write-Output ($meta | ConvertTo-Json -Compress)
}

exit 0
