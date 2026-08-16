param(
    [string]$ZipPath = '',
    [int]$Count = 1,
    [switch]$Deep,
    [switch]$QqSummary,
    [switch]$Quiet,
    [switch]$Json
)

# 可验证备份：只读检查 zip 完整性与世界结构，不碰线上 world、不停服。
# - 默认：打开 zip、统计条目、确认 level.dat / region、抽样读取 level.dat
# - Deep：额外校验每个 entry 可读（大备份较慢）
# 入口：!验备份 / 一键 bat / discord-watch 定时 / 命令行

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Join-Path $Root ('tmp\backup-verify\' + $Stamp)
$LatestDir = Join-Path $Root 'tmp\backup-verify\latest'
$PendingDir = Join-Path $Root 'tmp\backup-verify\pending'
$LogPath = Join-Path $Root 'logs\backup-verify.log'

function Write-VerifyLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
    if (-not $Quiet -and -not $QqSummary) { try { Write-Host $line } catch { } }
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KiB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-BackupZips {
    $dir = Join-Path $Root 'backups\world'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.zip' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
}

function Test-OneBackupZip([string]$Path, [bool]$DoDeep) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $result = [ordered]@{
        path          = $Path
        name          = [IO.Path]::GetFileName($Path)
        sizeBytes     = 0L
        ok            = $false
        openOk        = $false
        hasLevelDat   = $false
        hasRegion     = $false
        regionCount   = 0
        playerdataCount = 0
        entryCount    = 0
        levelDatBytes = 0
        ageHours      = $null
        errors        = New-Object System.Collections.Generic.List[string]
        warnings      = New-Object System.Collections.Generic.List[string]
        deepChecked   = 0
        deepFailed    = 0
    }
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        $result.sizeBytes = [long]$fi.Length
        $result.ageHours = [math]::Round(((Get-Date) - $fi.LastWriteTime).TotalHours, 1)
    } catch {
        $result.errors.Add('无法读取文件：' + $_.Exception.Message) | Out-Null
        return $result
    }
    if ($result.sizeBytes -lt 1024) {
        $result.errors.Add('文件过小，不像完整世界备份') | Out-Null
        return $result
    }

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $result.openOk = $true
        $result.entryCount = $zip.Entries.Count
        $levelEntry = $null
        foreach ($e in $zip.Entries) {
            $n = $e.FullName.Replace('\', '/')
            if ($n -match '(^|/)level\.dat$') {
                $result.hasLevelDat = $true
                if ($null -eq $levelEntry) { $levelEntry = $e }
            }
            if ($n -match '(^|/)region/[^/]+\.mca$') {
                $result.hasRegion = $true
                $result.regionCount++
            }
            if ($n -match '(^|/)playerdata/[^/]+\.dat$') {
                $result.playerdataCount++
            }
        }
        if (-not $result.hasLevelDat) {
            $result.errors.Add('zip 内未找到 level.dat') | Out-Null
        }
        if (-not $result.hasRegion) {
            $result.warnings.Add('未找到 region/*.mca（可能是空世界或路径异常）') | Out-Null
        }
        # 抽样读取 level.dat 验证该条目可解压
        if ($null -ne $levelEntry) {
            try {
                $stream = $levelEntry.Open()
                try {
                    $buf = New-Object byte[] 8192
                    $total = 0L
                    while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $total += $read
                        if ($total -gt 50MB) { break }
                    }
                    $result.levelDatBytes = $total
                    if ($total -lt 16) {
                        $result.errors.Add('level.dat 解压后过短') | Out-Null
                    }
                } finally { $stream.Dispose() }
            } catch {
                $result.errors.Add('level.dat 读取失败：' + $_.Exception.Message) | Out-Null
            }
        }
        if ($DoDeep) {
            $i = 0
            foreach ($e in $zip.Entries) {
                if ($e.Length -eq 0 -and $e.FullName.EndsWith('/')) { continue }
                $i++
                try {
                    $s = $e.Open()
                    try {
                        $buf = New-Object byte[] 4096
                        [void]$s.Read($buf, 0, $buf.Length)
                        $result.deepChecked++
                    } finally { $s.Dispose() }
                } catch {
                    $result.deepFailed++
                    if ($result.errors.Count -lt 8) {
                        $result.errors.Add(('条目不可读：{0} ({1})' -f $e.FullName, $_.Exception.Message)) | Out-Null
                    }
                }
            }
        }
        $result.ok = ($result.openOk -and $result.hasLevelDat -and $result.errors.Count -eq 0)
    } catch {
        $result.errors.Add('打开 zip 失败：' + $_.Exception.Message) | Out-Null
        $result.ok = $false
    } finally {
        if ($null -ne $zip) { try { $zip.Dispose() } catch { } }
    }
    return $result
}

Write-VerifyLog ("start count=$Count deep=$Deep zip=$ZipPath")

$targets = @()
if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "指定备份不存在：$ZipPath"
    }
    $targets = @(Get-Item -LiteralPath $ZipPath)
} else {
    $all = @(Get-BackupZips)
    if ($all.Count -eq 0) {
        $qq = "【备份验证】未找到任何世界备份 zip`n目录：backups\world`n请先跑备份调度或 !备份"
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $OutDir 'summary-qq.txt'), $qq, (New-Object System.Text.UTF8Encoding $true))
        if ($QqSummary) { Write-Output $qq } else { Write-Host $qq }
        exit 2
    }
    $n = [Math]::Max(1, $Count)
    $targets = @($all | Select-Object -First $n)
}

$results = @()
foreach ($t in $targets) {
    Write-VerifyLog ("checking " + $t.FullName)
    $results += ,(Test-OneBackupZip -Path $t.FullName -DoDeep:([bool]$Deep))
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
New-Item -ItemType Directory -Path $LatestDir -Force | Out-Null
New-Item -ItemType Directory -Path $PendingDir -Force | Out-Null

$okCount = @($results | Where-Object { $_.ok }).Count
$badCount = $results.Count - $okCount
$worst = $results | Where-Object { -not $_.ok } | Select-Object -First 1
$latestR = $results[0]

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('【备份验证】')
[void]$sb.AppendLine(('检查 {0} 份 · 通过 {1} · 失败 {2}{3}' -f $results.Count, $okCount, $badCount, $(if ($Deep) { ' · 深度模式' } else { '' })))
foreach ($r in $results) {
    $flag = if ($r.ok) { '通过' } else { '失败' }
    [void]$sb.AppendLine(('· [{0}] {1}' -f $flag, $r.name))
    [void]$sb.AppendLine(('  大小 {0} · {1} 小时前 · 条目 {2}' -f (Format-Bytes $r.sizeBytes), $r.ageHours, $r.entryCount))
    [void]$sb.AppendLine(('  level.dat={0} region区块={1} 玩家档={2}' -f $(if ($r.hasLevelDat) { '有' } else { '无' }), $r.regionCount, $r.playerdataCount))
    if ($r.levelDatBytes -gt 0) {
        [void]$sb.AppendLine(('  level.dat 可读 {0} 字节' -f $r.levelDatBytes))
    }
    if ($Deep) {
        [void]$sb.AppendLine(('  深度：已检 {0} · 失败 {1}' -f $r.deepChecked, $r.deepFailed))
    }
    foreach ($e in @($r.errors)) { [void]$sb.AppendLine(('  错误：' + $e)) }
    foreach ($w in @($r.warnings)) { [void]$sb.AppendLine(('  警告：' + $w)) }
}
if ($badCount -eq 0) {
    [void]$sb.AppendLine('结论：备份包结构正常，可作回档候选（未做完整开服冒烟）。')
} else {
    [void]$sb.AppendLine('结论：存在不可用备份，请立即手动 !备份 并检查磁盘。')
}
[void]$sb.AppendLine(('详情：tmp\backup-verify\' + $Stamp))
$qqText = $sb.ToString().TrimEnd()

$full = New-Object System.Text.StringBuilder
[void]$full.AppendLine($qqText)
[void]$full.AppendLine('')
[void]$full.AppendLine('说明：本验证只读打开 zip 并抽样读取 level.dat，不会解压覆盖线上 world，也不会启动 Minecraft。')
if (-not $Deep) {
    [void]$full.AppendLine('加 -Deep 可逐条目试读（数 GB 备份会较慢）。')
}

$enc = New-Object System.Text.UTF8Encoding $true
[IO.File]::WriteAllText((Join-Path $OutDir 'summary-qq.txt'), $qqText, $enc)
[IO.File]::WriteAllText((Join-Path $OutDir 'report.txt'), $full.ToString().TrimEnd(), $enc)
$meta = [ordered]@{
    stamp     = $Stamp
    checked   = $results.Count
    ok        = $okCount
    bad       = $badCount
    deep      = [bool]$Deep
    generated = (Get-Date).ToString('o')
    results   = $results
}
$jsonText = ($meta | ConvertTo-Json -Depth 8)
[IO.File]::WriteAllText((Join-Path $OutDir 'meta.json'), $jsonText, (New-Object System.Text.UTF8Encoding $false))
Copy-Item (Join-Path $OutDir 'summary-qq.txt') (Join-Path $LatestDir 'summary-qq.txt') -Force
Copy-Item (Join-Path $OutDir 'report.txt') (Join-Path $LatestDir 'report.txt') -Force
Copy-Item (Join-Path $OutDir 'meta.json') (Join-Path $LatestDir 'meta.json') -Force

# 仅在定时/失败时可选推送：这里始终写 pending 由调用方或配置决定；手动 -QqSummary 不强制 pending
# 为与卡顿取证一致：生成 pending 供 discord-watch 在 backupVerify.pushOnFail/always 时推送
$shouldPending = $false
try {
    $ops = Get-Content (Join-Path $Root 'tools\ops-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ops.backupVerify) {
        if ($badCount -gt 0 -and $ops.backupVerify.pushOnFail) { $shouldPending = $true }
        if ($ops.backupVerify.pushAlways) { $shouldPending = $true }
    }
} catch { }
# 环境变量强制（定时任务用）
if ($env:BACKUP_VERIFY_PUSH -eq '1') { $shouldPending = $true }

if ($shouldPending) {
    $pending = [ordered]@{
        stamp     = $Stamp
        summary   = $qqText
        ok        = ($badCount -eq 0)
        createdAt = (Get-Date).ToString('o')
        outDir    = $OutDir
    }
    $pp = Join-Path $PendingDir ($Stamp + '.json')
    [IO.File]::WriteAllText($pp, ($pending | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
    Write-VerifyLog ("pending " + $pp)
}

Write-VerifyLog ("done ok=$okCount bad=$badCount")

if ($QqSummary) {
    Write-Output $qqText
} elseif (-not $Quiet) {
    Write-Host $qqText
    Write-Host ''
    Write-Host ("报告目录：" + $OutDir) -ForegroundColor Cyan
}

if ($Json) { Write-Output $jsonText }

if ($badCount -gt 0) { exit 1 }
exit 0
