param(
    [double]$Mspt = 0,
    [double]$Tps = 0,
    [int]$Players = -1,
    [int]$PidHint = 0,
    [int]$SparkSeconds = 30,
    [switch]$NoSpark,
    [switch]$NoThreadDump,
    [switch]$Quiet,
    [switch]$Force,
    [string]$Reason = 'mspt_threshold'
)

# 卡顿自动取证：只读/旁路采集，不改配置、不停服。
# 由 perf-sampler 在连续 MSPT 超阈时调用；也可手动 -Force 试跑。
# 产物：tmp/lag-forensics/<stamp>/ + pending 通知（discord-watch 推 QQ/Discord）
# QQ 摘要一律中文友好。

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$ToolsDir = $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $Root ("tmp\lag-forensics\" + $Stamp)
$PendingDir = Join-Path $Root 'tmp\lag-forensics\pending'
$LatestDir = Join-Path $Root 'tmp\lag-forensics\latest'
# 注意：Windows PowerShell 变量名大小写不敏感，$LogPath 与 $logPath 会冲突。
$LagForensicsLogPath = Join-Path $Root 'logs\lag-forensics.log'

function Write-LagLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $dir = Split-Path -Parent $LagForensicsLogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LagForensicsLogPath -Value $line -Encoding UTF8
    } catch { }
    if (-not $Quiet) { try { Write-Host $line } catch { } }
}

function Invoke-Rcon([string]$Command) {
    $script = Join-Path $ToolsDir 'rcon-command.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return $null }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Command `"$Command`""
        $psi.WorkingDirectory = $Root
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        [void]$p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(20000)) {
            try { $p.Kill() } catch { }
            return $null
        }
        return $out.Trim()
    } catch {
        return $null
    }
}

function Get-LogTailMatches([string]$Path, [string]$Pattern, [int]$Max = 30) {
    $hits = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $hits }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            $all = New-Object System.Collections.Generic.List[string]
            while (-not $sr.EndOfStream) {
                $line = $sr.ReadLine()
                if ($line -match $Pattern) { $all.Add($line) | Out-Null }
            }
            $take = [Math]::Min($Max, $all.Count)
            for ($i = $all.Count - $take; $i -lt $all.Count; $i++) {
                if ($i -ge 0) { $hits.Add($all[$i]) | Out-Null }
            }
        } finally { $fs.Dispose() }
    } catch { }
    return $hits
}

function Get-FileSizeSafe([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return ([System.IO.FileInfo]$Path).Length
        }
    } catch { }
    return 0L
}

function Read-JsonlTail([string]$Path, [int]$Max = 20) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $rows }
    try {
        $lines = [System.IO.File]::ReadAllLines($Path)
        $start = [Math]::Max(0, $lines.Length - $Max)
        for ($i = $start; $i -lt $lines.Length; $i++) {
            if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
            try { $rows.Add(($lines[$i] | ConvertFrom-Json)) | Out-Null } catch { }
        }
    } catch { }
    return $rows
}

if ($Force -and ($Reason -eq 'mspt_threshold' -or [string]::IsNullOrWhiteSpace($Reason))) {
    $Reason = 'force'
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
New-Item -ItemType Directory -Path $PendingDir -Force | Out-Null
Write-LagLog ("start reason=$Reason mspt=$Mspt tps=$Tps players=$Players force=$Force")

$liveList = Invoke-Rcon 'list'
$tpsCmd = 'tps'
if (Test-Path (Join-Path $Root 'libraries\net\neoforged\neoforge')) { $tpsCmd = 'neoforge tps' }
elseif (Test-Path (Join-Path $Root 'libraries\net\minecraftforge\forge')) { $tpsCmd = 'forge tps' }
$liveTps = Invoke-Rcon $tpsCmd

$liveTpsVal = $null; $liveMsptVal = $null
if ($liveTps -match '([\d.]+)\s*TPS\s*\(([\d.]+)\s*ms/tick\)') {
    $liveTpsVal = [double]$matches[1]; $liveMsptVal = [double]$matches[2]
} elseif ($liveTps -match 'Mean tick time:\s*([\d.]+)\s*ms.*?Mean TPS:\s*([\d.]+)') {
    $liveMsptVal = [double]$matches[1]; $liveTpsVal = [double]$matches[2]
}
if ($Mspt -le 0 -and $null -ne $liveMsptVal) { $Mspt = $liveMsptVal }
if ($Tps -le 0 -and $null -ne $liveTpsVal) { $Tps = $liveTpsVal }
if ($Players -lt 0 -and $liveList -match '(?i)there are\s+(\d+)\s+of') { $Players = [int]$matches[1] }

$perfPath = Join-Path $Root 'logs\perf\samples.jsonl'
$perfRows = @(Read-JsonlTail $perfPath 15)
$perfText = ($perfRows | ForEach-Object {
        $ts = try { ([datetime]::Parse([string]$_.ts)).ToString('HH:mm:ss') } catch { $_.ts }
        '  {0} TPS={1} MSPT={2} pl={3} cpu={4}% mem={5}MB' -f $ts, $_.tps, $_.mspt, $_.players, $_.cpuPct, $_.memMb
    }) -join "`n"

$latestLogPath = Join-Path $Root 'logs\latest.log'
$keepUp = @(Get-LogTailMatches $latestLogPath "Can'?t keep up" 15)
$gcTicks = @(Get-LogTailMatches $latestLogPath 'included GC lasting' 15)
$errors = @(Get-LogTailMatches $latestLogPath '\[ERROR\]|/ERROR\]' 20)
$fpPath = Join-Path $Root 'logs\error-fingerprints.jsonl'
$fpRows = @(Read-JsonlTail $fpPath 10)
$auditPath = Join-Path $Root 'logs\ops-audit.jsonl'
$auditRows = @(Read-JsonlTail $auditPath 10)

$serverPid = $PidHint
if ($serverPid -le 0) {
    try {
        $props = Get-Content (Join-Path $Root 'server.properties') -ErrorAction SilentlyContinue
        $port = 25565
        foreach ($line in $props) {
            if ($line -match '^server-port=(\d+)') { $port = [int]$matches[1] }
        }
        $conn = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
        if ($conn.Count -gt 0) { $serverPid = [int]$conn[0].OwningProcess }
    } catch { }
}

$cpuPct = $null; $memMb = $null
if ($serverPid -gt 0) {
    try {
        $pr = Get-Process -Id $serverPid -ErrorAction Stop
        $memMb = [math]::Round($pr.WorkingSet64 / 1MB, 1)
        $t1 = $pr.TotalProcessorTime
        Start-Sleep -Milliseconds 400
        $pr.Refresh()
        $t2 = $pr.TotalProcessorTime
        $cpuPct = [math]::Round((($t2 - $t1).TotalMilliseconds / 400.0) * 100.0 / [Environment]::ProcessorCount, 1)
    } catch { }
}

$threadDumpPath = Join-Path $OutDir 'thread-dump.txt'
$threadDumpOk = $false
if (-not $NoThreadDump -and $serverPid -gt 0) {
    try {
        $jcmd = $null
        foreach ($c in @('jcmd', 'jcmd.exe')) {
            $cmd = Get-Command $c -ErrorAction SilentlyContinue
            if ($cmd) { $jcmd = $cmd.Source; break }
        }
        if (-not $jcmd -and $env:JAVA_HOME) {
            $cand = Join-Path $env:JAVA_HOME 'bin\jcmd.exe'
            if (Test-Path $cand) { $jcmd = $cand }
        }
        if ($jcmd) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $jcmd
            $psi.Arguments = "$serverPid Thread.print"
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $out = $p.StandardOutput.ReadToEnd()
            $err = $p.StandardError.ReadToEnd()
            if (-not $p.WaitForExit(45000)) { try { $p.Kill() } catch { } }
            $text = if ($out.Length -gt 80) { $out } else { $err }
            if ($text.Length -gt 80) {
                [System.IO.File]::WriteAllText($threadDumpPath, $text, (New-Object System.Text.UTF8Encoding $false))
                $threadDumpOk = $true
                Write-LagLog ("thread dump ok bytes=$($text.Length)")
            }
        } else {
            Write-LagLog 'jcmd not found; skip thread dump'
        }
    } catch {
        Write-LagLog ("thread dump failed: $($_.Exception.Message)")
    }
}

$sparkUrl = ''
$sparkNotes = New-Object System.Collections.Generic.List[string]
$sparkOk = $false
if (-not $NoSpark -and $SparkSeconds -gt 0) {
    $sec = [Math]::Max(10, [Math]::Min(120, $SparkSeconds))
    Write-LagLog ("spark profiler start timeout=${sec}s")
    [void](Invoke-Rcon "spark profiler start --timeout $sec")
    $deadline = (Get-Date).AddSeconds($sec + 25)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $hits = @(Get-LogTailMatches $latestLogPath 'spark\.lucko\.me|https?://[^\s]+spark|Profiler|profiler' 40)
        foreach ($h in $hits) {
            if ($h -match '(https?://spark\.lucko\.me/[A-Za-z0-9]+)') {
                $sparkUrl = $matches[1]
                $sparkOk = $true
            }
        }
        if ($sparkOk) { break }
    }
    if (-not $sparkOk) {
        [void](Invoke-Rcon 'spark profiler stop')
        Start-Sleep -Seconds 5
        $hits = @(Get-LogTailMatches $latestLogPath 'spark\.lucko\.me|https?://' 30)
        foreach ($h in $hits) {
            if ($h -match '(https?://spark\.lucko\.me/[A-Za-z0-9]+)') {
                $sparkUrl = $matches[1]; $sparkOk = $true; break
            }
        }
    }
    $sparkLog = @(Get-LogTailMatches $latestLogPath '\[spark/\]|spark-worker|Profiler|tickmonitor|Analysis is now' 25)
    foreach ($s in $sparkLog) { $sparkNotes.Add($s) | Out-Null }
    Write-LagLog ("spark done ok=$sparkOk url=$sparkUrl")
}

$meta = [ordered]@{
    stamp          = $Stamp
    reason         = $Reason
    force          = [bool]$Force
    triggerMspt    = $Mspt
    triggerTps     = $Tps
    triggerPlayers = $Players
    liveTps        = $liveTpsVal
    liveMspt       = $liveMsptVal
    liveList       = $liveList
    serverPid      = $serverPid
    cpuPct         = $cpuPct
    memMb          = $memMb
    sparkUrl       = $sparkUrl
    sparkOk        = $sparkOk
    threadDumpOk   = $threadDumpOk
    keepUpCount    = $keepUp.Count
    errorTailCount = $errors.Count
    generatedAt    = (Get-Date).ToString('o')
    outDir         = $OutDir
}

function FmtOrDash($v) {
    if ($null -eq $v) { return '-' }
    if ($v -is [double] -or $v -is [float] -or $v -is [decimal]) {
        return ([math]::Round([double]$v, 2)).ToString()
    }
    $s = [string]$v
    if ([string]::IsNullOrWhiteSpace($s)) { return '-' }
    return $s
}

function Format-LagReason([string]$R) {
    switch -Regex ($R) {
        'mspt_streak|mspt_threshold' { return '连续MSPT超阈' }
        'force|manual' { return '手动试跑' }
        default {
            if ([string]::IsNullOrWhiteSpace($R)) { return '未知' }
            return $R
        }
    }
}

$msptShow = if ($Mspt -gt 0) { FmtOrDash $Mspt } else { '-' }
$tpsShow = if ($Tps -gt 0) { FmtOrDash $Tps } else { '-' }
$plShow = if ($Players -ge 0) { [string]$Players } else { '-' }
$liveTpsShow = FmtOrDash $liveTpsVal
$liveMsptShow = FmtOrDash $liveMsptVal
$cpuShow = FmtOrDash $cpuPct
$memShow = FmtOrDash $memMb
$reasonCn = Format-LagReason $Reason
$dumpCn = if ($threadDumpOk) { '有' } else { '无' }

$summarySb = New-Object System.Text.StringBuilder
[void]$summarySb.AppendLine('【卡顿取证】')
[void]$summarySb.AppendLine(('原因：{0} · MSPT {1} · TPS {2} · 在线 {3}' -f $reasonCn, $msptShow, $tpsShow, $plShow))
[void]$summarySb.AppendLine(('实时：TPS {0} · MSPT {1}' -f $liveTpsShow, $liveMsptShow))
if ($null -ne $cpuPct -or $null -ne $memMb) {
    [void]$summarySb.AppendLine(('进程：CPU {0}% · 内存 {1} MB · PID {2}' -f $cpuShow, $memShow, $serverPid))
}
if ($liveList) {
    $listShort = [string]$liveList
    if ($listShort -match '(?i)there are\s+(\d+)\s+of\s+a\s+max\s+of\s+(\d+)\s+players online:\s*(.*)$') {
        $names = $matches[3].Trim()
        if ([string]::IsNullOrWhiteSpace($names)) {
            $listShort = ('在线 {0}/{1} 人' -f $matches[1], $matches[2])
        } else {
            $listShort = ('在线 {0}/{1}：{2}' -f $matches[1], $matches[2], $names)
        }
    } elseif ($listShort.Length -gt 200) {
        $listShort = $listShort.Substring(0, 200) + '...'
    }
    [void]$summarySb.AppendLine(('在线：' + $listShort))
}
if ($sparkOk -and $sparkUrl) {
    [void]$summarySb.AppendLine(('Spark 报告：' + $sparkUrl))
} elseif (-not $NoSpark) {
    [void]$summarySb.AppendLine('Spark：未拿到报告链接（RCON 无回文属正常，详见取证包 spark-notes）')
}
[void]$summarySb.AppendLine(("卡顿日志 CantKeepUp {0} 条 · ERROR 尾 {1} 条 · 线程转储 {2}" -f $keepUp.Count, $errors.Count, $dumpCn))
[void]$summarySb.AppendLine(('完整包：tmp\lag-forensics\' + $Stamp))
$qqText = $summarySb.ToString().TrimEnd()

$full = New-Object System.Text.StringBuilder
[void]$full.AppendLine($qqText)
[void]$full.AppendLine('')
[void]$full.AppendLine('## 近15条黑匣子样本')
if ($perfText) { [void]$full.AppendLine($perfText) } else { [void]$full.AppendLine('  （无）') }
[void]$full.AppendLine('')
[void]$full.AppendLine("## Cant keep up（近期）")
if ($keepUp.Count -eq 0) { [void]$full.AppendLine('  （无）') }
else { foreach ($k in $keepUp) { [void]$full.AppendLine(('  ' + $k)) } }
[void]$full.AppendLine('')
[void]$full.AppendLine('## GC/tick 提示')
if ($gcTicks.Count -eq 0) { [void]$full.AppendLine('  （无）') }
else { foreach ($g in $gcTicks) { [void]$full.AppendLine(('  ' + $g)) } }
[void]$full.AppendLine('')
[void]$full.AppendLine('## ERROR 日志尾')
if ($errors.Count -eq 0) { [void]$full.AppendLine('  （无）') }
else { foreach ($e in ($errors | Select-Object -Last 12)) { [void]$full.AppendLine(('  ' + $e)) } }
[void]$full.AppendLine('')
[void]$full.AppendLine('## 指纹告警尾')
if ($fpRows.Count -eq 0) { [void]$full.AppendLine('  （无）') }
else {
    foreach ($f in $fpRows) {
        [void]$full.AppendLine(('  [{0}] {1} total={2}' -f $f.action, $f.fp, $f.total))
    }
}
[void]$full.AppendLine('')
[void]$full.AppendLine('## 审计尾')
if ($auditRows.Count -eq 0) { [void]$full.AppendLine('  （无）') }
else {
    foreach ($a in $auditRows) {
        [void]$full.AppendLine(('  {0} action={1}' -f $a.ts, $a.action))
    }
}
if ($sparkNotes.Count -gt 0) {
    [void]$full.AppendLine('')
    [void]$full.AppendLine('## Spark 日志摘录')
    foreach ($s in $sparkNotes) { [void]$full.AppendLine(('  ' + $s)) }
}

$utf8bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText((Join-Path $OutDir 'summary-qq.txt'), $qqText, $utf8bom)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'report.txt'), $full.ToString().TrimEnd(), $utf8bom)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'meta.json'), ($meta | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
if ($liveList) { [System.IO.File]::WriteAllText((Join-Path $OutDir 'live-list.txt'), $liveList, $utf8bom) }
if ($liveTps) { [System.IO.File]::WriteAllText((Join-Path $OutDir 'live-tps.txt'), $liveTps, $utf8bom) }
if ($perfText) { [System.IO.File]::WriteAllText((Join-Path $OutDir 'perf-tail.txt'), $perfText, $utf8bom) }
if ($sparkNotes.Count -gt 0) {
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'spark-notes.txt'), ($sparkNotes -join "`n"), $utf8bom)
}

New-Item -ItemType Directory -Path $LatestDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $OutDir 'summary-qq.txt') -Destination (Join-Path $LatestDir 'summary-qq.txt') -Force
Copy-Item -LiteralPath (Join-Path $OutDir 'report.txt') -Destination (Join-Path $LatestDir 'report.txt') -Force
Copy-Item -LiteralPath (Join-Path $OutDir 'meta.json') -Destination (Join-Path $LatestDir 'meta.json') -Force

$pending = [ordered]@{
    stamp     = $Stamp
    outDir    = $OutDir
    summary   = $qqText
    sparkUrl  = $sparkUrl
    mspt      = $Mspt
    tps       = $Tps
    players   = $Players
    createdAt = (Get-Date).ToString('o')
}
$pendingPath = Join-Path $PendingDir ($Stamp + '.json')
[System.IO.File]::WriteAllText($pendingPath, ($pending | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

Write-LagLog ("done pending=$pendingPath")
if (-not $Quiet) {
    Write-Output $qqText
}
exit 0