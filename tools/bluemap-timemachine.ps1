param(
    [string]$SourceRoot = '',
    [switch]$Deep,
    [switch]$QqSummary,
    [switch]$Quiet,
    [switch]$Json,
    [string]$OutDir = ''
)

# BlueMap 时光机 MVP：只读生成轻量地图快照和前后差异。
# 默认不复制 tiles；-Deep 也只统计瓦片，不复制或改写任何 BlueMap/世界文件。

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = Split-Path -Parent $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BaseOut = Join-Path $Root 'tmp\bluemap-timemachine'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $BaseOut $Stamp
}
$LatestDir = Join-Path $BaseOut 'latest'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$source = if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    Join-Path $Root 'bluemap\web'
} elseif ([IO.Path]::IsPathRooted($SourceRoot)) {
    $SourceRoot
} else {
    Join-Path $Root $SourceRoot
}
try { $source = [IO.Path]::GetFullPath($source) } catch { }

function Write-Utf8([string]$Path, [string]$Value) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Value, $utf8)
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return '' }
}

function To-Iso([datetime]$Value) {
    if ($null -eq $Value) { return '' }
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-FileStat([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ exists = $false; bytes = 0; updatedAt = ''; sha256 = '' }
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        return [pscustomobject][ordered]@{
            exists    = $true
            bytes     = [int64]$item.Length
            updatedAt = To-Iso $item.LastWriteTime
            sha256    = Get-Sha256 $Path
        }
    } catch {
        return [pscustomobject][ordered]@{ exists = $true; bytes = 0; updatedAt = ''; sha256 = '' }
    }
}

function Get-RootFileStats([string]$Path) {
    $count = [int64]0
    $bytes = [int64]0
    $latest = $null
    $entries = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject][ordered]@{ count = 0; bytes = 0; latestAt = ''; fingerprint = '' }
    }
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue)) {
            $count++
            $bytes += [int64]$item.Length
            if ($null -eq $latest -or $item.LastWriteTime -gt $latest) { $latest = $item.LastWriteTime }
            # 只聚合地图根目录的直接文件内容；不把 LastWriteTime 纳入指纹，避免重渲染时间戳造成误报。
            $entries.Add(('{0}|{1}|{2}' -f $item.Name, [int64]$item.Length, (Get-Sha256 $item.FullName))) | Out-Null
        }
    } catch { }
    $rootFingerprint = ''
    if ($entries.Count -gt 0) {
        $fingerprintInput = ($entries | Sort-Object) -join "`n"
        $rootFingerprint = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintInput))))).Replace('-', '').ToLowerInvariant()
    }
    return [pscustomobject][ordered]@{ count = $count; bytes = $bytes; latestAt = To-Iso $latest; fingerprint = $rootFingerprint }
}

function Get-DeepFileStats([string]$Path) {
    $count = [int64]0
    $bytes = [int64]0
    $latest = $null
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject][ordered]@{ scanned = $false; count = 0; bytes = 0; latestAt = '' }
    }
    try {
        foreach ($fullName in [IO.Directory]::EnumerateFiles($Path, '*', [IO.SearchOption]::AllDirectories)) {
            try {
                $item = [IO.FileInfo]::new($fullName)
                $count++
                $bytes += [int64]$item.Length
                if ($null -eq $latest -or $item.LastWriteTime -gt $latest) { $latest = $item.LastWriteTime }
            } catch { }
        }
    } catch { }
    return [pscustomobject][ordered]@{ scanned = $true; count = $count; bytes = $bytes; latestAt = To-Iso $latest }
}

function Get-Relative([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        if ($full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
            return ($full.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/')
        }
    } catch { }
    return $Path
}

function Format-MiB([int64]$Bytes) {
    return ('{0:N1} MiB' -f ($Bytes / 1MB))
}

function Format-Md([string]$Text) {
    if ($null -eq $Text) { return '' }
    return $Text.Replace('|', '\|').Replace("`r", '').Replace("`n", ' ')
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
New-Item -ItemType Directory -Path $BaseOut -Force | Out-Null

$webSettingsPath = Join-Path $source 'settings.json'
$webSettings = Read-Json $webSettingsPath
$mapRoot = Join-Path $source 'maps'
$mapIds = @()
if ($webSettings -and $webSettings.maps) { $mapIds = @($webSettings.maps | ForEach-Object { [string]$_ }) }
if ($mapIds.Count -eq 0 -and (Test-Path -LiteralPath $mapRoot -PathType Container)) {
    $mapIds = @(Get-ChildItem -LiteralPath $mapRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}
$mapIds = @($mapIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

$maps = New-Object System.Collections.Generic.List[object]
$fingerprintVersion = 3
foreach ($mapId in $mapIds) {
    $mapDir = Join-Path $mapRoot $mapId
    $settingsPath = Join-Path $mapDir 'settings.json'
    $settings = Read-Json $settingsPath
    $settingsStat = Get-FileStat $settingsPath
    $rootStats = Get-RootFileStats $mapDir
    $live = [ordered]@{}
    foreach ($liveName in @('players.json', 'markers.json')) {
        $live[$liveName] = Get-FileStat (Join-Path (Join-Path $mapDir 'live') $liveName)
    }
    $tilesStats = if ($Deep) { Get-DeepFileStats (Join-Path $mapDir 'tiles') } else {
        [pscustomobject][ordered]@{ scanned = $false; count = 0; bytes = 0; latestAt = '' }
    }
    $dirUpdated = ''
    try { $dirUpdated = To-Iso (Get-Item -LiteralPath $mapDir -Force).LastWriteTime } catch { }
    $fingerprintInput = @(
        $mapId,
        [string]$settingsStat.sha256,
        [string]$rootStats.fingerprint,
        [string]$live['players.json'].sha256,
        [string]$live['markers.json'].sha256
    ) -join '|'
    $mapFingerprint = [Convert]::ToBase64String(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintInput)))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $tileFingerprintInput = @([string]$tilesStats.count, [string]$tilesStats.bytes, [string]$tilesStats.latestAt) -join '|'
    $tileFingerprint = [Convert]::ToBase64String(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($tileFingerprintInput)))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $maps.Add([pscustomobject][ordered]@{
            id          = $mapId
            name        = if ($settings -and $settings.name) { [string]$settings.name } else { $mapId }
            settings    = [pscustomobject][ordered]@{
                exists     = [bool]$settingsStat.exists
                sha256     = $settingsStat.sha256
                bytes      = $settingsStat.bytes
                updatedAt  = $settingsStat.updatedAt
                startPos   = if ($settings) { $settings.startPos } else { $null }
                flatView   = if ($settings -and $settings.flatView -ne $null) { [bool]$settings.flatView } else { $null }
                perspectiveView = if ($settings -and $settings.perspectiveView -ne $null) { [bool]$settings.perspectiveView } else { $null }
            }
            live        = [pscustomobject]$live
            rootFiles   = $rootStats
            tiles       = $tilesStats
            directoryUpdatedAt = $dirUpdated
            fingerprintVersion = $fingerprintVersion
            fingerprint = $mapFingerprint
            tileFingerprint = $tileFingerprint
        }) | Out-Null
}

$previousPath = Join-Path $LatestDir 'snapshot.json'
$previous = Read-Json $previousPath
$previousFingerprintVersion = 0
if ($previous -and $previous.PSObject.Properties['fingerprintVersion']) {
    try { $previousFingerprintVersion = [int]$previous.fingerprintVersion } catch { $previousFingerprintVersion = 0 }
}
$baseline = ($null -ne $previous -and $previousFingerprintVersion -ne $fingerprintVersion)
$previousMaps = @{}
if ($previous -and $previous.maps) {
    foreach ($oldMap in @($previous.maps)) { $previousMaps[[string]$oldMap.id] = $oldMap }
}
$currentIds = @($maps | ForEach-Object { [string]$_.id })
$added = @($currentIds | Where-Object { -not $previousMaps.ContainsKey($_) })
$removed = @($previousMaps.Keys | Where-Object { $_ -notin $currentIds })
$changed = New-Object System.Collections.Generic.List[object]
$refreshed = New-Object System.Collections.Generic.List[object]
foreach ($map in $maps) {
    if ($previousMaps.ContainsKey($map.id)) {
        $oldMap = $previousMaps[$map.id]
        $oldFingerprintVersion = 0
        if ($oldMap.PSObject.Properties['fingerprintVersion']) {
            try { $oldFingerprintVersion = [int]$oldMap.fingerprintVersion } catch { $oldFingerprintVersion = 0 }
        }
        if ($baseline -or $oldFingerprintVersion -ne $fingerprintVersion) { continue }
        $baseChanged = [string]$oldMap.fingerprint -ne [string]$map.fingerprint
        # deep/metadata 模式切换不应把所有地图误报为变化；只有两次都是 deep 才比较瓦片统计。
        $tileChanged = $Deep -and $previous -and [string]$previous.mode -eq 'deep' -and [string]$oldMap.tileFingerprint -ne [string]$map.tileFingerprint
        if ($baseChanged -or $tileChanged) {
            $changed.Add([pscustomobject][ordered]@{ id = $map.id; name = $map.name; before = $oldMap.fingerprint; after = $map.fingerprint; tileChanged = $tileChanged }) | Out-Null
        } elseif ([string]$oldMap.directoryUpdatedAt -ne [string]$map.directoryUpdatedAt) {
            # BlueMap 重渲染会更新地图目录时间，但不代表 settings/live/瓦片统计发生内容变化。
            $refreshed.Add([pscustomobject][ordered]@{ id = $map.id; name = $map.name; before = $oldMap.directoryUpdatedAt; after = $map.directoryUpdatedAt }) | Out-Null
        }
    }
}

$sourceUpdated = ''
try { $sourceUpdated = To-Iso (Get-Item -LiteralPath $source -Force).LastWriteTime } catch { }
$webSettingsStat = Get-FileStat $webSettingsPath
$capturedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$scanMode = if ($Deep) { 'deep' } else { 'metadata' }
$sourceRel = Get-Relative $source
$sourceExists = Test-Path -LiteralPath $source -PathType Container
$snapshot = [ordered]@{
    schema       = 1
    fingerprintVersion = $fingerprintVersion
    capturedAt   = $capturedAt
    mode         = $scanMode
    source       = [ordered]@{
        path         = $sourceRel
        exists       = $sourceExists
        webSettings  = $webSettingsStat
        updatedAt    = $sourceUpdated
        mapCount     = $maps.Count
        configuredMaps = @($mapIds)
    }
    maps         = $maps.ToArray()
    diff         = [ordered]@{
        hasPrevious = ($null -ne $previous)
        added       = @($added)
        removed     = @($removed)
        changed     = $changed.ToArray()
        refreshed   = $refreshed.ToArray()
        baseline    = $baseline
    }
}
$snapshotJson = $snapshot | ConvertTo-Json -Depth 12
$snapshotPath = Join-Path $OutDir 'snapshot.json'
Write-Utf8 $snapshotPath $snapshotJson

$report = New-Object System.Text.StringBuilder
[void]$report.AppendLine('# BlueMap 时光机快照')
[void]$report.AppendLine('')
[void]$report.AppendLine(('捕获时间：`{0}`  ·  模式：`{1}`' -f $capturedAt, $scanMode))
[void]$report.AppendLine(('来源：`{0}`  ·  地图数：`{1}`' -f (Get-Relative $source), $maps.Count))
[void]$report.AppendLine('')
[void]$report.AppendLine('> 安全边界：本工具只读 BlueMap web 目录；默认不扫描/复制瓦片，`-Deep` 也只统计瓦片数量、大小和最新时间，不改写 BlueMap、世界或配置。在线玩家文件只记录大小、时间和哈希，不把玩家坐标写入报告。')
[void]$report.AppendLine('')
[void]$report.AppendLine('## 差异摘要')
[void]$report.AppendLine('')
[void]$report.AppendLine(('- 新增地图：**{0}**；移除地图：**{1}**；内容/瓦片变化：**{2}**；仅目录刷新：**{3}**' -f $added.Count, $removed.Count, $changed.Count, $refreshed.Count))
if ($baseline) { [void]$report.AppendLine('- 指纹基线：本次升级了比较算法，先建立新基线，不把旧算法结果误报为内容变化。') }
if ($added.Count -gt 0) { [void]$report.AppendLine(('- 新增：`{0}`' -f (($added -join '`, `') + '`'))) }
if ($removed.Count -gt 0) { [void]$report.AppendLine(('- 移除：`{0}`' -f (($removed -join '`, `') + '`'))) }
if ($changed.Count -gt 0) { [void]$report.AppendLine(('- 变化：`{0}`' -f (($changed | ForEach-Object { $_.id }) -join '`, `'))) }
if ($refreshed.Count -gt 0) { [void]$report.AppendLine(('- 仅刷新：`{0}`' -f (($refreshed | ForEach-Object { $_.id }) -join '`, `'))) }

[void]$report.AppendLine('')
[void]$report.AppendLine('## 地图索引')
[void]$report.AppendLine('')
[void]$report.AppendLine('| 地图 | BlueMap 名称 | settings | live 数据 | 瓦片统计 |')
[void]$report.AppendLine('|---|---|---:|---:|---:|')
foreach ($map in $maps) {
    $liveBytes = [int64]$map.live.'players.json'.bytes + [int64]$map.live.'markers.json'.bytes
    $tileLabel = if ($Deep) { '{0} 个 / {1}' -f $map.tiles.count, (Format-MiB $map.tiles.bytes) } else { '未扫描（安全默认）' }
    $mapLine = [string]::Format('| `{0}` | {1} | {2} B | {3} B | {4} |', [object[]]@((Format-Md $map.id), (Format-Md $map.name), $map.settings.bytes, $liveBytes, $tileLabel))
    [void]$report.AppendLine($mapLine)
}
[void]$report.AppendLine('')
[void]$report.AppendLine('## 下一步建议')
[void]$report.AppendLine('')
[void]$report.AppendLine('- 将本快照纳入定时任务，可先用默认 metadata 模式低成本记录地图变更。')
[void]$report.AppendLine('- 需要核对瓦片生成量时再手动运行 `一键脚本\一键便携-BlueMap时光机.bat deep`；预计耗时随 8.9GB 渲染目录变化。')
[void]$report.AppendLine('- 真正的历史地图浏览仍需后续设计存储配额与瓦片保留策略，本 MVP 不自动复制大目录。')
$reportPath = Join-Path $OutDir 'report.md'
Write-Utf8 $reportPath $report.ToString()

$level = if (-not $sourceExists) { 'red' } elseif ($changed.Count -gt 0 -or $added.Count -gt 0 -or $removed.Count -gt 0) { 'yellow' } else { 'green' }
$qq = '【BlueMap时光机】{0} · {1}张地图 · 新增{2}/移除{3}/内容变化{4}/仅刷新{5} · 模式{6} · 报告 {7}' -f $level, $maps.Count, $added.Count, $removed.Count, $changed.Count, $refreshed.Count, $scanMode, (Get-Relative $reportPath)
$qqPath = Join-Path $OutDir 'summary-qq.txt'
Write-Utf8 $qqPath ($qq + "`r`n")

$meta = [ordered]@{
    schema      = 1
    overall     = $level
    capturedAt  = $capturedAt
    mode        = $scanMode
    mapCount    = $maps.Count
    baseline    = $baseline
    added       = @($added)
    removed     = @($removed)
    changed     = @($changed | ForEach-Object { $_.id })
    refreshed   = @($refreshed | ForEach-Object { $_.id })
    source      = $sourceRel
    snapshot    = Get-Relative $snapshotPath
    report      = Get-Relative $reportPath
    summary     = Get-Relative $qqPath
}
$metaJson = $meta | ConvertTo-Json -Depth 10
$metaPath = Join-Path $OutDir 'meta.json'
Write-Utf8 $metaPath $metaJson

# 稳定副本只落在本工具的 tmp 目录，便于面板/QQ/后续自动化读取。
New-Item -ItemType Directory -Path $LatestDir -Force | Out-Null
foreach ($name in @('snapshot.json', 'report.md', 'summary-qq.txt', 'meta.json')) {
    Copy-Item -LiteralPath (Join-Path $OutDir $name) -Destination (Join-Path $LatestDir $name) -Force
}

if ($QqSummary) {
    Write-Output $qq
} elseif ($Json) {
    Write-Output $metaJson
} elseif (-not $Quiet) {
    Write-Output ('BlueMap 时光机已完成：{0}' -f (Get-Relative $reportPath))
    Write-Output ('快照：{0}' -f (Get-Relative $snapshotPath))
    Write-Output $qq
}
