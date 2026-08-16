# 日志错误指纹：体检 health-check 与监控 discord-watch 共用同一套归一化规则。
# 设计目标：同一根因在刷屏日志里折叠成一条「指纹」，便于去重告警与聚类。

function Get-McLogFingerprint {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    $s = $Line
    # 去时间戳前缀（MC 日志 / 常见 ISO）
    $s = [regex]::Replace($s, '^\[[^\]]+\]\s*', '')
    $s = [regex]::Replace($s, '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}([.,]\d+)?\s*', '')
    # 去线程/logger 方括号段（保留级别关键词）
    $s = [regex]::Replace($s, '\[[^\]]*(INFO|WARN|ERROR|FATAL|DEBUG)[^\]]*\]\s*', '[$1] ')
    $s = [regex]::Replace($s, '\[[A-Za-z0-9_./:#$ -]{8,}\]\s*', '')
    # 归一化易变 token
    $s = [regex]::Replace($s, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<uuid>')
    $s = [regex]::Replace($s, '\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b', '<ip>')
    $s = [regex]::Replace($s, '\b\d+(\.\d+)?\s*(ms|s|ticks?|MB|GB|KiB|MiB|GiB)\b', '<n>$2', 'IgnoreCase')
    $s = [regex]::Replace($s, '\b\d{4,}\b', '<n>')
    $s = [regex]::Replace($s, '\b\d+\.\d+\b', '<n>')
    $s = [regex]::Replace($s, '\s+', ' ').Trim()
    if ($s.Length -gt 220) { $s = $s.Substring(0, 220) }
    return $s
}

function Test-McLogStackFrame {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $true }
    $trim = $Line.TrimStart()
    return [bool]($trim -match '^(at |More \d+ |\.\.\. \d+ more|Caused by:|Suppressed:)')
}

function Test-McLogSoftNoise {
    param([string]$Line)
    # 可选依赖 soft mixin 探测：未装对应模组时的 ClassNotFound，不是故障
    if ($Line -match '\[mixin/\].*ClassNotFoundException') { return $true }
    if ($Line -match 'Error loading class:.*ClassNotFoundException') { return $true }
    if ($Line -match 'moved wrongly!') { return $true }
    return $false
}

function Get-McLogLevel {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    if (Test-McLogStackFrame -Line $Line) { return $null }
    # 优先看 logger 段里的级别（MC/Log4j 常见）
    if ($Line -match '\]\s*\[ERROR\]|/ERROR\]|\[ERROR\]') { return 'ERROR' }
    if ($Line -match '\]\s*\[FATAL\]|/FATAL\]|\[FATAL\]') { return 'FATAL' }
    if ($Line -match '\]\s*\[WARN\]|/WARN\]|\[WARN\]') { return 'WARN' }
    # 宽松兜底：整行含 ERROR 且像日志头
    if ($Line -match '\bERROR\b' -and $Line -match '^\s*\[') { return 'ERROR' }
    if ($Line -match '\bFATAL\b' -and $Line -match '^\s*\[') { return 'FATAL' }
    if ($Line -match '\bWARN\b' -and $Line -match '^\s*\[') { return 'WARN' }
    return $null
}

function Test-McLogLevelAtLeast {
    param(
        [string]$Level,
        [ValidateSet('WARN', 'ERROR', 'FATAL')][string]$MinLevel = 'ERROR'
    )
    if ([string]::IsNullOrWhiteSpace($Level)) { return $false }
    $rank = @{ WARN = 1; ERROR = 2; FATAL = 3 }
    $lv = $Level.ToUpperInvariant()
    $min = $MinLevel.ToUpperInvariant()
    if (-not $rank.ContainsKey($lv)) { return $false }
    if (-not $rank.ContainsKey($min)) { $min = 'ERROR' }
    return ($rank[$lv] -ge $rank[$min])
}
