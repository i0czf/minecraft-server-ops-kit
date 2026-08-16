param(
    [int]$IntervalSeconds = 60,
    [int]$RetainDays = 14,
    [switch]$Once,
    [string]$Window = '',
    [switch]$Summary
)

# 性能黑匣子采样器：持续记录 TPS/MSPT、在线人数、CPU、内存、磁盘。
# 样本落盘 logs/perf/samples.jsonl（JSON Lines），供面板/QQ !性能 / 体检中心读取。
# 设计原则：
# 1) 失败永不拖垮主流程：RCON/WMI 失败只记空字段，进程继续。
# 2) 单行 JSON，便于 tail/按时间窗过滤，无需数据库。
# 3) 与 health-check 解耦：体检可独立跑；有样本时锦上添花。

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$ToolsDir = $PSScriptRoot
$PerfDir = Join-Path $Root 'logs\perf'
$SamplePath = Join-Path $PerfDir 'samples.jsonl'
$PidPath = Join-Path $Root 'tmp\perf-sampler.pid'
$LogPath = Join-Path $Root 'logs\perf-sampler.log'

function Write-SamplerLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
    if (-not $Summary) {
        try { Write-Host $line } catch { }
    }
}

function Read-ServerProperties {
    $props = @{}
    $path = Join-Path $Root 'server.properties'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $props }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            if ($line -match '^\s*([^#=]+)=(.*)$') { $props[$matches[1].Trim()] = $matches[2] }
        }
    } catch { }
    return $props
}

function Test-PortListening([int]$Port) {
    if ($Port -le 0) { return $false }
    try {
        foreach ($ep in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            if ($ep.Port -eq $Port) { return $true }
        }
    } catch { }
    return $false
}

function Get-ListeningPid([int]$Port) {
    if (-not (Test-PortListening $Port)) { return 0 }
    try {
        $conn = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($conn.Count -gt 0) { return [int]$conn[0].OwningProcess }
    } catch { }
    return 0
}

function Get-LoaderTpsCommand {
    if (Test-Path -LiteralPath (Join-Path $Root 'libraries\net\neoforged\neoforge') -PathType Container) {
        return 'neoforge tps'
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'libraries\net\minecraftforge\forge') -PathType Container) {
        return 'forge tps'
    }
    return 'tps'
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
        if (-not $p.WaitForExit(10000)) {
            try { $p.Kill() } catch { }
            return $null
        }
        if ($p.ExitCode -ne 0) { return $null }
        return $out.Trim()
    } catch {
        return $null
    }
}

function Parse-Tps([string]$Text) {
    $result = @{ tps = $null; mspt = $null }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $result }
    if ($Text -match '([\d.]+)\s*TPS\s*\(([\d.]+)\s*ms/tick\)') {
        $result.tps = [double]$matches[1]
        $result.mspt = [double]$matches[2]
    } elseif ($Text -match 'Mean tick time:\s*([\d.]+)\s*ms.*?Mean TPS:\s*([\d.]+)') {
        $result.mspt = [double]$matches[1]
        $result.tps = [double]$matches[2]
    }
    return $result
}

function Parse-ListCount([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    # "There are 3 of a max of 20 players online:" 或中文/模组变体
    if ($Text -match '(?i)there are\s+(\d+)\s+of') { return [int]$matches[1] }
    if ($Text -match '(?i)(\d+)\s*/\s*\d+') { return [int]$matches[1] }
    if ($Text -match '在线[^0-9]*(\d+)') { return [int]$matches[1] }
    return $null
}

function Get-ProcessCpuMem([int]$ProcId) {
    $cpu = $null; $ws = $null
    if ($ProcId -le 0) { return @{ cpu = $cpu; memMb = $ws } }
    try {
        $p = Get-Process -Id $ProcId -ErrorAction Stop
        $ws = [math]::Round($p.WorkingSet64 / 1MB, 1)
        # 进程 CPU%：两次采样差分（简易）
        $t1 = $p.TotalProcessorTime.TotalMilliseconds
        Start-Sleep -Milliseconds 200
        $p.Refresh()
        $t2 = $p.TotalProcessorTime.TotalMilliseconds
        $cores = [Environment]::ProcessorCount
        if ($cores -lt 1) { $cores = 1 }
        $cpu = [math]::Round((($t2 - $t1) / 200.0) * 100.0 / $cores, 1)
        if ($cpu -lt 0) { $cpu = 0 }
        if ($cpu -gt 100) { $cpu = 100 }
    } catch { }
    return @{ cpu = $cpu; memMb = $ws }
}

function Get-SystemMemPct {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $total = [double]$os.TotalVisibleMemorySize
        $free = [double]$os.FreePhysicalMemory
        if ($total -le 0) { return $null }
        return [math]::Round(100.0 * (1.0 - $free / $total), 1)
    } catch {
        return $null
    }
}

function Get-DiskFreeGb {
    try {
        $rootPath = [System.IO.Path]::GetPathRoot($Root)
        $di = New-Object System.IO.DriveInfo($rootPath)
        return [math]::Round($di.AvailableFreeSpace / 1GB, 2)
    } catch {
        return $null
    }
}

function Collect-Sample {
    $props = Read-ServerProperties
    $port = 25565
    if ($props.ContainsKey('server-port')) {
        $tmp = 0
        if ([int]::TryParse(([string]$props['server-port']).Trim(), [ref]$tmp) -and $tmp -gt 0) { $port = $tmp }
    }
    $serverPid = Get-ListeningPid $port
    $serverUp = $serverPid -gt 0
    $tps = $null; $mspt = $null; $players = $null
    if ($serverUp -and ($props['enable-rcon'] -as [string]) -eq 'true') {
        $tpsText = Invoke-Rcon (Get-LoaderTpsCommand)
        $parsed = Parse-Tps $tpsText
        $tps = $parsed.tps
        $mspt = $parsed.mspt
        $listText = Invoke-Rcon 'list'
        $players = Parse-ListCount $listText
    }
    $pm = Get-ProcessCpuMem $serverPid
    $obj = [ordered]@{
        ts         = (Get-Date).ToString('o')
        serverUp   = $serverUp
        pid        = $serverPid
        tps        = $tps
        mspt       = $mspt
        players    = $players
        cpuPct     = $pm.cpu
        memMb      = $pm.memMb
        sysMemPct  = (Get-SystemMemPct)
        diskFreeGb = (Get-DiskFreeGb)
    }
    return $obj
}

function Append-Sample($obj) {
    if (-not (Test-Path -LiteralPath $PerfDir)) {
        New-Item -ItemType Directory -Path $PerfDir -Force | Out-Null
    }
    $line = ($obj | ConvertTo-Json -Compress -Depth 4)
    Add-Content -LiteralPath $SamplePath -Value $line -Encoding UTF8
}

function Prune-Samples {
    if (-not (Test-Path -LiteralPath $SamplePath)) { return }
    $cutoff = (Get-Date).AddDays(-[Math]::Abs($RetainDays))
    try {
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($line in [System.IO.File]::ReadLines($SamplePath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $o = $line | ConvertFrom-Json
                $ts = [datetime]::Parse($o.ts)
                if ($ts -ge $cutoff) { $kept.Add($line) | Out-Null }
            } catch {
                # 坏行丢弃
            }
        }
        [System.IO.File]::WriteAllLines($SamplePath, $kept, (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Write-SamplerLog ("prune failed: {0}" -f $_.Exception.Message)
    }
}

function Parse-Window([string]$W) {
    if ([string]::IsNullOrWhiteSpace($W)) { return [TimeSpan]::FromHours(1) }
    $w = $W.Trim().ToLowerInvariant()
    if ($w -match '^(\d+)\s*h') { return [TimeSpan]::FromHours([int]$matches[1]) }
    if ($w -match '^(\d+)\s*d') { return [TimeSpan]::FromDays([int]$matches[1]) }
    if ($w -match '^(\d+)\s*m') { return [TimeSpan]::FromMinutes([int]$matches[1]) }
    if ($w -eq '1h' -or $w -eq 'hour') { return [TimeSpan]::FromHours(1) }
    if ($w -eq '24h' -or $w -eq '1d' -or $w -eq 'day') { return [TimeSpan]::FromHours(24) }
    if ($w -eq '7d' -or $w -eq 'week') { return [TimeSpan]::FromDays(7) }
    return [TimeSpan]::FromHours(1)
}

function Get-SummaryText([string]$WindowText) {
    $span = Parse-Window $WindowText
    $since = (Get-Date) - $span
    $rows = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $SamplePath) {
        foreach ($line in [System.IO.File]::ReadLines($SamplePath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $o = $line | ConvertFrom-Json
                $ts = [datetime]::Parse($o.ts)
                if ($ts -ge $since) { $rows.Add($o) | Out-Null }
            } catch { }
        }
    }

    $sb = New-Object System.Text.StringBuilder
    $label = if ($span.TotalHours -ge 24) {
        ('{0:N0} 天' -f ($span.TotalDays))
    } elseif ($span.TotalHours -ge 1) {
        ('{0:N0} 小时' -f $span.TotalHours)
    } else {
        ('{0:N0} 分钟' -f $span.TotalMinutes)
    }
    [void]$sb.AppendLine(("[性能黑匣子] 最近 {0}" -f $label))

    if ($rows.Count -eq 0) {
        [void]$sb.AppendLine('暂无样本。请确认 perf-sampler 已随运维启动，或先看实时 TPS。')
        # 实时兜底
        $live = Collect-Sample
        if ($live.serverUp) {
            [void]$sb.AppendLine(("实时：TPS={0} MSPT={1} 在线={2} CPU={3}% 内存={4}MB" -f `
                        $(if ($null -ne $live.tps) { $live.tps } else { '?' }), `
                        $(if ($null -ne $live.mspt) { $live.mspt } else { '?' }), `
                        $(if ($null -ne $live.players) { $live.players } else { '?' }), `
                        $(if ($null -ne $live.cpuPct) { $live.cpuPct } else { '?' }), `
                        $(if ($null -ne $live.memMb) { $live.memMb } else { '?' })))
        } else {
            [void]$sb.AppendLine('实时：服务端未在监听。')
        }
        return $sb.ToString().TrimEnd()
    }

    $upRows = @($rows | Where-Object { $_.serverUp -eq $true })
    $tpsRows = @($upRows | Where-Object { $null -ne $_.tps })
    $msptRows = @($upRows | Where-Object { $null -ne $_.mspt })
    $playerRows = @($upRows | Where-Object { $null -ne $_.players })
    $lagRows = @($msptRows | Where-Object { [double]$_.mspt -ge 50 })

    function Avg($arr, $prop) {
        $vals = @($arr | ForEach-Object { [double]$_.$prop })
        if ($vals.Count -eq 0) { return $null }
        return [math]::Round((($vals | Measure-Object -Average).Average), 2)
    }
    function MinV($arr, $prop) {
        $vals = @($arr | ForEach-Object { [double]$_.$prop })
        if ($vals.Count -eq 0) { return $null }
        return [math]::Round((($vals | Measure-Object -Minimum).Minimum), 2)
    }
    function MaxV($arr, $prop) {
        $vals = @($arr | ForEach-Object { [double]$_.$prop })
        if ($vals.Count -eq 0) { return $null }
        return [math]::Round((($vals | Measure-Object -Maximum).Maximum), 2)
    }

    [void]$sb.AppendLine(("样本 {0} 条（服务端在线 {1} 条）" -f $rows.Count, $upRows.Count))
    if ($tpsRows.Count -gt 0) {
        [void]$sb.AppendLine(("TPS  均 {0} / 最低 {1} / 最高 {2}" -f (Avg $tpsRows 'tps'), (MinV $tpsRows 'tps'), (MaxV $tpsRows 'tps')))
    }
    if ($msptRows.Count -gt 0) {
        [void]$sb.AppendLine(("MSPT 均 {0} / 最高 {1}  ms" -f (Avg $msptRows 'mspt'), (MaxV $msptRows 'mspt')))
    }
    if ($playerRows.Count -gt 0) {
        [void]$sb.AppendLine(("在线 均 {0} / 峰值 {1}" -f (Avg $playerRows 'players'), (MaxV $playerRows 'players')))
    }
    $cpuRows = @($upRows | Where-Object { $null -ne $_.cpuPct })
    if ($cpuRows.Count -gt 0) {
        [void]$sb.AppendLine(("服务端CPU 均 {0}% / 峰值 {1}%" -f (Avg $cpuRows 'cpuPct'), (MaxV $cpuRows 'cpuPct')))
    }
    $memRows = @($upRows | Where-Object { $null -ne $_.memMb })
    if ($memRows.Count -gt 0) {
        [void]$sb.AppendLine(("服务端内存 均 {0}MB / 峰值 {1}MB" -f (Avg $memRows 'memMb'), (MaxV $memRows 'memMb')))
    }
    [void]$sb.AppendLine(("卡顿样本（MSPT≥50）{0} 次" -f $lagRows.Count))
    if ($lagRows.Count -gt 0) {
        $worst = $lagRows | Sort-Object { [double]$_.mspt } -Descending | Select-Object -First 3
        foreach ($w in $worst) {
            $tshort = try { ([datetime]::Parse([string]$w.ts)).ToString('MM-dd HH:mm') } catch { $w.ts }
            [void]$sb.AppendLine(("  · {0}  MSPT={1} TPS={2} 在线={3}" -f $tshort, $w.mspt, $w.tps, $w.players))
        }
    }
    return $sb.ToString().TrimEnd()
}

# -------- 入口：摘要模式 --------
if ($Summary -or -not [string]::IsNullOrWhiteSpace($Window)) {
    $w = if ([string]::IsNullOrWhiteSpace($Window)) { '1h' } else { $Window }
    Write-Output (Get-SummaryText $w)
    exit 0
}

# -------- 入口：采样模式 --------
if (-not (Test-Path -LiteralPath (Join-Path $Root 'tmp'))) {
    New-Item -ItemType Directory -Path (Join-Path $Root 'tmp') -Force | Out-Null
}

if (-not $Once) {
    # 单实例：已有「别的」存活采样器则退出。
    # 注意：start-ops-monitor 可能先把本进程 PID 写入 pid 文件再进脚本，
    # 此时 old==$PID，绝不能当成「已有实例」而自杀退出。
    if (Test-Path -LiteralPath $PidPath) {
        $old = 0
        try { [void][int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$old) } catch { }
        if ($old -gt 0 -and $old -ne $PID) {
            $op = Get-Process -Id $old -ErrorAction SilentlyContinue
            if ($op) {
                Write-SamplerLog ("already running pid=$old; exit")
                exit 0
            }
        }
    }
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
}

function Get-LagWatchConfig {
    $cfg = [pscustomobject]@{
        Enabled             = $true
        MsptThreshold       = 50.0
        ConsecutiveSamples  = 2
        CooldownSeconds     = 900
        SparkProfilerSeconds = 30
        SparkEnabled        = $true
        ThreadDump          = $true
    }
    try {
        $opsPath = Join-Path $Root 'tools\ops-config.json'
        if (-not (Test-Path -LiteralPath $opsPath)) { return $cfg }
        $ops = Get-Content -LiteralPath $opsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $ops.PSObject.Properties['lagWatch'] -or -not $ops.lagWatch) { return $cfg }
        $lw = $ops.lagWatch
        if ($null -ne $lw.enabled) { $cfg.Enabled = [bool]$lw.enabled }
        if ($null -ne $lw.msptThreshold) {
            $v = 0.0
            if ([double]::TryParse([string]$lw.msptThreshold, [ref]$v) -and $v -ge 20) { $cfg.MsptThreshold = $v }
        }
        if ($null -ne $lw.consecutiveSamples) {
            $n = 0
            if ([int]::TryParse([string]$lw.consecutiveSamples, [ref]$n) -and $n -ge 1) { $cfg.ConsecutiveSamples = $n }
        }
        if ($null -ne $lw.cooldownSeconds) {
            $c = 0
            if ([int]::TryParse([string]$lw.cooldownSeconds, [ref]$c) -and $c -ge 60) { $cfg.CooldownSeconds = $c }
        }
        if ($null -ne $lw.sparkProfilerSeconds) {
            $s = 0
            if ([int]::TryParse([string]$lw.sparkProfilerSeconds, [ref]$s) -and $s -ge 0) { $cfg.SparkProfilerSeconds = $s }
        }
        if ($null -ne $lw.sparkEnabled) { $cfg.SparkEnabled = [bool]$lw.sparkEnabled }
        if ($null -ne $lw.threadDump) { $cfg.ThreadDump = [bool]$lw.threadDump }
    } catch { }
    return $cfg
}

function Invoke-LagForensicsIfNeeded($sample) {
    $lw = Get-LagWatchConfig
    if (-not $lw.Enabled) { return }
    if (-not $sample.serverUp) {
        $script:LagStreak = 0
        return
    }
    $mspt = $null
    if ($null -ne $sample.mspt) {
        try { $mspt = [double]$sample.mspt } catch { $mspt = $null }
    }
    if ($null -eq $mspt) { return }

    if ($mspt -ge $lw.MsptThreshold) {
        $script:LagStreak++
    } else {
        $script:LagStreak = 0
        return
    }

    if ($script:LagStreak -lt $lw.ConsecutiveSamples) { return }

    $now = Get-Date
    if ($script:LastLagForensics -and ($now - $script:LastLagForensics).TotalSeconds -lt $lw.CooldownSeconds) {
        Write-SamplerLog ("lag streak=$($script:LagStreak) mspt=$mspt but cooldown active")
        return
    }

    $forensics = Join-Path $ToolsDir 'lag-forensics.ps1'
    if (-not (Test-Path -LiteralPath $forensics)) {
        Write-SamplerLog 'lag-forensics.ps1 missing; skip'
        return
    }

    $script:LastLagForensics = $now
    $script:LagStreak = 0
    Write-SamplerLog ("trigger lag-forensics mspt=$mspt tps=$($sample.tps) players=$($sample.players)")

    try {
        $args = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $forensics,
            '-Mspt', ([string][math]::Round($mspt, 3)),
            '-Quiet'
        )
        if ($null -ne $sample.tps) { $args += @('-Tps', ([string]$sample.tps)) }
        if ($null -ne $sample.players) { $args += @('-Players', ([string][int]$sample.players)) }
        if ($null -ne $sample.pid -and [int]$sample.pid -gt 0) { $args += @('-PidHint', ([string][int]$sample.pid)) }
        if (-not $lw.SparkEnabled -or $lw.SparkProfilerSeconds -le 0) {
            $args += '-NoSpark'
        } else {
            $args += @('-SparkSeconds', ([string]$lw.SparkProfilerSeconds))
        }
        if (-not $lw.ThreadDump) { $args += '-NoThreadDump' }
        $args += @('-Reason', 'mspt_streak')

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ($args | ForEach-Object {
                if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
            }) -join ' '
        $psi.WorkingDirectory = $Root
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        # 不阻塞采样环：后台等，最长 4 分钟
        if (-not $p.WaitForExit(240000)) {
            try { $p.Kill() } catch { }
            Write-SamplerLog 'lag-forensics timeout 240s'
        } else {
            $out = $p.StandardOutput.ReadToEnd()
            $err = $p.StandardError.ReadToEnd()
            Write-SamplerLog ("lag-forensics exit=$($p.ExitCode) outLen=$($out.Length) errLen=$($err.Length)")
        }
    } catch {
        Write-SamplerLog ("lag-forensics spawn failed: $($_.Exception.Message)")
    }
}

Write-SamplerLog ("start interval=${IntervalSeconds}s once=$Once")
$round = 0
$script:LagStreak = 0
$script:LastLagForensics = $null
try {
    while ($true) {
        $round++
        try {
            $sample = Collect-Sample
            Append-Sample $sample
            if (($round % 60) -eq 0) { Prune-Samples }
            Write-SamplerLog ("sample tps=$($sample.tps) mspt=$($sample.mspt) players=$($sample.players) cpu=$($sample.cpuPct)")
            Invoke-LagForensicsIfNeeded $sample
        } catch {
            Write-SamplerLog ("sample error: $($_.Exception.Message)")
        }
        if ($Once) { break }
        Start-Sleep -Seconds ([Math]::Max(15, $IntervalSeconds))
    }
} finally {
    if (-not $Once) {
        try {
            if (Test-Path -LiteralPath $PidPath) {
                $cur = (Get-Content -LiteralPath $PidPath -Raw).Trim()
                if ($cur -eq [string]$PID) { Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue }
            }
        } catch { }
    }
}
Write-SamplerLog 'exit'
exit 0
