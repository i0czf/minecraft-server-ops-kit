param(
    [ValidateSet('1h', '6h', '24h', '1d', '7d')][string]$Window = '6h',
    [int]$MaxEvents = 80,
    [double]$MsptAlert = 50,
    [switch]$QqSummary,
    [switch]$Quiet,
    [switch]$Json,
    [string]$OutDir = ''
)

# 运维时间机：只读聚合启停/审计/指纹/卡顿/备份/崩溃等，输出时间线。
# 不改配置、不停服。QQ: !时间线 [1h|6h|24h|7d]

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $Root ('tmp\ops-timeline\' + $Stamp)
}
$LatestDir = Join-Path $Root 'tmp\ops-timeline\latest'

function Parse-Window([string]$W) {
    switch ($W.ToLowerInvariant()) {
        '1h' { return [TimeSpan]::FromHours(1) }
        '6h' { return [TimeSpan]::FromHours(6) }
        '24h' { return [TimeSpan]::FromHours(24) }
        '1d' { return [TimeSpan]::FromHours(24) }
        '7d' { return [TimeSpan]::FromDays(7) }
        default { return [TimeSpan]::FromHours(6) }
    }
}

function Window-Label([string]$W) {
    switch ($W.ToLowerInvariant()) {
        '1h' { return '最近 1 小时' }
        '6h' { return '最近 6 小时' }
        '24h' { return '最近 24 小时' }
        '1d' { return '最近 24 小时' }
        '7d' { return '最近 7 天' }
        default { return ('窗口 ' + $W) }
    }
}

function Add-Event {
    param(
        [System.Collections.Generic.List[object]]$List,
        [datetime]$Ts,
        [string]$Kind,
        [string]$Title,
        [string]$Detail = ''
    )
    if ($null -eq $Ts) { return }
    $List.Add([pscustomobject]@{
            ts     = $Ts
            kind   = $Kind
            title  = $Title
            detail = $Detail
        }) | Out-Null
}

function Try-ParseTs([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    try { return [datetime]::Parse($s) } catch { return $null }
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KiB' -f ($Bytes / 1KB))
}

function Kind-Cn([string]$K) {
    switch ($K) {
        'wrapper' { return '启停' }
        'audit' { return '审计' }
        'fingerprint' { return '指纹' }
        'lag' { return '卡顿' }
        'perf' { return '性能' }
        'backup' { return '备份' }
        'backup_verify' { return '验备份' }
        'crash' { return '崩溃' }
        'joinquit' { return '进出' }
        default { return $K }
    }
}

$span = Parse-Window $Window
$since = (Get-Date) - $span
$label = Window-Label $Window
$events = New-Object System.Collections.Generic.List[object]
$counts = [ordered]@{}

function Inc([string]$k) {
    if (-not $counts.Contains($k)) { $counts[$k] = 0 }
    $counts[$k] = [int]$counts[$k] + 1
}

# --- server-wrapper.log ---
$wrapperPath = Join-Path $Root 'logs\server-wrapper.log'
if (Test-Path -LiteralPath $wrapperPath) {
    try {
        foreach ($line in [System.IO.File]::ReadLines($wrapperPath)) {
            $ts = $null
            if ($line -match '\[(\d{4}/\d{2}/\d{2}).*?(\d{2}:\d{2}:\d{2})') {
                try {
                    $ts = [datetime]::ParseExact(($matches[1] + ' ' + $matches[2]), 'yyyy/MM/dd HH:mm:ss', $null)
                } catch { continue }
            } else { continue }
            if ($ts -lt $since) { continue }
            if ($line -match 'PortableKit server starting|TFCR server starting') {
                Add-Event $events $ts 'wrapper' '服务端启动' $line.Trim()
                Inc 'wrapper'
            } elseif ($line -match 'Restarting in') {
                Add-Event $events $ts 'wrapper' '计划重启' $line.Trim()
                Inc 'wrapper'
            } elseif ($line -match 'Java exited with code\s*(-?\d+)') {
                Add-Event $events $ts 'wrapper' ('Java 退出 code=' + $matches[1]) $line.Trim()
                Inc 'wrapper'
            } elseif ($line -match 'session\.lock|world lock|世界锁') {
                Add-Event $events $ts 'wrapper' '世界锁相关' $line.Trim()
                Inc 'wrapper'
            }
        }
    } catch { }
}

# --- ops-audit.jsonl ---
$auditPath = Join-Path $Root 'logs\ops-audit.jsonl'
if (Test-Path -LiteralPath $auditPath) {
    try {
        foreach ($line in [System.IO.File]::ReadLines($auditPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $o = $line | ConvertFrom-Json
                $ts = Try-ParseTs ([string]$o.ts)
                if ($null -eq $ts -or $ts -lt $since) { continue }
                $action = [string]$o.action
                $actor = [string]$o.actor
                if ([string]::IsNullOrWhiteSpace($actor)) { $actor = [string]$o.actorId }
                $detail = [string]$o.detail
                $title = switch ($action) {
                    'stop' { '停服/重启指令' }
                    'risk_request' { '高危请求' }
                    'risk_confirm' { '高危已确认' }
                    'risk_cancel' { '高危已取消' }
                    'rcon' { 'RCON' }
                    'set_server_property' { '改 server.properties' }
                    default { '审计:' + $action }
                }
                $more = ('操作者={0}' -f $actor)
                if (-not [string]::IsNullOrWhiteSpace($detail)) {
                    $d = $detail
                    if ($d.Length -gt 120) { $d = $d.Substring(0, 120) + '...' }
                    $more = $more + ' · ' + $d
                }
                if ($o.result) { $more = $more + ' · 结果=' + $o.result }
                Add-Event $events $ts 'audit' $title $more
                Inc 'audit'
            } catch { }
        }
    } catch { }
}

# --- error-fingerprints.jsonl ---
$fpPath = Join-Path $Root 'logs\error-fingerprints.jsonl'
if (Test-Path -LiteralPath $fpPath) {
    try {
        foreach ($line in [System.IO.File]::ReadLines($fpPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $o = $line | ConvertFrom-Json
                $ts = Try-ParseTs ([string]$o.ts)
                if ($null -eq $ts -or $ts -lt $since) { continue }
                $act = [string]$o.action
                if ($act -notin @('first', 'alert')) { continue }
                $fp = [string]$o.fp
                if ($fp.Length -gt 100) { $fp = $fp.Substring(0, 100) + '...' }
                $title = if ($act -eq 'first') { '新指纹告警' } else { '重复指纹告警' }
                Add-Event $events $ts 'fingerprint' $title $fp
                Inc 'fingerprint'
            } catch { }
        }
    } catch { }
}

# --- perf samples: lag streaks (mspt >= threshold) ---
$perfPath = Join-Path $Root 'logs\perf\samples.jsonl'
$lagSampleCount = 0
$worstMspt = $null
if (Test-Path -LiteralPath $perfPath) {
    try {
        $streakStart = $null
        $streakMax = 0.0
        $streakN = 0
        foreach ($line in [System.IO.File]::ReadLines($perfPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $o = $line | ConvertFrom-Json
                $ts = Try-ParseTs ([string]$o.ts)
                if ($null -eq $ts -or $ts -lt $since) { continue }
                if ($null -eq $o.mspt) { continue }
                $mspt = [double]$o.mspt
                if ($null -eq $worstMspt -or $mspt -gt $worstMspt) { $worstMspt = $mspt }
                if ($mspt -ge $MsptAlert) {
                    $lagSampleCount++
                    if ($null -eq $streakStart) { $streakStart = $ts; $streakMax = $mspt; $streakN = 1 }
                    else {
                        $streakN++
                        if ($mspt -gt $streakMax) { $streakMax = $mspt }
                    }
                } else {
                    if ($null -ne $streakStart -and $streakN -ge 2) {
                        Add-Event $events $streakStart 'perf' ('MSPT 连续偏高 x' + $streakN) (
                            ('峰值 MSPT={0:N1}（阈 {1}）' -f $streakMax, $MsptAlert)
                        )
                        Inc 'perf'
                    }
                    $streakStart = $null; $streakN = 0; $streakMax = 0
                }
            } catch { }
        }
        if ($null -ne $streakStart -and $streakN -ge 2) {
            Add-Event $events $streakStart 'perf' ('MSPT 连续偏高 x' + $streakN) (
                ('峰值 MSPT={0:N1}' -f $streakMax)
            )
            Inc 'perf'
        }
    } catch { }
}

# --- lag-forensics packs (meta.json under stamp dirs) ---
$lagRoot = Join-Path $Root 'tmp\lag-forensics'
if (Test-Path -LiteralPath $lagRoot) {
    try {
        Get-ChildItem -LiteralPath $lagRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
            ForEach-Object {
                $metaPath = Join-Path $_.FullName 'meta.json'
                if (-not (Test-Path $metaPath)) { return }
                try {
                    $m = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $ts = Try-ParseTs ([string]$m.generatedAt)
                    if ($null -eq $ts) {
                        try { $ts = [datetime]::ParseExact($_.Name, 'yyyyMMdd-HHmmss', $null) } catch { $ts = $_.LastWriteTime }
                    }
                    if ($ts -lt $since) { return }
                    $title = '卡顿取证包'
                    $detail = ('目录 {0} · 触发MSPT={1} TPS={2} 在线={3}' -f $_.Name, $m.triggerMspt, $m.triggerTps, $m.triggerPlayers)
                    if ($m.sparkUrl) { $detail = $detail + ' · Spark有链接' }
                    if ($m.threadDumpOk) { $detail = $detail + ' · 有线程转储' }
                    Add-Event $events $ts 'lag' $title $detail
                    Inc 'lag'
                } catch { }
            }
    } catch { }
}

# --- backup-verify ---
$bvRoot = Join-Path $Root 'tmp\backup-verify'
if (Test-Path -LiteralPath $bvRoot) {
    try {
        Get-ChildItem -LiteralPath $bvRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{8}-\d{6}$' } |
            ForEach-Object {
                $metaPath = Join-Path $_.FullName 'meta.json'
                if (-not (Test-Path $metaPath)) { return }
                try {
                    $m = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $ts = Try-ParseTs ([string]$m.generated)
                    if ($null -eq $ts) {
                        try { $ts = [datetime]::ParseExact($_.Name, 'yyyyMMdd-HHmmss', $null) } catch { $ts = $_.LastWriteTime }
                    }
                    if ($ts -lt $since) { return }
                    $ok = [int]$m.ok; $bad = [int]$m.bad
                    $title = if ($bad -gt 0) { '备份验证失败' } else { '备份验证通过' }
                    Add-Event $events $ts 'backup_verify' $title ('通过 {0} · 失败 {1} · {2}' -f $ok, $bad, $_.Name)
                    Inc 'backup_verify'
                } catch { }
            }
    } catch { }
}

# --- backup zips in window ---
$backupDir = Join-Path $Root 'backups\world'
if (Test-Path -LiteralPath $backupDir) {
    try {
        Get-ChildItem -LiteralPath $backupDir -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since } |
            ForEach-Object {
                Add-Event $events $_.LastWriteTime 'backup' '世界备份完成' (
                    ('{0} · {1}' -f $_.Name, (Format-Bytes $_.Length))
                )
                Inc 'backup'
            }
    } catch { }
}

# --- crashes ---
$crashDir = Join-Path $Root 'crash-reports'
if (Test-Path -LiteralPath $crashDir) {
    try {
        Get-ChildItem -LiteralPath $crashDir -File -Filter 'crash-*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since } |
            ForEach-Object {
                Add-Event $events $_.LastWriteTime 'crash' '崩溃报告' $_.Name
                Inc 'crash'
            }
    } catch { }
}

# --- join/quit from latest.log (best effort, may include older if log not rotated) ---
$logPath = Join-Path $Root 'logs\latest.log'
if (Test-Path -LiteralPath $logPath) {
    try {
        $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            while (-not $sr.EndOfStream) {
                $line = $sr.ReadLine()
                # [06Aug2026 20:29:01.331] or similar — hard to parse all locales; use file write time fallback only for matches
                $ts = $null
                if ($line -match '\[(\d{2})([A-Za-z]{3})(\d{4})\s+(\d{2}:\d{2}:\d{2})') {
                    # skip complex month parse; use Now-window heuristic: only count, attach approximate if we can
                }
                if ($line -match 'joined the game') {
                    $name = ''
                    if ($line -match ':\s*([^\s\]]+)\s+joined the game') { $name = $matches[1] }
                    # Without reliable ts in all encodings, skip join/quit on timeline if no ts — try ISO-like
                    if ($line -match '(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})') {
                        $ts = Try-ParseTs $matches[1]
                    }
                    # MC format 06Aug2026 — approximate using last write if in window is too wrong; skip if no ts
                    if ($null -ne $ts -and $ts -ge $since) {
                        Add-Event $events $ts 'joinquit' ('玩家上线 ' + $name) ''
                        Inc 'joinquit'
                    }
                }
            }
        } finally { $fs.Dispose() }
    } catch { }
}

# sort
$sorted = @($events | Sort-Object { $_.ts })
$total = $sorted.Count
if ($MaxEvents -gt 0 -and $sorted.Count -gt $MaxEvents) {
    $sorted = @($sorted | Select-Object -Last $MaxEvents)
}

# build full report
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('【运维时间机】' + $label)
[void]$sb.AppendLine(('生成：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')))
[void]$sb.AppendLine(('事件合计 {0} 条（展示 {1} 条，上限 {2}）' -f $total, $sorted.Count, $MaxEvents))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('◆ 分类统计')
if ($counts.Count -eq 0) {
    [void]$sb.AppendLine('  （窗口内无事件）')
} else {
    foreach ($k in @($counts.Keys)) {
        [void]$sb.AppendLine(('  {0}：{1}' -f (Kind-Cn $k), $counts[$k]))
    }
}
if ($null -ne $worstMspt) {
    [void]$sb.AppendLine(('  黑匣子峰值 MSPT：{0:N1}' -f $worstMspt))
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('◆ 时间线（旧 → 新）')
if ($sorted.Count -eq 0) {
    [void]$sb.AppendLine('  （无）')
} else {
    foreach ($e in $sorted) {
        $t = $e.ts.ToString('MM-dd HH:mm:ss')
        $line = ('{0}  [{1}] {2}' -f $t, (Kind-Cn $e.kind), $e.title)
        [void]$sb.AppendLine($line)
        if (-not [string]::IsNullOrWhiteSpace($e.detail)) {
            $d = [string]$e.detail
            if ($d.Length -gt 160) { $d = $d.Substring(0, 160) + '...' }
            [void]$sb.AppendLine(('         {0}' -f $d))
        }
    }
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('提示：!体检 · !周报 · !验备份 · !性能 6h · 完整见 tmp\ops-timeline\')
$fullText = $sb.ToString().TrimEnd()

# QQ short: last 12 events + counts
$qq = New-Object System.Text.StringBuilder
[void]$qq.AppendLine('【时间线】' + $label)
$statParts = @()
foreach ($k in @('crash', 'wrapper', 'lag', 'fingerprint', 'audit', 'backup', 'backup_verify', 'perf')) {
    if ($counts.Contains($k) -and [int]$counts[$k] -gt 0) {
        $statParts += ('{0}{1}' -f (Kind-Cn $k), $counts[$k])
    }
}
if ($statParts.Count -eq 0) {
    [void]$qq.AppendLine('窗口内暂无关键运维事件')
} else {
    [void]$qq.AppendLine(('统计：' + ($statParts -join ' · ')))
}
$tail = @($sorted | Select-Object -Last 12)
if ($tail.Count -gt 0) {
    [void]$qq.AppendLine('最近：')
    foreach ($e in $tail) {
        $t = $e.ts.ToString('HH:mm')
        [void]$qq.AppendLine(('{0} [{1}] {2}' -f $t, (Kind-Cn $e.kind), $e.title))
    }
}
[void]$qq.AppendLine('详情 tmp\ops-timeline\ · !体检')
$qqText = $qq.ToString().TrimEnd()

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
New-Item -ItemType Directory -Path $LatestDir -Force | Out-Null
$enc = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText((Join-Path $OutDir 'timeline.txt'), $fullText, $enc)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'timeline-qq.txt'), $qqText, $enc)

$meta = [ordered]@{
    window     = $Window
    since      = $since.ToString('o')
    total      = $total
    shown      = $sorted.Count
    counts     = $counts
    worstMspt  = $worstMspt
    generated  = (Get-Date).ToString('o')
    outDir     = $OutDir
}
[System.IO.File]::WriteAllText(
    (Join-Path $OutDir 'timeline.json'),
    ($meta | ConvertTo-Json -Depth 6),
    (New-Object System.Text.UTF8Encoding $false)
)

# event list json for tooling
$evExport = @($sorted | ForEach-Object {
        [ordered]@{
            ts     = $_.ts.ToString('o')
            kind   = $_.kind
            title  = $_.title
            detail = $_.detail
        }
    })
[System.IO.File]::WriteAllText(
    (Join-Path $OutDir 'events.json'),
    ($evExport | ConvertTo-Json -Depth 5),
    (New-Object System.Text.UTF8Encoding $false)
)

Copy-Item (Join-Path $OutDir 'timeline.txt') (Join-Path $LatestDir 'timeline.txt') -Force
Copy-Item (Join-Path $OutDir 'timeline-qq.txt') (Join-Path $LatestDir 'timeline-qq.txt') -Force
Copy-Item (Join-Path $OutDir 'timeline.json') (Join-Path $LatestDir 'timeline.json') -Force
Copy-Item (Join-Path $OutDir 'events.json') (Join-Path $LatestDir 'events.json') -Force

if ($QqSummary) {
    Write-Output $qqText
} elseif (-not $Quiet) {
    Write-Host $fullText
    Write-Host ''
    Write-Host ('报告目录：' + $OutDir) -ForegroundColor Cyan
} else {
    Write-Output $fullText
}

if ($Json) {
    Write-Output ($meta | ConvertTo-Json -Compress)
}

exit 0