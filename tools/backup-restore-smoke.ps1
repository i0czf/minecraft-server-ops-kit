param(
    [string]$ZipPath = '',
    [string]$ReuseWorldDir = '',
    [int]$SmokePort = 25566,
    [switch]$Boot,
    [int]$BootTimeoutMinutes = 25,
    [switch]$QqSummary,
    [switch]$Quiet
)

# 备份完整恢复冒烟：独立目录解压 + 可选影子服起服到 Done。
# 不碰线上 world/；不改线上 server.properties。

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$WorkRoot = Join-Path $Root ('tmp\backup-restore-smoke\' + $Stamp)
$WorldDir = Join-Path $WorkRoot 'world'
$ServerDir = Join-Path $WorkRoot 'smoke-server'
$LogPath = Join-Path $Root 'logs\backup-restore-smoke.log'
$LatestDir = Join-Path $Root 'tmp\backup-restore-smoke\latest'

function Write-SmokeLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $d = Split-Path -Parent $LogPath
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
    if (-not $Quiet) { try { Write-Host $line } catch { } }
}

function Format-Bytes([double]$B) {
    if ($B -ge 1GB) { return ('{0:N2} GiB' -f ($B / 1GB)) }
    if ($B -ge 1MB) { return ('{0:N1} MiB' -f ($B / 1MB)) }
    return ('{0:N0} KiB' -f ($B / 1KB))
}

function Get-LatestBackupZip {
    $dir = Join-Path $Root 'backups\world'
    if (-not (Test-Path $dir)) { return $null }
    return Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.zip' -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Test-PortFree([int]$Port) {
    try {
        foreach ($ep in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            if ($ep.Port -eq $Port) { return $false }
        }
    } catch { }
    return $true
}

function New-DirJunction([string]$Link, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Target)) { return $false }
    if (Test-Path -LiteralPath $Link) { return $true }
    $parent = Split-Path -Parent $Link
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'mklink', '/J', "`"$Link`"", "`"$Target`"") -Wait -PassThru -WindowStyle Hidden
    return ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $Link))
}

function Get-LivePlayerCount {
    try {
        $rcon = Join-Path $Root 'tools\rcon-command.ps1'
        if (-not (Test-Path $rcon)) { return -1 }
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rcon -Command 'list' 2>$null | Out-String
        if ($out -match '(?i)there are\s+(\d+)\s+of') { return [int]$matches[1] }
    } catch { }
    return -1
}

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$extractOk = $false
$levelDatOk = $false
$regionCount = 0
$extractBytes = 0L
$extractSeconds = 0.0
$bootRequested = [bool]$Boot
$bootOk = $false
$bootSkipped = $false
$bootReason = ''
$bootSeconds = 0.0
$doBoot = [bool]$Boot

Write-SmokeLog ("start boot=$Boot port=$SmokePort")
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

if ($ZipPath) {
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "备份不存在: $ZipPath" }
    $zipItem = Get-Item -LiteralPath $ZipPath
} else {
    $zipItem = Get-LatestBackupZip
    if (-not $zipItem) { throw '未找到 backups\world 下的 zip' }
}
Write-SmokeLog ("zip=" + $zipItem.Name + " " + (Format-Bytes $zipItem.Length))

$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root))
$need = [long]($zipItem.Length * 1.15)
if ($drive.AvailableFreeSpace -lt $need) {
    throw ("磁盘不足: 需要约 {0}, 剩余 {1}" -f (Format-Bytes $need), (Format-Bytes $drive.AvailableFreeSpace))
}

if ($doBoot) {
    $pc = Get-LivePlayerCount
    if ($pc -gt 0) {
        $warnings.Add("线上仍有 $pc 名玩家, 跳过起服仅解压") | Out-Null
        $doBoot = $false
        $bootSkipped = $true
        $bootReason = 'players_online'
    }
}

# extract or reuse
if (-not [string]::IsNullOrWhiteSpace($ReuseWorldDir) -and (Test-Path -LiteralPath $ReuseWorldDir -PathType Container)) {
    $WorldDir = (Resolve-Path -LiteralPath $ReuseWorldDir).Path
    Write-SmokeLog ("reuse world dir " + $WorldDir)
    $extractOk = $true
    $extractSeconds = 0
    $sum = (Get-ChildItem -LiteralPath $WorldDir -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($null -ne $sum) { $extractBytes = [long]$sum }
} else {
    New-Item -ItemType Directory -Path $WorldDir -Force | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-SmokeLog "extracting..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($zipItem.FullName, $WorldDir)
        $extractOk = $true
    } catch {
        Expand-Archive -LiteralPath $zipItem.FullName -DestinationPath $WorldDir -Force
        $extractOk = $true
    }
    $sw.Stop()
    $extractSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $sum = (Get-ChildItem -LiteralPath $WorldDir -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($null -ne $sum) { $extractBytes = [long]$sum }
    Write-SmokeLog ("extract done {0}s {1}" -f $extractSeconds, (Format-Bytes $extractBytes))
}

$levelDatOk = Test-Path (Join-Path $WorldDir 'level.dat')
$regionDir = Join-Path $WorldDir 'region'
if (Test-Path $regionDir) {
    $regionCount = @(Get-ChildItem $regionDir -Filter '*.mca' -File -EA SilentlyContinue).Count
}
if (-not $levelDatOk) { $errors.Add('解压后缺少 level.dat') | Out-Null }
if ($regionCount -le 0) { $warnings.Add('解压后无 region/*.mca') | Out-Null }

# boot
if ($doBoot -and $extractOk -and $levelDatOk) {
    if (-not (Test-PortFree $SmokePort)) {
        $errors.Add("端口 $SmokePort 已被占用") | Out-Null
    } else {
        New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null
        # 不 junction config/bluemap：避免与线上抢端口/状态；只共享 libraries/mods 与数据包
        foreach ($d in @('libraries', 'mods', 'defaultconfigs', 'tacz', 'tlm_custom_pack', 'moonlight-global-datapacks', 'patchouli_books')) {
            $okj = New-DirJunction (Join-Path $ServerDir $d) (Join-Path $Root $d)
            if (-not $okj -and $d -in @('libraries', 'mods')) {
                $errors.Add("junction 失败: $d") | Out-Null
            }
        }
        # 最小 config：从线上复制后去掉语音/蓝图端口冲突项（整目录复制过大则只建空目录）
        $cfgDst = Join-Path $ServerDir 'config'
        if (-not (Test-Path $cfgDst)) {
            New-Item -ItemType Directory -Path $cfgDst -Force | Out-Null
            $cfgSrc = Join-Path $Root 'config'
            if (Test-Path $cfgSrc) {
                # 用 junction 仍会抢端口；复制 voicechat 配置改端口
                try {
                    $vc = Join-Path $cfgSrc 'voicechat'
                    if (Test-Path $vc) {
                        Copy-Item -LiteralPath $vc -Destination (Join-Path $cfgDst 'voicechat') -Recurse -Force
                        $vcProps = Join-Path $cfgDst 'voicechat\voicechat-server.properties'
                        if (Test-Path $vcProps) {
                            $txt = Get-Content $vcProps -Raw
                            $txt = $txt -replace '(?m)^port=\d+', 'port=25454'
                            Set-Content -LiteralPath $vcProps -Value $txt -Encoding UTF8
                        }
                    }
                } catch { }
            }
        }
        if (-not (New-DirJunction (Join-Path $ServerDir 'world') $WorldDir)) {
            $errors.Add('无法挂载解压世界') | Out-Null
        }
        foreach ($f in @('user_jvm_args.txt', 'eula.txt', 'server-icon.png')) {
            $src = Join-Path $Root $f
            if (Test-Path $src) { Copy-Item $src (Join-Path $ServerDir $f) -Force }
        }
        $eulaPath = Join-Path $ServerDir 'eula.txt'
        if (-not (Test-Path $eulaPath)) {
            Set-Content $eulaPath 'eula=true' -Encoding ASCII
        } else {
            $e = (Get-Content $eulaPath -Raw) -replace 'eula=false', 'eula=true'
            Set-Content $eulaPath $e -Encoding ASCII
        }

        $props = New-Object System.Collections.Generic.List[string]
        $sp = Join-Path $Root 'server.properties'
        if (Test-Path $sp) {
            foreach ($line in [IO.File]::ReadAllLines($sp)) {
                if ($line -match '^\s*(server-port|query\.port|rcon\.port|enable-rcon|level-name|motd|max-players|online-mode|white-list|enforce-whitelist)=') { continue }
                $props.Add($line) | Out-Null
            }
        }
        $props.Add("server-port=$SmokePort") | Out-Null
        $props.Add("query.port=$SmokePort") | Out-Null
        $props.Add('enable-rcon=false') | Out-Null
        $props.Add('level-name=world') | Out-Null
        $props.Add('motd=backup-restore-smoke') | Out-Null
        $props.Add('max-players=1') | Out-Null
        $props.Add('online-mode=false') | Out-Null
        $props.Add('white-list=true') | Out-Null
        $props.Add('enforce-whitelist=true') | Out-Null
        [IO.File]::WriteAllLines((Join-Path $ServerDir 'server.properties'), $props.ToArray(), [Text.UTF8Encoding]::new($false))

        $javaExe = 'java'
        $runBat = Join-Path $Root 'run.bat'
        if (Test-Path $runBat) {
            $rb = Get-Content $runBat -Raw
            if ($rb -match '"([^"]+java\.exe)"') { $javaExe = $matches[1] }
        }
        $nfRoot = Join-Path $ServerDir 'libraries\net\neoforged\neoforge'
        $verName = $null
        if (Test-Path $nfRoot) {
            $verName = (Get-ChildItem $nfRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
        }
        if ((-not (Test-Path $javaExe)) -and $javaExe -ne 'java') {
            $errors.Add('找不到 Java') | Out-Null
        } elseif (-not $verName) {
            $errors.Add('找不到 NeoForge') | Out-Null
        } elseif ($errors.Count -eq 0) {
            $argStr = '@user_jvm_args.txt @libraries/net/neoforged/neoforge/' + $verName + '/win_args.txt nogui'
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $javaExe
            $psi.Arguments = $argStr
            $psi.WorkingDirectory = $ServerDir
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $smokeLog = Join-Path $WorkRoot 'smoke-server-console.log'
            $smokeErr = Join-Path $WorkRoot 'smoke-server-console.err.log'
            if (Test-Path $smokeLog) { Remove-Item $smokeLog -Force -EA SilentlyContinue }
            if (Test-Path $smokeErr) { Remove-Item $smokeErr -Force -EA SilentlyContinue }
            Write-SmokeLog "starting smoke java port=$SmokePort"
            # Start-Process 重定向避开中文路径下 cmd 转义问题
            $proc = Start-Process -FilePath $javaExe `
                -ArgumentList $argStr `
                -WorkingDirectory $ServerDir `
                -RedirectStandardOutput $smokeLog `
                -RedirectStandardError $smokeErr `
                -PassThru `
                -WindowStyle Hidden
            $bootSw = [Diagnostics.Stopwatch]::StartNew()
            $deadline = (Get-Date).AddMinutes([Math]::Max(5, $BootTimeoutMinutes))
            $done = $false
            $lastBeat = 0
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 3
                foreach ($logCandidate in @(
                        (Join-Path $ServerDir 'logs\latest.log'),
                        $smokeLog
                    )) {
                    if (-not (Test-Path -LiteralPath $logCandidate)) { continue }
                    try {
                        $fs = [IO.File]::Open($logCandidate, 'Open', 'Read', 'ReadWrite')
                        try {
                            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
                            $all = $sr.ReadToEnd()
                        } finally { $fs.Dispose() }
                        if ($all -match 'Done\s*\(' -or $all -match 'For help, type "help"') {
                            $done = $true
                            Write-SmokeLog ("Done detected in " + [IO.Path]::GetFileName($logCandidate))
                            break
                        }
                    } catch { }
                }
                if ($done) { break }
                if ($proc.HasExited) {
                    # 进程已退仍可能已 Done（上次误判场景）
                    if (Test-Path $smokeLog) {
                        try {
                            $all = [IO.File]::ReadAllText($smokeLog)
                            if ($all -match 'Done\s*\(') {
                                $done = $true
                                Write-SmokeLog 'Done found after exit in console log'
                            }
                        } catch { }
                    }
                    if (-not $done) { Write-SmokeLog ("java/cmd exited " + $proc.ExitCode) }
                    break
                }
                $sec = [int]$bootSw.Elapsed.TotalSeconds
                if ($sec - $lastBeat -ge 60) {
                    $lastBeat = $sec
                    Write-SmokeLog ("boot waiting ${sec}s")
                }
            }
            $bootSw.Stop()
            $bootSeconds = [math]::Round($bootSw.Elapsed.TotalSeconds, 1)
            $bootOk = $done
            try {
                if (-not $proc.HasExited) {
                    Write-SmokeLog 'stopping smoke java tree'
                    # kill java children of this smoke
                    Get-CimInstance Win32_Process -Filter "Name='java.exe'" -EA SilentlyContinue |
                        Where-Object { $_.CommandLine -and $_.CommandLine -like '*backup-restore-smoke*' -or ($_.CommandLine -like "*$SmokePort*" -and $_.CommandLine -like '*win_args.txt*') } |
                        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } catch { } }
                    try { $proc.Kill() } catch { }
                    Start-Sleep -Seconds 2
                }
            } catch { }
            # 兜底：按端口杀监听
            try {
                $conns = @(Get-NetTCPConnection -LocalPort $SmokePort -State Listen -EA SilentlyContinue)
                foreach ($c in $conns) {
                    try { Stop-Process -Id $c.OwningProcess -Force -EA SilentlyContinue } catch { }
                }
            } catch { }
            if (-not $done) { $errors.Add('起服未在超时内看到 Done') | Out-Null }
        }
    }
} elseif ($bootRequested -and -not $doBoot -and -not $bootSkipped) {
    $bootSkipped = $true
    $bootReason = 'extract_or_level_failed'
}

$baseOk = $extractOk -and $levelDatOk -and $regionCount -gt 0
if ($bootRequested -and -not $bootSkipped) {
    $ok = $baseOk -and $bootOk
} else {
    $ok = $baseOk
}

$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('【备份恢复冒烟】')
[void]$sb.AppendLine(('备份：{0}' -f $zipItem.Name))
[void]$sb.AppendLine(('大小：{0} · 解压 {1}s → {2}' -f (Format-Bytes $zipItem.Length), $extractSeconds, (Format-Bytes $extractBytes)))
[void]$sb.AppendLine(('世界：level.dat={0} · region={1}' -f $(if ($levelDatOk) { '有' } else { '无' }), $regionCount))
if ($bootRequested) {
    if ($bootSkipped) {
        [void]$sb.AppendLine(('起服：已跳过（{0}）' -f $bootReason))
    } elseif ($bootOk) {
        [void]$sb.AppendLine(('起服：成功 Done · {0}s · 端口 {1}' -f $bootSeconds, $SmokePort))
    } else {
        [void]$sb.AppendLine(('起服：失败/超时 · {0}s · 端口 {1}' -f $bootSeconds, $SmokePort))
    }
} else {
    [void]$sb.AppendLine('起服：未请求（仅解压）')
}
foreach ($e in $errors) { [void]$sb.AppendLine(('错误：' + $e)) }
foreach ($w in $warnings) { [void]$sb.AppendLine(('警告：' + $w)) }
[void]$sb.AppendLine($(if ($ok) { '结论：通过' } else { '结论：未通过' }))
[void]$sb.AppendLine(('目录：tmp\backup-restore-smoke\' + $Stamp))
$qqText = $sb.ToString().TrimEnd()

$meta = [ordered]@{
    stamp = $Stamp
    ok = $ok
    zip = $zipItem.FullName
    zipSize = $zipItem.Length
    extractOk = $extractOk
    levelDatOk = $levelDatOk
    regionCount = $regionCount
    extractBytes = $extractBytes
    extractSeconds = $extractSeconds
    bootRequested = $bootRequested
    bootOk = $bootOk
    bootSkipped = $bootSkipped
    bootReason = $bootReason
    bootSeconds = $bootSeconds
    smokePort = $SmokePort
    workRoot = $WorkRoot
    errors = @($errors)
    warnings = @($warnings)
    generatedAt = (Get-Date).ToString('o')
}

$enc = New-Object Text.UTF8Encoding $true
[IO.File]::WriteAllText((Join-Path $WorkRoot 'summary-qq.txt'), $qqText, $enc)
[IO.File]::WriteAllText((Join-Path $WorkRoot 'report.txt'), $qqText, $enc)
[IO.File]::WriteAllText((Join-Path $WorkRoot 'meta.json'), ($meta | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path $LatestDir -Force | Out-Null
Copy-Item (Join-Path $WorkRoot 'summary-qq.txt') (Join-Path $LatestDir 'summary-qq.txt') -Force
Copy-Item (Join-Path $WorkRoot 'meta.json') (Join-Path $LatestDir 'meta.json') -Force
Copy-Item (Join-Path $WorkRoot 'report.txt') (Join-Path $LatestDir 'report.txt') -Force

Write-SmokeLog ("done ok=$ok")
if ($QqSummary) { Write-Output $qqText }
elseif (-not $Quiet) {
    Write-Host $qqText
    Write-Host ('报告目录: ' + $WorkRoot) -ForegroundColor Cyan
}

if ($ok) { exit 0 } else { exit 1 }
