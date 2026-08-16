param(
    [switch]$NoPause,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '启动所有运维 —— 各监控会在独立窗口运行' } catch { }
trap {
    Write-Host "[运维] 启动失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root "tools\ops-config.json"
$ScriptPath = Join-Path $Root "tools\discord-watch.ps1"
$BackupSchedulerPath = Join-Path $Root "tools\backup-scheduler.ps1"
$PerfSamplerPath = Join-Path $Root "tools\perf-sampler.ps1"
$ItemSweeperPath = Join-Path $Root "tools\item-sweeper.ps1"
$OpsSupervisorPath = Join-Path $Root "tools\ops-supervisor.ps1"
$ModReleaseStarterPath = Join-Path $Root "tools\start-mod-release-manager.ps1"
$ConsoleBridgePath = Join-Path $Root "tools\DiscordConsoleBridge.java"
$QQConsoleBridgePath = Join-Path $Root "tools\QQConsoleBridge.java"
$PidPath = Join-Path $Root "tmp\discord-watch.pid"
$BackupPidPath = Join-Path $Root "tmp\backup-scheduler.pid"
$PerfPidPath = Join-Path $Root "tmp\perf-sampler.pid"
$ItemSweeperPidPath = Join-Path $Root "tmp\item-sweeper.pid"
$OpsSupervisorPidPath = Join-Path $Root "tmp\ops-supervisor.pid"
$ConsolePidPath = Join-Path $Root "tmp\discord-console.pid"
$QQConsolePidPath = Join-Path $Root "tmp\qq-console.pid"
$ModReleasePidPath = Join-Path $Root "tmp\mod-release-manager.pid"
$script:StartFailures = @()

function Resolve-Java17 {
    # 扫目录而不是写死小版本号（Adoptium 升级一次就失配一次），取版本号最高的 jdk-17*
    $adoptium = 'C:\Program Files\Eclipse Adoptium'
    if (Test-Path -LiteralPath $adoptium -PathType Container) {
        $hit = Get-ChildItem -LiteralPath $adoptium -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\java.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($hit) { return $hit }
    }
    if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        return (Join-Path $env:JAVA_HOME "bin\java.exe")
    }
    return "java.exe"
}

# 源码没改就跳过 javac：QQConsoleBridge.java 有 27 万字符，每次重启运维都白编译好几秒
function Test-JavaCompileNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$ClassesDir
    )
    $className = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $classFile = Join-Path $ClassesDir ($className + '.class')
    if (-not (Test-Path -LiteralPath $classFile -PathType Leaf)) { return $true }
    return ((Get-Item -LiteralPath $SourcePath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $classFile).LastWriteTimeUtc)
}

function Resolve-Javac17 {
    $java = Resolve-Java17
    if ($java -and $java.EndsWith("java.exe")) {
        $javac = $java.Substring(0, $java.Length - "java.exe".Length) + "javac.exe"
        if (Test-Path -LiteralPath $javac) { return $javac }
    }
    return "javac.exe"
}

function Test-ProcessAlive {
    param([int]$PidValue)
    try {
        $p = Get-Process -Id $PidValue -ErrorAction Stop
        return -not $p.HasExited
    } catch {
        return $false
    }
}

# PID 会被系统回收给无关进程。只凭 Get-Process -Id 判断，轻则误报「已在运行」而跳过启动，
# 重则 Stop-TrackedProcess 把那个无关进程直接杀掉（可能是浏览器甚至系统进程）。
# 判据：运维进程必然在写 PID 文件之前就已启动；被回收的 PID，其进程启动时间必然晚于文件写入时间。
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


function Confirm-StartedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$PidFile,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$DelayMilliseconds = 3000
    )
    Start-Sleep -Milliseconds $DelayMilliseconds
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
        Write-Host "[运维] 警告：$Label 未写入 PID 文件。" -ForegroundColor Yellow
        $script:StartFailures += $Label
        return
    }
    $raw = Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue
    $id = 0
    if (-not ($raw -and [int]::TryParse($raw.Trim(), [ref]$id) -and $id -gt 0 -and (Test-ProcessAlive -PidValue $id))) {
        Write-Host "[运维] 警告：$Label 启动后已退出，请查看 logs 目录下对应日志。" -ForegroundColor Yellow
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        $script:StartFailures += $Label
        return
    }
    Write-Host "[运维] $Label 存活确认，PID=$id" -ForegroundColor Green
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
                $msg = [string]$_.Exception.Message
if ($msg -match 'Access is denied|拒绝访问') { $msg = '权限不足，请用管理员权限运行一键入口。' }
throw "无法停止 $Label，PID=${oldPid}：$msg"
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
        Write-Host "[运维] 扫描残留 $Label 进程失败：$($_.Exception.Message)"
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
        Write-Host "[运维] 扫描残留 $Label 进程失败：$($_.Exception.Message)"
    }
}

function Clear-MonitorLocks {
    param([string[]]$Names)
    $allLocks = @('tmp\discord-watch.instance.lock', 'tmp\discord-console.lock', 'tmp\qq-console.lock', 'tmp\qq-console.lastid', 'tmp\discord-send-dedupe.lock')
    $targets = if ($Names.Count -gt 0) { $Names } else { $allLocks }
    foreach ($rel in $targets) {
        Remove-Item -LiteralPath (Join-Path $Root $rel) -Force -ErrorAction SilentlyContinue
    }
}

function Is-TrackedProcessCurrent {
    param(
        [Parameter(Mandatory = $true)][string]$PidFile,
        [Parameter(Mandatory = $true)][string[]]$WatchedFiles,
        [int]$OldPid = 0
    )
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return $false }
    if ($OldPid -le 0) {
        $pidText = Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue
        if (-not [int]::TryParse($pidText.Trim(), [ref]$OldPid)) { return $false }
    }
    if (-not (Test-ProcessAlive -PidValue $OldPid)) { return $false }
    # PID 被回收给无关进程时，这里若返回 true 会让调用方判定「已在运行」而跳过启动，
    # 监控就此静默缺席。校验归属，不是我们的进程一律当作没在跑（随后走重启分支）。
    if (-not (Test-TrackedPidOwned -ProcessId $OldPid -PidFile $PidFile)) { return $false }
    $pidStamp = (Get-Item -LiteralPath $PidFile).LastWriteTimeUtc
    foreach ($file in $WatchedFiles) {
        if ((Test-Path -LiteralPath $file -PathType Leaf) -and (Get-Item -LiteralPath $file).LastWriteTimeUtc -gt $pidStamp) {
            return $false
        }
    }
    return $true
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "[运维] 未找到 tools\ops-config.json。请先运行初始化配置，或根据模板创建配置文件。"
    if (-not $NoPause) { pause }
    return
}

New-Item -ItemType Directory -Force (Join-Path $Root "tmp") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Root "logs") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Root "backups") | Out-Null

if ($Restart) {
    Stop-TrackedProcess -PidFile $OpsSupervisorPidPath -Label '运维自愈看门狗'
    Stop-TrackedProcess -PidFile $PidPath -Label 'Discord/QQ 日志监控'
    Stop-TrackedProcess -PidFile $BackupPidPath -Label '备份调度'
    Stop-TrackedProcess -PidFile $PerfPidPath -Label '性能黑匣子'
    Stop-TrackedProcess -PidFile $ItemSweeperPidPath -Label '扫地僧'
    Stop-TrackedProcess -PidFile $ConsolePidPath -Label 'Discord 频道反控桥'
    Stop-TrackedProcess -PidFile $QQConsolePidPath -Label 'QQ 群反控桥'
    Stop-TrackedProcess -PidFile $ModReleasePidPath -Label '模组发布管理器'
    Stop-CommandLineMatch -Pattern 'discord-watch\.ps1|backup-scheduler\.ps1|perf-sampler\.ps1|item-sweeper\.ps1|ops-supervisor\.ps1|mod-release-manager\.py|start-mod-release-manager\.ps1|DiscordConsoleBridge|QQConsoleBridge' -Label '运维监控'
    Stop-LegacyRelativeConsoleBridge

    Start-Sleep -Seconds 2
    # 兜底：强制按 PID 杀掉残留进程
    foreach ($pf in @($OpsSupervisorPidPath, $PidPath, $BackupPidPath, $PerfPidPath, $ItemSweeperPidPath, $ConsolePidPath, $QQConsolePidPath, $ModReleasePidPath)) {
        if (Test-Path -LiteralPath $pf) {
            $raw = Get-Content -LiteralPath $pf -Raw -ErrorAction SilentlyContinue
            $id = 0
            # 同样要校验归属：这条是兜底强杀，误伤代价最大
            if ($raw -and [int]::TryParse($raw.Trim(), [ref]$id) -and $id -gt 0 -and (Test-TrackedPidOwned -ProcessId $id -PidFile $pf)) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
                Write-Host "[运维] 已强制清理残留 PID $id"
            }
        }
    }
    Start-Sleep -Seconds 1
    Clear-MonitorLocks
}

$OpsConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$discordAlreadyRunning = $false
if (Test-Path -LiteralPath $PidPath) {
    $oldPidText = Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue
    $oldPid = 0
    if ([int]::TryParse($oldPidText.Trim(), [ref]$oldPid) -and (Test-ProcessAlive -PidValue $oldPid)) {
        if (Is-TrackedProcessCurrent -PidFile $PidPath -WatchedFiles @($ScriptPath, $ConfigPath) -OldPid $oldPid) {
            Write-Host "[运维] Discord/QQ 日志监控已在运行，PID=$oldPid"
            $discordAlreadyRunning = $true
        } else {
            Write-Host "[运维] Discord/QQ 日志监控脚本或配置已更新，正在重启 PID=$oldPid"
            Stop-TrackedProcess -PidFile $PidPath -Label 'Discord/QQ 日志监控'
            Clear-MonitorLocks -Names @('tmp\discord-watch.instance.lock')
        }
    } else {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        Clear-MonitorLocks -Names @('tmp\discord-watch.instance.lock')
    }
}

if (-not $discordAlreadyRunning) {
    $watchLogName = "discord-watch.child.{0:yyyyMMdd-HHmmss}.{1}.log" -f (Get-Date), $PID
    $watchLogPath = Join-Path $Root (Join-Path "logs" $watchLogName)
    $watchCommand = @"
Set-Location -LiteralPath '$Root'
try {
  & '$ScriptPath' -ConfigPath '$ConfigPath' *>> '$watchLogPath'
} catch {
  Add-Content -LiteralPath '$watchLogPath' -Value (`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' 启动器严重错误：' + `$_.Exception.Message) -Encoding UTF8
  throw
}
"@
    $watchEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchCommand))
    $proc = Start-Process powershell.exe `
        -WorkingDirectory $Root `
        -WindowStyle Hidden `
        -PassThru `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $watchEncoded)
    Set-Content -LiteralPath $PidPath -Value $proc.Id -Encoding ASCII
    Write-Host "[运维] Discord/QQ 日志监控已启动，PID=$($proc.Id)"
    Confirm-StartedProcess -PidFile $PidPath -Label 'Discord/QQ 日志监控'
}

if ($OpsConfig.backupSchedule -and $OpsConfig.backupSchedule.enabled) {
    $backupAlreadyRunning = $false
    if (Test-Path -LiteralPath $BackupPidPath) {
        $oldPidText = Get-Content -LiteralPath $BackupPidPath -Raw -ErrorAction SilentlyContinue
        $oldPid = 0
        if ([int]::TryParse($oldPidText.Trim(), [ref]$oldPid) -and (Test-ProcessAlive -PidValue $oldPid)) {
            if (Is-TrackedProcessCurrent -PidFile $BackupPidPath -WatchedFiles @($BackupSchedulerPath, $ConfigPath) -OldPid $oldPid) {
                $backupAlreadyRunning = $true
            } else {
                Write-Host "[运维] 备份调度脚本或配置已更新，正在重启 PID=$oldPid"
                Stop-TrackedProcess -PidFile $BackupPidPath -Label '备份调度'
            }
        } else {
            Remove-Item -LiteralPath $BackupPidPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($backupAlreadyRunning) {
        Write-Host "[运维] 备份调度已在运行，PID=$oldPid"
    } else {
        $backupLogPath = Join-Path $Root "logs\backup-scheduler.child.log"
        $backupCommand = @"
Set-Location -LiteralPath '$Root'
try {
  & '$BackupSchedulerPath' -ConfigPath '$ConfigPath' *>> '$backupLogPath'
} catch {
  Add-Content -LiteralPath '$backupLogPath' -Value (`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' 启动器严重错误：' + `$_.Exception.Message) -Encoding UTF8
  throw
}
"@
        $backupEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($backupCommand))
        $backupProc = Start-Process powershell.exe `
            -WorkingDirectory $Root `
            -WindowStyle Hidden `
            -PassThru `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $backupEncoded)
        Set-Content -LiteralPath $BackupPidPath -Value $backupProc.Id -Encoding ASCII
        Write-Host "[运维] 备份调度已启动，PID=$($backupProc.Id)"
        Confirm-StartedProcess -PidFile $BackupPidPath -Label '备份调度'
    }
}

# --- 性能黑匣子采样（TPS/CPU/内存时间线，供 !性能 / 体检中心读取）---
if (Test-Path -LiteralPath $PerfSamplerPath -PathType Leaf) {
    $perfAlreadyRunning = $false
    if (Test-Path -LiteralPath $PerfPidPath) {
        $oldPidText = Get-Content -LiteralPath $PerfPidPath -Raw -ErrorAction SilentlyContinue
        $oldPid = 0
        if ([int]::TryParse($oldPidText.Trim(), [ref]$oldPid) -and (Test-ProcessAlive -PidValue $oldPid)) {
            if (Is-TrackedProcessCurrent -PidFile $PerfPidPath -WatchedFiles @($PerfSamplerPath) -OldPid $oldPid) {
                $perfAlreadyRunning = $true
            } else {
                Write-Host "[运维] 性能黑匣子脚本已更新，正在重启 PID=$oldPid"
                Stop-TrackedProcess -PidFile $PerfPidPath -Label '性能黑匣子'
            }
        } else {
            Remove-Item -LiteralPath $PerfPidPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($perfAlreadyRunning) {
        Write-Host "[运维] 性能黑匣子已在运行，PID=$oldPid"
    } else {
        $perfLogPath = Join-Path $Root "logs\perf-sampler.child.log"
        $perfCommand = @"
Set-Location -LiteralPath '$Root'
try {
  & '$PerfSamplerPath' -IntervalSeconds 60 *>> '$perfLogPath'
} catch {
  Add-Content -LiteralPath '$perfLogPath' -Value (`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' 启动器严重错误：' + `$_.Exception.Message) -Encoding UTF8
  throw
}
"@
        $perfEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($perfCommand))
        $perfProc = Start-Process powershell.exe `
            -WorkingDirectory $Root `
            -WindowStyle Hidden `
            -PassThru `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $perfEncoded)
        # perf-sampler 自己也会写 PID；这里先占位，Confirm 以脚本自写为准时再探一次
        Set-Content -LiteralPath $PerfPidPath -Value $perfProc.Id -Encoding ASCII
        Write-Host "[运维] 性能黑匣子已启动，PID=$($perfProc.Id)"
        Confirm-StartedProcess -PidFile $PerfPidPath -Label '性能黑匣子'
    }
} else {
    Write-Host "[运维] 未找到 tools\perf-sampler.ps1，已跳过性能黑匣子。" -ForegroundColor Yellow
}

# --- 扫地僧（定时 RCON 清掉落物，不碰 MC 进程）---
$itemSweeperEnabled = $false
try {
    if ($OpsConfig.itemSweeper -and $null -ne $OpsConfig.itemSweeper.enabled) {
        $itemSweeperEnabled = [bool]$OpsConfig.itemSweeper.enabled
    }
} catch { }
if ($itemSweeperEnabled -and (Test-Path -LiteralPath $ItemSweeperPath -PathType Leaf)) {
    $sweepAlreadyRunning = $false
    if (Test-Path -LiteralPath $ItemSweeperPidPath) {
        $oldPidText = Get-Content -LiteralPath $ItemSweeperPidPath -Raw -ErrorAction SilentlyContinue
        $oldPid = 0
        if ([int]::TryParse($oldPidText.Trim(), [ref]$oldPid) -and (Test-ProcessAlive -PidValue $oldPid)) {
            if (Is-TrackedProcessCurrent -PidFile $ItemSweeperPidPath -WatchedFiles @($ItemSweeperPath, $ConfigPath) -OldPid $oldPid) {
                $sweepAlreadyRunning = $true
            } else {
                Write-Host "[运维] 扫地僧脚本/配置已更新，正在重启 PID=$oldPid"
                Stop-TrackedProcess -PidFile $ItemSweeperPidPath -Label '扫地僧'
            }
        } else {
            Remove-Item -LiteralPath $ItemSweeperPidPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($sweepAlreadyRunning) {
        Write-Host "[运维] 扫地僧已在运行，PID=$oldPid"
    } else {
        $sweepLogPath = Join-Path $Root "logs\item-sweeper.child.log"
        $sweepCommand = @"
Set-Location -LiteralPath '$Root'
try {
  & '$ItemSweeperPath' -ConfigPath '$ConfigPath' *>> '$sweepLogPath'
} catch {
  Add-Content -LiteralPath '$sweepLogPath' -Value (`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' 启动器严重错误：' + `$_.Exception.Message) -Encoding UTF8
  throw
}
"@
        $sweepEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sweepCommand))
        $sweepProc = Start-Process powershell.exe `
            -WorkingDirectory $Root `
            -WindowStyle Hidden `
            -PassThru `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $sweepEncoded)
        Set-Content -LiteralPath $ItemSweeperPidPath -Value $sweepProc.Id -Encoding ASCII
        Write-Host "[运维] 扫地僧已启动，PID=$($sweepProc.Id)"
        Confirm-StartedProcess -PidFile $ItemSweeperPidPath -Label '扫地僧'
    }
} elseif (-not $itemSweeperEnabled) {
    Write-Host "[运维] itemSweeper.enabled=false，已跳过扫地僧。"
} else {
    Write-Host "[运维] 未找到 tools\item-sweeper.ps1，已跳过扫地僧。" -ForegroundColor Yellow
}

$java = Resolve-Java17
$javac = Resolve-Javac17
$classesDir = Join-Path $Root "tmp\java-classes"

$consoleAlreadyRunning = $false
if (Test-Path -LiteralPath $ConsolePidPath) {
    $oldPidText = Get-Content -LiteralPath $ConsolePidPath -Raw -ErrorAction SilentlyContinue
    $oldPid = 0
    if ([int]::TryParse($oldPidText.Trim(), [ref]$oldPid) -and (Test-ProcessAlive -PidValue $oldPid)) {
        if (Is-TrackedProcessCurrent -PidFile $ConsolePidPath -WatchedFiles @($ConsoleBridgePath, $ConfigPath) -OldPid $oldPid) {
            $consoleAlreadyRunning = $true
        } else {
            Write-Host "[运维] Discord 频道反控桥脚本或配置已更新，正在重启 PID=$oldPid"
            Stop-TrackedProcess -PidFile $ConsolePidPath -Label 'Discord 频道反控桥'
        }
    } else {
        Remove-Item -LiteralPath $ConsolePidPath -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path -LiteralPath $ConsoleBridgePath -PathType Leaf)) {
    # 公开包不含 Discord 频道反控组件（国内 QQ 方案即可），缺文件时静默跳过，不影响 QQ 桥和备份调度
    Write-Host "[运维] 未找到 tools\DiscordConsoleBridge.java（公开包不含 Discord 频道反控组件），已跳过。"
} elseif ($consoleAlreadyRunning) {
    Write-Host "[运维] Discord 频道反控桥已在运行，PID=$oldPid"
} else {
    $java = Resolve-Java17
    $javac = Resolve-Javac17
    $classesDir = Join-Path $Root "tmp\java-classes"
    New-Item -ItemType Directory -Force $classesDir | Out-Null
    if (Test-JavaCompileNeeded -SourcePath $ConsoleBridgePath -ClassesDir $classesDir) {
        & $javac -encoding UTF-8 -d $classesDir $ConsoleBridgePath
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[运维] Discord 频道反控桥编译失败。"
            if (-not $NoPause) { pause }
            return
        }
    } else {
        Write-Host "[运维] Discord 频道反控桥源码未变，复用已编译类。"
    }
    $consoleProc = Start-Process -FilePath $java `
        -WorkingDirectory $Root `
        -WindowStyle Hidden `
        -PassThru `
        -ArgumentList @("-Dfile.encoding=UTF-8", "-cp", "`"$classesDir`"", "DiscordConsoleBridge", "`"$ConfigPath`"")
    Set-Content -LiteralPath $ConsolePidPath -Value $consoleProc.Id -Encoding ASCII
    Write-Host "[运维] Discord 频道反控桥已启动，PID=$($consoleProc.Id)"
    Confirm-StartedProcess -PidFile $ConsolePidPath -Label 'Discord 频道反控桥'
}

# --- QQ 控制桥 ---
if ($OpsConfig.qq -and $OpsConfig.qq.enabled) {
    $qqConsoleAlreadyRunning = $false
    # 源码热更新只静默这一次；源码未变的正常冷启动/重启仍保留群内上线提示。
    # 先看生产 class，可覆盖 -Restart 已经移除旧 PID 的情形。
    $qqExistingClass = Join-Path $Root "tmp\java-classes\QQConsoleBridge.class"
    $qqQuietMaintenanceStart = (Test-Path -LiteralPath $qqExistingClass -PathType Leaf) -and
        ((Get-Item -LiteralPath $QQConsoleBridgePath).LastWriteTimeUtc -gt
            (Get-Item -LiteralPath $qqExistingClass).LastWriteTimeUtc)
    if (Test-Path -LiteralPath $QQConsolePidPath) {
        $oldPidText = Get-Content -LiteralPath $QQConsolePidPath -Raw -ErrorAction SilentlyContinue
        $oldPid = 0
        if ([int]::TryParse($oldPidText.Trim(), [ref]$oldPid) -and (Test-ProcessAlive -PidValue $oldPid)) {
            if (Is-TrackedProcessCurrent -PidFile $QQConsolePidPath -WatchedFiles @($QQConsoleBridgePath, $ConfigPath) -OldPid $oldPid) {
                $qqConsoleAlreadyRunning = $true
            } else {
                Write-Host "[运维] QQ 群反控桥已过期，正在重启 PID=$oldPid"
                $qqQuietMaintenanceStart = $true
                Stop-TrackedProcess -PidFile $QQConsolePidPath -Label 'QQ 群反控桥'
            }
        } else {
            Remove-Item -LiteralPath $QQConsolePidPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($qqConsoleAlreadyRunning) {
        Write-Host "[运维] QQ 群反控桥已在运行，PID=$oldPid"
    } else {
        $java = Resolve-Java17
        $javac = Resolve-Javac17
        $classesDir = Join-Path $Root "tmp\java-classes"
        New-Item -ItemType Directory -Force $classesDir | Out-Null
        $qqCompileOk = $true
        if (Test-JavaCompileNeeded -SourcePath $QQConsoleBridgePath -ClassesDir $classesDir) {
            & $javac -encoding UTF-8 -d $classesDir $QQConsoleBridgePath
            if ($LASTEXITCODE -ne 0) { $qqCompileOk = $false }
        } else {
            Write-Host "[运维] QQ 群反控桥源码未变，复用已编译类。"
        }
        if (-not $qqCompileOk) {
            Write-Host "[运维] QQ 群反控桥编译失败，请确认 JDK 可用。"
        } else {
            $qqStartArgs = @("-Dfile.encoding=UTF-8")
            if ($qqQuietMaintenanceStart) {
                $qqStartArgs += "-Dqq.quietStart=true"
            }
            $qqStartArgs += @("-cp", "`"$classesDir`"", "QQConsoleBridge", "`"$ConfigPath`"")
            $qqConsoleProc = Start-Process -FilePath $java `
                -WorkingDirectory $Root `
                -WindowStyle Hidden `
                -PassThru `
                -ArgumentList $qqStartArgs
            Set-Content -LiteralPath $QQConsolePidPath -Value $qqConsoleProc.Id -Encoding ASCII
            Write-Host "[运维] QQ 群反控桥已启动，PID=$($qqConsoleProc.Id)"
            Confirm-StartedProcess -PidFile $QQConsolePidPath -Label 'QQ 群反控桥'
        }
    }
}

# --- 本机图床（已在听则跳过，不抢用户自己开的窗口）---
$ImageHostStarter = Join-Path $Root 'tools\start-image-host.ps1'
if ($OpsConfig.imageHost -and $OpsConfig.imageHost.enabled -and (Test-Path -LiteralPath $ImageHostStarter -PathType Leaf)) {
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ImageHostStarter -NoPause
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Host "[运维] 图床启动器返回 $LASTEXITCODE，QQ 转图床会失败直到图床窗口重新打开。" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[运维] 图床启动器异常：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- QQ 群模组发布事务管理器 ---
# QQConsoleBridge 只负责把受信 group_upload 写入 inbox；真正的下载、校验、双端原子替换、
# 玩家发布和回滚由独立 Python 进程负责。服务端是否停服/起服由 modRelease.manageServerLifecycle 决定。
if ($OpsConfig.modRelease -and $OpsConfig.modRelease.enabled -and (Test-Path -LiteralPath $ModReleaseStarterPath -PathType Leaf)) {
    $managerAlreadyRunning = $false
    if (Test-Path -LiteralPath $ModReleasePidPath) {
        $oldPidText = Get-Content -LiteralPath $ModReleasePidPath -Raw -ErrorAction SilentlyContinue
        $oldPid = 0
        if ([int]::TryParse($oldPidText.Trim(), [ref]$oldPid) -and (Test-ProcessAlive -PidValue $oldPid)) {
            if (Is-TrackedProcessCurrent -PidFile $ModReleasePidPath -WatchedFiles @($ModReleaseStarterPath, $ConfigPath, (Join-Path $Root 'tools\mod-release-manager.py')) -OldPid $oldPid) {
                $managerAlreadyRunning = $true
            } else {
                Write-Host "[运维] 模组发布管理器已过期，正在重启 PID=$oldPid"
                Stop-TrackedProcess -PidFile $ModReleasePidPath -Label '模组发布管理器'
            }
        } else {
            Remove-Item -LiteralPath $ModReleasePidPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($managerAlreadyRunning) {
        Write-Host "[运维] 模组发布管理器已在运行，PID=$oldPid"
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ModReleaseStarterPath
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $ModReleasePidPath) {
            Write-Host "[运维] 模组发布管理器已启动。"
            Confirm-StartedProcess -PidFile $ModReleasePidPath -Label '模组发布管理器'
        } else {
            Write-Host "[运维] 模组发布管理器没有写入 PID，可能未找到 Python。" -ForegroundColor Yellow
        }
    }
}

# --- 运维自愈看门狗（监控挂了自动 start-ops 补起，不碰 Minecraft）---
if (Test-Path -LiteralPath $OpsSupervisorPath -PathType Leaf) {
    $supAlready = $false
    if (Test-Path -LiteralPath $OpsSupervisorPidPath) {
        $oldPidText = Get-Content -LiteralPath $OpsSupervisorPidPath -Raw -ErrorAction SilentlyContinue
        $oldPid = 0
        if ([int]::TryParse($oldPidText.Trim(), [ref]$oldPid) -and (Test-ProcessAlive -PidValue $oldPid)) {
            if (Is-TrackedProcessCurrent -PidFile $OpsSupervisorPidPath -WatchedFiles @($OpsSupervisorPath) -OldPid $oldPid) {
                $supAlready = $true
            } else {
                Stop-TrackedProcess -PidFile $OpsSupervisorPidPath -Label '运维自愈看门狗'
            }
        } else {
            Remove-Item -LiteralPath $OpsSupervisorPidPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($supAlready) {
        Write-Host "[运维] 运维自愈看门狗已在运行，PID=$oldPid"
    } else {
        $supLog = Join-Path $Root "logs\ops-supervisor.child.log"
        $supCommand = @"
Set-Location -LiteralPath '$Root'
try {
  & '$OpsSupervisorPath' -IntervalSeconds 60 *>> '$supLog'
} catch {
  Add-Content -LiteralPath '$supLog' -Value (`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' 启动器严重错误：' + `$_.Exception.Message) -Encoding UTF8
  throw
}
"@
        $supEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($supCommand))
        $supProc = Start-Process powershell.exe `
            -WorkingDirectory $Root `
            -WindowStyle Hidden `
            -PassThru `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $supEncoded)
        Set-Content -LiteralPath $OpsSupervisorPidPath -Value $supProc.Id -Encoding ASCII
        Write-Host "[运维] 运维自愈看门狗已启动，PID=$($supProc.Id)"
        Confirm-StartedProcess -PidFile $OpsSupervisorPidPath -Label '运维自愈看门狗'
    }
}

if ($script:StartFailures.Count -gt 0) {
    Write-Host ("[运维] 部分运维组件启动后退出：{0}" -f ($script:StartFailures -join '，')) -ForegroundColor Yellow
    exit 1
}

if (-not $NoPause) {
    pause
}
