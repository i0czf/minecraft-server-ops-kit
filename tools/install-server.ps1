# 服务端下载安装向导（控制台）
# 维护注意：
# - 本文件含中文，必须保存为 UTF-8 带 BOM + CRLF（无 BOM 时 Windows PowerShell 5 按 ANSI 解析，满屏语法错误）。
# - 通常由控制面板「服务端下载与安装」按钮调度（面板负责弹文件夹选择器并传 -TargetDir），
#   也可以独立运行：powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-server.ps1
# - 支持 原版 / Forge / NeoForge / Fabric 四种加载器，任意 Minecraft 版本；
#   下载源可选官方或 BMCLAPI 国内镜像（镜像覆盖 原版+Forge；NeoForge/Fabric 走官方源，见提示）。
# - Forge/NeoForge 安装需要运行官方 installer，会按目标 MC 版本自动匹配本机 Java（逻辑同 portable-run-server.ps1）。

param(
    [string]$TargetDir = '',
    [string]$Loader = '',        # vanilla | forge | neoforge | fabric
    [string]$Mc = '',
    [string]$LoaderVersion = '',
    [string]$Source = ''         # official | bmclapi
)

$ErrorActionPreference = 'Stop'

try { $Host.UI.RawUI.WindowTitle = '服务端下载安装向导 —— 自选版本与加载器一键部署' } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }

function Write-Step([string]$Msg)  { Write-Host ('[安装] ' + $Msg) -ForegroundColor Cyan }
function Write-Ok([string]$Msg)    { Write-Host ('[安装] ' + $Msg) -ForegroundColor Green }
function Write-Warn2([string]$Msg) { Write-Host ('[安装] ' + $Msg) -ForegroundColor Yellow }
function Write-Bad([string]$Msg)   { Write-Host ('[安装] ' + $Msg) -ForegroundColor Red }

function Format-Bytes([long]$Bytes) {
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

# 网络请求一律自动重试：经代理/跨国链路的 TLS 连接偶发瞬断（WebClient 请求期间发生异常），
# 重试一次通常就过（2026-07-11 用户下载 NeoForge installer 实锤：第一次断、第二次成）。
function Get-Text([string]$Url) {
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            $wc = New-Object System.Net.WebClient
            try {
                $wc.Encoding = [System.Text.Encoding]::UTF8
                $wc.Headers['User-Agent'] = 'portable-server-kit-installer'
                return $wc.DownloadString($Url)
            } finally { $wc.Dispose() }
        } catch {
            if ($i -ge $attempts) { throw }
            Write-Warn2 ('请求失败（{0}），2 秒后自动重试（第 {1}/{2} 次）…' -f $_.Exception.GetBaseException().Message, $i, $attempts)
            Start-Sleep -Seconds 2
        }
    }
}

function Get-File([string]$Url, [string]$Dest) {
    Write-Step ('正在下载：' + $Url)
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            $wc = New-Object System.Net.WebClient
            try {
                $wc.Headers['User-Agent'] = 'portable-server-kit-installer'
                $wc.DownloadFile($Url, $Dest)
            } finally { $wc.Dispose() }
            $size = (Get-Item -LiteralPath $Dest).Length
            Write-Ok ('下载完成：{0}（{1}）' -f (Split-Path -Leaf $Dest), (Format-Bytes $size))
            return
        } catch {
            try { if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -Confirm:$false -ErrorAction SilentlyContinue } } catch { }
            if ($i -ge $attempts) { throw }
            Write-Warn2 ('下载失败（{0}），3 秒后自动重试（第 {1}/{2} 次）…' -f $_.Exception.GetBaseException().Message, $i, $attempts)
            Start-Sleep -Seconds 3
        }
    }
}

# ---------- Java 自动匹配 ----------
# 首选官方版本 JSON 的 javaVersion.majorVersion（权威）；拿不到才用这套经验映射兜底。
function Get-RequiredJavaMajor([string]$McVer) {
    if ($McVer -notmatch '^(\d+)\.(\d+)(?:\.(\d+))?$') { return 21 } # 快照等异形版本号按新要求
    if ([int]$matches[1] -ne 1) { return 25 } # 2026 起的新纪年版本号（26.x）：官方要求 Java 25（26.1.1 实测）
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

function Resolve-JavaForInstall([string]$McVer, [int]$Required) {
    $required = $Required
    if ($required -le 0) { $required = Get-RequiredJavaMajor $McVer }
    $exact = ''
    $higher = ''
    $higherMaj = 0
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($cand in (Find-JavaCandidates)) {
        $maj = Get-JavaMajor $cand
        if ($maj -le 0) { continue }
        [void]$seen.Add("Java $maj = $cand")
        if ($maj -eq $required -and -not $exact) { $exact = $cand }
        if ($maj -gt $required -and (-not $higher -or $maj -lt $higherMaj)) { $higher = $cand; $higherMaj = $maj }
    }
    if ($exact) {
        Write-Ok ("Minecraft {0} 需要 Java {1}，已自动选择：{2}" -f $McVer, $required, $exact)
        return $exact
    }
    if ($higher) {
        Write-Warn2 ("Minecraft {0} 需要 Java {1}，本机没有该版本，改用更高的 Java {2}：{3}" -f $McVer, $required, $higherMaj, $higher)
        return $higher
    }
    Write-Bad ("无法继续：Minecraft {0} 的安装器需要 Java {1}，但本机没有找到可用的 Java。" -f $McVer, $required)
    if ($seen.Count -gt 0) {
        Write-Warn2 '本机已找到的 Java：'
        foreach ($s in $seen) { Write-Host ('  ' + $s) }
    }
    Write-Warn2 ("请安装 Java {0} 后重试（推荐 Adoptium Temurin，中文页面）：" -f $required)
    Write-Host ("  https://adoptium.net/zh-CN/temurin/releases/?version=" + $required)
    return ''
}

# ---------- 下载源 ----------
function Get-ManifestUrl {
    if ($script:UseMirror) { return 'https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json' }
    return 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
}
function Convert-MirrorUrl([string]$Url) {
    if (-not $script:UseMirror) { return $Url }
    # BMCLAPI 直接镜像 Mojang 各域名的路径结构，换域名即可
    return ($Url -replace '^https://(piston-meta|piston-data|launchermeta|launcher)\.mojang\.com', 'https://bmclapi2.bangbang93.com')
}
# PS 5.1 的 ConvertFrom-Json 对 JSON 数组输出「单个数组对象」（NoEnumerate），
# 直接 @(... | ConvertFrom-Json) 会得到 Count=1 的嵌套数组；统一走这个助手展开。
function ConvertFrom-JsonArray([string]$Json) {
    $parsed = ConvertFrom-Json $Json
    return @($parsed)
}

# 版本号数字化排序用（Forge/NeoForge 元数据顺序不可靠：官方升序、镜像降序、老版本还带分支后缀）
function ConvertTo-SortableVersion([string]$V) {
    $core = (($V -replace '[^0-9.].*$', '')).Trim('.')
    if ($core -notmatch '\.') { $core = $core + '.0' }
    try { return [version]$core } catch { return [version]'0.0' }
}

# Forge/NeoForge 官方安装器：个别库下载抽风时退出码非 0 并提示 Try again，
# 重跑会跳过已校验的库只补缺的，所以自动重试最多 3 次。
function Invoke-LoaderInstaller([string]$JavaExe, [string]$WorkDir, [string]$InstallerName, [string]$Label) {
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        Write-Step ('正在运行 {0} 官方安装器（--installServer，第 {1}/{2} 次），窗口会输出安装进度…' -f $Label, $i, $attempts)
        Push-Location -LiteralPath $WorkDir
        try { & $JavaExe -jar $InstallerName --installServer } finally { Pop-Location }
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($i -lt $attempts) {
            Write-Warn2 ('{0} 安装器退出码 {1}（多为个别库下载失败），3 秒后自动重试：已下载的库会跳过，只补缺的。' -f $Label, $LASTEXITCODE)
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

# ---------- 主流程 ----------
try {
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host '     Minecraft 服务端下载安装向导' -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host ''

    # 1) 目标目录
    if ([string]::IsNullOrWhiteSpace($TargetDir)) {
        $TargetDir = Read-Host '请输入服务端安装目录（不存在会自动创建）'
    }
    if ([string]::IsNullOrWhiteSpace($TargetDir)) { throw '未指定安装目录。' }
    $TargetDir = [System.IO.Path]::GetFullPath($TargetDir.Trim('"').Trim())
    New-Item -ItemType Directory -Force $TargetDir | Out-Null
    Write-Step ('安装目录：' + $TargetDir)
    $existing = @(Get-ChildItem -LiteralPath $TargetDir -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'libraries' -or $_.Name -ieq 'world' -or $_.Name -match '(?i)^(minecraft_)?server.*\.jar$' -or $_.Name -ieq 'run.bat' })
    if ($existing.Count -gt 0) {
        Write-Warn2 '该目录里已经有服务端文件（world/mods 不会被删除，但同名核心文件会被覆盖）：'
        foreach ($e in $existing) { Write-Host ('  ' + $e.Name) }
        $go = Read-Host '继续安装吗？[y/N]'
        if ($go.Trim().ToLowerInvariant() -notin @('y', 'yes')) { Write-Warn2 '已取消。'; Read-Host '按回车退出' | Out-Null; exit 0 }
    }

    # 2) 下载源
    if ([string]::IsNullOrWhiteSpace($Source)) {
        Write-Host ''
        Write-Host '下载源：'
        Write-Host '  [1] 官方源（Mojang / Forge / NeoForge / Fabric 官方，需要能正常访问国际网络）'
        Write-Host '  [2] BMCLAPI 国内镜像（覆盖 原版 + Forge；NeoForge/Fabric 元数据仍走官方源）'
        $pick = Read-Host '请选择 [1/2]（回车 = 1 官方）'
        $Source = if ($pick.Trim() -eq '2') { 'bmclapi' } else { 'official' }
    }
    $script:UseMirror = ($Source.Trim().ToLowerInvariant() -eq 'bmclapi')
    Write-Step ('下载源：' + $(if ($script:UseMirror) { 'BMCLAPI 国内镜像' } else { '官方源' }))

    # 3) 加载器
    if ([string]::IsNullOrWhiteSpace($Loader)) {
        Write-Host ''
        Write-Host '模组加载器：'
        Write-Host '  [1] Forge     （1.20.1 及大多数传统模组包）'
        Write-Host '  [2] NeoForge  （1.20.2+ 的 Forge 社区分支）'
        Write-Host '  [3] Fabric    （轻量加载器）'
        Write-Host '  [4] 原版      （不装加载器，纯净服）'
        $pick = Read-Host '请选择 [1-4]（回车 = 1 Forge）'
        $Loader = switch ($pick.Trim()) {
            '2' { 'neoforge' }
            '3' { 'fabric' }
            '4' { 'vanilla' }
            default { 'forge' }
        }
    }
    $Loader = $Loader.Trim().ToLowerInvariant()
    if ($Loader -notin @('vanilla', 'forge', 'neoforge', 'fabric')) { throw ('未知的加载器：' + $Loader) }
    Write-Step ('加载器：' + $Loader)

    # 4) Minecraft 版本（从官方清单取正式版列表）
    Write-Step '正在获取 Minecraft 版本清单…'
    $manifest = Get-Text (Get-ManifestUrl) | ConvertFrom-Json
    $latestRelease = [string]$manifest.latest.release
    $releases = @($manifest.versions | Where-Object { $_.type -eq 'release' })
    if ([string]::IsNullOrWhiteSpace($Mc)) {
        $recent = @($releases | Select-Object -First 12 | ForEach-Object { $_.id })
        Write-Host ''
        Write-Host ('最新正式版：' + $latestRelease)
        Write-Host ('最近正式版：' + ($recent -join '  '))
        $Mc = Read-Host ('请输入 Minecraft 版本（回车 = ' + $latestRelease + '，也可输入清单里的任意版本/快照）')
        if ([string]::IsNullOrWhiteSpace($Mc)) { $Mc = $latestRelease }
    }
    $Mc = $Mc.Trim()
    $verEntry = $manifest.versions | Where-Object { $_.id -eq $Mc } | Select-Object -First 1
    if (-not $verEntry) { throw ('版本清单里没有这个版本：' + $Mc) }
    if ($verEntry.type -ne 'release') { Write-Warn2 ('注意：' + $Mc + ' 不是正式版（type=' + $verEntry.type + '），模组加载器多半不支持。') }
    Write-Step ('Minecraft 版本：' + $Mc)

    # 版本详情 JSON：原版服务端下载地址和官方标注的 Java 要求都在这里，Java 匹配以它为准
    Write-Step '正在获取版本详情…'
    $verJson = $null
    try { $verJson = ConvertFrom-Json (Get-Text (Convert-MirrorUrl ([string]$verEntry.url))) } catch { $verJson = $null }
    $requiredJava = 0
    try {
        if ($verJson -and $verJson.javaVersion -and $verJson.javaVersion.majorVersion) { $requiredJava = [int]$verJson.javaVersion.majorVersion }
    } catch { }
    if ($requiredJava -gt 0) { Write-Step ('官方标注的 Java 要求：Java ' + $requiredJava) }

    # 5) 分加载器解析版本并安装
    $installedDesc = ''
    switch ($Loader) {
        'vanilla' {
            if (-not $verJson) { throw ('无法获取版本详情 JSON：' + $Mc + '（网络问题请重试或换下载源）。') }
            if (-not $verJson.downloads -or -not $verJson.downloads.server) {
                throw ('该版本没有官方服务端下载（太老的版本请自行寻找 server.jar）：' + $Mc)
            }
            $jarName = 'minecraft_server.' + $Mc + '.jar'
            Get-File (Convert-MirrorUrl ([string]$verJson.downloads.server.url)) (Join-Path $TargetDir $jarName)
            $installedDesc = ('原版 ' + $Mc + '（' + $jarName + '）')
        }
        'forge' {
            Write-Step '正在获取 Forge 版本列表…'
            # 镜像的 maven-metadata 停更在 2022（实测），必须用 BMCLAPI 专用 forge API；官方走 maven 元数据
            $forgeVers = @()
            if ($script:UseMirror) {
                $forgeVers = @(ConvertFrom-JsonArray (Get-Text ('https://bmclapi2.bangbang93.com/forge/minecraft/' + [uri]::EscapeDataString($Mc))) |
                    ForEach-Object { [string]$_.version })
            } else {
                $meta = [xml](Get-Text 'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml')
                $forgeVers = @(@($meta.metadata.versioning.versions.version) |
                    Where-Object { $_ -like ($Mc + '-*') } |
                    ForEach-Object { ([string]$_).Substring($Mc.Length + 1) })
            }
            if ($forgeVers.Count -eq 0) { throw ('Forge 没有适配 Minecraft ' + $Mc + ' 的版本。') }
            $sortedForge = @($forgeVers | Sort-Object { ConvertTo-SortableVersion $_ })
            $defaultForge = [string]$sortedForge[-1]
            $recommended = ''
            try {
                $promos = ConvertFrom-Json (Get-Text 'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json')
                $rec = $promos.promos.PSObject.Properties[($Mc + '-recommended')]
                if ($rec -and $rec.Value) { $recommended = [string]$rec.Value }
            } catch { }
            if ([string]::IsNullOrWhiteSpace($LoaderVersion)) {
                Write-Host ''
                Write-Host ('该 MC 版本共有 {0} 个 Forge 版本；最新：{1}{2}' -f $forgeVers.Count, $defaultForge, $(if ($recommended) { '，官方推荐：' + $recommended } else { '' }))
                $def = if ($recommended) { $recommended } else { $defaultForge }
                $LoaderVersion = Read-Host ('请输入 Forge 版本（回车 = ' + $def + '）')
                if ([string]::IsNullOrWhiteSpace($LoaderVersion)) { $LoaderVersion = $def }
            }
            $LoaderVersion = $LoaderVersion.Trim()
            $full = $Mc + '-' + $LoaderVersion
            if (-not ($forgeVers -contains $LoaderVersion)) { Write-Warn2 ('版本列表里没有 ' + $LoaderVersion + '，仍尝试下载（老版本可能带分支后缀，失败请核对版本号）。') }
            $installerName = 'forge-' + $full + '-installer.jar'
            $installerUrl = if ($script:UseMirror) {
                'https://bmclapi2.bangbang93.com/forge/download?mcversion=' + [uri]::EscapeDataString($Mc) + '&version=' + [uri]::EscapeDataString($LoaderVersion) + '&category=installer&format=jar'
            } else {
                'https://maven.minecraftforge.net/net/minecraftforge/forge/' + $full + '/' + $installerName
            }
            Get-File $installerUrl (Join-Path $TargetDir $installerName)
            $javaExe = Resolve-JavaForInstall $Mc $requiredJava
            if (-not $javaExe) { throw '没有可用的 Java，无法运行 Forge 安装器。' }
            if (-not (Invoke-LoaderInstaller $javaExe $TargetDir $installerName 'Forge')) {
                throw 'Forge 安装器连续 3 次失败（常见原因：网络无法访问 Forge/Mojang 仓库，可换下载源或挂代理重试）。'
            }
            $installedDesc = ('Forge ' + $full)
        }
        'neoforge' {
            if ($script:UseMirror) { Write-Warn2 'NeoForge 官方仓库没有 BMCLAPI 镜像，本步骤走官方源（安装器内部下载也走官方仓库）。' }
            Write-Step '正在获取 NeoForge 版本列表…'
            $meta = [xml](Get-Text 'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml')
            $all = @($meta.metadata.versioning.versions.version)
            # NeoForge 版本号随 MC 版本方案走（2026-07-11 实测）：
            #   1.x 时代：1.21.4 → 21.4.<build>；1.21 → 21.0.<build>（1.20.1 及更早没有 NeoForge）
            #   26.x 新纪年（2026 起）：MC 26.1.2 → 26.1.2.<build>；MC 26.2 → 26.2.0.<build>-beta
            $prefixes = @()
            if ($Mc -match '^1\.(\d+)(?:\.(\d+))?$') {
                $prefixes += ($matches[1] + '.' + $(if ($matches[2]) { $matches[2] } else { '0' }) + '.')
            } elseif ($Mc -match '^\d+\.\d+\.\d+$') {
                $prefixes += ($Mc + '.')
            } elseif ($Mc -match '^\d+\.\d+$') {
                $prefixes += ($Mc + '.0.')
                $prefixes += ($Mc + '.')
            }
            $mine = @()
            foreach ($p in $prefixes) {
                $mine = @($all | Where-Object { $_ -like ($p + '*') } | Sort-Object { ConvertTo-SortableVersion $_ })
                if ($mine.Count -gt 0) { break }
            }
            if ($mine.Count -eq 0 -and [string]::IsNullOrWhiteSpace($LoaderVersion)) {
                # 推断不出来别硬报错：把仓库最新条目亮出来让用户自己挑
                Write-Warn2 ('没能按前缀（' + ($prefixes -join ' / ') + '）匹配到 NeoForge 版本：可能该 MC 版本还没有 NeoForge，或命名方案又变了。')
                $tail = @($all | Sort-Object { ConvertTo-SortableVersion $_ } | Select-Object -Last 12)
                Write-Host ('NeoForge 仓库最新条目：' + ($tail -join '  '))
                $LoaderVersion = Read-Host '请直接输入完整 NeoForge 版本（留空取消安装）'
                if ([string]::IsNullOrWhiteSpace($LoaderVersion)) { throw '未选择 NeoForge 版本（1.20.1 及更早请用 Forge）。' }
            }
            if ([string]::IsNullOrWhiteSpace($LoaderVersion)) {
                $stable = @($mine | Where-Object { $_ -notmatch 'beta' })
                $defaultNeo = if ($stable.Count -gt 0) { [string]$stable[-1] } else { [string]$mine[-1] }
                Write-Host ''
                Write-Host ('该 MC 版本共有 {0} 个 NeoForge 版本；最新稳定：{1}' -f $mine.Count, $defaultNeo)
                $LoaderVersion = Read-Host ('请输入 NeoForge 版本（回车 = ' + $defaultNeo + '）')
                if ([string]::IsNullOrWhiteSpace($LoaderVersion)) { $LoaderVersion = $defaultNeo }
            }
            $LoaderVersion = $LoaderVersion.Trim()
            $installerName = 'neoforge-' + $LoaderVersion + '-installer.jar'
            Get-File ('https://maven.neoforged.net/releases/net/neoforged/neoforge/' + $LoaderVersion + '/' + $installerName) (Join-Path $TargetDir $installerName)
            $javaExe = Resolve-JavaForInstall $Mc $requiredJava
            if (-not $javaExe) { throw '没有可用的 Java，无法运行 NeoForge 安装器。' }
            if (-not (Invoke-LoaderInstaller $javaExe $TargetDir $installerName 'NeoForge')) {
                throw 'NeoForge 安装器连续 3 次失败（常见原因：网络无法访问 NeoForge/Mojang 仓库，可挂代理重试）。'
            }
            $installedDesc = ('NeoForge ' + $LoaderVersion + '（MC ' + $Mc + '）')
        }
        'fabric' {
            if ($script:UseMirror) { Write-Warn2 'Fabric 元数据/服务端包体积很小，本步骤直接走官方源 meta.fabricmc.net。' }
            Write-Step '正在获取 Fabric 加载器版本…'
            $loaders = @(ConvertFrom-JsonArray (Get-Text ('https://meta.fabricmc.net/v2/versions/loader/' + [uri]::EscapeDataString($Mc))))
            if ($loaders.Count -eq 0) { throw ('Fabric 不支持 Minecraft ' + $Mc + '（需要 1.14+）。') }
            $defaultFab = [string]$loaders[0].loader.version
            $stableFab = $loaders | Where-Object { $_.loader.stable } | Select-Object -First 1
            if ($stableFab) { $defaultFab = [string]$stableFab.loader.version }
            if ([string]::IsNullOrWhiteSpace($LoaderVersion)) {
                $LoaderVersion = Read-Host ('请输入 Fabric Loader 版本（回车 = ' + $defaultFab + '）')
                if ([string]::IsNullOrWhiteSpace($LoaderVersion)) { $LoaderVersion = $defaultFab }
            }
            $LoaderVersion = $LoaderVersion.Trim()
            $installers = @(ConvertFrom-JsonArray (Get-Text 'https://meta.fabricmc.net/v2/versions/installer'))
            $inst = ($installers | Where-Object { $_.stable } | Select-Object -First 1)
            if (-not $inst) { $inst = $installers[0] }
            $iv = [string]$inst.version
            $jarName = ('fabric-server-mc.{0}-loader.{1}-launcher.{2}.jar' -f $Mc, $LoaderVersion, $iv)
            Get-File ('https://meta.fabricmc.net/v2/versions/loader/{0}/{1}/{2}/server/jar' -f [uri]::EscapeDataString($Mc), $LoaderVersion, $iv) (Join-Path $TargetDir $jarName)
            $installedDesc = ('Fabric Loader ' + $LoaderVersion + '（MC ' + $Mc + '，' + $jarName + '）')
        }
    }

    # 6) EULA
    $eulaPath = Join-Path $TargetDir 'eula.txt'
    $eulaDone = $false
    if (Test-Path -LiteralPath $eulaPath -PathType Leaf) {
        if ((Get-Content -LiteralPath $eulaPath -Raw) -match '(?im)^\s*eula\s*=\s*true') { $eulaDone = $true }
    }
    if (-not $eulaDone) {
        Write-Host ''
        Write-Host '服务端首次启动前需要同意 Minecraft 最终用户许可协议（EULA）：'
        Write-Host '  https://aka.ms/MinecraftEULA'
        $agree = Read-Host '你是否同意 EULA，并现在写入 eula.txt=true？[y/N]'
        if ($agree.Trim().ToLowerInvariant() -in @('y', 'yes')) {
            [System.IO.File]::WriteAllText($eulaPath, "# 由服务端下载安装向导写入，表示你已同意 https://aka.ms/MinecraftEULA`r`neula=true`r`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok '已写入 eula.txt=true。'
        } else {
            Write-Warn2 '未写入 EULA：首次启动服务端会自动生成 eula.txt，把里面的 eula=false 改成 true 即可。'
        }
    }

    # 7) 收尾
    Write-Host ''
    Write-Host '=============================================' -ForegroundColor Green
    Write-Ok ('部署完成：' + $installedDesc)
    Write-Ok ('安装目录：' + $TargetDir)
    Write-Host ''
    $kitRoot = Split-Path -Parent $PSScriptRoot
    if ([System.IO.Path]::GetFullPath($kitRoot).TrimEnd('\') -ieq $TargetDir.TrimEnd('\')) {
        Write-Host '下一步：这就是当前工具包目录——回到控制面板点「初始化配置向导」重新识别版本，然后「启动服务端」。'
    } else {
        Write-Host '下一步：'
        Write-Host '  1. 把整个工具包（tools\ + 一键脚本\ + 控制面板 bat）复制到新目录，即可用控制面板管理这个新服；'
        Write-Host '  2. 在新目录跑「初始化配置向导」识别版本，再点「启动服务端」（Java 会自动匹配）。'
    }
    Write-Host ''
} catch {
    Write-Host ''
    Write-Bad ('安装失败：' + $_.Exception.Message)
    Write-Warn2 '如果是网络问题：官方源需要能访问 Mojang/Forge 等国际站点，可换 BMCLAPI 镜像或挂代理后重试。'
}
Read-Host '按回车关闭窗口' | Out-Null
