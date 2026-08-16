# 工具包自更新：从「主工具包 zip」拉取最新版覆盖本服工具文件。
# 设计与玩家拉新同套路：版本号比对（KIT-VERSION.txt）→ 解压 → 覆盖，本地私有配置绝不覆盖。
# 更新源在 tools\toolkit-update-source.txt 里配置（通常指向主开发服务端的 dist\portable-server-kit-private-latest.zip）。
# 维护注意：本文件含中文，必须保存为 UTF-8 带 BOM。
param(
    [string]$SourceZip = "",
    [switch]$Force,
    [switch]$RestartPanel,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = '工具包更新器 —— 更新期间请勿关闭' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch {}

function Wait-Exit([int]$Code) {
    if (-not $NoPause) { Read-Host '按回车退出' | Out-Null }
    exit $Code
}

Write-Host '====== 便携工具包自更新 ======' -ForegroundColor Cyan

# ---- 更新源解析 ----
$sourceCfg = Join-Path $Root 'tools\toolkit-update-source.txt'
if ([string]::IsNullOrWhiteSpace($SourceZip) -and (Test-Path -LiteralPath $sourceCfg -PathType Leaf)) {
    $SourceZip = (Get-Content -LiteralPath $sourceCfg -Raw -Encoding UTF8).Trim()
}
if ([string]::IsNullOrWhiteSpace($SourceZip)) {
    Write-Host '[失败] 还没有配置工具包更新源。' -ForegroundColor Red
    Write-Host '在 tools\toolkit-update-source.txt 里写一行主工具包 zip 的完整路径即可，例如：' -ForegroundColor Yellow
    Write-Host '  D:\我的主服务端\dist\portable-server-kit-private-latest.zip' -ForegroundColor Yellow
    Write-Host '（主开发目录每次点「生成私用工具包」，这个 latest.zip 就是最新版；其他服双击本更新入口即可跟进。）' -ForegroundColor Yellow
    Wait-Exit 1
}
$rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
if ($SourceZip -match '^(?i)https?://') {
    # 外发工具包走公网检查更新通道（更新服务的无令牌 /kit/ 路径）
    Write-Host "更新源（网络）：$SourceZip"
    Write-Host '正在从更新服务器下载最新工具包…'
    $downloadTo = Join-Path $Root 'tmp\toolkit-update-download.zip'
    New-Item -ItemType Directory -Force (Join-Path $Root 'tmp') | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        (New-Object System.Net.WebClient).DownloadFile($SourceZip, $downloadTo)
    } catch {
        Write-Host ("[失败] 下载更新失败：" + $_.Exception.Message) -ForegroundColor Red
        Write-Host '请检查网络，或联系作者确认更新服务器已开启。' -ForegroundColor Yellow
        Wait-Exit 1
    }
    $SourceZip = $downloadTo
} else {
    if (-not [System.IO.Path]::IsPathRooted($SourceZip)) { $SourceZip = [System.IO.Path]::GetFullPath((Join-Path $Root $SourceZip)) }
    if (-not (Test-Path -LiteralPath $SourceZip -PathType Leaf)) {
        Write-Host "[失败] 更新源 zip 不存在：$SourceZip" -ForegroundColor Red
        Write-Host '请到主开发服务端先生成一次工具包（面板⑤「生成私用工具包」），或修正 tools\toolkit-update-source.txt 里的路径。' -ForegroundColor Yellow
        Wait-Exit 1
    }
    # 主发布目录防呆：更新源在本目录内（但不含 tmp\ 下我们自己下载的临时 zip）说明这就是发布方自己
    $srcProbe = [System.IO.Path]::GetFullPath($SourceZip)
    $tmpPrefix = (Join-Path $rootFull 'tmp') + '\'
    if ($srcProbe.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $srcProbe.StartsWith($tmpPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host '[提示] 本目录就是主发布目录（更新源指向自己 dist 里的 zip），无需也不应自更新——' -ForegroundColor Yellow
        Write-Host '      否则会用打包时的旧文件覆盖你正在开发的新改动。主目录直接改文件、生成工具包即为发布。' -ForegroundColor Yellow
        Wait-Exit 0
    }
}
$sourceFull = [System.IO.Path]::GetFullPath($SourceZip)
Write-Host "更新源：$sourceFull"

# ---- 版本比对 ----
Add-Type -AssemblyName System.IO.Compression.FileSystem
$newVersion = ''
$zip = [System.IO.Compression.ZipFile]::OpenRead($sourceFull)
try {
    $verEntry = $zip.Entries | Where-Object { $_.FullName -eq 'KIT-VERSION.txt' } | Select-Object -First 1
    if ($verEntry) {
        $sr = New-Object System.IO.StreamReader($verEntry.Open(), [System.Text.Encoding]::UTF8)
        $newVersion = $sr.ReadToEnd().Trim()
        $sr.Dispose()
    }
} finally { $zip.Dispose() }
if ([string]::IsNullOrWhiteSpace($newVersion)) {
    Write-Host '[失败] 更新源 zip 里没有 KIT-VERSION.txt，说明它是旧版工具包打的。' -ForegroundColor Red
    Write-Host '请到主开发目录重新生成一次工具包后再试。' -ForegroundColor Yellow
    Wait-Exit 1
}
$curVersionPath = Join-Path $Root 'KIT-VERSION.txt'
$curVersion = '(未记录)'
if (Test-Path -LiteralPath $curVersionPath -PathType Leaf) {
    $curVersion = (Get-Content -LiteralPath $curVersionPath -Raw -Encoding UTF8).Trim()
}
Write-Host "本服版本：$curVersion"
Write-Host "最新版本：$newVersion"
if ($curVersion -eq $newVersion -and -not $Force) {
    Write-Host '[完成] 已是最新版本，无需更新。' -ForegroundColor Green
    Wait-Exit 0
}

# ---- 解压到临时目录 ----
$tmp = Join-Path $Root 'tmp\toolkit-update'
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory($sourceFull, $tmp)
$tmpFull = [System.IO.Path]::GetFullPath($tmp)

# ---- 覆盖复制（保护本地私有配置） ----
# 这三个文件承载本服身份与密钥/本机路径，更新永不触碰；工具包 zip 里的同名文件是净化模板。
# KIT-VERSION.txt 不在循环里复制：必须等全部文件落地成功后最后写入，否则半途失败会被误判为「已最新」。
$protectedRel = @('tools\portable-pack.json', 'tools\ops-config.json', 'tools\toolkit-update-source.txt', 'KIT-VERSION.txt')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $Root "backups\toolkit-update-$stamp"
$updated = 0
$protectedSkipped = 0
$backedUp = 0
$lockedLLBot = New-Object System.Collections.Generic.List[string]
$failedOther = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath $tmp -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($tmpFull.Length + 1)
    foreach ($p in $protectedRel) {
        if ([string]::Equals($rel, $p, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:protectedSkipped++
            return
        }
    }
    $dest = Join-Path $rootFull $rel
    # LLBot 程序目录体积大且账号数据只存在于本地（zip 里没有 data），直接覆盖程序文件、不做备份；
    # QQ 机器人常驻运行时其文件会被占用，逐个跳过即可，不能拖垮整次更新。
    $isLLBot = ($rel -match '(?i)^tools\\LLBot-CLI-win-x64\\')
    try {
        if (-not $isLLBot -and (Test-Path -LiteralPath $dest -PathType Leaf)) {
            $bak = Join-Path $backupDir $rel
            New-Item -ItemType Directory -Force (Split-Path -Parent $bak) | Out-Null
            Copy-Item -LiteralPath $dest -Destination $bak -Force
            $script:backedUp++
        }
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction Stop
        $script:updated++
    } catch {
        if ($isLLBot) { [void]$lockedLLBot.Add($rel) }
        else { [void]$failedOther.Add($rel + '（' + $_.Exception.Message + '）') }
    }
}
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($failedOther.Count -gt 0) {
    Write-Host ''
    Write-Host "[失败] 有 $($failedOther.Count) 个文件被占用或写入失败，本次更新未完成（版本号不推进，下次会重试）：" -ForegroundColor Red
    $failedOther | Select-Object -First 8 | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }
    Write-Host '请关闭正在运行的控制面板/更新服务等程序后，重新点「更新工具包」。' -ForegroundColor Yellow
    Wait-Exit 1
}
# 全部关键文件落地后才推进版本号
Set-Content -LiteralPath $curVersionPath -Value $newVersion -Encoding ASCII

Write-Host ''
Write-Host "[完成] 工具包已更新：$curVersion → $newVersion" -ForegroundColor Green
Write-Host "  更新文件：$updated 个（本地私有配置已保护 $protectedSkipped 个，改动前备份 $backedUp 个到 backups\toolkit-update-$stamp）"
if ($lockedLLBot.Count -gt 0) {
    Write-Host "  [提示] QQ 机器人（LLBot）正在运行，其程序文件本次跳过 $($lockedLLBot.Count) 个——登录数据与功能不受影响。" -ForegroundColor Yellow
    Write-Host '         如确需更新 LLBot 本体：先关掉 LLBot 窗口，再点一次「更新工具包」（加 -Force）。' -ForegroundColor Yellow
}
Write-Host '生效提示：' -ForegroundColor Yellow
Write-Host '  - 控制面板：关闭后重新双击即用新版；' -ForegroundColor Yellow
Write-Host '  - 运维监控：点面板「重启运维监控」（或双击 一键脚本\一键便携-重启运维监控.bat）加载新版脚本。' -ForegroundColor Yellow
if ($RestartPanel) {
    $panelBat = Join-Path $Root '一键便携-控制面板.bat'
    if (Test-Path -LiteralPath $panelBat -PathType Leaf) {
        Write-Host '正在用新版重启控制面板…' -ForegroundColor Green
        Start-Process -FilePath $env:ComSpec -WorkingDirectory $Root -ArgumentList @('/d', '/c', ('"' + $panelBat + '"'))
    }
}
Wait-Exit 0
