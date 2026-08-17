<#
    portable-stage-daemon.ps1 —— 客户端后台"暂存 daemon"

    目的：把整合包更新的下载耗时，从"下次启动前干等"提前到"玩家在线正在游戏时后台悄悄拉"。
          管理员在线发布更新后，本进程后台把变更文件下到 .portable-staging/，玩家下次重启游戏时
          由 -Mode Promote 就地落位，再交给 player-update-generic.ps1 正常对账（删旧/去重/校验）。

    设计铁律（务必保持）：
      1) 只写 .portable-staging/，绝不改运行中被 JVM 锁住的 mods/*.jar 等文件——热覆盖在 Windows 上必失败。
      2) player-update-generic.ps1 仍是唯一权威对账器。暂存只是"预下载"，即使暂存过期/残缺也无害：
         Promote 落位后 player-update 会用最新清单重新校验、补下、删多余。所以本脚本不做任何删除。
      3) 只在 manifest 文本变化时才做文件 diff；idle 轮询近乎零开销（一次 GET + 字符串比较）。
      4) 生命周期自管：游戏由 PCL/HMCL 独立进程启动，本 daemon 靠"检测 java 进程 + 最大时长 + 单例锁"自退，
         不残留后台进程。
      5) 编码/换行按仓库铁律：UTF-8 无 BOM 保存；本文件是 PowerShell，CRLF 或 LF 均可，但保存时勿加 BOM。
#>
param(
    [string]$InstanceDir = ".",
    [string]$ManifestUrl = "",
    [ValidateSet("Watch", "Promote")]
    [string]$Mode = "Watch",
    [int]$IntervalSeconds = 30,
    [int]$MaxRuntimeMinutes = 720,
    [int]$GraceMinutes = 15,
    [int]$IdleExitChecks = 3,
    [switch]$Toast
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $OutputEncoding = [Console]::OutputEncoding } catch {}

function Resolve-FullPath { param([string]$Path) return [System.IO.Path]::GetFullPath($Path) }
function Normalize-Rel { param([string]$Rel) return ([string]$Rel).Replace('\', '/').TrimStart('/') }

function Test-RelativePathSafe {
    param([string]$Rel)
    $n = Normalize-Rel $Rel
    if ([string]::IsNullOrWhiteSpace($n)) { return $false }
    if ($n.StartsWith('/') -or $n -match '^[A-Za-z]:') { return $false }
    foreach ($part in $n.Split('/')) { if ($part -eq '..' -or $part -eq '.') { return $false } }
    return $true
}

function Join-SafeRel {
    param([string]$Root, [string]$Rel)
    if (-not (Test-RelativePathSafe -Rel $Rel)) { throw "Unsafe path: $Rel" }
    return Join-Path $Root ((Normalize-Rel $Rel).Replace('/', '\'))
}

function Get-Sha1 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    $hash = [System.Security.Cryptography.SHA1]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        return ([System.BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($stream) { $stream.Dispose() }
        $hash.Dispose()
    }
}

function Test-GlobMatch {
    param([string]$Rel, $Globs)
    $n = Normalize-Rel $Rel
    foreach ($g in @($Globs)) {
        $gg = Normalize-Rel ([string]$g)
        if ([string]::IsNullOrWhiteSpace($gg)) { continue }
        if ($n -like $gg) { return $true }
    }
    return $false
}

function Read-UpdateUrls {
    param([string]$Root, [string]$Override)
    $urls = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param([string]$Value)
        $v = ([string]$Value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v) -and -not $v.StartsWith('#') -and $seen.Add($v)) { [void]$urls.Add($v) }
    }
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        & $add $Override
        return @($urls.ToArray())
    }
    # TFCR-update-url.txt 是旧周目玩家包留下的文件名，老玩家实例里还有——请勿删除。
    $primary = @('UPDATE-URL.txt', 'PORTABLE-UPDATE-URL.txt', 'TFCR-update-url.txt', '_updater\UPDATE-URL.txt', '_updater\PORTABLE-UPDATE-URL.txt')
    $fallback = @('UPDATE-URL-LAN.txt', 'PORTABLE-UPDATE-URL-LAN.txt', '_updater\UPDATE-URL-LAN.txt', '_updater\PORTABLE-UPDATE-URL-LAN.txt')
    foreach ($rel in ($primary + $fallback)) {
        $p = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            foreach ($line in ((Get-Content -LiteralPath $p -Encoding UTF8 -ErrorAction Stop) -split "`r?`n")) { & $add $line }
        } catch {}
    }
    return @($urls.ToArray())
}

function Read-UpdateUrl {
    param([string]$Root, [string]$Override)
    $urls = @(Read-UpdateUrls -Root $Root -Override $Override)
    if ($urls.Count -gt 0) { return [string]$urls[0] }
    return ""
}

function Test-PrivateUpdateUrl {
    param([string]$Url)
    try { $hostName = ([Uri]$Url).Host.ToLowerInvariant() } catch { return $false }
    if ($hostName -in @('localhost', '127.0.0.1', '::1') -or $hostName.EndsWith('.local')) { return $true }
    if ($hostName -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)') { return $true }
    if ($hostName -match '^(fc|fd|fe80:)') { return $true }
    return $false
}

function Test-ManifestUrl {
    param([string]$Url)
    $request = $null
    $response = $null
    $stream = $null
    $reader = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Proxy = $null
        $request.Method = 'GET'
        $request.Timeout = 8000
        $request.ReadWriteTimeout = 8000
        $request.UserAgent = 'portable-server-kit-stage/1.0'
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($stream, (New-Object System.Text.UTF8Encoding($false)), $true)
        $manifest = $reader.ReadToEnd() | ConvertFrom-Json
        return ($null -ne $manifest -and $null -ne $manifest.files)
    } catch {
        return $false
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { try { $request.Abort() } catch {} }
    }
}

function Join-UrlPath {
    param([string]$BaseUrl, [string]$Rel)
    $parts = (Normalize-Rel $Rel).Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
    return $BaseUrl + (($parts) -join '/')
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Value)
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Log {
    param([string]$Message)
    $line = ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogPath -Value ($line + "`r`n") -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

function Test-OfficialHttpsUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try { $uri = [Uri]$Url } catch { return $false }
    if (-not $uri.IsAbsoluteUri) { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    $h = [string]$uri.Host
    if ([string]::IsNullOrWhiteSpace($h)) { return $false }
    if ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -eq '::1') { return $false }
    return $true
}

function Get-OfficialFileUrls {
    param($File)
    $out = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($File -and $File.PSObject.Properties['url'] -and -not [string]::IsNullOrWhiteSpace([string]$File.url)) {
        [void]$candidates.Add(([string]$File.url).Trim())
    }
    if ($File -and $File.PSObject.Properties['downloads']) {
        foreach ($u in @($File.downloads)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$u)) { [void]$candidates.Add(([string]$u).Trim()) }
        }
    }
    foreach ($u in $candidates) {
        if ((Test-OfficialHttpsUrl $u) -and $seen.Add($u)) { [void]$out.Add($u) }
    }
    return @($out)
}

function Get-DownloadFailReason {
    param($Exception)
    $msg = [string]$Exception.Message
    if ($msg -match 'SHA1') { return '哈希不符' }
    if ($msg -match 'too slow|太慢') { return '太慢' }
    if ($msg -match 'timed out|Timeout|超时') { return '超时' }
    if ($msg -match '\(404\)') { return '404' }
    if ($msg -match '\(403\)') { return '403' }
    return '连接失败'
}

$script:StageProxyUrl = $null
$script:StageProxyResolved = $false
$script:OfficialSkip = $false

function Get-StageProxyUrl {
    if ($script:StageProxyResolved) { return [string]$script:StageProxyUrl }
    $script:StageProxyResolved = $true
    $script:StageProxyUrl = ''
    $flag = ([string][Environment]::GetEnvironmentVariable('PORTABLE_SYNC_NOPROXY')).Trim().ToLowerInvariant()
    if ($flag -in @('1', 'true', 'yes', 'on')) { return '' }
    foreach ($key in @('PORTABLE_SYNC_PROXY', 'HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $raw = ([string][Environment]::GetEnvironmentVariable($key)).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if ($raw.StartsWith('socks', [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($raw -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $raw = 'http://' + $raw }
        $script:StageProxyUrl = $raw
        return $script:StageProxyUrl
    }
    try {
        $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$ie.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$ie.ProxyServer)) {
            $server = [string]$ie.ProxyServer
            if ($server -notmatch '=') { $script:StageProxyUrl = $(if ($server -match '://') { $server } else { 'http://' + $server }) }
        }
    } catch {}
    return [string]$script:StageProxyUrl
}

function Test-StageShouldUseProxy {
    param([string]$Url)
    $proxy = Get-StageProxyUrl
    if ([string]::IsNullOrWhiteSpace($proxy)) { return $false }
    try { $h = ([Uri]$Url).Host.ToLowerInvariant() } catch { return $false }
    if ($h -in @('localhost', '127.0.0.1', '::1')) { return $false }
    if ($h.StartsWith('192.168.') -or $h.StartsWith('10.')) { return $false }
    return $true
}

function Save-UrlToFile {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutSec = 120, [switch]$AllowProxy, [int]$MinBytesAfterTimeout = 0)
    $request = [System.Net.HttpWebRequest]::Create($Url)
    if ($AllowProxy) {
        $proxy = Get-StageProxyUrl
        if ($proxy) { $request.Proxy = New-Object System.Net.WebProxy($proxy) } else { $request.Proxy = $null }
    } else {
        $request.Proxy = $null
    }
    $request.Timeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.ReadWriteTimeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.KeepAlive = $false
    try { $request.ServicePoint.Expect100Continue = $false } catch {}
    $request.UserAgent = 'portable-server-kit-stage/1.0'
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $got = [long]0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $checkedSlow = $false
        while (($n = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $n)
            $got += $n
            if ($MinBytesAfterTimeout -gt 0 -and -not $checkedSlow -and $sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
                if ($got -lt $MinBytesAfterTimeout) { throw 'official source too slow' }
                $checkedSlow = $true
            }
        }
    } catch {
        try { $request.Abort() } catch {}
        throw
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

# --- 解析实例目录与暂存区 -------------------------------------------------
$instanceRoot = Resolve-FullPath $InstanceDir
$stageRoot = Join-Path $instanceRoot '.portable-staging'
$readyPath = Join-Path $stageRoot 'READY.json'
$noticePath = Join-Path $instanceRoot '更新已就绪.txt'
$lockPath = Join-Path $stageRoot 'daemon.lock'
$script:LogPath = Join-Path $stageRoot 'daemon.log'

# ==========================================================================
# Promote 模式：把暂存区就地落位，然后自身清空暂存区。仅在游戏未运行时调用（启动脚本里、player-update 之前）。
# ==========================================================================
if ($Mode -eq 'Promote') {
    if (-not (Test-Path -LiteralPath $stageRoot -PathType Container)) { return }
    # 基线 = 上次同步写入状态文件的清单哈希。落位前用它三方判断：目标文件与基线不符
    # 说明玩家本地改过，绝不直接覆盖（丢弃暂存件，交给权威同步器按保留规则裁决）。
    # 没有这层防护时，Promote 会无备份地清掉玩家自改的 config（2026-07-21 玩家实锤）。
    $baseline = @{}
    $syncStatePath = Join-Path $instanceRoot '.portable-sync-state.json'
    if (Test-Path -LiteralPath $syncStatePath -PathType Leaf) {
        try {
            $syncState = Get-Content -LiteralPath $syncStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($item in @($syncState.files)) {
                if ($item -and $item.path -and $item.sha1) { $baseline[(Normalize-Rel ([string]$item.path)).ToLowerInvariant()] = ([string]$item.sha1).ToLowerInvariant() }
            }
        } catch {}
    }
    $files = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
    $promoted = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($stageRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        # 暂存区自身的元文件不落位
        if ($rel -in @('READY.json', 'daemon.lock', 'daemon.log')) { continue }
        if (-not (Test-RelativePathSafe -Rel $rel)) { continue }
        $dest = Join-SafeRel -Root $instanceRoot -Rel $rel
        try {
            # 目标缺失但上次同步基线里有它：交给权威同步器按清单的
            # preserveLocalDeletionGlobs / forceSyncGlobs 裁决，绝不能让
            # 暂存件绕过删除保护直接复活（尤其是玩家删掉的 mods/*.jar）。
            if (-not (Test-Path -LiteralPath $dest -PathType Leaf) -and $baseline.ContainsKey($rel.ToLowerInvariant())) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                Write-Host ("[暂存落位] 目标缺失且已有同步基线，交给同步器裁决：" + $rel)
                continue
            }
            if (Test-Path -LiteralPath $dest -PathType Leaf) {
                $destHash = Get-Sha1 -Path $dest
                $baseHash = [string]$baseline[$rel.ToLowerInvariant()]
                if ($destHash -ne (Get-Sha1 -Path $f.FullName) -and $destHash -ne $baseHash) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    Write-Host ("[暂存落位] 检测到本地修改，跳过：" + $rel)
                    continue
                }
            }
            New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
            Move-Item -LiteralPath $f.FullName -Destination $dest -Force
            $promoted++
        } catch {
            Write-Host ("[暂存落位] 跳过（可能被占用）：" + $rel + "；" + $_.Exception.Message)
        }
    }
    if ($promoted -gt 0) { Write-Host ("[暂存落位] 已落位 $promoted 个预下载文件，交给同步器校验。") }
    # 清空暂存区（含元文件），下个会话重新开始。落位失败残留的文件保留，等下次。
    try {
        Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $noticePath -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $stageRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } }
    } catch {}
    return
}

# ==========================================================================
# Watch 模式：后台轮询 + 增量暂存
# ==========================================================================
# 自身最小化控制台（运行时 ShowWindow，非命令行 -WindowStyle Hidden——后者会命中火绒
# PS.NetLoader 启发式害得拉起它的 bat 被删。控制面板同款手法，已验证安全）。
try {
    if (-not ([System.Management.Automation.PSTypeName]'PortableWin32').Type) {
        Add-Type -Namespace '' -Name 'PortableWin32' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool FlashWindow(System.IntPtr hWnd, bool bInvert);
'@ -ErrorAction SilentlyContinue
    }
    $hwnd = [PortableWin32]::GetConsoleWindow()
    if ($hwnd -ne [System.IntPtr]::Zero) { [void][PortableWin32]::ShowWindow($hwnd, 6) }  # 6 = SW_MINIMIZE
} catch {}

New-Item -ItemType Directory -Force $stageRoot | Out-Null

# --- 单例锁：同一实例只允许一个 daemon 在跑 ------------------------------
if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    $oldPid = 0
    try { $oldPid = [int]((Get-Content -LiteralPath $lockPath -Raw -ErrorAction SilentlyContinue).Trim()) } catch { $oldPid = 0 }
    if ($oldPid -gt 0) {
        $alive = $null
        try { $alive = Get-Process -Id $oldPid -ErrorAction SilentlyContinue } catch { $alive = $null }
        if ($alive) { Write-Host "[暂存] 已有 daemon 在运行（PID $oldPid），本次退出。"; return }
    }
}
Set-Content -LiteralPath $lockPath -Value ([string]$PID) -Encoding ASCII

$manifestUrls = @(Read-UpdateUrls -Root $instanceRoot -Override $ManifestUrl)
if ($manifestUrls.Count -eq 0) {
    Write-Log "未找到 UPDATE-URL，暂存 daemon 退出。"
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    return
}
$manifestUrls = @(@($manifestUrls | Where-Object { Test-PrivateUpdateUrl $_ }) + @($manifestUrls | Where-Object { -not (Test-PrivateUpdateUrl $_) }))
$manifestUrl = ""
$selectedIndex = -1
for ($i = 0; $i -lt $manifestUrls.Count; $i++) {
    if (Test-ManifestUrl -Url ([string]$manifestUrls[$i])) {
        $manifestUrl = [string]$manifestUrls[$i]
        $selectedIndex = $i
        break
    }
}
if ([string]::IsNullOrWhiteSpace($manifestUrl)) {
    Write-Log "更新源暂时不可达，暂存 daemon 本轮不启动；下次玩家同步会重试。"
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    return
}
if ($selectedIndex -gt 0) { Write-Log "已切换到备用更新地址（通常是局域网地址）。" }
$baseUrl = $manifestUrl.Substring(0, $manifestUrl.LastIndexOf('/') + 1)
Write-Log ("暂存 daemon 启动 (PID $PID)，间隔 ${IntervalSeconds}s，最长 ${MaxRuntimeMinutes} 分钟。")

# 本地 sha1 缓存：key = "rel|size|mtimeTicks"，避免每轮重算数百 MB 的哈希。
$script:LocalShaCache = @{}
function Get-LocalSha1Cached {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    $fi = Get-Item -LiteralPath $Path
    $key = ("{0}|{1}|{2}" -f $Path.ToLowerInvariant(), $fi.Length, $fi.LastWriteTimeUtc.Ticks)
    if ($script:LocalShaCache.ContainsKey($key)) { return $script:LocalShaCache[$key] }
    $h = Get-Sha1 -Path $Path
    $script:LocalShaCache[$key] = $h
    return $h
}

# 条件请求拉清单：带上一版的 Last-Modified，服务器没变就回 304（几乎零流量），
# 这样才能把轮询降到 30s 也不心疼。更新服基于 SimpleHTTPRequestHandler，支持 If-Modified-Since。
$script:LastModified = $null
function Get-ManifestIfChanged {
    param([string]$Url)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Proxy = $null
    $req.Method = 'GET'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000
    try { $req.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore) } catch {}
    if ($script:LastModified) { $req.IfModifiedSince = $script:LastModified }
    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response
        if ($r) {
            try { $sc = [int]$r.StatusCode } catch { $sc = 0 }
            $r.Close()
            if ($sc -eq 304) { return [pscustomobject]@{ Changed = $false; Text = $null } }
        }
        throw
    }
    try {
        # 只在服务器真的给了 Last-Modified 时才记录，否则保持 $null 走全量兜底，避免误判为"永远未变"。
        $lm = $resp.Headers['Last-Modified']
        if (-not [string]::IsNullOrWhiteSpace($lm)) {
            try { $script:LastModified = [DateTime]::Parse($lm, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch {}
        }
        $stream = $resp.GetResponseStream()
        $sr = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
        return [pscustomobject]@{ Changed = $true; Text = ($text.TrimStart([char]0xFEFF)) }
    } finally { $resp.Close() }
}

function Save-StagedFile {
    param([string]$Url, [string]$Destination, [string]$ExpectedSha1, [switch]$AllowProxy, [int]$TimeoutSec = 120, [int]$MinBytesAfterTimeout = 0)
    New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("portable-stage-" + [System.Guid]::NewGuid().ToString('N') + ".tmp")
    try {
        Save-UrlToFile -Url $Url -Path $tmp -TimeoutSec $TimeoutSec -AllowProxy:$AllowProxy -MinBytesAfterTimeout $MinBytesAfterTimeout
        $actual = Get-Sha1 -Path $tmp
        if ($actual -ne $ExpectedSha1.ToLowerInvariant()) { throw "SHA1 mismatch expected=$ExpectedSha1 actual=$actual" }
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Save-StagedEntry {
    param($File, [string]$BaseUrl, [string]$Destination, [string]$ExpectedSha1, [string]$Rel)
    $urls = @()
    if (-not $script:OfficialSkip) { $urls = @(Get-OfficialFileUrls $File) }
    foreach ($url in $urls) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $useProxy = Test-StageShouldUseProxy $url
        try {
            Save-StagedFile -Url $url -Destination $Destination -ExpectedSha1 $ExpectedSha1 -TimeoutSec 8 -AllowProxy:$useProxy -MinBytesAfterTimeout (256KB)
            return 'official'
        } catch {
            Write-Log ("[预下载] 官方源不可用（{0:N1}s，{1}），改走更新服务：{2}" -f $sw.Elapsed.TotalSeconds, (Get-DownloadFailReason $_.Exception), $Rel)
            if (-not $script:OfficialSkip) {
                $script:OfficialSkip = $true
                Write-Log '[预下载] 官方源本轮不再尝试，其余文件直接走更新服务。'
            }
            break
        }
    }
    Save-StagedFile -Url (Join-UrlPath -BaseUrl $BaseUrl -Rel $Rel) -Destination $Destination -ExpectedSha1 $ExpectedSha1
    return 'home'
}

function Test-GameRunning {
    # 严格：只认命令行精确含本实例路径的进程 = 本实例的游戏在跑。
    # 这样守 A 实例的 daemon 绝不会被主客户端/别的实例/无关 java 带偏（每实例各管各的，语义干净）。
    # 主客户端的 --gameDir 是它自己的版本目录、不含本实例路径，故它在跑不会误判成本实例在跑。
    # 仅当"完全读不到任何 java 命令行"（权限）时才保守当作在跑，避免误退。
    param([string]$Root)
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue
    } catch { return $true }
    if (-not $procs) { return $false }
    $needle = $Root.ToLowerInvariant()
    $sawCmdline = $false
    foreach ($p in $procs) {
        $cl = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($cl)) { continue }
        $sawCmdline = $true
        if ($cl.ToLowerInvariant().Contains($needle)) { return $true }
    }
    if (-not $sawCmdline) { return $true }
    return $false
}

function Show-Toast {
    param([string]$Title, [string]$Text)
    if (-not $Toast) { return }
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $tmpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $tmpl.GetElementsByTagName('text')
        $texts.Item(0).AppendChild($tmpl.CreateTextNode($Title)) | Out-Null
        $texts.Item(1).AppendChild($tmpl.CreateTextNode($Text)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($tmpl)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('便携整合包同步').Show($toast)
    } catch {
        # 系统不支持 toast 时静默；READY.json + 更新已就绪.txt + 下面的窗口提醒才是主通道。
    }
}

function Show-ReadyNotice {
    # 主通道（可靠、不抢焦点）：把最小化的小黑窗还原（不激活）+ 任务栏闪烁 + 大字横幅 + 改标题。
    # 玩家 alt-tab 或瞄一眼任务栏就能看到，全程不打断正在玩的游戏。toast 只作锦上添花。
    param([string]$Text)
    try {
        $hwnd = [PortableWin32]::GetConsoleWindow()
        if ($hwnd -ne [System.IntPtr]::Zero) {
            [void][PortableWin32]::ShowWindow($hwnd, 4)  # 4 = SW_SHOWNOACTIVATE：显示但不抢焦点
            for ($i = 0; $i -lt 8; $i++) { [void][PortableWin32]::FlashWindow($hwnd, $true); Start-Sleep -Milliseconds 200 }
        }
        try { $Host.UI.RawUI.WindowTitle = '★ 整合包更新已就绪 — 重开游戏即可生效 ★' } catch {}
    } catch {}
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ('  ' + $Text) -ForegroundColor Yellow
    Write-Host '  退出游戏后重开「更新mod-Windows端.bat」即可用上新内容' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ''
    Show-Toast -Title '整合包更新已就绪' -Text $Text
}

$startTime = Get-Date
$lastManifestText = ""
$idleGameChecks = 0
$stagedTotal = 0
$firstIteration = $true

try {
    while ($true) {
        # 启动后先等 3s 立刻探一次（不让玩家干等一个轮询周期）；此后每 IntervalSeconds 一轮。
        if ($firstIteration) { $firstIteration = $false; Start-Sleep -Seconds 3 } else { Start-Sleep -Seconds $IntervalSeconds }

        $elapsedMin = ((Get-Date) - $startTime).TotalMinutes
        if ($elapsedMin -ge $MaxRuntimeMinutes) { Write-Log "达到最长运行时间，退出。"; break }

        # 生命周期：过了宽限期后，若连续多次检测不到本实例的游戏进程，判定玩家已退出，收工。
        if ($elapsedMin -ge $GraceMinutes) {
            if (Test-GameRunning -Root $instanceRoot) { $idleGameChecks = 0 }
            else {
                $idleGameChecks++
                if ($idleGameChecks -ge $IdleExitChecks) { Write-Log "检测到游戏已退出，暂存 daemon 收工。"; break }
            }
        }

        try {
        # 条件请求拉清单：304（未变化）或失败都跳过本轮，几乎零负担。
        $mres = $null
        try { $mres = Get-ManifestIfChanged -Url $manifestUrl } catch { Write-Log ("清单获取失败：" + $_.Exception.Message); continue }
        if (-not $mres.Changed) { continue }
        $manifestText = [string]$mres.Text
        if ([string]::IsNullOrWhiteSpace($manifestText)) { continue }
        # 二次保险：内容和上一版逐字节相同就跳过（防服务器不给 Last-Modified 时的空转）。
        if ($manifestText -eq $lastManifestText) { continue }

        $manifest = $null
        try { $manifest = $manifestText | ConvertFrom-Json } catch { Write-Log "清单解析失败，跳过本轮。"; continue }
        if (-not $manifest.files) { $lastManifestText = $manifestText; continue }
        $lastManifestText = $manifestText

        $preserveChangeGlobs = @()
        if ($manifest.PSObject.Properties['preserveLocalChangeGlobs']) { $preserveChangeGlobs = @($manifest.preserveLocalChangeGlobs) }
        $preserveDeletionGlobs = @()
        if ($manifest.PSObject.Properties['preserveLocalDeletionGlobs']) { $preserveDeletionGlobs = @($manifest.preserveLocalDeletionGlobs) }
        $forceSyncGlobs = @()
        if ($manifest.PSObject.Properties['forceSyncGlobs']) { $forceSyncGlobs = @($manifest.forceSyncGlobs) }
        $preservePlayerCustomizations = $true
        if ($manifest.PSObject.Properties['preservePlayerCustomizations']) { $preservePlayerCustomizations = [bool]$manifest.preservePlayerCustomizations }
        # 基线 = 上次同步的清单哈希：本地文件与基线不符即玩家改过，不预下载（与 Promote 同一防线）。
        $baseline = @{}
        $syncStatePath = Join-Path $instanceRoot '.portable-sync-state.json'
        if (Test-Path -LiteralPath $syncStatePath -PathType Leaf) {
            try {
                $syncState = Get-Content -LiteralPath $syncStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($item in @($syncState.files)) {
                    if ($item -and $item.path -and $item.sha1) { $baseline[(Normalize-Rel ([string]$item.path)).ToLowerInvariant()] = ([string]$item.sha1).ToLowerInvariant() }
                }
            } catch {}
        }

        Write-Log "检测到新清单，开始比对并后台预下载……"
        $newStaged = 0
        $stagedList = New-Object System.Collections.Generic.List[string]
        foreach ($file in @($manifest.files)) {
            $rel = Normalize-Rel ([string]$file.path)
            if (-not (Test-RelativePathSafe -Rel $rel)) { continue }
            if ($rel -in @('server-manifest.json', 'update-log.txt')) { continue }
            $expected = ([string]$file.sha1).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($expected)) { continue }
            # 玩家会本地改动/保留的文件（options、模组配置、资源包、光影、存档等）不预下载，避免打架。
            # forceSyncGlobs 例外：管理员点名强推的文件照常预下载。
            $isForceSync = Test-GlobMatch -Rel $rel -Globs $forceSyncGlobs
            if (-not $isForceSync -and (Test-GlobMatch -Rel $rel -Globs $preserveChangeGlobs)) { continue }

            $localPath = Join-SafeRel -Root $instanceRoot -Rel $rel
            $localHash = Get-LocalSha1Cached -Path $localPath
            if ($localHash -eq $expected) { continue }  # 本地已是最新，无需暂存
            $baseHash = if ($baseline.ContainsKey($rel.ToLowerInvariant())) { [string]$baseline[$rel.ToLowerInvariant()] } else { '' }
            # 与 player-update-generic.ps1 保持同一语义：已在上次清单中、
            # 当前被玩家删除、且命中删除保留规则的文件不预下载。
            # 若旧 daemon 已留下暂存件，也在这里丢弃，避免下一次落位复活。
            if ([string]::IsNullOrWhiteSpace($localHash) -and -not [string]::IsNullOrWhiteSpace($baseHash) -and
                $preservePlayerCustomizations -and -not $isForceSync -and (Test-GlobMatch -Rel $rel -Globs $preserveDeletionGlobs)) {
                $stagePath = Join-SafeRel -Root $stageRoot -Rel $rel
                if (Test-Path -LiteralPath $stagePath -PathType Leaf) {
                    Remove-Item -LiteralPath $stagePath -Force -ErrorAction SilentlyContinue
                    Write-Log ("[预下载] 保留玩家删除，丢弃旧暂存：" + $rel)
                }
                continue
            }
            if (-not $isForceSync -and $localHash) {
                # 本地存在但与基线不符（或没有基线记录）= 玩家改过：不预下载，交给权威同步器按规则裁决。
                if (-not $baseHash -or $localHash -ne $baseHash) { continue }
            }

            $stagePath = Join-SafeRel -Root $stageRoot -Rel $rel
            if ((Test-Path -LiteralPath $stagePath -PathType Leaf) -and ((Get-Sha1 -Path $stagePath) -eq $expected)) { continue }  # 已暂存

            try {
                $source = Save-StagedEntry -File $file -BaseUrl $baseUrl -Destination $stagePath -ExpectedSha1 $expected -Rel $rel
                if ($source -eq 'official') { Write-Log ("[预下载/官方源] " + $rel) } else { Write-Log ("[预下载] " + $rel) }
                $newStaged++
                [void]$stagedList.Add($rel)
            } catch {
                Write-Log ("[预下载失败] " + $rel + "；" + $_.Exception.Message)
            }
        }

        if ($newStaged -gt 0) {
            $stagedTotal += $newStaged
            $version = ''
            if ($manifest.PSObject.Properties['version']) { $version = [string]$manifest.version }
            $ready = [ordered]@{
                version = $version
                stagedAt = (Get-Date).ToString('s')
                count = $stagedTotal
                lastBatch = @($stagedList)
            }
            Write-Utf8NoBom -Path $readyPath -Value (($ready | ConvertTo-Json -Depth 6) + "`r`n")
            Write-Utf8NoBom -Path $noticePath -Value ("整合包有更新，已在后台下载完成 $stagedTotal 个文件。`r`n重启游戏即可自动生效（无需再等下载）。`r`n版本：$version`r`n" )
            Write-Log ("本轮预下载完成 $newStaged 个，累计 $stagedTotal 个；已写就绪标记。")
            Show-ReadyNotice -Text "整合包更新已在后台下载完成（$stagedTotal 个文件）"
        } else {
            Write-Log "清单有变化，但无需预下载的新文件（可能只是元数据/被保留项）。"
        }
        } catch {
            # 兜住本轮任何未预期异常：记进日志、继续下一轮，绝不让 daemon 崩掉或在小黑窗里闪红。
            Write-Log ("本轮异常已跳过：" + $_.Exception.Message)
        }
    }
} finally {
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    Write-Log "暂存 daemon 已退出。"
}
