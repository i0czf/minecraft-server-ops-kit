param(
    [string]$Java = "java",
    [string]$Memory = "4G",
    [string]$ServerJar = "",
    [string]$StartCommand = "",
    [switch]$NoPause,
    [switch]$NoWatchdog,
    [switch]$SkipOpsMonitor,
    [switch]$StopOpsMonitorOnExit,
    [switch]$RestartOnCleanExit,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = 'Minecraft 服务端控制台 —— 输入 stop 安全停服；请勿直接关闭窗口（会强杀服务端）' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

function Write-WrapperLog {
    param([string]$Message)
    $dir = Join-Path $Root "logs"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $line = "[{0:yyyy/MM/dd} WRAP {0:HH:mm:ss.ff}] {1}" -f (Get-Date), $Message
    Add-Content -LiteralPath (Join-Path $dir "server-wrapper.log") -Value $line -Encoding UTF8
}

# world\session.lock 守护：MC 用它独占世界目录，服务端正常退出会释放。
# 若上一个 JVM 卡死/僵尸没退干净仍握着锁，此时再拉起一个新 JVM，它抢不到锁会立刻崩，
# 看门狗见崩溃又 10 秒后重来 —— 变成无限崩溃循环；更坏的情况是两个进程同时写一个世界导致存档损坏。
# 所以启动前和 Java 退出后都探一次锁：拿得到=没人占，拿不到=还有进程握着，别启动/别重启。
# 输出的日志措辞与 discord-watch.ps1 的 Format-WrapperLogLine 约定一致，通知才会发出来。
function Test-GamePortOpen {
    $port = 25565
    $props = Join-Path $Root 'server.properties'
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($props)) {
            if ($line -match '^\s*server-port\s*=\s*(\d+)') {
                $port = [int]$matches[1]
                break
            }
        }
    } catch {}
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(400)
        if ($ok -and $c.Connected) { $c.Close(); return $true }
        try { $c.Close() } catch {}
        return $false
    } catch {
        return $false
    }
}

function Test-WorldSessionLocked {
    $lock = Join-Path $Root 'world\session.lock'
    if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { return $false }
    try {
        # 能以独占方式打开 = 没有别的进程持有它
        $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $fs.Dispose()
        return $false
    } catch [System.IO.IOException] {
        return $true
    } catch {
        # 权限等其它异常：不误判为被占用，放行交给 MC 自己处理
        return $false
    }
}

function Test-ModReleaseHold {
    $hold = Join-Path $Root 'tmp\mod-release\deploy.hold'
    return (Test-Path -LiteralPath $hold -PathType Leaf)
}

function Get-RelativeToRoot([string]$Path) {
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $Root $Path)) }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($rootFull.Length + 1)
    }
    return $full
}

# ---------- Java 自动匹配 ----------
# MC 与 Java 的硬性对应：<=1.16 → 8；1.17~1.20.4 → 17；>=1.20.5（含 1.21+）→ 21。
# PATH 上的 java 版本不对时服务端会秒退（Unsupported major.minor version），并被看门狗拖进重启循环，
# 所以启动前先按本服版本挑对 Java；找不到就中文提示下载并直接退出，不进循环。

function Get-DetectedMcVersion {
    $forgeRoot = Join-Path $Root 'libraries\net\minecraftforge\forge'
    if (Test-Path -LiteralPath $forgeRoot -PathType Container) {
        $d = Get-ChildItem -LiteralPath $forgeRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d -and $d.Name -match '^(?<mc>[0-9]+(\.[0-9]+){1,2})-') { return $matches.mc }
    }
    $neoRoot = Join-Path $Root 'libraries\net\neoforged\neoforge'
    if (Test-Path -LiteralPath $neoRoot -PathType Container) {
        $d = Get-ChildItem -LiteralPath $neoRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d -and $d.Name -match '^(?<a>\d+)\.(?<b>\d+)\.(?<c>\d+)') {
            $a = [int]$matches.a; $b = [int]$matches.b; $c = [int]$matches.c
            if ($a -ge 26) {
                # 26.x 新纪年（2026 起）：NeoForge = MC版本.构建号（26.1.2.78 → MC 26.1.2；26.2.0.x → MC 26.2）
                if ($c -eq 0) { return ('{0}.{1}' -f $a, $b) }
                return ('{0}.{1}.{2}' -f $a, $b, $c)
            }
            # 1.x 时代：前两段对应 MC（21.1.x → 1.21.1；21.0.x → 1.21）
            if ($b -eq 0) { return ('1.' + $a) }
            return ('1.{0}.{1}' -f $a, $b)
        }
    }
    $packPath = Join-Path $Root 'tools\portable-pack.json'
    if (Test-Path -LiteralPath $packPath -PathType Leaf) {
        try {
            $pack = Get-Content -LiteralPath $packPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $mc = ([string]$pack.minecraftVersion).Trim()
            if ($mc -match '^[0-9]+(\.[0-9]+){1,2}$') { return $mc }
        } catch { }
    }
    return ''
}

function Get-RequiredJavaMajor([string]$Mc) {
    if ($Mc -notmatch '^(\d+)\.(\d+)(?:\.(\d+))?$') { return 0 }
    # 2026 起 Mojang 改用新纪年版本号（26.1.1 这类，首段不再是 1）：官方版本 JSON 标注要求 Java 25。
    # 不加这条会掉进下面按 minor 判断的老映射，把 26.x 错判成 Java 8。
    if ([int]$matches[1] -ne 1) { return 25 }
    $minor = [int]$matches[2]
    $patch = 0
    if ($matches[3]) { $patch = [int]$matches[3] }
    if ($minor -ge 21) { return 21 }
    if ($minor -eq 20 -and $patch -ge 5) { return 21 }
    if ($minor -ge 17) { return 17 }
    return 8
}

function Get-JavaMajor([string]$Exe) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = '-version'
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $txt = $proc.StandardError.ReadToEnd() + $proc.StandardOutput.ReadToEnd()
        [void]$proc.WaitForExit(10000)
        if ($txt -match 'version\s+"(\d+)(?:\.(\d+))?') {
            $maj = [int]$matches[1]
            if ($maj -eq 1 -and $matches[2]) { $maj = [int]$matches[2] } # 1.8.0_xxx → 8
            return $maj
        }
    } catch { }
    return 0
}

function Find-JavaCandidates {
    $list = New-Object System.Collections.Generic.List[string]
    function Add-Cand([string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        $full = [System.IO.Path]::GetFullPath($Path)
        if (-not ($list -contains $full)) { [void]$list.Add($full) }
    }
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { Add-Cand $cmd.Source }
    if ($env:JAVA_HOME) { Add-Cand (Join-Path $env:JAVA_HOME 'bin\java.exe') }
    foreach ($base in @(
        (Join-Path $env:ProgramFiles 'Java'),
        (Join-Path $env:ProgramFiles 'Eclipse Adoptium'),
        (Join-Path $env:ProgramFiles 'Microsoft'),
        (Join-Path $env:ProgramFiles 'Zulu'),
        (Join-Path $env:ProgramFiles 'Amazon Corretto'),
        (Join-Path $env:ProgramFiles 'BellSoft'),
        (Join-Path ${env:ProgramFiles(x86)} 'Java')
    )) {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Add-Cand (Join-Path $_.FullName 'bin\java.exe')
        }
    }
    # 启动器下载的运行时（官方启动器 / HMCL / PCL——腐竹机器上往往只有这里才有 Java 21）
    foreach ($runtimeBase in @(
        (Join-Path $env:APPDATA '.minecraft\runtime'),
        (Join-Path $env:APPDATA '.hmcl\java'),
        (Join-Path $env:ProgramData 'PCL\Java'),
        (Join-Path $env:LOCALAPPDATA 'PCL\Java')
    )) {
        if (-not (Test-Path -LiteralPath $runtimeBase -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $runtimeBase -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -ieq 'bin' } |
            ForEach-Object { Add-Cand $_.FullName }
    }
    return @($list)
}

function Resolve-JavaForServer([string]$Requested) {
    $mc = Get-DetectedMcVersion
    $required = Get-RequiredJavaMajor $mc
    if ($Requested -and $Requested -ne 'java') {
        # 用户显式指定的 Java 永远尊重，只做版本提醒
        if ($required -gt 0) {
            $maj = Get-JavaMajor $Requested
            if ($maj -gt 0 -and $maj -lt $required) {
                Write-Host "[便携] 警告：指定的 Java 是 $maj，而 Minecraft $mc 需要 Java $required，可能无法启动。" -ForegroundColor Yellow
            }
        }
        return $Requested
    }
    if ($required -le 0) { return $Requested } # 识别不出版本需求，维持默认行为

    $exact = $null
    $higher = $null; $higherMaj = 0
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($cand in (Find-JavaCandidates)) {
        $maj = Get-JavaMajor $cand
        if ($maj -le 0) { continue }
        [void]$seen.Add("Java $maj = $cand")
        if ($maj -eq $required -and -not $exact) { $exact = $cand }
        elseif ($maj -gt $required -and (($higherMaj -eq 0) -or ($maj -lt $higherMaj))) { $higher = $cand; $higherMaj = $maj }
    }
    if ($exact) {
        Write-Host "[便携] Minecraft $mc 需要 Java $required，已自动选择：$exact" -ForegroundColor Green
        return $exact
    }
    if ($higher) {
        Write-Host "[便携] Minecraft $mc 需要 Java $required，本机没有该版本，改用更高的 Java ${higherMaj}：$higher" -ForegroundColor Yellow
        Write-Host "[便携] 高版本 Java 大多兼容；如果启动失败，请安装 Java ${required}：https://adoptium.net/zh-CN/temurin/releases/?version=$required" -ForegroundColor Yellow
        return $higher
    }
    Write-Host ''
    Write-Host "[便携] 无法启动：Minecraft $mc 需要 Java $required，但本机没有找到可用的 Java $required。" -ForegroundColor Red
    if ($seen.Count -gt 0) {
        Write-Host '本机已找到的 Java：' -ForegroundColor Yellow
        foreach ($s in $seen) { Write-Host ("  " + $s) -ForegroundColor Yellow }
    } else {
        Write-Host '本机没有找到任何 Java。' -ForegroundColor Yellow
    }
    Write-Host "请安装 Java $required 后重试（推荐 Adoptium Temurin，中文页面）：" -ForegroundColor Yellow
    Write-Host "  https://adoptium.net/zh-CN/temurin/releases/?version=$required" -ForegroundColor Cyan
    Write-Host '安装后无需改任何配置，重新点「启动服务端」会自动识别。' -ForegroundColor Yellow
    if (-not $NoPause) { pause }
    exit 1
}

function Resolve-ArgFilePlan {
    # Forge 与 NeoForge 的现代安装方式都不留根目录 jar，只留 libraries 里的 win_args.txt。
    foreach ($spec in @(
        @{ Path = 'libraries\net\minecraftforge\forge'; Label = 'Forge' },
        @{ Path = 'libraries\net\neoforged\neoforge';   Label = 'NeoForge' }
    )) {
        $loaderRoot = Join-Path $Root $spec.Path
        if (-not (Test-Path -LiteralPath $loaderRoot -PathType Container)) { continue }
        $loaderDir = Get-ChildItem -LiteralPath $loaderRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $loaderDir) { continue }
        $winArgs = Join-Path $loaderDir.FullName 'win_args.txt'
        if (-not (Test-Path -LiteralPath $winArgs -PathType Leaf)) { continue }

        $args = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath (Join-Path $Root 'user_jvm_args.txt') -PathType Leaf) { $args.Add('@user_jvm_args.txt') | Out-Null }
        $args.Add('@' + (Get-RelativeToRoot $winArgs)) | Out-Null
        $args.Add('nogui') | Out-Null
        return [pscustomobject]@{
            Mode = 'JavaArgs'
            Description = "$($spec.Label) argfile $((Split-Path -Leaf $loaderDir.FullName))"
            Args = @($args.ToArray())
        }
    }
    return $null
}

function Resolve-LaunchPlan {
    if (-not [string]::IsNullOrWhiteSpace($StartCommand)) {
        return [pscustomobject]@{ Mode = 'Command'; Description = $StartCommand; Command = $StartCommand }
    }

    if (-not [string]::IsNullOrWhiteSpace($ServerJar)) {
        $jarPath = if ([System.IO.Path]::IsPathRooted($ServerJar)) { $ServerJar } else { Join-Path $Root $ServerJar }
        if (Test-Path -LiteralPath $jarPath -PathType Leaf) {
            return [pscustomobject]@{ Mode = 'Jar'; Description = (Get-RelativeToRoot $jarPath); Jar = $jarPath }
        }
        throw "未找到服务端 jar：$ServerJar"
    }

    foreach ($candidate in @('fabric-server-launch.jar', 'forge-server-launch.jar', 'server.jar')) {
        $path = Join-Path $Root $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return [pscustomobject]@{ Mode = 'Jar'; Description = $candidate; Jar = $path }
        }
    }

    $argFilePlan = Resolve-ArgFilePlan
    if ($argFilePlan) { return $argFilePlan }

    $jar = Get-ChildItem -LiteralPath $Root -File -Filter '*.jar' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'installer|client|sources|javadoc' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($jar) { return [pscustomobject]@{ Mode = 'Jar'; Description = $jar.Name; Jar = $jar.FullName } }

    $runBat = Join-Path $Root 'run.bat'
    if (Test-Path -LiteralPath $runBat -PathType Leaf) {
        return [pscustomobject]@{ Mode = 'Command'; Description = 'run.bat nogui'; Command = 'call run.bat nogui' }
    }

    throw "未找到可启动的服务端。需要 server.jar / fabric-server-launch.jar / Forge 或 NeoForge win_args.txt / run.bat 之一。"
}

function Start-OpsMonitor {
    if ($SkipOpsMonitor) { return }
    $ops = Join-Path $Root 'tools\start-ops-monitor.ps1'
    $cfg = Join-Path $Root 'tools\ops-config.json'
    if (-not (Test-Path -LiteralPath $ops -PathType Leaf)) { Write-Host "[便携] 未找到运维监控脚本，已跳过。" -ForegroundColor Yellow; return }
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { Write-Host "[便携] 未找到 tools\ops-config.json，已跳过运维监控。" -ForegroundColor Yellow; return }
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ops -NoPause } catch { Write-Host "[便携] 运维监控启动失败：$($_.Exception.Message)" -ForegroundColor Yellow }
}

function Stop-OpsMonitor {
    if (-not $StopOpsMonitorOnExit) { return }
    $stop = Join-Path $Root 'tools\stop-ops-monitor.ps1'
    if (-not (Test-Path -LiteralPath $stop -PathType Leaf)) { Write-Host "[便携] 未找到运维停止脚本，已跳过。" -ForegroundColor Yellow; return }
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stop -NoPause } catch { Write-Host "[便携] 运维监控停止失败：$($_.Exception.Message)" -ForegroundColor Yellow }
}

$plan = Resolve-LaunchPlan
$JavaExe = $Java
if ($plan.Mode -ne 'Command') {
    # run.bat 模式用它自己的 java，无法代选；Jar/argfile 模式按本服版本自动匹配
    $JavaExe = Resolve-JavaForServer -Requested $Java
}
if ($DryRun) {
    Write-Host "[便携] 根目录：$Root"
    Write-Host "[便携] 启动模式：$($plan.Mode)"
    Write-Host "[便携] 启动目标：$($plan.Description)"
    if ($plan.Mode -ne 'Command') { Write-Host "[便携] 使用 Java：$JavaExe" }
    if ($plan.Mode -eq 'JavaArgs') { Write-Host ("[便携] Java 参数：" + (($plan.Args) -join ' ')) }
    exit 0
}

Start-OpsMonitor
$code = 0
do {
    if (Test-ModReleaseHold) {
        Write-WrapperLog "mod-release deployment hold present before start; waiting for release manager"
        break
    }
    if (Test-Path -LiteralPath (Join-Path $Root "maintenance.stop") -PathType Leaf) { Write-WrapperLog "maintenance.stop present before start; aborting watchdog loop"; break }
    if (Test-WorldSessionLocked) {
        if (Test-GamePortOpen) {
            Write-WrapperLog "world\session.lock is locked and game port is listening; skipping duplicate start"
            Write-Host "[便携] 服务端已在运行，跳过重复启动。" -ForegroundColor Yellow
            $code = 0
            break
        }
        Write-WrapperLog "world\session.lock is locked before start; aborting"
        Write-Host "[便携] world\session.lock 仍被占用：可能上一个服务端进程没退干净。" -ForegroundColor Red
        Write-Host "[便携] 已中止启动，避免两个进程同时写同一个世界导致存档损坏。" -ForegroundColor Red
        Write-Host "[便携] 请在任务管理器结束残留的 java.exe 后重试。" -ForegroundColor Yellow
        $code = 1
        break
    }
    Write-WrapperLog "PortableKit server starting"
    Write-Host "[便携] 正在启动服务端：$($plan.Description)"
    switch ($plan.Mode) {
        'Jar' { & $JavaExe "-Xms$Memory" "-Xmx$Memory" -jar $plan.Jar nogui }
        'JavaArgs' { & $JavaExe @($plan.Args) }
        'Command' { & cmd.exe /d /c $plan.Command }
        default { throw "不支持的启动模式：$($plan.Mode)" }
    }
    $code = $LASTEXITCODE
    Write-WrapperLog "Java exited with code $code"
    if ($NoWatchdog) { break }
    if (Test-ModReleaseHold) { Write-WrapperLog "mod-release deployment hold present after Java exit; not restarting"; break }
    if ($code -eq 0 -and -not $RestartOnCleanExit) { Write-WrapperLog "Java exited cleanly; not restarting"; break }
    if (Test-Path -LiteralPath (Join-Path $Root "maintenance.stop") -PathType Leaf) { Write-WrapperLog "maintenance.stop present after Java exit; not restarting"; break }
    # Java 说自己退了，但锁还被握着 = 进程没真正结束（僵尸/卡在关闭流程）。
    # 此时重启必然抢不到世界锁而秒崩，只会陷入 10 秒一轮的崩溃循环，不如停下来交给人处理。
    # 给 3 秒宽限：正常退出时句柄释放可能比进程退出稍晚一点。
    if (Test-WorldSessionLocked) {
        Start-Sleep -Seconds 3
        if (Test-WorldSessionLocked) {
            Write-WrapperLog "world\session.lock is still locked after Java exit; not restarting"
            Write-Host "[便携] Java 已退出，但 world\session.lock 仍被占用，自动重启已停止。" -ForegroundColor Red
            Write-Host "[便携] 多半是残留的 java.exe 没结束干净，请在任务管理器里结束它再手动启动。" -ForegroundColor Yellow
            break
        }
    }
    Write-WrapperLog "Restarting in 10 seconds"
    Write-Host "[便携] 服务端已退出，10 秒后自动重启。如需保持停服，请创建 maintenance.stop 文件。" -ForegroundColor Yellow
    Start-Sleep -Seconds 10
} while ($true)
Stop-OpsMonitor
if (-not $NoPause) { pause }
exit $code


