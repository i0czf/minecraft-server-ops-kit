param(
    [int]$SmokePort = 25567,
    [int]$BootTimeoutMinutes = 25,
    [switch]$AllowWithPlayers,
    [switch]$QqSummary,
    [switch]$Quiet
)

# 影子服试车间：用当前整合包在独立目录起服到 Done，验证「发版前能不能开起来」。
# 不碰线上 world/；不改线上 server.properties。默认无人在线才起服。

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$WorkRoot = Join-Path $Root ('tmp\shadow-smoke\' + $Stamp)
$ServerDir = Join-Path $WorkRoot 'smoke-server'
$LogPath = Join-Path $Root 'logs\shadow-smoke.log'
$LatestDir = Join-Path $Root 'tmp\shadow-smoke\latest'

function Write-SmokeLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $d = Split-Path -Parent $LogPath
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
    if (-not $Quiet) { try { Write-Host $line } catch { } }
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

function Stop-SmokePort([int]$Port) {
    try {
        @(Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue) | ForEach-Object {
            try { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue } catch { }
        }
    } catch { }
}

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$bootOk = $false
$bootSeconds = 0.0
$skipped = $false
$skipReason = ''

Write-SmokeLog ("start port=$SmokePort")
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

$pc = Get-LivePlayerCount
if ($pc -gt 0 -and -not $AllowWithPlayers) {
    $skipped = $true
    $skipReason = "players_online_$pc"
    $errors.Add("线上仍有 $pc 名玩家在线，已中止影子服起服（可加 -AllowWithPlayers 强制，不推荐）") | Out-Null
    Write-SmokeLog "abort players=$pc"
} elseif (-not (Test-PortFree $SmokePort)) {
    $errors.Add("端口 $SmokePort 已被占用") | Out-Null
} else {
    New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null

    # 共享重目录；不共享 config/bluemap（防抢端口）
    foreach ($d in @('libraries', 'mods', 'defaultconfigs', 'tacz', 'tlm_custom_pack', 'moonlight-global-datapacks', 'patchouli_books')) {
        $okj = New-DirJunction (Join-Path $ServerDir $d) (Join-Path $Root $d)
        if (-not $okj -and $d -in @('libraries', 'mods')) {
            $errors.Add("junction 失败: $d") | Out-Null
        }
    }

    # 最小 config：改语音端口
    $cfgDst = Join-Path $ServerDir 'config'
    New-Item -ItemType Directory -Path $cfgDst -Force | Out-Null
    try {
        $vc = Join-Path $Root 'config\voicechat'
        if (Test-Path $vc) {
            Copy-Item -LiteralPath $vc -Destination (Join-Path $cfgDst 'voicechat') -Recurse -Force
            $vcProps = Join-Path $cfgDst 'voicechat\voicechat-server.properties'
            if (Test-Path $vcProps) {
                $txt = Get-Content $vcProps -Raw
                $txt = $txt -replace '(?m)^port=\d+', ('port=' + (24454 + ($SmokePort % 100)))
                Set-Content -LiteralPath $vcProps -Value $txt -Encoding UTF8
            }
        }
    } catch { }

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

    # 新世界：不挂线上 world，让服务端生成空 world
    $props = New-Object System.Collections.Generic.List[string]
    $sp = Join-Path $Root 'server.properties'
    if (Test-Path $sp) {
        foreach ($line in [IO.File]::ReadAllLines($sp)) {
            if ($line -match '^\s*(server-port|query\.port|rcon\.port|enable-rcon|level-name|motd|max-players|online-mode|white-list|enforce-whitelist|level-seed|level-type)=') { continue }
            $props.Add($line) | Out-Null
        }
    }
    $props.Add("server-port=$SmokePort") | Out-Null
    $props.Add("query.port=$SmokePort") | Out-Null
    $props.Add('enable-rcon=false') | Out-Null
    $props.Add('level-name=world') | Out-Null
    $props.Add('motd=shadow-smoke workshop') | Out-Null
    $props.Add('max-players=1') | Out-Null
    $props.Add('online-mode=false') | Out-Null
    $props.Add('white-list=true') | Out-Null
    $props.Add('enforce-whitelist=true') | Out-Null
    $props.Add('level-type=minecraft:normal') | Out-Null
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

    if ($errors.Count -eq 0) {
        if ((-not (Test-Path $javaExe)) -and $javaExe -ne 'java') {
            $errors.Add('找不到 Java: ' + $javaExe) | Out-Null
        } elseif (-not $verName) {
            $errors.Add('找不到 NeoForge libraries') | Out-Null
        } else {
            $argStr = '@user_jvm_args.txt @libraries/net/neoforged/neoforge/' + $verName + '/win_args.txt nogui'
            $smokeLog = Join-Path $WorkRoot 'smoke-server-console.log'
            $smokeErr = Join-Path $WorkRoot 'smoke-server-console.err.log'
            if (Test-Path $smokeLog) { Remove-Item $smokeLog -Force -EA SilentlyContinue }
            if (Test-Path $smokeErr) { Remove-Item $smokeErr -Force -EA SilentlyContinue }

            Write-SmokeLog "starting shadow java port=$SmokePort"
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
                foreach ($logCandidate in @((Join-Path $ServerDir 'logs\latest.log'), $smokeLog)) {
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
                    if (Test-Path $smokeLog) {
                        try {
                            $all = [IO.File]::ReadAllText($smokeLog)
                            if ($all -match 'Done\s*\(') {
                                $done = $true
                                Write-SmokeLog 'Done found after exit'
                            }
                        } catch { }
                    }
                    if (-not $done) { Write-SmokeLog ("java exited " + $proc.ExitCode) }
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
                    Write-SmokeLog 'stopping shadow java'
                    try { $proc.Kill() } catch { }
                    Start-Sleep -Seconds 2
                }
            } catch { }
            Stop-SmokePort $SmokePort
            # 再扫一遍可能残留的 smoke 工作目录 java
            try {
                Get-CimInstance Win32_Process -Filter "Name='java.exe'" -EA SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine -like '*shadow-smoke*' } |
                    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } catch { } }
            } catch { }

            if (-not $done) { $errors.Add('起服未在超时内看到 Done') | Out-Null }
        }
    }
}

$ok = $bootOk -and ($errors.Count -eq 0)

$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('【影子服试车间】')
[void]$sb.AppendLine(('目标：当前整合包独立起服 · 端口 {0}' -f $SmokePort))
if ($skipped) {
    [void]$sb.AppendLine(('已跳过：{0}' -f $skipReason))
} elseif ($bootOk) {
    [void]$sb.AppendLine(('起服：成功 Done · {0}s' -f $bootSeconds))
} else {
    [void]$sb.AppendLine(('起服：失败/超时 · {0}s' -f $bootSeconds))
}
foreach ($e in $errors) { [void]$sb.AppendLine(('错误：' + $e)) }
foreach ($w in $warnings) { [void]$sb.AppendLine(('警告：' + $w)) }
[void]$sb.AppendLine($(if ($ok) { '结论：通过（发版前冒烟 OK）' } else { '结论：未通过' }))
[void]$sb.AppendLine(('目录：tmp\shadow-smoke\' + $Stamp))
$qqText = $sb.ToString().TrimEnd()

$meta = [ordered]@{
    stamp         = $Stamp
    ok            = $ok
    smokePort     = $SmokePort
    bootOk        = $bootOk
    bootSeconds   = $bootSeconds
    skipped       = $skipped
    skipReason    = $skipReason
    workRoot      = $WorkRoot
    livePlayers   = $pc
    errors        = @($errors)
    warnings      = @($warnings)
    generatedAt   = (Get-Date).ToString('o')
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
