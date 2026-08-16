param(
    [int]$IntervalSeconds = 60
)

# 运维自愈：只盯 PID 文件，挂了就单独拉起，绝不碰 Minecraft。
# 解决「discord-watch / QQ 桥 / 备份调度 静默死掉、上线通知在下线通知没了」一类问题。

$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = '运维自愈看门狗' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$LogPath = Join-Path $Root 'logs\ops-supervisor.log'
$PidPath = Join-Path $Root 'tmp\ops-supervisor.pid'

function Write-SupLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
    try { Write-Host $line } catch { }
}

function Test-PidFileAlive([string]$RelPid) {
    $path = Join-Path $Root $RelPid
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $id = 0
    try {
        if (-not [int]::TryParse((Get-Content -LiteralPath $path -Raw).Trim(), [ref]$id)) { return $false }
    } catch { return $false }
    if ($id -le 0) { return $false }
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    try {
        $started = $proc.StartTime
        $stamp = (Get-Item -LiteralPath $path).LastWriteTime
        if ($started -gt $stamp.AddSeconds(60)) { return $false }
    } catch { return $false }
    return $true
}

function Start-DetachedPowerShell {
    param([Parameter(Mandatory = $true)][string]$ArgumentList)
    # 尽量脱离父进程 Job（Cursor/工具链超时杀 Job 时会连带子进程）。
    # cmd start 新开进程树，避免自愈/运维被「启动它的那个会话」一起带走。
    try {
        $cmdArgs = '/c start "" /min powershell.exe ' + $ArgumentList
        Start-Process -FilePath 'cmd.exe' -WorkingDirectory $Root -WindowStyle Hidden `
            -ArgumentList $cmdArgs | Out-Null
        return
    } catch { }
    try {
        Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Root -WindowStyle Hidden `
            -ArgumentList $ArgumentList | Out-Null
    } catch {
        Write-SupLog ("Start-DetachedPowerShell failed: " + $_.Exception.Message)
    }
}

function Start-OpsBundle {
    $starter = Join-Path $Root 'tools\start-ops-monitor.ps1'
    if (-not (Test-Path -LiteralPath $starter)) {
        Write-SupLog "missing start-ops-monitor.ps1"
        return
    }
    Write-SupLog "restarting dead ops via start-ops-monitor.ps1 (no MC touch)"
    # 注意：不要 -Restart（会先杀光含本看门狗在内的运维）；缺啥补啥即可。
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $starter + '" -NoPause'
    Start-DetachedPowerShell -ArgumentList $arg
}

# 单实例
if (Test-Path -LiteralPath $PidPath) {
    $old = 0
    try { [void][int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$old) } catch { }
    if ($old -gt 0 -and $old -ne $PID) {
        $op = Get-Process -Id $old -ErrorAction SilentlyContinue
        if ($op) {
            Write-SupLog "already running pid=$old; exit"
            exit 0
        }
    }
}
$tmp = Join-Path $Root 'tmp'
if (-not (Test-Path -LiteralPath $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
Write-SupLog "start interval=${IntervalSeconds}s"

$targets = @(
    'tmp\discord-watch.pid',
    'tmp\qq-console.pid',
    'tmp\perf-sampler.pid'
)
$opsConfigPath = Join-Path $Root 'tools\ops-config.json'
try {
    $ops = Get-Content -LiteralPath $opsConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ops.backupSchedule -and [bool]$ops.backupSchedule.enabled) {
        $targets += 'tmp\backup-scheduler.pid'
    }
    if ($ops.itemSweeper -and [bool]$ops.itemSweeper.enabled) {
        $targets += 'tmp\item-sweeper.pid'
    }
    if ($ops.modRelease -and [bool]$ops.modRelease.enabled) {
        $targets += 'tmp\mod-release-manager.pid'
    }
} catch {
    Write-SupLog ("cannot read ops-config for optional targets: " + $_.Exception.Message)
}

$round = 0
$lastHeal = $null
try {
    while ($true) {
        $round++
        $dead = @()
        foreach ($t in $targets) {
            if (-not (Test-PidFileAlive $t)) { $dead += $t }
        }
        # 心跳：每 10 轮写一次，便于确认「自愈进程还活着」（否则日志只有 start 像没跑）
        if (($round % 10) -eq 1) {
            $aliveN = $targets.Count - $dead.Count
            Write-SupLog ("heartbeat alive=$aliveN/$($targets.Count) dead=[$($dead -join ', ')]")
        }
        # discord-watch 是通知核心；它挂了就整组补起（start-ops 默认不 -Restart，会跳过已存活的）
        # 冷却 90s，避免补起过程中反复触发
        # targets only contains enabled components, so any dead target deserves a
        # heal attempt. The cooldown below prevents restart storms.
        $needHeal = ($dead.Count -ge 1)
        if ($needHeal) {
            $now = Get-Date
            if ($null -eq $lastHeal -or ($now - $lastHeal).TotalSeconds -ge 90) {
                Write-SupLog ("dead: " + ($dead -join ', '))
                $lastHeal = $now
                Start-OpsBundle
                Start-Sleep -Seconds 25
            } else {
                Write-SupLog ("dead but heal cooldown: " + ($dead -join ', '))
            }
        }
        Start-Sleep -Seconds ([Math]::Max(30, $IntervalSeconds))
    }
} finally {
    try {
        if (Test-Path -LiteralPath $PidPath) {
            $cur = (Get-Content -LiteralPath $PidPath -Raw).Trim()
            if ($cur -eq [string]$PID) { Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
    Write-SupLog 'exit'
}
