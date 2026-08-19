param(
    [string]$InstanceDir = ".",
    [string]$ManifestUrl = "",
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# PS 5.1 默认不启用 TLS 1.2；更新源切 HTTPS 后没有这行会直接握手失败。对 HTTP 无影响。
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

function Resolve-FullPath { param([Parameter(Mandatory = $true)][string]$Path) return [System.IO.Path]::GetFullPath($Path) }
# 注意 '\' 与 '\\'：PowerShell 单引号不转义，String.Replace 是字面替换而非正则。
# 这里必须是单反斜杠——写成 '\\' 只会替换「连续两个反斜杠」，单反斜杠路径根本不会被规范化，
# 于是 Test-RelativePathSafe 按 '/' 切分时看不到 '..' 段，形如 ..\..\x 的路径会绕过安全检查。
function Normalize-Rel { param([string]$Rel) return ([string]$Rel).Replace('\', '/').TrimStart('/') }
function Normalize-RelKey { param([string]$Rel) return (Normalize-Rel $Rel).ToLowerInvariant() }

function Test-RelativePathSafe {
    param([Parameter(Mandatory = $true)][string]$Rel)
    $normalized = Normalize-Rel $Rel
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:') { return $false }
    foreach ($part in $normalized.Split('/')) {
        if ($part -eq '..') { return $false }
    }
    return $true
}

function Join-SafeRelativePath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Rel)
    if (-not (Test-RelativePathSafe -Rel $Rel)) { throw "Unsafe manifest path: $Rel" }
    return Join-Path $Root ((Normalize-Rel $Rel).Replace('/', '\'))
}

function Get-Sha1 {
    param([Parameter(Mandatory = $true)][string]$Path)
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

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Value)
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Read-UpdateUrls {
    param([string]$Root, [string]$Override)
    $rawValues = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        [void]$rawValues.Add($Override)
    } else {
        # TFCR-update-url.txt 是旧周目玩家包留下的文件名，老玩家实例里还有——请勿删除。
        $primary = @('UPDATE-URL.txt', 'PORTABLE-UPDATE-URL.txt', 'TFCR-update-url.txt', '_updater\UPDATE-URL.txt', '_updater\PORTABLE-UPDATE-URL.txt')
        foreach ($rel in $primary) {
            $path = Join-Path $Root $rel
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try { [void]$rawValues.Add((Get-Content -LiteralPath $path -Raw -Encoding UTF8)) } catch { }
            }
        }
    }
    $urls = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in $rawValues) {
        foreach ($line in ([string]$raw -split "`r?`n")) {
            $value = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('#')) { continue }
            if ($seen.Add($value)) { [void]$urls.Add($value) }
        }
    }
    if ($urls.Count -eq 0) { throw '找不到 UPDATE-URL.txt。请确认玩家包没有被拆散，或使用 -ManifestUrl 手动指定 server-manifest.json 地址。' }
    return @($urls)
}

function Read-UpdateUrl {
    param([string]$Root, [string]$Override)
    return (Read-UpdateUrls -Root $Root -Override $Override | Select-Object -First 1)
}

function ConvertTo-FileMap {
    param($Files)
    $map = @{}
    foreach ($file in @($Files)) {
        if ($file -and $file.path) { $map[(Normalize-RelKey ([string]$file.path))] = [string]$file.sha1 }
    }
    return $map
}

function Test-GlobMatch {
    param([Parameter(Mandatory = $true)][string]$Rel, $Globs)
    $normalized = Normalize-Rel $Rel
    foreach ($glob in @($Globs)) {
        $g = Normalize-Rel ([string]$glob)
        if ([string]::IsNullOrWhiteSpace($g)) { continue }
        if ($normalized -like $g) { return $true }
    }
    return $false
}

function Join-UrlPath {
    param([Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$Rel)
    $parts = (Normalize-Rel $Rel).Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
    return $BaseUrl + (($parts) -join '/')
}

function Get-MaskedUrl {
    # 更新地址首个路径段是访问 token，玩家截图求助时容易泄漏，打印前掩码。
    param([string]$Url)
    return [regex]::Replace([string]$Url, '(?<=^[A-Za-z][A-Za-z0-9+.-]*://[^/]+/)[^/]+(?=/)', '***')
}

function Test-ProtectedRel {
    # 同步自身生成的备份/归档目录，任何清理规则都不得删除。
    param([string]$Rel)
    $normalized = Normalize-Rel $Rel
    return ($normalized -like '.portable-sync-backups/*' -or $normalized -like '_disabled_*/*')
}

function Backup-FileIfExists {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Rel, [Parameter(Mandatory = $true)][string]$BackupRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $backupPath = Join-SafeRelativePath -Root $BackupRoot -Rel $Rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $backupPath) | Out-Null
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
}

$script:ProxyUrl = $null
$script:ProxyResolved = $false
$script:OfficialSkip = $false
$script:OfficialSkipNotified = $false
$script:OfficialMinBytes = 1MB
$script:OfficialMinRateBps = 128KB
$script:PrivateProbeTimeoutSec = 2
$script:PublicProbeTimeoutSec = 8

function Normalize-ProxyUrl {
    param([string]$Raw)
    $raw = ([string]$Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    if ($raw.StartsWith('socks', [StringComparison]::OrdinalIgnoreCase)) { return '' }
    if ($raw -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $raw = 'http://' + $raw }
    try {
        $uri = [Uri]$raw
        if ($uri.Scheme -notin @('http', 'https')) { return '' }
        if ([string]::IsNullOrWhiteSpace($uri.Host)) { return '' }
        return $raw
    } catch { return '' }
}

function ConvertFrom-WinProxyServer {
    param([string]$Server)
    $server = ([string]$Server).Trim()
    if ([string]::IsNullOrWhiteSpace($server)) { return '' }
    if ($server -match '=') {
        $map = @{}
        foreach ($item in $server.Split(';')) {
            if ($item -notmatch '=') { continue }
            $pair = $item.Split('=', 2)
            $map[$pair[0].Trim().ToLowerInvariant()] = $pair[1].Trim()
        }
        foreach ($key in @('https', 'http')) {
            if ($map.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($map[$key])) {
                $parsed = Normalize-ProxyUrl $map[$key]
                if ($parsed) { return $parsed }
            }
        }
        return ''
    }
    return (Normalize-ProxyUrl $server)
}

function Get-SystemProxyUrl {
    if ($script:ProxyResolved) { return [string]$script:ProxyUrl }
    $script:ProxyResolved = $true
    $script:ProxyUrl = ''
    $flag = ([string][Environment]::GetEnvironmentVariable('PORTABLE_SYNC_NOPROXY')).Trim().ToLowerInvariant()
    if ($flag -in @('1', 'true', 'yes', 'on')) { return '' }
    $override = Normalize-ProxyUrl ([Environment]::GetEnvironmentVariable('PORTABLE_SYNC_PROXY'))
    if ($override) { $script:ProxyUrl = $override; return $script:ProxyUrl }
    foreach ($key in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy')) {
        $parsed = Normalize-ProxyUrl ([Environment]::GetEnvironmentVariable($key))
        if ($parsed) { $script:ProxyUrl = $parsed; return $script:ProxyUrl }
    }
    try {
        $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$ie.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$ie.ProxyServer)) {
            $parsed = ConvertFrom-WinProxyServer ([string]$ie.ProxyServer)
            if ($parsed) { $script:ProxyUrl = $parsed; return $script:ProxyUrl }
        }
    } catch {}
    return ''
}

function Get-ProxyDescription {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { $Url = Get-SystemProxyUrl }
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    try {
        $uri = [Uri]$Url
        if ($uri.Port -gt 0) { return ($uri.Host + ':' + $uri.Port) }
        return $uri.Host
    } catch { return $Url }
}

function Test-LocalOrPrivateHost {
    param([string]$HostName)
    $h = ([string]$HostName).Trim().Trim('[', ']').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($h)) { return $true }
    if ($h -in @('localhost', '127.0.0.1', '::1')) { return $true }
    $parts = $h.Split('.')
    if ($parts.Count -eq 4) {
        $nums = @()
        foreach ($p in $parts) {
            $n = 0
            if (-not [int]::TryParse($p, [ref]$n)) { return $false }
            $nums += $n
        }
        $a = $nums[0]; $b = $nums[1]
        if ($a -eq 127 -or $a -eq 10) { return $true }
        if ($a -eq 192 -and $b -eq 168) { return $true }
        if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $true }
    }
    return $false
}

function Test-UrlBypassesProxy {
    param([string]$Url)
    try { $hostName = ([Uri]$Url).Host } catch { return $true }
    if (Test-LocalOrPrivateHost $hostName) { return $true }
    $raw = [Environment]::GetEnvironmentVariable('NO_PROXY')
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = [Environment]::GetEnvironmentVariable('no_proxy') }
    foreach ($item in @(([string]$raw).Split(','))) {
        $rule = $item.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($rule)) { continue }
        if ($rule -eq '*') { return $true }
        $h = $hostName.ToLowerInvariant()
        if ($rule.StartsWith('.')) {
            if ($h.EndsWith($rule) -or $h -eq $rule.Substring(1)) { return $true }
        } elseif ($h -eq $rule -or $h.EndsWith('.' + $rule)) { return $true }
    }
    return $false
}

function Test-ShouldUseProxyForOfficial {
    param([string]$Url)
    $proxy = Get-SystemProxyUrl
    if ([string]::IsNullOrWhiteSpace($proxy)) { return $false }
    if (Test-UrlBypassesProxy $Url) { return $false }
    return $true
}

function Get-ProbeTimeoutSec {
    param([string]$Url)
    try { $hostName = ([Uri]$Url).Host } catch { return $script:PublicProbeTimeoutSec }
    if (Test-LocalOrPrivateHost $hostName) { return $script:PrivateProbeTimeoutSec }
    return $script:PublicProbeTimeoutSec
}

function Test-PrivateUpdateUrl {
    param([string]$Url)
    try { return (Test-LocalOrPrivateHost ([Uri]$Url).Host) } catch { return $false }
}

function Get-OrderedManifestUrls {
    param([string[]]$Urls, [string]$LastGood = '')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $out = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$Value)
        $v = ([string]$Value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v) -and $seen.Add($v)) { [void]$out.Add($v) }
    }
    $public = @($Urls | Where-Object { -not (Test-PrivateUpdateUrl $_) })
    $candidates = if ($public.Count -gt 0) { $public } else { @($Urls) }
    if (-not [string]::IsNullOrWhiteSpace($LastGood) -and -not (Test-PrivateUpdateUrl $LastGood)) { & $add $LastGood }
    foreach ($u in $candidates) { & $add $u }
    return @($out)
}

function Get-FileVerifyRecord {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Sha1)
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{ sha1 = $Sha1.ToLowerInvariant(); size = [int64]$item.Length; mtime = [int64][double]$item.LastWriteTimeUtc.Subtract([datetime]'1970-01-01Z').TotalSeconds }
}

function Test-LooksLikeCurrentFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        $ManifestSize,
        [string]$PreviousHash,
        $Verified
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $false }
    $item = Get-Item -LiteralPath $Path
    $size = [int64]$item.Length
    if ($null -ne $ManifestSize -and [string]$ManifestSize -ne '' -and [string]$ManifestSize -ne '0') {
        try { if ($size -ne [int64]$ManifestSize) { return $false } } catch {}
    }
    $expected = $Expected.ToLowerInvariant()
    $previous = ([string]$PreviousHash).ToLowerInvariant()
    $vSha = ''
    $vSize = [int64]-1
    $vMtime = [int64]-1
    if ($Verified) {
        try { $vSha = ([string]$Verified.sha1).ToLowerInvariant() } catch {}
        try { $vSize = [int64]$Verified.size } catch {}
        try { $vMtime = [int64]$Verified.mtime } catch {}
    }
    $mtime = [int64][double]$item.LastWriteTimeUtc.Subtract([datetime]'1970-01-01Z').TotalSeconds
    if ($previous -eq $expected) {
        if ($vSha -eq $expected) {
            if ($vSize -eq $size -and $vMtime -eq $mtime) { return $true }
            return ((Get-Sha1 -Path $Path) -eq $expected)
        }
        return $true
    }
    if ($vSha -eq $expected -and $vSize -eq $size -and $vMtime -eq $mtime) { return $true }
    return ((Get-Sha1 -Path $Path) -eq $expected)
}

function New-DirectHttpRequest {
    param([Parameter(Mandatory = $true)][string]$Url, [int]$TimeoutSec = 30, [switch]$AllowProxy)
    # 家宽更新源走非标准端口，系统代理（Clash/安全软件）可能把请求丢进黑洞，必须直连。
    # 官方 CDN 有代理时走代理（国内直连经常能通但很慢）；走代理时不要改写成 IPv4，
    # 否则 HTTPS CONNECT / Clash 分流对不上域名。
    $target = $Url
    $hostHeader = $null
    if (-not $AllowProxy) {
        try {
            $uri = [Uri]$Url
            if ($uri.HostNameType -eq [UriHostNameType]::Dns) {
                $ipv4 = [Net.Dns]::GetHostAddresses($uri.Host) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                    Select-Object -First 1
                if ($ipv4) {
                    $b = New-Object UriBuilder $uri
                    $b.Host = $ipv4.IPAddressToString
                    $target = $b.Uri.AbsoluteUri
                    $hostHeader = $uri.Host
                }
            }
        } catch {}
    }
    $request = [System.Net.HttpWebRequest]::Create($target)
    if ($hostHeader) { $request.Host = $hostHeader }
    if ($AllowProxy) {
        $proxy = Get-SystemProxyUrl
        if ($proxy) { $request.Proxy = New-Object System.Net.WebProxy($proxy) }
    } else {
        $request.Proxy = $null
    }
    $request.Timeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.ReadWriteTimeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.KeepAlive = $false
    try { $request.ServicePoint.Expect100Continue = $false } catch {}
    $request.UserAgent = 'portable-server-kit-sync/1.0'
    try { $request.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore) } catch {}
    return $request
}

function Get-DownloadFailReason {
    param($Exception)
    $msg = [string]$Exception.Message
    if ($msg -match 'SHA1') { return '哈希不符' }
    if ($msg -match 'too slow|太慢') { return '太慢' }
    if ($msg -match 'timed out|Timeout|超时') { return '超时' }
    if ($msg -match '\(404\)') { return '404' }
    if ($msg -match '\(403\)') { return '403' }
    if ($msg -match '无法解析|name or service|DNS') { return 'DNS' }
    return '连接失败'
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

function Read-UrlUtf8Text {
    # 更新源重启/隧道瞬断会短暂 502/503，重试几次再放弃。
    param([Parameter(Mandatory = $true)][string]$Url, [int]$TimeoutSec = 30, [int]$Retries = 2)
    for ($attempt = 0; $attempt -le $Retries; $attempt++) {
        $request = $null
        $response = $null
        $reader = $null
        try {
            $request = New-DirectHttpRequest -Url $Url -TimeoutSec $TimeoutSec
            $response = $request.GetResponse()
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            return ($reader.ReadToEnd()).TrimStart([char]0xFEFF)
        } catch {
            if ($attempt -ge $Retries) { throw }
            $wait = if ($TimeoutSec -le 2) { 0 } else { 3 }
            if ($wait -gt 0) {
                Write-Host ("[同步] 清单获取失败（第 " + ($attempt + 1) + " 次）：" + $_.Exception.Message + "；${wait} 秒后重试...")
                Start-Sleep -Seconds $wait
            }
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }
}

function Copy-DownloadStream {
    param($InputStream, $OutputStream, [int]$TimeoutSec = 60, [int]$MinBytesAfterTimeout = 0, [int]$MinRateBps = 0)
    $buffer = New-Object byte[] 65536
    $got = [long]0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $nextCheck = [double]$TimeoutSec
    while (($n = $InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $OutputStream.Write($buffer, 0, $n)
        $got += $n
        if ($nextCheck -le 0) { continue }
        $elapsed = $sw.Elapsed.TotalSeconds
        if ($elapsed -lt $nextCheck) { continue }
        if ($MinRateBps -gt 0 -and $got -lt ($MinRateBps * $elapsed)) { throw 'official source too slow' }
        if ($MinBytesAfterTimeout -gt 0 -and $got -lt $MinBytesAfterTimeout) { throw 'official source too slow' }
        $nextCheck = $elapsed + [Math]::Max(1, $TimeoutSec)
    }
}

function Save-OfficialViaProxy {
    # HttpWebRequest + 系统代理时 Timeout 经常不生效。先用 HttpClient 拿响应头（8 秒取消），
    # 再按字节流读 body：8 秒内字节太少就放弃，避免国内直连细水长流。
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutSec = 8, [string]$ProxyUrl, [int]$MinBytesAfterTimeout = 0, [int]$MinRateBps = 0)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $true
    $handler.Proxy = New-Object System.Net.WebProxy($ProxyUrl)
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'portable-server-kit-sync/1.0') | Out-Null
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter([Math]::Max(1000, $TimeoutSec * 1000))
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ("HTTP {0} from official proxy download" -f [int]$response.StatusCode)
        }
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        Copy-DownloadStream -InputStream $inputStream -OutputStream $outputStream -TimeoutSec $TimeoutSec -MinBytesAfterTimeout $MinBytesAfterTimeout -MinRateBps $MinRateBps
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        $cts.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Save-UrlToFile {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutSec = 60, [switch]$AllowProxy, [int]$MinBytesAfterTimeout = 0, [int]$MinRateBps = 0)
    if ($AllowProxy) {
        $proxy = Get-SystemProxyUrl
        if ($proxy) {
            Save-OfficialViaProxy -Url $Url -Path $Path -TimeoutSec $TimeoutSec -ProxyUrl $proxy -MinBytesAfterTimeout $MinBytesAfterTimeout -MinRateBps $MinRateBps
            return
        }
    }
    $request = New-DirectHttpRequest -Url $Url -TimeoutSec $TimeoutSec -AllowProxy:$AllowProxy
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        Copy-DownloadStream -InputStream $inputStream -OutputStream $outputStream -TimeoutSec $TimeoutSec -MinBytesAfterTimeout $MinBytesAfterTimeout -MinRateBps $MinRateBps
    } catch {
        try { $request.Abort() } catch {}
        throw
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}
function Download-ManifestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSha1,
        [switch]$AllowProxy,
        [int]$TimeoutSec = 60,
        [int]$Retries = 1,
        [int]$MinBytesAfterTimeout = 0,
        [int]$MinRateBps = 0
    )
    New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("portable-sync-" + [System.Guid]::NewGuid().ToString('N') + ".tmp")
    try {
        $attempt = 0
        while ($true) {
            try {
                Save-UrlToFile -Url $Url -Path $tmp -TimeoutSec $TimeoutSec -AllowProxy:$AllowProxy -MinBytesAfterTimeout $MinBytesAfterTimeout -MinRateBps $MinRateBps
                break
            } catch {
                $attempt++
                if ($attempt -gt $Retries) { throw }
                Start-Sleep -Seconds 2
            }
        }
        $actual = Get-Sha1 -Path $tmp
        if ($actual -ne $ExpectedSha1.ToLowerInvariant()) { throw "SHA1 mismatch for $(Get-MaskedUrl $Url). expected=$ExpectedSha1 actual=$actual" }
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Set-OfficialSkip {
    $script:OfficialSkip = $true
    if (-not $script:OfficialSkipNotified) {
        $script:OfficialSkipNotified = $true
        Write-Host '[同步] 官方源本轮不再尝试，其余文件直接走更新服务。'
    }
}

function Download-ManifestEntry {
    param($File, [Parameter(Mandatory = $true)][string]$BaseUrl, [Parameter(Mandatory = $true)][string]$Destination, [Parameter(Mandatory = $true)][string]$ExpectedSha1, [Parameter(Mandatory = $true)][string]$Rel)
    # 官方源：有系统代理就走代理；8 秒内字节太少或失败立刻回落家宽。
    # 家宽始终直连。本轮官方失败一次后不再试，避免每个文件白等 8 秒。
    $urls = @()
    if (-not $script:OfficialSkip) { $urls = @(Get-OfficialFileUrls $File) }
    foreach ($url in $urls) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $useProxy = Test-ShouldUseProxyForOfficial $url
        try {
            Download-ManifestFile -Url $url -Destination $Destination -ExpectedSha1 $ExpectedSha1 -TimeoutSec 8 -Retries 0 -AllowProxy:$useProxy -MinBytesAfterTimeout $script:OfficialMinBytes -MinRateBps $script:OfficialMinRateBps
            return 'official'
        } catch {
            Write-Host ("[同步] 官方源不可用（{0:N1}s，{1}），改走更新服务：{2}" -f $sw.Elapsed.TotalSeconds, (Get-DownloadFailReason $_.Exception), $Rel)
            Set-OfficialSkip
            break
        }
    }
    $homeTimeout = 180
    try {
        if ($File -and $File.PSObject.Properties['size'] -and [int64]$File.size -gt 0) {
            $homeTimeout = [Math]::Max(120, [Math]::Min(300, [int]([int64]$File.size / 131072) + 60))
        }
    } catch { $homeTimeout = 180 }
    Download-ManifestFile -Url (Join-UrlPath -BaseUrl $BaseUrl -Rel $Rel) -Destination $Destination -ExpectedSha1 $ExpectedSha1 -TimeoutSec $homeTimeout
    return 'home'
}

function Test-OptionalHelperFile {
    param([Parameter(Mandatory = $true)][string]$Rel)
    $normalized = Normalize-Rel $Rel
    return ($normalized -in @('_updater/Windows-sync.bat', '更新mod-Windows端.bat', '更新mod-Mac端.command', '更新mod.bat', '启动游戏-Windows端.bat', 'Windows-sync.bat', '_updater/macOS-sync.command', '启动游戏-Mac端.command', 'macOS-sync.command', '_updater/portable-stage-daemon.ps1', '_updater/portable-stage-daemon.py'))
}

function Write-SyncWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ("[warn] " + $Message)
}
function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $Default
}

function Get-ArrayValue {
    param($Object, [string]$Name, [object[]]$Default = @())
    if ($Object -and $Object.PSObject.Properties[$Name]) { return @($Object.PSObject.Properties[$Name].Value) }
    return $Default
}

function Get-ExistingFileHashIndex {
    # 一个 SHA1 可能对应多个本地文件（枪包音效在 assets/ccrp、assets/classicr 下重复），
    # 所以每个哈希存一个路径列表，不能只留第一个——否则同哈希的后续条目会指向已被
    # 前一次接管移走的路径，Move-Item 报 "does not exist" 崩掉（2026-07-08 玩家实锤）。
    param([string]$Root)
    $map = @{}
    foreach ($dir in @('mods', 'config', 'defaultconfigs', 'kubejs', 'scripts', 'resourcepacks', 'shaderpacks', 'data')) {
        $full = Join-Path $Root $dir
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
            if ($rel -like 'mods/.connector/*' -or $rel -like '*/.connector/*') { return }
            $digest = Get-Sha1 -Path $_.FullName
            if (-not $digest) { return }
            if (-not $map.ContainsKey($digest)) { $map[$digest] = New-Object System.Collections.Generic.List[string] }
            [void]$map[$digest].Add($_.FullName)
        }
    }
    return $map
}

function Get-AdoptSource {
    # 挑一个本地已有、SHA1 相符的文件来满足 $Target，省去重新下载。返回 Path+Mode：
    #   move = 一份"多余副本"，可以安全地移动消费掉；
    #   copy = 唯一可用的同哈希文件本身也是清单要保留的目标，复制而不是偷走它。
    # 顺手剔除已失效（被前一次接管移走）的索引项，避免指向不存在的路径。
    param($Index, [string]$Expected, [string]$TargetFull, $ManifestTargets)
    if (-not $Index.ContainsKey($Expected)) { return $null }
    $alive = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Index[$Expected]) { if (Test-Path -LiteralPath $p -PathType Leaf) { [void]$alive.Add($p) } }
    $Index[$Expected] = $alive
    $spare = $null
    $twin = $null
    foreach ($p in $alive) {
        $pf = [System.IO.Path]::GetFullPath($p)
        if ($pf -ieq $TargetFull) { continue }
        if ($ManifestTargets.Contains($pf)) { if (-not $twin) { $twin = $p } }
        elseif (-not $spare) { $spare = $p }
    }
    if ($spare) {
        $rest = New-Object System.Collections.Generic.List[string]
        foreach ($p in $alive) { if ($p -ne $spare) { [void]$rest.Add($p) } }
        $Index[$Expected] = $rest
        return [pscustomobject]@{ Path = $spare; Mode = 'move' }
    }
    if ($twin) { return [pscustomobject]@{ Path = $twin; Mode = 'copy' } }
    return $null
}

function Set-OptionLine {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Value)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $found = $false
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ($line -match '^([^:]+):') {
                $k = $Matches[1]
                if ($k -eq $Key) {
                    $lines.Add("${Key}:${Value}")
                    $found = $true
                    continue
                }
            }
            $lines.Add($line)
        }
    }
    if (-not $found) { $lines.Add("${Key}:${Value}") }
    Write-Utf8NoBom -Path $Path -Value (($lines -join "`n") + "`n")
}

function Apply-OptionDefaults {
    param([string]$Root, $Manifest, [string]$BackupRoot)
    $optionsConfig = Get-PropertyValue -Object $Manifest -Name 'playerOptions' -Default $null
    if (-not $optionsConfig) { return 0 }
    $defaults = Get-PropertyValue -Object $optionsConfig -Name 'defaults' -Default $null
    if (-not $defaults) { return 0 }
    $applyMode = [string](Get-PropertyValue -Object $optionsConfig -Name 'apply' -Default 'missing')
    $targets = Get-ArrayValue -Object $optionsConfig -Name 'targets' -Default @('options.txt')
    $changed = 0
    foreach ($targetRel in $targets) {
        if (-not (Test-RelativePathSafe -Rel ([string]$targetRel))) { continue }
        if ($script:PreservedDeletionKeys -and $script:PreservedDeletionKeys.Contains((Normalize-RelKey ([string]$targetRel)))) { continue }
        $path = Join-SafeRelativePath -Root $Root -Rel ([string]$targetRel)
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        if ($applyMode -eq 'missing' -and ($exists -or (-not $script:InitialSync))) { continue }
        if ($exists) { Backup-FileIfExists -Path $path -Rel ([string]$targetRel) -BackupRoot $BackupRoot }
        foreach ($prop in $defaults.PSObject.Properties) {
            Set-OptionLine -Path $path -Key ([string]$prop.Name) -Value ([string]$prop.Value)
            $changed++
        }
    }
    if ($changed -gt 0) { Write-Host "[修复] 已写入安全默认选项：$changed 项" }
    return $changed
}

function Write-U16BE { param([System.IO.BinaryWriter]$Writer, [int]$Value) $Writer.Write([byte](($Value -shr 8) -band 0xff)); $Writer.Write([byte]($Value -band 0xff)) }
function Write-I32BE { param([System.IO.BinaryWriter]$Writer, [int]$Value) $Writer.Write([byte](($Value -shr 24) -band 0xff)); $Writer.Write([byte](($Value -shr 16) -band 0xff)); $Writer.Write([byte](($Value -shr 8) -band 0xff)); $Writer.Write([byte]($Value -band 0xff)) }
function Write-NbtStringPayload { param([System.IO.BinaryWriter]$Writer, [string]$Value) $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value); Write-U16BE -Writer $Writer -Value $bytes.Length; $Writer.Write($bytes) }
function Write-NamedTagHeader { param([System.IO.BinaryWriter]$Writer, [byte]$Type, [string]$Name) $Writer.Write($Type); Write-NbtStringPayload -Writer $Writer -Value $Name }

function Write-ServersDat {
    param([string]$Path, [string]$Name, [string]$Ip)
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $ms = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($ms)
    try {
        Write-NamedTagHeader -Writer $writer -Type 10 -Name ""
        Write-NamedTagHeader -Writer $writer -Type 9 -Name "servers"
        $writer.Write([byte]10)
        Write-I32BE -Writer $writer -Value 1
        Write-NamedTagHeader -Writer $writer -Type 8 -Name "name"
        Write-NbtStringPayload -Writer $writer -Value $Name
        Write-NamedTagHeader -Writer $writer -Type 8 -Name "ip"
        Write-NbtStringPayload -Writer $writer -Value $Ip
        Write-NamedTagHeader -Writer $writer -Type 1 -Name "acceptTextures"
        $writer.Write([byte]1)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    } finally { $writer.Dispose(); $ms.Dispose() }
}

function Show-LauncherHints {
    param([string]$Root)
    $launcherRoot = Join-Path $Root '_launchers'
    if (-not (Test-Path -LiteralPath $launcherRoot -PathType Container)) { return }
    $items = @(
        @{ Name = 'PCL'; Path = Join-Path $launcherRoot 'PCL.exe' },
        @{ Name = 'PCL 最近启动脚本'; Path = Join-Path $launcherRoot 'PCL\LatestLaunch.bat' },
        @{ Name = 'HMCL'; Path = Join-Path $launcherRoot 'HMCL.jar' }
    )
    $found = @($items | Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf })
    if ($found.Count -le 0) { return }
    Write-Host '[启动器] 已同步启动器文件：'
    foreach ($item in $found) { Write-Host ("[启动器] {0}: {1}" -f $item.Name, $item.Path) }
}
function Get-LauncherInstanceName {
    param([string]$Root, $Manifest)
    $launcher = Get-PropertyValue -Object $Manifest -Name 'launcher' -Default $null
    $pcl = Get-PropertyValue -Object $Manifest -Name 'pcl' -Default $null
    $name = [string](Get-PropertyValue -Object $launcher -Name 'instanceName' -Default '')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-PropertyValue -Object $pcl -Name 'instanceName' -Default '') }
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    $json = Get-ChildItem -LiteralPath $Root -File -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('launcher_profiles.json', '.portable-sync-state.json') } | Sort-Object Length -Descending | Select-Object -First 1
    if ($json) { return [System.IO.Path]::GetFileNameWithoutExtension($json.Name) }
    return (Split-Path -Leaf $Root)
}

function Get-MinecraftHomeForInstance {
    param([string]$Root)
    $parent = Split-Path -Parent $Root
    if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
    $grandparent = Split-Path -Parent $parent
    if ([string]::IsNullOrWhiteSpace($grandparent)) { return $null }
    if (((Split-Path -Leaf $parent) -ieq 'versions') -and ((Split-Path -Leaf $grandparent) -ieq '.minecraft')) {
        return (Split-Path -Parent $grandparent)
    }
    return $null
}

function Write-PclGlobalConfig {
    param([string]$PclHome, [string]$MinecraftDirValue, [string]$InstanceName, [string]$BackupRoot)
    # 温和写入：PCL.ini 缺失才创建；Setup.ini 只维护 LaunchFolderSelect 一行，
    # 保留玩家自己的其他 PCL 设置，避免每次同步重置启动器个人配置。
    $pclIni = Join-Path $PclHome 'PCL.ini'
    if (-not (Test-Path -LiteralPath $pclIni -PathType Leaf)) {
        $cardName = $InstanceName.Replace(':', '-')
        Write-Utf8NoBom -Path $pclIni -Value ("InstanceCache:{0}`r`nVersion:{1}`r`nCardKey1:2`r`nCardValue1:2:{1}:1:`r`nCardCount:1`r`n" -f ([Math]::Abs($PclHome.GetHashCode())), $cardName)
    }

    $pclDir = Join-Path $PclHome 'PCL'
    New-Item -ItemType Directory -Force $pclDir | Out-Null
    $setup = Join-Path $pclDir 'Setup.ini'
    $desired = ("LaunchFolderSelect:{0}" -f $MinecraftDirValue)
    if (Test-Path -LiteralPath $setup -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $setup -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($lines -contains $desired) { return }
        Backup-FileIfExists -Path $setup -Rel 'pcl-home/PCL/Setup.ini' -BackupRoot $BackupRoot
        $kept = @($lines | Where-Object { $_ -notmatch '^LaunchFolderSelect:' })
        $out = @($desired) + $kept
        Write-Utf8NoBom -Path $setup -Value (($out -join "`r`n") + "`r`n")
    } else {
        Write-Utf8NoBom -Path $setup -Value ($desired + "`r`n")
    }
}

function Copy-LauncherFileToRoot {
    param([string]$Root, [string]$Relative, [string]$BackupRoot)
    $source = Join-SafeRelativePath -Root (Join-Path $Root '_launchers') -Rel $Relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $null }
    $dest = Join-SafeRelativePath -Root $Root -Rel $Relative
    # 启动器（HMCL / PCL 等）会自我升级：玩家点了“升级”后，本地版本比包内自带的更新。
    # 只做「首次落位」——已存在就保留玩家自己的版本，绝不用包内旧版覆盖回去，否则每次同步
    # 都把玩家升级好的启动器打回原形（与 .py 端一致，2026-07-11 实锤）。
    if (Test-Path -LiteralPath $dest -PathType Leaf) { return $dest }
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest -Force
    return $dest
}

function Apply-LauncherProfile {
    param([string]$Root, $Manifest, [string]$BackupRoot)
    $launcherRoot = Join-Path $Root '_launchers'
    if (-not (Test-Path -LiteralPath $launcherRoot -PathType Container)) { return }

    $instanceName = Get-LauncherInstanceName -Root $Root -Manifest $Manifest
    $packName = [string](Get-PropertyValue -Object $Manifest -Name 'packName' -Default $instanceName)
    if ([string]::IsNullOrWhiteSpace($packName)) { $packName = $instanceName }
    $mcVersion = [string](Get-PropertyValue -Object $Manifest -Name 'minecraftVersion' -Default '')
    $loader = Get-PropertyValue -Object $Manifest -Name 'loader' -Default $null
    $loaderType = [string](Get-PropertyValue -Object $loader -Name 'type' -Default '')
    $loaderVersion = [string](Get-PropertyValue -Object $loader -Name 'version' -Default '')

    foreach ($rel in @('PCL.exe', 'Plain Craft Launcher.exe', 'SakuraLauncher.exe', 'HMCL.jar')) {
        [void](Copy-LauncherFileToRoot -Root $Root -Relative $rel -BackupRoot $BackupRoot)
    }

    $mcHome = Get-MinecraftHomeForInstance -Root $Root
    if ($mcHome) {
        foreach ($rel in @('PCL.exe', 'Plain Craft Launcher.exe', 'SakuraLauncher.exe', 'HMCL.jar')) {
            $source = Join-SafeRelativePath -Root $launcherRoot -Rel $rel
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $dest = Join-Path $mcHome $rel
                # 同上：启动器自升级后不回退，缺失才落位。
                if (Test-Path -LiteralPath $dest -PathType Leaf) { continue }
                Copy-Item -LiteralPath $source -Destination $dest -Force
            }
        }
    }

    $profilePath = Join-Path $Root 'launcher_profiles.json'
    Backup-FileIfExists -Path $profilePath -Rel 'launcher_profiles.json' -BackupRoot $BackupRoot
    $profile = [ordered]@{
        profiles = [ordered]@{
            Portable = [ordered]@{
                icon = 'Furnace'
                name = $packName
                lastVersionId = $instanceName
                type = 'custom'
                lastUsed = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.0000Z")
            }
        }
        selectedProfile = 'Portable'
        clientToken = '23323323323323323323323323323333'
    }
    Write-Utf8NoBom -Path $profilePath -Value (($profile | ConvertTo-Json -Depth 8) + "`r`n")

    $pclIni = Join-Path $Root 'PCL.ini'
    Backup-FileIfExists -Path $pclIni -Rel 'PCL.ini' -BackupRoot $BackupRoot
    $cardName = $instanceName.Replace(':', '-')
    Write-Utf8NoBom -Path $pclIni -Value ("InstanceCache:{0}`r`nVersion:{1}`r`nCardKey1:2`r`nCardValue1:2:{1}:1:`r`nCardCount:1`r`n" -f ([Math]::Abs($Root.GetHashCode())), $cardName)

    $pclDir = Join-Path $Root 'PCL'
    New-Item -ItemType Directory -Force $pclDir | Out-Null
    $setup = Join-Path $pclDir 'Setup.ini'
    Backup-FileIfExists -Path $setup -Rel 'PCL/Setup.ini' -BackupRoot $BackupRoot
    $info = if ($loaderType -and $loaderVersion) { "正式版 $mcVersion, $($loaderType.Substring(0,1).ToUpper() + $loaderType.Substring(1)) $loaderVersion" } else { "正式版 $mcVersion" }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('State:9')
    if ($mcVersion) { $lines.Add("VersionVanillaName:$mcVersion") }
    $lines.Add('VersionArgumentIndieV2:True')
    $lines.Add("Info:$info")
    $lines.Add('VersionLiteLoader:False')
    if ($loaderType -ieq 'forge' -and $loaderVersion) { $lines.Add("VersionForge:$loaderVersion") }
    if ($loaderType -ieq 'fabric' -and $loaderVersion) { $lines.Add("VersionFabric:$loaderVersion") }
    $lines.Add('Logo:pack://application:,,,/Plain Craft Launcher 2;component/Images/Blocks/Anvil.png')
    $lines.Add("LaunchFolderSelect:$Root")
    Write-Utf8NoBom -Path $setup -Value (($lines -join "`r`n") + "`r`n")

    if ($mcHome) {
        $profileHome = Join-Path (Join-Path $mcHome '.minecraft') 'launcher_profiles.json'
        Backup-FileIfExists -Path $profileHome -Rel 'pcl-home/.minecraft/launcher_profiles.json' -BackupRoot $BackupRoot
        Write-Utf8NoBom -Path $profileHome -Value (($profile | ConvertTo-Json -Depth 8) + "`r`n")
        Write-PclGlobalConfig -PclHome $mcHome -MinecraftDirValue '$.minecraft\' -InstanceName $instanceName -BackupRoot $BackupRoot
    }

    # Mirror launcher config for older wrappers that still start PCL/HMCL from _launchers.
    foreach ($rel in @('launcher_profiles.json', 'PCL.ini', 'PCL/Setup.ini')) {
        $src = Join-SafeRelativePath -Root $Root -Rel $rel
        $dst = Join-SafeRelativePath -Root $launcherRoot -Rel $rel
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            if (Test-Path -LiteralPath $dst -PathType Leaf) { Backup-FileIfExists -Path $dst -Rel ("_launchers/" + $rel) -BackupRoot $BackupRoot }
            New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    Write-Host ("[启动器] 已写入本地实例配置：{0}" -f $instanceName)
}
function Apply-ServerList {
    param([string]$Root, $Manifest, [string]$BackupRoot)
    $serverList = Get-PropertyValue -Object $Manifest -Name 'serverList' -Default $null
    if (-not $serverList -or -not [bool](Get-PropertyValue -Object $serverList -Name 'enabled' -Default $false)) { return }
    $target = [string](Get-PropertyValue -Object $serverList -Name 'target' -Default 'servers.dat')
    $name = [string](Get-PropertyValue -Object $serverList -Name 'name' -Default (Get-PropertyValue -Object $Manifest -Name 'serverName' -Default 'Minecraft Server'))
    $address = [string](Get-PropertyValue -Object $serverList -Name 'address' -Default (Get-PropertyValue -Object $Manifest -Name 'serverAddress' -Default ''))
    $writeIfMissingOnly = [bool](Get-PropertyValue -Object $serverList -Name 'writeIfMissingOnly' -Default $true)
    if ([string]::IsNullOrWhiteSpace($address) -or -not (Test-RelativePathSafe -Rel $target)) { return }
    if ($script:PreservedDeletionKeys -and $script:PreservedDeletionKeys.Contains((Normalize-RelKey $target))) { return }
    $path = Join-SafeRelativePath -Root $Root -Rel $target
    if ($writeIfMissingOnly) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return }
        if (-not $script:InitialSync) { return }
    }
    Backup-FileIfExists -Path $path -Rel $target -BackupRoot $BackupRoot
    Write-ServersDat -Path $path -Name $name -Ip $address
    Write-Host "[修复] 已写入服务器列表：$name / $address"
}

function Move-ToDisabledDir {
    param([string]$Path, [string]$DisabledDir)
    New-Item -ItemType Directory -Force $DisabledDir | Out-Null
    $item = Get-Item -LiteralPath $Path
    $dest = Join-Path $DisabledDir $item.Name
    if (Test-Path -LiteralPath $dest) { $dest = Join-Path $DisabledDir ("{0}.{1}{2}" -f $item.BaseName, (Get-Date -Format 'yyyyMMddHHmmss'), $item.Extension) }
    Move-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

function Remove-ConnectorRuntimeCache {
    param([string]$Root)
    $cache = Join-Path $Root 'mods\.connector'
    if (Test-Path -LiteralPath $cache -PathType Container) {
        Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '[修复] 已清理 Connector 运行缓存：mods/.connector'
    }
}

function Disable-LauncherRepairIndex {
    param([string[]]$Roots)
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $index = Join-Path $root 'modrinth.index.json'
        if (-not (Test-Path -LiteralPath $index -PathType Leaf)) { continue }
        $dest = Move-ToDisabledDir -Path $index -DisabledDir (Join-Path $root '_disabled_launcher_repair')
        Write-Host "[修复] 已禁用启动器修包索引：$dest"
    }
}

function Get-JarModId {
    param([string]$Path)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($name in @('fabric.mod.json', 'quilt.mod.json')) {
                $entry = $zip.GetEntry($name)
                if ($entry) {
                    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
                    try { $json = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                    if ($json.id) { return ([string]$json.id).ToLowerInvariant() }
                    if ($json.quilt_loader -and $json.quilt_loader.id) { return ([string]$json.quilt_loader.id).ToLowerInvariant() }
                }
            }
            foreach ($name in @('META-INF/mods.toml', 'META-INF/neoforge.mods.toml')) {
                $entry = $zip.GetEntry($name)
                if ($entry) {
                    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    $m = [regex]::Match($text, '(?m)^\s*modId\s*=\s*["'']([^"'']+)["'']')
                    if ($m.Success) { return $m.Groups[1].Value.ToLowerInvariant() }
                }
            }
            $mcmod = $zip.GetEntry('mcmod.info')
            if ($mcmod) {
                $reader = New-Object System.IO.StreamReader($mcmod.Open(), [System.Text.Encoding]::UTF8, $true)
                try { $json = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                if ($json -is [array] -and $json.Count -gt 0 -and $json[0].modid) { return ([string]$json[0].modid).ToLowerInvariant() }
            }
        } finally { $zip.Dispose() }
    } catch { return $null }
    return $null
}

function Disable-DuplicateMods {
    param([string]$Root, $Manifest)
    $mods = Join-Path $Root 'mods'
    if (-not (Test-Path -LiteralPath $mods -PathType Container)) { return }
    $managedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $managedSha1 = @{}
    foreach ($item in @($Manifest.files)) {
        $rel = Normalize-Rel ([string]$item.path)
        if ($rel -like 'mods/*.jar') {
            [void]$managedPaths.Add($rel)
            $managedSha1[[string]$item.sha1] = $rel
        }
    }
    $disabled = Join-Path $Root '_disabled_mod_duplicates'
    $moved = 0
    Get-ChildItem -LiteralPath $mods -File -Filter '*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
        if ($managedPaths.Contains($rel)) { return }
        $digest = Get-Sha1 -Path $_.FullName
        if ($managedSha1.ContainsKey($digest)) {
            $dest = Move-ToDisabledDir -Path $_.FullName -DisabledDir $disabled
            Write-Host "[修复] 已按 SHA1 归档旧重复 mod：$rel -> $dest"
            $script:DuplicateMoved++
        }
    }
    $groups = @{}
    Get-ChildItem -LiteralPath $mods -File -Filter '*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
        $modId = Get-JarModId -Path $_.FullName
        if ([string]::IsNullOrWhiteSpace($modId)) { return }
        if (-not $groups.ContainsKey($modId)) { $groups[$modId] = New-Object System.Collections.ArrayList }
        [void]$groups[$modId].Add($_)
    }
    foreach ($modId in $groups.Keys) {
        $items = @($groups[$modId])
        if ($items.Count -le 1) { continue }
        $keep = $items | Sort-Object -Descending @{Expression={ $rel=$_.FullName.Substring($Root.Length).TrimStart('\','/').Replace('\','/'); if($managedPaths.Contains($rel)){2}else{0} }}, LastWriteTime | Select-Object -First 1
        foreach ($jar in $items) {
            if ($jar.FullName -eq $keep.FullName) { continue }
            $dest = Move-ToDisabledDir -Path $jar.FullName -DisabledDir $disabled
            Write-Host "[修复] 已归档重复 modId=$modId；保留 $($keep.Name)，移动 $($jar.Name)"
            $script:DuplicateMoved++
        }
    }
    if ($script:DuplicateMoved -gt $moved) { Write-Host "[修复] 重复 mod 清理完成，移动 $($script:DuplicateMoved - $moved) 个" }
}

$instanceRoot = Resolve-FullPath $InstanceDir
New-Item -ItemType Directory -Force $instanceRoot | Out-Null
Set-Location -LiteralPath $instanceRoot

# 老系统/未开启强加密的 .NET 默认拿不到 TLS 1.2，https 更新源会直接失败；入口 bat 已设，
# 这里再兜一层，保证直接跑本脚本（不经 bat）也能连 https。
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }

$manifestUrls = @(Read-UpdateUrls -Root $instanceRoot -Override $ManifestUrl)
$statePath = Join-Path $instanceRoot '.portable-sync-state.json'
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}
$lastGood = ''
if ([string]::IsNullOrWhiteSpace($ManifestUrl) -and $state) {
    $lastGood = [string](Get-PropertyValue -Object $state -Name 'lastManifestUrl' -Default (Get-PropertyValue -Object $state -Name 'manifestUrl' -Default ''))
}
if ([string]::IsNullOrWhiteSpace($ManifestUrl)) {
    $manifestUrls = @(Get-OrderedManifestUrls -Urls $manifestUrls -LastGood $lastGood)
}
Write-Host ("[同步] 清单候选：" + (($manifestUrls | ForEach-Object { Get-MaskedUrl $_ }) -join '；'))
$detectedProxy = Get-SystemProxyUrl
if ($detectedProxy) {
    Write-Host ("[同步] 已检测到系统代理 {0}，官方源走代理；家宽更新服务始终直连。" -f (Get-ProxyDescription $detectedProxy))
} else {
    Write-Host '[同步] 未检测到系统代理，官方源直连（太慢会在约 8 秒内回落更新服务）。'
    if ($state -and [bool](Get-PropertyValue -Object $state -Name 'skipOfficial' -Default $false)) {
        Set-OfficialSkip
        Write-Host '[同步] 上次官方源偏慢，本轮直接走更新服务。检测到代理后会再试官方源。'
    }
}
$manifest = $null
$manifestText = $null
$selectedManifestUrl = $null
$lastManifestError = $null
foreach ($candidate in $manifestUrls) {
    $probeTimeout = Get-ProbeTimeoutSec -Url $candidate
    $retries = if ($probeTimeout -le 2) { 0 } else { 1 }
    try {
        $candidateText = Read-UrlUtf8Text -Url $candidate -TimeoutSec $probeTimeout -Retries $retries
        $candidateManifest = $candidateText | ConvertFrom-Json
        if (-not $candidateManifest.files) { throw 'manifest 缺少 files。' }
        $manifestText = $candidateText
        $manifest = $candidateManifest
        $selectedManifestUrl = $candidate
        break
    } catch {
        $lastManifestError = $_.Exception
    }
}

# 完整包通常自带清单；更新源短暂不可达时，用它继续做本地哈希对账，
# 已有文件可以完成同步，缺失文件等更新源恢复后再补下。
if (-not $manifest) {
    $localManifestPath = Join-Path $instanceRoot 'server-manifest.json'
    if (Test-Path -LiteralPath $localManifestPath -PathType Leaf) {
        try {
            $localManifest = Get-Content -LiteralPath $localManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($localManifest.files) {
                $manifest = $localManifest
                $selectedManifestUrl = $manifestUrls[0]
                Write-Host '[降级] 更新源暂时不可达，改用包内 server-manifest.json 做本地对账；缺失文件仍需更新源恢复后补下。' -ForegroundColor Yellow
            }
        } catch { $manifest = $null }
    }
}
if (-not $manifest) {
    throw ("清单获取失败：" + $lastManifestError.Message + "；已尝试 " + $manifestUrls.Count + " 个更新地址。请确认当前更新地址可达，以及路由器已把更新端口转到服机。")
}
$manifestUrl = [string]$selectedManifestUrl
if (-not [string]::IsNullOrWhiteSpace($lastGood) -and $manifestUrl -eq $lastGood) {
    Write-Host "[同步] 沿用上次可用更新地址：$(Get-MaskedUrl $manifestUrl)"
} elseif ($manifestUrl -ne [string]$manifestUrls[0]) {
    Write-Host "[同步] 已切换到可用备用地址：$(Get-MaskedUrl $manifestUrl)"
}
if (-not $manifest.files) { throw 'manifest 缺少 files。' }

$slash = $manifestUrl.LastIndexOf('/')
if ($slash -lt 0) { throw "manifest URL 格式异常：$manifestUrl" }
$baseUrl = $manifestUrl.Substring(0, $slash + 1)
$script:InitialSync = -not $state -or -not (Get-PropertyValue -Object $state -Name 'files' -Default $null)
$previousMap = ConvertTo-FileMap -Files (Get-PropertyValue -Object $state -Name 'files' -Default @())
# key 是小写化的，删除旧文件时要还原状态文件里的原始大小写（大小写敏感卷才找得到文件）。
$previousRelByKey = @{}
foreach ($item in @(Get-PropertyValue -Object $state -Name 'files' -Default @())) {
    if ($item -and $item.path) { $previousRelByKey[(Normalize-RelKey ([string]$item.path))] = Normalize-Rel ([string]$item.path) }
}
$newMap = ConvertTo-FileMap -Files $manifest.files
$verified = @{}
$rawVerified = Get-PropertyValue -Object $state -Name 'verified' -Default $null
if ($rawVerified) {
    foreach ($prop in $rawVerified.PSObject.Properties) {
        try { $verified[(Normalize-RelKey $prop.Name)] = $prop.Value } catch {}
    }
}
$preserveChangeGlobs = Get-ArrayValue -Object $manifest -Name 'preserveLocalChangeGlobs' -Default @()
$preserveDeletionGlobs = Get-ArrayValue -Object $manifest -Name 'preserveLocalDeletionGlobs' -Default @()
$forceDeleteGlobs = Get-ArrayValue -Object $manifest -Name 'forceDeleteGlobs' -Default @()
# 强制同步：匹配的文件无视保留规则、一律以服务端为准（覆盖前照常备份）。
# 服务端确需推送玩家常改的配置时，临时把路径加进 forceSyncGlobs 发布一版即可。
$forceSyncGlobs = Get-ArrayValue -Object $manifest -Name 'forceSyncGlobs' -Default @()
$additiveDirs = Get-ArrayValue -Object $manifest -Name 'additiveDirs' -Default @('shaderpacks', 'resourcepacks', 'schematics', 'saves', 'screenshots')
$cleanup = Get-PropertyValue -Object $manifest -Name 'cleanup' -Default $null
$preservePlayerCustomizations = [bool](Get-PropertyValue -Object $manifest -Name 'preservePlayerCustomizations' -Default $true)
$adoptExistingFiles = [bool](Get-PropertyValue -Object $manifest -Name 'adoptExistingFiles' -Default $true)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $instanceRoot (".portable-sync-backups\$stamp")

if ([bool](Get-PropertyValue -Object $cleanup -Name 'removeConnectorCache' -Default $true)) { Remove-ConnectorRuntimeCache -Root $instanceRoot }
if ([bool](Get-PropertyValue -Object $cleanup -Name 'disableLauncherRepairIndex' -Default $true)) { Disable-LauncherRepairIndex -Roots @($PSScriptRoot, $instanceRoot) }

# 接管索引惰性构建：日常同步通常没有缺失文件，这时不必对 mods/config/resourcepacks 等
# 目录做全量 SHA1 扫描（大包一次要几十秒）。只在真的遇到缺失文件需要接管时才建一次。
$script:AdoptIndexCache = $null
function Get-AdoptIndex {
    if ($null -eq $script:AdoptIndexCache) {
        Write-Host '[同步] 有文件缺失，正在建立本地文件哈希索引（仅本次需要）...'
        $script:AdoptIndexCache = Get-ExistingFileHashIndex -Root $instanceRoot
    }
    return $script:AdoptIndexCache
}
# 清单里所有目标的绝对路径集合：接管时据此区分"多余副本"（可移动）与"清单要保留的孪生文件"（只能复制）。
$manifestTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in @($manifest.files)) {
    $mr = Normalize-Rel ([string]$file.path)
    if (Test-RelativePathSafe -Rel $mr) { [void]$manifestTargets.Add([System.IO.Path]::GetFullPath((Join-SafeRelativePath -Root $instanceRoot -Rel $mr))) }
}
$downloaded = 0
$adopted = 0
$skipped = 0
$preserved = 0
$removed = 0
$script:PreservedDeletionKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
# 保留了玩家修改、但服务端同一文件本次其实也有更新的清单：结尾集中提醒一次。
$script:PreservedConflicts = New-Object 'System.Collections.Generic.List[string]'

foreach ($file in @($manifest.files)) {
    $rel = Normalize-Rel ([string]$file.path)
    $relKey = Normalize-RelKey $rel
    if (-not (Test-RelativePathSafe -Rel $rel)) { throw "Unsafe manifest path: $rel" }
    $target = Join-SafeRelativePath -Root $instanceRoot -Rel $rel
    $expected = ([string]$file.sha1).ToLowerInvariant()
    $exists = Test-Path -LiteralPath $target -PathType Leaf
    $hadPrevious = $previousMap.ContainsKey($relKey)
    $previousHash = if ($hadPrevious) { [string]$previousMap[$relKey] } else { "" }
    $manifestSize = $null
    if ($file.PSObject.Properties['size']) { $manifestSize = $file.size }
    $verifiedEntry = $null
    if ($verified.ContainsKey($relKey)) { $verifiedEntry = $verified[$relKey] }
    if ($exists -and (Test-LooksLikeCurrentFile -Path $target -Expected $expected -ManifestSize $manifestSize -PreviousHash $previousHash -Verified $verifiedEntry)) {
        $verified[$relKey] = Get-FileVerifyRecord -Path $target -Sha1 $expected
        $skipped++
        continue
    }
    $currentHash = if ($exists) { Get-Sha1 -Path $target } else { "" }
    if ($exists -and $currentHash -eq $expected) {
        $verified[$relKey] = Get-FileVerifyRecord -Path $target -Sha1 $expected
        $skipped++
        continue
    }
    $forceSync = Test-GlobMatch -Rel $rel -Globs $forceSyncGlobs
    if (-not $exists -and $hadPrevious -and $preservePlayerCustomizations -and -not $forceSync -and (Test-GlobMatch -Rel $rel -Globs $preserveDeletionGlobs)) {
        Write-Host "[保留玩家删除] $rel"
        [void]$script:PreservedDeletionKeys.Add($relKey)
        $preserved++
        continue
    }
    if ($exists -and $preservePlayerCustomizations -and -not $forceSync -and (Test-GlobMatch -Rel $rel -Globs $preserveChangeGlobs)) {
        # 三方对比：current==previousHash 说明玩家没改过，照常走下面的更新；
        # 改过（或没有基线）就保留。若服务端同一文件本次也变了，记下来结尾集中提醒。
        if ([string]::IsNullOrWhiteSpace($previousHash) -or $currentHash -ne $previousHash) {
            if ($hadPrevious -and $expected -ne $previousHash) { [void]$script:PreservedConflicts.Add($rel) }
            Write-Host "[保留玩家修改] $rel"
            $preserved++
            continue
        }
    }
    if (-not $exists -and $adoptExistingFiles) {
        $targetFull = [System.IO.Path]::GetFullPath($target)
        $adopt = Get-AdoptSource -Index (Get-AdoptIndex) -Expected $expected -TargetFull $targetFull -ManifestTargets $manifestTargets
        if ($adopt) {
            New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
            if ($adopt.Mode -eq 'move') { Move-Item -LiteralPath $adopt.Path -Destination $target -Force }
            else { Copy-Item -LiteralPath $adopt.Path -Destination $target -Force }
            if ((Get-Sha1 -Path $target) -eq $expected) {
                $verified[$relKey] = Get-FileVerifyRecord -Path $target -Sha1 $expected
                Write-Host "[接管本地文件] $rel"
                $adopted++
                continue
            }
            # 接管后校验不符（极罕见）：不 continue，落到下面正常下载覆盖。
        }
    }
    if ($exists) { Backup-FileIfExists -Path $target -Rel $rel -BackupRoot $backupRoot }
    try {
        $source = Download-ManifestEntry -File $file -BaseUrl $baseUrl -Destination $target -ExpectedSha1 $expected -Rel $rel
        $verified[$relKey] = Get-FileVerifyRecord -Path $target -Sha1 $expected
        if ($source -eq 'official') { Write-Host "[官方源] $rel" } else { Write-Host "[更新] $rel" }
        $downloaded++
    } catch {
        if (Test-OptionalHelperFile -Rel $rel) {
            Write-SyncWarning "辅助脚本未更新：$rel；$($_.Exception.Message)"
            $preserved++
            continue
        }
        throw
    }
}

foreach ($oldKey in @($previousMap.Keys)) {
    if ($newMap.ContainsKey($oldKey)) { continue }
    $oldRel = if ($previousRelByKey.ContainsKey($oldKey)) { $previousRelByKey[$oldKey] } else { $oldKey }
    if (-not (Test-RelativePathSafe -Rel $oldRel)) { continue }
    $target = Join-SafeRelativePath -Root $instanceRoot -Rel $oldRel
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
    # tacz 等大件：清单撤下也不删玩家已装的。
    # mods/** 也在删除保留里，但官方换版本（旧 jar 名离开清单）仍要清掉未改过的旧文件，否则会双模组。
    $keepByDeletionGlob = $preservePlayerCustomizations -and (Test-GlobMatch -Rel $oldRel -Globs $preserveDeletionGlobs)
    $isPackMod = $oldRel -like 'mods/*'
    if ($keepByDeletionGlob -and -not $isPackMod) {
        Write-Host "[保留本地额外文件] $oldRel"
        $preserved++
        continue
    }
    $currentHash = Get-Sha1 -Path $target
    if ($currentHash -ne $previousMap[$oldKey]) { Write-Host "[保留本地额外文件] $oldRel"; $preserved++; continue }
    Backup-FileIfExists -Path $target -Rel $oldRel -BackupRoot $backupRoot
    Remove-Item -LiteralPath $target -Force
    Write-Host "[删除旧文件] $oldRel"
    $removed++
}

foreach ($pattern in $forceDeleteGlobs) {
    $patternText = Normalize-Rel ([string]$pattern)
    if ([string]::IsNullOrWhiteSpace($patternText)) { continue }
    if (-not (Test-RelativePathSafe -Rel ($patternText.Replace('*', 'x').Replace('?', 'x')))) { throw "Unsafe forceDelete glob: $patternText" }
    $matches = @()
    if ($patternText -match '[*?]') {
        $matches = Get-ChildItem -LiteralPath $instanceRoot -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
            $rel = $_.FullName.Substring($instanceRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            (-not (Test-ProtectedRel -Rel $rel)) -and (Test-GlobMatch -Rel $rel -Globs @($patternText))
        }
    } else {
        if (Test-ProtectedRel -Rel $patternText) { continue }
        $exact = Join-SafeRelativePath -Root $instanceRoot -Rel $patternText
        if (Test-Path -LiteralPath $exact -PathType Leaf) { $matches = @(Get-Item -LiteralPath $exact) }
    }
    foreach ($match in $matches) {
        $rel = $match.FullName.Substring($instanceRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        Backup-FileIfExists -Path $match.FullName -Rel $rel -BackupRoot $backupRoot
        Remove-Item -LiteralPath $match.FullName -Force
        Write-Host "[强制删除] $rel"
        $removed++
    }
}

foreach ($dir in $additiveDirs) {
    $rel = Normalize-Rel ([string]$dir)
    if ([string]::IsNullOrWhiteSpace($rel) -or -not (Test-RelativePathSafe -Rel $rel)) { continue }
    New-Item -ItemType Directory -Force (Join-SafeRelativePath -Root $instanceRoot -Rel $rel) | Out-Null
}

[void](Apply-OptionDefaults -Root $instanceRoot -Manifest $manifest -BackupRoot $backupRoot)
Apply-ServerList -Root $instanceRoot -Manifest $manifest -BackupRoot $backupRoot
Apply-LauncherProfile -Root $instanceRoot -Manifest $manifest -BackupRoot $backupRoot
Show-LauncherHints -Root $instanceRoot
if ([bool](Get-PropertyValue -Object $cleanup -Name 'removeConnectorCache' -Default $true)) { Remove-ConnectorRuntimeCache -Root $instanceRoot }
if ([bool](Get-PropertyValue -Object $cleanup -Name 'disableDuplicateMods' -Default $true)) {
    $extras = @()
    $modsDir = Join-Path $instanceRoot 'mods'
    if (Test-Path -LiteralPath $modsDir -PathType Container) {
        $managedModPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @($manifest.files)) {
            $mr = Normalize-Rel ([string]$item.path)
            if ($mr -like 'mods/*.jar') { [void]$managedModPaths.Add($mr) }
        }
        $extras = @(Get-ChildItem -LiteralPath $modsDir -File -Filter '*.jar' -ErrorAction SilentlyContinue | Where-Object {
            $rel = $_.FullName.Substring($instanceRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            -not $managedModPaths.Contains($rel)
        })
    }
    if ($extras.Count -gt 0 -or $downloaded -gt 0 -or $adopted -gt 0 -or $removed -gt 0 -or $script:InitialSync) {
        $script:DuplicateMoved = 0
        Disable-DuplicateMods -Root $instanceRoot -Manifest $manifest
    }
}
if ([bool](Get-PropertyValue -Object $cleanup -Name 'disableLauncherRepairIndex' -Default $true)) { Disable-LauncherRepairIndex -Roots @($PSScriptRoot, $instanceRoot) }

$verifiedOut = [ordered]@{}
foreach ($key in @($verified.Keys)) {
    if ($newMap.ContainsKey($key)) { $verifiedOut[$key] = $verified[$key] }
}
$stateOut = [ordered]@{
    format = 3
    packId = Get-PropertyValue -Object $manifest -Name 'packId' -Default (Get-PropertyValue -Object $manifest -Name 'pack' -Default '')
    packName = Get-PropertyValue -Object $manifest -Name 'packName' -Default (Get-PropertyValue -Object $manifest -Name 'name' -Default '')
    version = Get-PropertyValue -Object $manifest -Name 'version' -Default ''
    manifestUrl = $manifestUrl
    lastManifestUrl = $manifestUrl
    skipOfficial = [bool]($script:OfficialSkip -and -not $detectedProxy)
    syncedAt = (Get-Date).ToString('s')
    files = $manifest.files
    verified = $verifiedOut
}
Write-Utf8NoBom -Path $statePath -Value (($stateOut | ConvertTo-Json -Depth 8) + "`r`n")
Write-Host "[同步] 完成。更新=$downloaded 接管=$adopted 跳过=$skipped 保留=$preserved 删除=$removed 备份=$backupRoot"
if ($script:PreservedConflicts.Count -gt 0) {
    Write-Host ("[提示] 以下 " + $script:PreservedConflicts.Count + " 个文件保留了你的本地修改，但服务端本次也更新了它们（未应用服务端版）：")
    foreach ($r in $script:PreservedConflicts) { Write-Host ("  - " + $r) }
    Write-Host "[提示] 如相关模组出现异常，删除对应文件后重新同步，即可取回服务端最新版本。"
}

if (-not $NoPause) {
    Write-Host '按回车关闭。'
    [void][Console]::ReadLine()
}
