param(
    [ValidateSet('1h', '6h', '24h', '1d', '7d')][string]$Window = '24h',
    [int]$MaxIncidents = 12,
    [switch]$QqSummary,
    [switch]$Quiet,
    [switch]$Json,
    [string]$OutDir = ''
)

# 事故自动复盘：只读关联已有证据，不停服、不回滚、不改配置。
# 输入：运维时间线、性能黑匣子、卡顿取证、错误指纹、高危审计、崩溃报告、备份验证。
# 输出：report.md（完整复盘）、summary-qq.txt（群摘要）、meta.json（结构化结果）。

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $Root ('tmp\incident-postmortem\' + $Stamp)
}
$LatestDir = Join-Path $Root 'tmp\incident-postmortem\latest'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Get-WindowSpan([string]$W) {
    switch ($W.ToLowerInvariant()) {
        '1h' { return [TimeSpan]::FromHours(1) }
        '6h' { return [TimeSpan]::FromHours(6) }
        '7d' { return [TimeSpan]::FromDays(7) }
        '1d' { return [TimeSpan]::FromDays(1) }
        default { return [TimeSpan]::FromHours(24) }
    }
}

function Get-WindowLabel([string]$W) {
    switch ($W.ToLowerInvariant()) {
        '1h' { return '最近 1 小时' }
        '6h' { return '最近 6 小时' }
        '7d' { return '最近 7 天' }
        '1d' { return '最近 24 小时' }
        default { return '最近 24 小时' }
    }
}

function Try-Date([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [datetime]::Parse([string]$Value) } catch { return $null }
}

function Get-RowDate([object]$Row) {
    foreach ($name in @('ts', 'timestamp', 'time', 'generatedAt', 'createdAt')) {
        if ($Row -and $Row.psobject.Properties[$name]) {
            $value = Try-Date $Row.$name
            if ($null -ne $value) { return $value }
        }
    }
    return $null
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Read-JsonlSince([string]$Path, [datetime]$Since) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $rows }
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $row = $line | ConvertFrom-Json
                $ts = Get-RowDate $row
                if ($null -eq $ts -or $ts -ge $Since) { $rows.Add($row) | Out-Null }
            } catch { }
        }
    } catch { }
    return $rows
}

function Sanitize([string]$Text) {
    if ($null -eq $Text) { return '' }
    $s = $Text
    $s = $s -replace [regex]::Escape($Root), '<server-root>'
    $s = $s -replace '(?i)(token|password|api[_-]?key|webhook)(\s*[:=]\s*)[^\s,;]+', '$1$2<redacted>'
    $s = $s -replace '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?(?!\d)', '<ip>'
    if ($s.Length -gt 320) { $s = $s.Substring(0, 320) + '…' }
    return $s
}

function Format-MdText([string]$Text) {
    return (Sanitize $Text).Replace('|', '\|').Replace("`r", '').Replace("`n", ' ')
}

function Format-Count([int]$Value, [string]$Unit) {
    return ('{0}{1}' -f $Value, $Unit)
}

function Read-LogTail([string]$Path, [int]$Tail = 12000) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try { return @(Get-Content -LiteralPath $Path -Tail $Tail -Encoding UTF8 -ErrorAction Stop) } catch { return @() }
}

function Add-Incident {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Type,
        [string]$Severity,
        [string]$Title,
        [datetime]$StartedAt,
        [datetime]$EndedAt,
        [string]$Confidence,
        [string[]]$Evidence,
        [string[]]$Actions
    )
    $List.Add([pscustomobject][ordered]@{
            id         = ('INC-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ($List.Count + 1).ToString('00'))
            type       = $Type
            severity   = $Severity
            title      = $Title
            startedAt  = if ($null -ne $StartedAt) { $StartedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            endedAt    = if ($null -ne $EndedAt) { $EndedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            confidence = $Confidence
            evidence   = @($Evidence | ForEach-Object { Sanitize $_ })
            actions    = @($Actions)
        }) | Out-Null
}

function Get-Relative([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
    }
    return (Sanitize $Path)
}

$span = Get-WindowSpan $Window
$since = (Get-Date) - $span
$label = Get-WindowLabel $Window
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# 优先读取已有时间线；没有时自动生成一次，保持一键入口可用。
$timelineEventsPath = Join-Path $Root 'tmp\ops-timeline\latest\events.json'
if (-not (Test-Path -LiteralPath $timelineEventsPath -PathType Leaf)) {
    $freshTimeline = Join-Path $OutDir 'timeline'
    New-Item -ItemType Directory -Path $freshTimeline -Force | Out-Null
    $timelineScript = Join-Path $PSScriptRoot 'ops-timeline.ps1'
    if (Test-Path -LiteralPath $timelineScript -PathType Leaf) {
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $timelineScript -Window $Window -OutDir $freshTimeline -Quiet *> (Join-Path $OutDir 'timeline-run.log')
            if (Test-Path -LiteralPath (Join-Path $freshTimeline 'events.json') -PathType Leaf) {
                $timelineEventsPath = Join-Path $freshTimeline 'events.json'
            }
        } catch { }
    }
}

$timelineRows = @()
$timelineRaw = Read-JsonFile $timelineEventsPath
if ($timelineRaw) { $timelineRows = @($timelineRaw | Where-Object { $d = Get-RowDate $_; $null -eq $d -or $d -ge $since }) }
$perfRows = @(Read-JsonlSince (Join-Path $Root 'logs\perf\samples.jsonl') $since)
$auditRows = @(Read-JsonlSince (Join-Path $Root 'logs\ops-audit.jsonl') $since)
$fingerprintRows = @(Read-JsonlSince (Join-Path $Root 'logs\error-fingerprints.jsonl') $since)
$lagRows = @($timelineRows | Where-Object { $_.kind -eq 'lag' })
$wrapperRows = @($timelineRows | Where-Object { $_.kind -eq 'wrapper' })
$backupRows = @($timelineRows | Where-Object { $_.kind -eq 'backup' })
$verifyRows = @($timelineRows | Where-Object { $_.kind -eq 'backup_verify' })
$fingerprintEvents = @($timelineRows | Where-Object { $_.kind -eq 'fingerprint' })
$auditEvents = @($timelineRows | Where-Object { $_.kind -eq 'audit' })

$crashFiles = @()
$crashDir = Join-Path $Root 'crash-reports'
if (Test-Path -LiteralPath $crashDir -PathType Container) {
    $crashFiles = @(Get-ChildItem -LiteralPath $crashDir -Filter 'crash-*.txt' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime)
}

$lagMeta = @()
$lagRoot = Join-Path $Root 'tmp\lag-forensics'
if (Test-Path -LiteralPath $lagRoot -PathType Container) {
    foreach ($metaFile in @(Get-ChildItem -LiteralPath $lagRoot -Recurse -Filter 'meta.json' -File -ErrorAction SilentlyContinue)) {
        $meta = Read-JsonFile $metaFile.FullName
        $d = if ($meta) { Get-RowDate $meta } else { $null }
        if ($null -eq $d) { $d = $metaFile.LastWriteTime }
        if ($d -ge $since -and $d -le (Get-Date).AddMinutes(2)) { $lagMeta += $meta }
    }
}
$lagMeta = @($lagMeta | Group-Object { [string]$_.stamp } | ForEach-Object { $_.Group | Select-Object -First 1 })

$verifyFailures = @($verifyRows | Where-Object {
        [string]$_.detail -match '失败\s*[1-9]\d*|fail(?:ed|ures?)?\s*[:=]?\s*[1-9]\d*'
    })
$badExits = @($wrapperRows | Where-Object {
        ([string]$_.title -match '退出') -and ([string]$_.title -match 'code\s*=\s*[1-9]|code\s+[1-9]' -or [string]$_.detail -match 'code\s+[1-9]')
    })
$plannedRestarts = @($wrapperRows | Where-Object { [string]$_.title -match '计划重启|Restarting' })
$starts = @($wrapperRows | Where-Object { [string]$_.title -match '服务端启动|starting' })

$peakMspt = $null
$peakRow = $null
foreach ($row in $perfRows) {
    $value = $null
    foreach ($name in @('mspt', 'MSPT', 'msptAvg', 'tickMspt')) {
        if ($row.psobject.Properties[$name]) { try { $value = [double]$row.$name } catch { } ; if ($null -ne $value) { break } }
    }
    if ($null -ne $value -and ($null -eq $peakMspt -or $value -gt $peakMspt)) { $peakMspt = $value; $peakRow = $row }
}

$incidents = New-Object System.Collections.Generic.List[object]
if ($crashFiles.Count -gt 0) {
    $firstCrash = $crashFiles[0].LastWriteTime
    $lastCrash = $crashFiles[$crashFiles.Count - 1].LastWriteTime
    $excerpt = @()
    try { $excerpt = @(Get-Content -LiteralPath $crashFiles[0].FullName -TotalCount 18 -Encoding UTF8 -ErrorAction Stop) } catch { }
    Add-Incident $incidents 'crash' '高' ('窗口内发现 {0} 份崩溃报告' -f $crashFiles.Count) $firstCrash $lastCrash '强' `
        (@('崩溃文件：' + (Get-Relative $crashFiles[0].FullName)) + @($excerpt | Select-Object -First 5)) `
        @('保留崩溃报告与最近一份可读备份。', '对照崩溃前后错误指纹和最近一次模组/配置变更。', '必要时先跑影子服试车间，再考虑回滚；本工具不自动执行回滚。')
}
if ($badExits.Count -gt 0) {
    $badFirst = Get-RowDate $badExits[0]
    $badLast = Get-RowDate $badExits[$badExits.Count - 1]
    Add-Incident $incidents 'unexpected_exit' '高' ('发现 {0} 次非零退出' -f $badExits.Count) $badFirst $badLast '强' `
        (@($badExits | Select-Object -First 4 | ForEach-Object { [string]$_.detail })) `
        @('检查 wrapper 与 latest.log 的同一时间段，确认是 JVM、模组还是外部杀进程。', '确认最近备份可读；若世界状态可疑，先做恢复冒烟。')
}
if ($lagRows.Count -gt 0 -or $lagMeta.Count -gt 0) {
    $lagFirst = if ($lagRows.Count -gt 0) { Get-RowDate $lagRows[0] } else { $null }
    $lagLast = if ($lagRows.Count -gt 0) { Get-RowDate $lagRows[$lagRows.Count - 1] } else { $null }
    $lagEvidence = @('时间线卡顿取证包：' + $lagRows.Count + ' 个', '卡顿 meta：' + $lagMeta.Count + ' 个')
    foreach ($m in @($lagMeta | Select-Object -First 3)) {
        $lagEvidence += ('触发 MSPT={0} TPS={1} 在线={2} 线程转储={3} Spark={4}' -f $m.triggerMspt, $m.triggerTps, $m.triggerPlayers, $m.threadDumpOk, $m.sparkOk)
    }
    Add-Incident $incidents 'lag' '中' ('发现 {0} 个卡顿取证包' -f [Math]::Max($lagRows.Count, $lagMeta.Count)) $lagFirst $lagLast '中' $lagEvidence `
        @('先查看对应 tmp/lag-forensics/*/report.txt 与线程转储。', '对照性能黑匣子峰值和在线人数；确认持续复现后再做模组/区块/实体治理。')
}
if ($fingerprintEvents.Count -ge 3 -or $fingerprintRows.Count -ge 3) {
    $fpFirst = if ($fingerprintEvents.Count -gt 0) { Get-RowDate $fingerprintEvents[0] } else { $null }
    $fpLast = if ($fingerprintEvents.Count -gt 0) { Get-RowDate $fingerprintEvents[$fingerprintEvents.Count - 1] } else { $null }
    $groups = @($fingerprintEvents | ForEach-Object { Sanitize ([string]$_.detail) } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5)
    $fpEvidence = @('新指纹事件：' + $fingerprintEvents.Count, '指纹落盘记录：' + $fingerprintRows.Count)
    foreach ($g in $groups) { $fpEvidence += ('{0}× {1}' -f $g.Count, $g.Name) }
    Add-Incident $incidents 'fingerprint' '中' ('错误指纹集中出现（{0} 条新事件）' -f $fingerprintEvents.Count) $fpFirst $fpLast '中' $fpEvidence `
        @('先按重复次数和出现时间排序，不要把每条 ERROR 直接当成独立事故。', '对最高频指纹生成诊断包并结合启动时间、模组版本和配置变更判断根因。')
}
if ($verifyFailures.Count -gt 0) {
    Add-Incident $incidents 'backup_verify' '高' ('备份验证失败 {0} 次' -f $verifyFailures.Count) (Get-RowDate $verifyFailures[0]) (Get-RowDate $verifyFailures[$verifyFailures.Count - 1]) '强' `
        (@($verifyFailures | ForEach-Object { [string]$_.detail })) `
        @('暂停把未验证备份当作可恢复点，保留失败日志。', '手动指定一份历史备份做深度验证或恢复冒烟；不自动覆盖线上世界。')
}

$incidents = @($incidents | Select-Object -First ([Math]::Max(1, $MaxIncidents)))
$overall = 'green'
if (@($incidents | Where-Object { $_.severity -eq '高' }).Count -gt 0) { $overall = 'red' }
elseif (@($incidents | Where-Object { $_.severity -eq '中' }).Count -gt 0) { $overall = 'yellow' }

$summary = if ($overall -eq 'red') {
    '发现高风险证据，需要人工复核。'
} elseif ($overall -eq 'yellow') {
    '发现需要关注的异常证据，但未自动认定为确定根因。'
} else {
    '窗口内未发现崩溃、非零退出或备份验证失败；仅保留正常运维事件。'
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# 事故自动复盘') | Out-Null
$lines.Add('') | Out-Null
$lines.Add(('> 窗口：{0}（{1} 至 {2}）' -f $label, $since.ToString('yyyy-MM-dd HH:mm:ss'), (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))) | Out-Null
$lines.Add('> 口径：只做证据关联，不把相关性冒充确定根因；不自动停服、回滚或修改配置。') | Out-Null
$lines.Add('') | Out-Null
$lines.Add(('## 结论：{0}' -f $summary)) | Out-Null
$lines.Add('') | Out-Null
$lines.Add('| 指标 | 数值 |') | Out-Null
$lines.Add('|---|---:|') | Out-Null
$lines.Add(('| 复盘事件 | {0} |' -f $timelineRows.Count)) | Out-Null
$lines.Add(('| 崩溃报告 | {0} |' -f $crashFiles.Count)) | Out-Null
$lines.Add(('| 非零退出 | {0} |' -f $badExits.Count)) | Out-Null
$lines.Add(('| 计划重启 | {0} |' -f $plannedRestarts.Count)) | Out-Null
$lines.Add(('| 服务端启动 | {0} |' -f $starts.Count)) | Out-Null
$lines.Add(('| 卡顿取证 | {0} |' -f [Math]::Max($lagRows.Count, $lagMeta.Count))) | Out-Null
$lines.Add(('| 新错误指纹 | {0} |' -f $fingerprintEvents.Count)) | Out-Null
$lines.Add(('| 备份验证失败 | {0} |' -f $verifyFailures.Count)) | Out-Null
$lines.Add(('| 性能黑匣子样本 | {0} |' -f $perfRows.Count)) | Out-Null
$lines.Add(('| 黑匣子峰值 MSPT | {0} |' -f $(if ($null -ne $peakMspt) { '{0:N2}' -f $peakMspt } else { '无数据' }))) | Out-Null
$lines.Add('') | Out-Null

if ($incidents.Count -eq 0) {
    $lines.Add('## 关联结果') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('本窗口没有形成需要单独处置的事故卡片。时间线中的计划重启、备份和普通指纹事件仍保留在证据目录中。') | Out-Null
} else {
    $lines.Add('## 关联结果') | Out-Null
    $lines.Add('') | Out-Null
    foreach ($incident in $incidents) {
        $lines.Add(('### [{0}] {1} · {2}' -f $incident.severity, $incident.title, $incident.confidence)) | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add(('时间：{0} → {1}' -f $(if ($incident.startedAt) { $incident.startedAt } else { '未知' }), $(if ($incident.endedAt) { $incident.endedAt } else { '未知' }))) | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add('证据：') | Out-Null
        foreach ($e in @($incident.evidence)) { $lines.Add(('- {0}' -f (Format-MdText $e))) | Out-Null }
        $lines.Add('') | Out-Null
        $lines.Add('建议动作（人工确认）：') | Out-Null
        foreach ($a in @($incident.actions)) { $lines.Add(('- {0}' -f (Format-MdText $a))) | Out-Null }
        $lines.Add('') | Out-Null
    }
}

$lines.Add('## 关联说明') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('- “高/中”表示证据需要优先查看，不等于已经自动证明根因。') | Out-Null
$lines.Add('- 同一启动阶段的多个 ERROR 指纹会按归一化文本聚合，避免把一个模组问题误报成十几个事故。') | Out-Null
$lines.Add('- 卡顿证据来自已有取证包；本脚本不会重新抓线程、启动 Spark 或修改线上状态。') | Out-Null
$lines.Add('') | Out-Null
$lines.Add('## 证据位置') | Out-Null
$lines.Add('') | Out-Null
$lines.Add(('- 时间线：`{0}`' -f (Get-Relative $timelineEventsPath))) | Out-Null
$lines.Add('- 性能黑匣子：`logs/perf/samples.jsonl`') | Out-Null
$lines.Add('- 错误指纹：`logs/error-fingerprints.jsonl`') | Out-Null
$lines.Add('- 高危审计：`logs/ops-audit.jsonl`') | Out-Null
$lines.Add('- 卡顿取证：`tmp/lag-forensics/`') | Out-Null
$lines.Add('- 崩溃报告：`crash-reports/`') | Out-Null
$lines.Add('- 本次复盘目录：`tmp/incident-postmortem/`') | Out-Null
$lines.Add('') | Out-Null
$lines.Add(('生成时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))) | Out-Null

$reportText = ($lines -join "`r`n").TrimEnd() + "`r`n"
$qqLines = New-Object System.Collections.Generic.List[string]
$qqLines.Add(('【事故复盘】{0} · {1}' -f $label, $(if ($overall -eq 'red') { '🔴需人工复核' } elseif ($overall -eq 'yellow') { '🟡需关注' } else { '🟢未发现高风险事故' }))) | Out-Null
$qqLines.Add(('崩溃 {0} · 非零退出 {1} · 卡顿 {2} · 新指纹 {3} · 验备份失败 {4}' -f $crashFiles.Count, $badExits.Count, [Math]::Max($lagRows.Count, $lagMeta.Count), $fingerprintEvents.Count, $verifyFailures.Count)) | Out-Null
if ($null -ne $peakMspt) { $qqLines.Add(('黑匣子峰值 MSPT {0:N1}' -f $peakMspt)) | Out-Null }
foreach ($incident in @($incidents | Select-Object -First 3)) { $qqLines.Add(('· [{0}] {1}' -f $incident.severity, $incident.title)) | Out-Null }
$qqLines.Add('证据关联仅供人工复核，不自动停服/回滚。') | Out-Null
$qqLines.Add(('完整报告：tmp/incident-postmortem/{0}/report.md' -f $Stamp)) | Out-Null
$qqText = ($qqLines -join "`r`n") + "`r`n"

$meta = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    window = $Window
    since = $since.ToString('o')
    overall = $overall
    summary = $summary
    incidentCount = $incidents.Count
    counts = [ordered]@{
        timeline = $timelineRows.Count
        crashes = $crashFiles.Count
        badExits = $badExits.Count
        plannedRestarts = $plannedRestarts.Count
        starts = $starts.Count
        lag = [Math]::Max($lagRows.Count, $lagMeta.Count)
        fingerprints = $fingerprintEvents.Count
        audit = $auditEvents.Count
        backups = $backupRows.Count
        backupVerifyFailures = $verifyFailures.Count
        perfSamples = $perfRows.Count
    }
    peakMspt = $peakMspt
    incidents = $incidents
    reportPath = (Get-Relative (Join-Path $OutDir 'report.md'))
    qqPath = (Get-Relative (Join-Path $OutDir 'summary-qq.txt'))
}

[System.IO.File]::WriteAllText((Join-Path $OutDir 'report.md'), $reportText, $utf8)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'summary-qq.txt'), $qqText, $utf8Bom)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'meta.json'), ($meta | ConvertTo-Json -Depth 12), $utf8)
New-Item -ItemType Directory -Path $LatestDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $OutDir 'report.md') -Destination (Join-Path $LatestDir 'report.md') -Force
Copy-Item -LiteralPath (Join-Path $OutDir 'summary-qq.txt') -Destination (Join-Path $LatestDir 'summary-qq.txt') -Force
Copy-Item -LiteralPath (Join-Path $OutDir 'meta.json') -Destination (Join-Path $LatestDir 'meta.json') -Force

if (-not $Quiet -and -not $QqSummary) { Write-Host $reportText }
if ($QqSummary) { Write-Output $qqText }
if ($Json) { Write-Output ($meta | ConvertTo-Json -Compress -Depth 12) }
