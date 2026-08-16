param(
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '停止所有运维' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$PidPath = Join-Path $Root "tmp\discord-watch.pid"
$BackupPidPath = Join-Path $Root "tmp\backup-scheduler.pid"
$PerfPidPath = Join-Path $Root "tmp\perf-sampler.pid"
$OpsSupervisorPidPath = Join-Path $Root "tmp\ops-supervisor.pid"
$ConsolePidPath = Join-Path $Root "tmp\discord-console.pid"
$QQConsolePidPath = Join-Path $Root "tmp\qq-console.pid"

# PID 会被系统回收给无关进程。只凭 Get-Process -Id 判断，轻则误报「运行中」，
# 重则下面的 Stop-Process -Force 把那个无关进程直接杀掉（可能是浏览器甚至系统进程）。
# 判据：运维进程必然在写 PID 文件之前就已启动；被回收的 PID，其进程启动时间必然晚于文件写入时间。
# 用进程 StartTime 与 PID 文件 mtime 对比即可判定归属，成本极低（不查 CIM）。
function Test-TrackedPidOwned {
    param([int]$ProcessId, [string]$PidFile)
    if ($ProcessId -le 0) { return $false }
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    try { $started = $proc.StartTime } catch { return $false }  # 无权读取=系统进程，肯定不是我们启的
    try {
        $stamp = (Get-Item -LiteralPath $PidFile -ErrorAction Stop).LastWriteTime
    } catch {
        return $true   # 拿不到文件时间就退回旧行为，不误伤
    }
    # 容差 60 秒：Set-Content 紧跟在 Start-Process 之后，正常情况下 started <= stamp
    return ($started -le $stamp.AddSeconds(60))
}

function Stop-TrackedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$PidFile,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return }
    $pidText = Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue
    $oldPid = 0
    if ([int]::TryParse($pidText.Trim(), [ref]$oldPid)) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($proc -and -not (Test-TrackedPidOwned -ProcessId $oldPid -PidFile $PidFile)) {
            Write-Host "[运维] PID=$oldPid 现在属于其它进程（$($proc.ProcessName)），不是 $Label，已跳过并清理 PID 文件。" -ForegroundColor Yellow
            $proc = $null
        }
        if ($proc) {
            Write-Host "[运维] 正在停止 $Label，PID=$oldPid"
            try {
                Stop-Process -Id $oldPid -Force -ErrorAction Stop
            } catch {
                throw "无法停止 $Label，PID=${oldPid}：$($_.Exception.Message)"
            }
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Date) -lt $deadline -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
                Start-Sleep -Milliseconds 250
            }
            if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
                throw "无法在限定时间内停止 $Label，PID=${oldPid}。"
            }
        } else {
            Write-Host "[运维] $Label 的 PID=$oldPid 未运行，清理 PID 文件。"
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

function Stop-CommandLineMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )
    try {
        $rootNeedle = [regex]::Escape($Root)
        $matches = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            if ($_.ProcessId -eq $PID -or -not $_.CommandLine) { return $false }
            $cmd = [string]$_.CommandLine
            $decoded = ''
            if ($cmd -match '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)') {
                try { $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($matches[1])) } catch { $decoded = '' }
            }
            $haystack = $cmd + "`n" + $decoded
            return ($haystack -match $rootNeedle -and $haystack -match $Pattern)
        })
        foreach ($match in $matches) {
            Write-Host "[运维] 正在停止残留 $Label 进程，PID=$($match.ProcessId)"
            Stop-Process -Id $match.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "[运维] 扫描残留 $Label 进程失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stop-LegacyRelativeConsoleBridge {
    param([string]$Label = 'legacy Discord 频道反控桥')
    try {
        $matches = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            if ($_.ProcessId -eq $PID -or -not $_.CommandLine) { return $false }
            $cmd = [string]$_.CommandLine
            return ($cmd -match '(?i)\bDiscordConsoleBridge\b' -and $cmd -match '(?i)(^|\s)"?tools\\ops-config\.json"?(\s|$)')
        })
        foreach ($match in $matches) {
            Write-Host "[运维] 正在停止残留 $Label 进程，PID=$($match.ProcessId)"
            Stop-Process -Id $match.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "[运维] 扫描残留 $Label 进程失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Stop-KnownPathProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $fullPaths = @($Paths | ForEach-Object { [System.IO.Path]::GetFullPath($_) })
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        $procPath = $null
        try { $procPath = $proc.Path } catch { $procPath = $null }
        if (-not $procPath) { continue }
        if ($fullPaths -contains [System.IO.Path]::GetFullPath($procPath)) {
            Write-Host "[运维] 正在停止 $Label，PID=$($proc.Id)"
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-MonitorLocks {
    foreach ($rel in @('tmp\discord-watch.instance.lock', 'tmp\discord-console.lock', 'tmp\qq-console.lock', 'tmp\qq-console.lastid', 'tmp\discord-send-dedupe.lock')) {
        Remove-Item -LiteralPath (Join-Path $Root $rel) -Force -ErrorAction SilentlyContinue
    }
}

New-Item -ItemType Directory -Force (Join-Path $Root "tmp") | Out-Null
Stop-TrackedProcess -PidFile $OpsSupervisorPidPath -Label '运维自愈看门狗'
Stop-TrackedProcess -PidFile $PidPath -Label 'Discord/QQ 日志监控'
Stop-TrackedProcess -PidFile $BackupPidPath -Label '备份调度'
Stop-TrackedProcess -PidFile $PerfPidPath -Label '性能黑匣子'
Stop-TrackedProcess -PidFile $ConsolePidPath -Label 'Discord 频道反控桥'
Stop-TrackedProcess -PidFile $QQConsolePidPath -Label 'QQ 群反控桥'
Stop-CommandLineMatch -Pattern 'discord-watch\.ps1|backup-scheduler\.ps1|perf-sampler\.ps1|ops-supervisor\.ps1|DiscordConsoleBridge|QQConsoleBridge' -Label '运维监控'
Stop-LegacyRelativeConsoleBridge
$llbotDir = Join-Path $Root 'tools\LLBot-CLI-win-x64'
Stop-KnownPathProcess -Label 'LLBot 机器人运行时' -Paths @(
    (Join-Path $llbotDir 'llbot.exe'),
    (Join-Path $llbotDir 'bin\llbot\node.exe')
)
Clear-MonitorLocks
Write-Host '[运维] 运维监控已停止（Discord + QQ + LLBot + 备份 + 性能黑匣子 + 自愈看门狗）；Minecraft 服务端进程不受影响。' -ForegroundColor Green

if (-not $NoPause) { pause }