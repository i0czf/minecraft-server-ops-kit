# 便携服务端 Web 运维面板（Windows PowerShell 5.1）
#
# 设计原则：
# - 默认只监听 127.0.0.1；需要路由器端口转发时，用户显式把 bindAddress 改成 0.0.0.0。
# - 不执行任意脚本，只调用现有白名单 bat/ps1；RCON 控制台默认关闭。
# - 不依赖 IIS、Node、Python 或 URL ACL，使用 TcpListener，普通用户即可启动。
# - 页面无第三方 CDN，端口转发或内网断网时仍可用。
#
# 文件编码要求：本文件含中文，必须保存为 UTF-8 with BOM，供 Windows PowerShell 5.1 使用。

param(
    [string]$ConfigPath = '',
    [string]$BindAddress = '',
    [int]$Port = 0,
    [switch]$ResetToken,
    [switch]$ShowToken,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ToolsDir = $PSScriptRoot
Set-Location -LiteralPath $Root

$DefaultConfigPath = Join-Path $ToolsDir 'portable-web-panel.json'
$TokenPath = Join-Path $Root 'tmp\portable-web-panel.token'
$PidPath = Join-Path $Root 'tmp\portable-web-panel.pid'
$LogPath = Join-Path $Root 'logs\portable-web-panel.log'
$ExampleConfigPath = Join-Path $ToolsDir 'portable-web-panel.example.json'

$script:Listener = $null
$script:Sessions = @{}
$script:FailedLogins = @{}
$script:Config = $null
$script:ListenAddressText = ''
$script:ListenPort = 0
$script:PanelToken = ''
$script:AllowConsoleCommands = $false
$script:SessionMinutes = 720
$script:MaxLogLines = 200

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Ascii([string]$Path, [string]$Value) {
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Value, [System.Text.Encoding]::ASCII)
}

function Get-DefaultConfig {
    return [ordered]@{
        '_说明' = 'Web 面板默认只监听本机。需要外部端口转发时，把 bindAddress 改为 0.0.0.0，并优先使用 SSH/VPN 隧道。'
        bindAddress = '127.0.0.1'
        port = 58080
        allowConsoleCommands = $false
        sessionMinutes = 720
        maxLogLines = 200
    }
}

function Get-ConfigValue([object]$Object, [string]$Name, [object]$DefaultValue) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $DefaultValue
}

function Resolve-ConfigFile {
    $path = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $DefaultConfigPath }
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
    return [System.IO.Path]::GetFullPath($path)
}

function Read-PanelConfig {
    $path = Resolve-ConfigFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $config = Get-DefaultConfig
        Write-Utf8NoBom $path (($config | ConvertTo-Json -Depth 5) + "`r`n")
        Write-Host "[Web] 首次运行，已生成配置：$path" -ForegroundColor Yellow
        return [pscustomobject]$config
    }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Web 面板配置解析失败：$path`r`n$($_.Exception.Message)"
    }
}

function New-PanelToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $value = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return 'wp-' + $value
}

function Get-PanelToken {
    New-Item -ItemType Directory -Path (Split-Path -Parent $TokenPath) -Force | Out-Null
    if ($ResetToken -and (Test-Path -LiteralPath $TokenPath -PathType Leaf)) {
        Remove-Item -LiteralPath $TokenPath -Force -Confirm:$false
        Write-Host '[Web] 已轮换 Web 面板令牌，旧令牌立即失效。' -ForegroundColor Yellow
    }
    if (-not (Test-Path -LiteralPath $TokenPath -PathType Leaf)) {
        Write-Ascii $TokenPath (New-PanelToken)
    }
    $token = (Get-Content -LiteralPath $TokenPath -Raw -Encoding ASCII).Trim()
    if ($token -notmatch '^wp-[A-Za-z0-9_-]{32,80}$') {
        throw "Web 面板令牌文件格式错误：$TokenPath。可用 -ResetToken 重新生成。"
    }
    return $token
}

function Resolve-ListenAddress([string]$Value) {
    $text = if ([string]::IsNullOrWhiteSpace($Value)) { '127.0.0.1' } else { $Value.Trim() }
    if ($text -eq '*' -or $text -eq '0.0.0.0') { return [System.Net.IPAddress]::Any }
    if ($text -eq '::') { return [System.Net.IPAddress]::IPv6Any }
    if ($text -ieq 'localhost') { return [System.Net.IPAddress]::Loopback }
    try { return [System.Net.IPAddress]::Parse($text) } catch { throw "bindAddress 不是有效 IP：$text" }
}

function Format-ListenAddress([System.Net.IPAddress]$Address) {
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        return '[' + $Address.IPAddressToString + ']'
    }
    return $Address.IPAddressToString
}

function Write-WebLog([string]$Message) {
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Get-RequestHeader([object]$Request, [string]$Name) {
    $key = $Name.ToLowerInvariant()
    if ($Request.Headers.ContainsKey($key)) { return [string]$Request.Headers[$key] }
    return ''
}

function Read-HttpRequest([System.Net.Sockets.TcpClient]$Client) {
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 10000
    $buffer = New-Object byte[] 8192
    $memory = New-Object System.IO.MemoryStream
    $headerEnd = -1
    try {
        while ($memory.Length -lt 65536) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { return $null }
            $memory.Write($buffer, 0, $read)
            $headText = [System.Text.Encoding]::ASCII.GetString($memory.ToArray())
            $headerEnd = $headText.IndexOf("`r`n`r`n", [System.StringComparison]::Ordinal)
            if ($headerEnd -ge 0) { break }
        }
        if ($headerEnd -lt 0) { throw 'HTTP 请求头过大或不完整。' }

        $allBytes = $memory.ToArray()
        $headerBytes = [Math]::Min($headerEnd, $allBytes.Length)
        $headerText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerBytes)
        $lines = $headerText -split "`r`n"
        if ($lines.Count -lt 1) { throw 'HTTP 请求行为空。' }
        $requestLine = $lines[0] -split ' ', 3
        if ($requestLine.Count -lt 2) { throw 'HTTP 请求行格式错误。' }
        $headers = @{}
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $colon = $lines[$i].IndexOf(':')
            if ($colon -le 0) { continue }
            $key = $lines[$i].Substring(0, $colon).Trim().ToLowerInvariant()
            $value = $lines[$i].Substring($colon + 1).Trim()
            $headers[$key] = $value
        }
        $contentLength = 0
        if ($headers.ContainsKey('content-length')) {
            if (-not [int]::TryParse($headers['content-length'], [ref]$contentLength)) { throw 'Content-Length 无效。' }
        }
        if ($contentLength -lt 0 -or $contentLength -gt 1048576) { throw '请求体超过 1 MB 限制。' }
        $bodyStart = $headerEnd + 4
        $bodyBytes = New-Object byte[] $contentLength
        $already = $allBytes.Length - $bodyStart
        if ($contentLength -gt 0 -and $already -gt 0) {
            $copy = [Math]::Min($contentLength, $already)
            [Array]::Copy($allBytes, $bodyStart, $bodyBytes, 0, $copy)
            $offset = $copy
        } else {
            $offset = 0
        }
        while ($offset -lt $contentLength) {
            $read = $stream.Read($bodyBytes, $offset, $contentLength - $offset)
            if ($read -le 0) { throw 'HTTP 请求体不完整。' }
            $offset += $read
        }
        return [pscustomobject]@{
            Method = $requestLine[0].ToUpperInvariant()
            Target = [string]$requestLine[1]
            Headers = $headers
            Body = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
            Stream = $stream
        }
    } finally {
        $memory.Dispose()
    }
}

$StatusReasons = @{
    200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 401 = 'Unauthorized';
    403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed';
    409 = 'Conflict'; 413 = 'Payload Too Large'; 429 = 'Too Many Requests'; 500 = 'Internal Server Error'
}

function Send-Bytes([System.IO.Stream]$Stream, [int]$Status, [string]$ContentType, [byte[]]$Bytes, [System.Collections.IDictionary]$ExtraHeaders) {
    $reason = if ($StatusReasons.ContainsKey($Status)) { $StatusReasons[$Status] } else { 'OK' }
    $header = "HTTP/1.1 $Status $reason`r`n" +
        "Content-Length: $($Bytes.Length)`r`n" +
        "Content-Type: $ContentType`r`n" +
        "Cache-Control: no-store`r`n" +
        "X-Content-Type-Options: nosniff`r`n" +
        "X-Frame-Options: DENY`r`n" +
        "Referrer-Policy: no-referrer`r`n" +
        "Connection: close`r`n"
    if ($ExtraHeaders) {
        foreach ($key in $ExtraHeaders.Keys) { $header += "$key`: $($ExtraHeaders[$key])`r`n" }
    }
    $header += "`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Bytes.Length -gt 0) { $Stream.Write($Bytes, 0, $Bytes.Length) }
    $Stream.Flush()
}

function Send-Text([System.IO.Stream]$Stream, [int]$Status, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [System.Collections.IDictionary]$ExtraHeaders = $null) {
    Send-Bytes -Stream $Stream -Status $Status -ContentType $ContentType -Bytes ([System.Text.Encoding]::UTF8.GetBytes([string]$Text)) -ExtraHeaders $ExtraHeaders
}

function Send-Json([System.IO.Stream]$Stream, [int]$Status, [object]$Object, [System.Collections.IDictionary]$ExtraHeaders = $null) {
    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    Send-Text -Stream $Stream -Status $Status -Text $json -ContentType 'application/json; charset=utf-8' -ExtraHeaders $ExtraHeaders
}

function Get-PathAndQuery([string]$Target) {
    $question = $Target.IndexOf('?')
    if ($question -lt 0) {
        return [pscustomobject]@{ Path = $Target; Query = @{} }
    }
    $path = $Target.Substring(0, $question)
    $queryText = $Target.Substring($question + 1)
    $query = @{}
    foreach ($part in ($queryText -split '&')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $eq = $part.IndexOf('=')
        if ($eq -lt 0) { $key = $part; $value = '' } else { $key = $part.Substring(0, $eq); $value = $part.Substring($eq + 1) }
        try { $key = [Uri]::UnescapeDataString($key.Replace('+', ' ')); $value = [Uri]::UnescapeDataString($value.Replace('+', ' ')) } catch { }
        $query[$key] = $value
    }
    return [pscustomobject]@{ Path = $path; Query = $query }
}

function Read-JsonBody([object]$Request) {
    if ([string]::IsNullOrWhiteSpace($Request.Body)) { return [pscustomobject]@{} }
    try { return $Request.Body | ConvertFrom-Json } catch { throw '请求 JSON 格式错误。' }
}

function Get-CookieValue([object]$Request, [string]$CookieName) {
    $cookie = Get-RequestHeader $Request 'cookie'
    foreach ($part in ($cookie -split ';')) {
        $pair = $part.Trim() -split '=', 2
        if ($pair.Count -eq 2 -and $pair[0] -eq $CookieName) { return $pair[1] }
    }
    return ''
}

function New-RandomSessionId {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-FixedToken([string]$Expected, [string]$Actual) {
    if ([string]::IsNullOrEmpty($Expected) -or [string]::IsNullOrEmpty($Actual)) { return $false }
    $left = [System.Text.Encoding]::UTF8.GetBytes($Expected)
    $right = [System.Text.Encoding]::UTF8.GetBytes($Actual)
    $diff = $left.Length -bxor $right.Length
    $count = [Math]::Max($left.Length, $right.Length)
    for ($i = 0; $i -lt $count; $i++) {
        $a = if ($i -lt $left.Length) { $left[$i] } else { 0 }
        $b = if ($i -lt $right.Length) { $right[$i] } else { 0 }
        $diff = $diff -bor ($a -bxor $b)
    }
    return ($diff -eq 0)
}

function Test-PanelRequest([object]$Request) {
    return ((Get-RequestHeader $Request 'x-panel-request') -eq '1')
}

function Get-RemoteAddress([System.Net.Sockets.TcpClient]$Client) {
    try { return $Client.Client.RemoteEndPoint.Address.IPAddressToString } catch { return 'unknown' }
}

function Test-LoginRate([string]$Address) {
    $now = Get-Date
    if ($script:FailedLogins.ContainsKey($Address)) {
        $entry = $script:FailedLogins[$Address]
        if (($now - $entry.Since).TotalSeconds -gt 60) {
            [void]$script:FailedLogins.Remove($Address)
        } elseif ($entry.Count -ge 5) {
            return $false
        }
    }
    return $true
}

function Record-FailedLogin([string]$Address) {
    $now = Get-Date
    if (-not $script:FailedLogins.ContainsKey($Address) -or (($now - $script:FailedLogins[$Address].Since).TotalSeconds -gt 60)) {
        $script:FailedLogins[$Address] = [pscustomobject]@{ Count = 1; Since = $now }
    } else {
        $script:FailedLogins[$Address].Count++
    }
}

function New-Session([string]$Address) {
    $id = New-RandomSessionId
    $script:Sessions[$id] = [pscustomobject]@{ Address = $Address; Expires = (Get-Date).AddMinutes($script:SessionMinutes) }
    return $id
}

function Get-AuthenticatedSession([object]$Request) {
    $id = Get-CookieValue $Request 'portable_web_session'
    if ([string]::IsNullOrWhiteSpace($id) -or -not $script:Sessions.ContainsKey($id)) { return $null }
    $session = $script:Sessions[$id]
    if ((Get-Date) -gt $session.Expires) {
        [void]$script:Sessions.Remove($id)
        return $null
    }
    $session.Expires = (Get-Date).AddMinutes($script:SessionMinutes)
    return [pscustomobject]@{ Id = $id; Data = $session }
}

function Get-RequestClientAddress([object]$Request) {
    try { return $Request.ClientAddress } catch { return 'unknown' }
}

function Read-ServerProperties {
    $props = @{}
    $path = Join-Path $Root 'server.properties'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $props }
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*([^#=]+)=(.*)$') { $props[$matches[1].Trim()] = $matches[2] }
    }
    return $props
}

function Get-ListeningPid([int]$TargetPort) {
    if ($TargetPort -le 0) { return 0 }
    if (-not (Test-ListeningPort $TargetPort)) { return 0 }
    try {
        $connections = @(Get-NetTCPConnection -State Listen -LocalPort $TargetPort -ErrorAction Stop)
        if ($connections.Count -gt 0) { return [int]$connections[0].OwningProcess }
    } catch { }
    # 某些 Windows 安全策略会拒绝普通用户读取 Get-NetTCPConnection；
    # netstat 仍能提供端口归属，作为只读兜底，避免性能面板只有「未开服」。
    try {
        $portText = [regex]::Escape([string]$TargetPort)
        foreach ($line in @(& netstat.exe -ano -p tcp 2>$null)) {
            if ([string]$line -match ('(?i)^\s*TCP\s+\S+:' + $portText + '\s+\S+\s+(?:LISTENING|正在侦听)\s+(\d+)\s*$')) {
                return [int]$matches[1]
            }
        }
    } catch { }
    return 0
}

function Test-ListeningPort([int]$TargetPort) {
    if ($TargetPort -le 0) { return $false }
    try {
        foreach ($endpoint in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            if ($endpoint.Port -eq $TargetPort) { return $true }
        }
    } catch { }
    return $false
}

function Get-PidFileAlive([string]$RelativePath) {
    $path = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
    $pidValue = 0
    try { if (-not [int]::TryParse((Get-Content -LiteralPath $path -Raw).Trim(), [ref]$pidValue)) { return 0 } } catch { return 0 }
    if ($pidValue -le 0) { return 0 }
    $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $process) { return 0 }
    try {
        $stamp = (Get-Item -LiteralPath $path).LastWriteTime
        if ($process.StartTime -gt $stamp.AddSeconds(60)) { return 0 }
    } catch { }
    return $pidValue
}

# ---------- Web 性能监控采样 ----------
# CPU、内存、磁盘由 Web 请求即时读取；GPU 计数器单次采样可能耗时数秒，
# 必须放到后台 PowerShell 管道，不能阻塞 HTTP 主循环。
$script:MemoryInfoType = $null
try {
    $script:MemoryInfoType = (Add-Type -PassThru -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PortableWebPanelNative {
    public static class MemInfo {
        [StructLayout(LayoutKind.Sequential)]
        private struct MEMORYSTATUSEX {
            public uint dwLength; public uint dwMemoryLoad;
            public ulong ullTotalPhys; public ulong ullAvailPhys;
            public ulong ullTotalPageFile; public ulong ullAvailPageFile;
            public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
        public static ulong[] Query() {
            MEMORYSTATUSEX m = new MEMORYSTATUSEX();
            m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            if (!GlobalMemoryStatusEx(ref m)) return null;
            return new ulong[] { m.ullTotalPhys, m.ullAvailPhys, (ulong)m.dwMemoryLoad };
        }
    }
}
'@) | Select-Object -First 1
} catch { $script:MemoryInfoType = $null }

$script:GpuState = [hashtable]::Synchronized(@{
    Pct = -2.0
    UpdatedAt = ''
})
$script:GpuPS = $null
$script:PerfPrev = $null

function Start-PerformanceSampling {
    if ($script:GpuPS) { return }
    try {
        $gpuPs = [powershell]::Create()
        [void]$gpuPs.AddScript({
            param($State)
            $failStreak = 0
            while ($true) {
                $pct = -1.0
                try {
                    $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
                    $byType = @{}
                    foreach ($sample in $samples) {
                        if ($sample.InstanceName -match 'engtype_([A-Za-z0-9 ]+)') {
                            $engineType = $matches[1]
                            $byType[$engineType] = [double]$byType[$engineType] + [double]$sample.CookedValue
                        }
                    }
                    $max = 0.0
                    foreach ($value in $byType.Values) { if ([double]$value -gt $max) { $max = [double]$value } }
                    $pct = [math]::Min(100.0, [math]::Max(0.0, $max))
                } catch { $pct = -1.0 }
                if ($pct -ge 0) {
                    $failStreak = 0
                    $State['Pct'] = $pct
                    $State['UpdatedAt'] = (Get-Date).ToString('o')
                    Start-Sleep -Seconds 3
                } else {
                    $failStreak++
                    if ($failStreak -ge 3) { $State['Pct'] = -1.0 }
                    Start-Sleep -Seconds 3
                }
            }
        }).AddArgument($script:GpuState)
        $script:GpuPS = $gpuPs
        [void]$gpuPs.BeginInvoke()
    } catch {
        $script:GpuState['Pct'] = -1.0
    }
}

function Stop-PerformanceSampling {
    if ($script:GpuPS) {
        try { $script:GpuPS.Stop() } catch { }
        try { $script:GpuPS.Dispose() } catch { }
        $script:GpuPS = $null
    }
}

function Get-MemorySnapshot {
    try {
        if ($script:MemoryInfoType) {
            $memory = $script:MemoryInfoType::Query()
            if ($memory) {
                $total = [double]$memory[0]
                $available = [double]$memory[1]
                return [ordered]@{
                    pct = [double]$memory[2]
                    totalBytes = [int64]$total
                    availableBytes = [int64]$available
                    usedBytes = [int64]($total - $available)
                }
            }
        }
    } catch { }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $total = [double]$os.TotalVisibleMemorySize * 1KB
        $available = [double]$os.FreePhysicalMemory * 1KB
        if ($total -gt 0) {
            return [ordered]@{
                pct = [double](100.0 - ($available / $total * 100.0))
                totalBytes = [int64]$total
                availableBytes = [int64]$available
                usedBytes = [int64]($total - $available)
            }
        }
    } catch { }
    return [ordered]@{ pct = -1.0; totalBytes = 0L; availableBytes = 0L; usedBytes = 0L }
}

function Get-PerformanceData([int]$ServerPid) {
    $now = [DateTime]::UtcNow
    $cpuPct = -1.0
    $cpuState = 'offline'
    $serverMemoryBytes = 0L
    $serverPrivateBytes = 0L
    $process = $null
    if ($ServerPid -gt 0) { $process = Get-Process -Id $ServerPid -ErrorAction SilentlyContinue }
    if ($process) {
        $cpuState = 'sampling'
        try {
            $cpuSeconds = $process.TotalProcessorTime.TotalSeconds
            $serverMemoryBytes = [int64]$process.WorkingSet64
            $serverPrivateBytes = [int64]$process.PrivateMemorySize64
            if ($script:PerfPrev -and $script:PerfPrev.ProcId -eq $ServerPid) {
                $elapsed = ($now - $script:PerfPrev.Stamp).TotalSeconds
                if ($elapsed -ge 1) {
                    $cpuPct = (($cpuSeconds - $script:PerfPrev.Cpu) / $elapsed / [Math]::Max(1, [Environment]::ProcessorCount)) * 100.0
                    $cpuPct = [math]::Max(0.0, [math]::Min(100.0, $cpuPct))
                    $cpuState = 'ready'
                }
            }
            $script:PerfPrev = @{ ProcId = $ServerPid; Cpu = $cpuSeconds; Stamp = $now }
        } catch {
            $script:PerfPrev = $null
            $cpuState = 'unavailable'
        }
    } else {
        $script:PerfPrev = $null
    }

    $memory = Get-MemorySnapshot
    $disk = [ordered]@{ pct = -1.0; totalBytes = 0L; freeBytes = 0L; usedBytes = 0L }
    try {
        $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($Root))
        $total = [double]$drive.TotalSize
        $free = [double]$drive.AvailableFreeSpace
        if ($total -gt 0) {
            $disk = [ordered]@{
                pct = [double](100.0 - ($free / $total * 100.0))
                totalBytes = [int64]$total
                freeBytes = [int64]$free
                usedBytes = [int64]($total - $free)
            }
        }
    } catch { }

    $gpuPct = -1.0
    $gpuState = 'unavailable'
    try { $gpuPct = [double]$script:GpuState['Pct'] } catch { }
    if ($gpuPct -ge 0) { $gpuState = 'ready' }
    elseif ($gpuPct -le -1.5) { $gpuState = 'sampling' }

    return [ordered]@{
        cpu = [ordered]@{
            pct = [double]$cpuPct
            state = $cpuState
            cores = [int][Environment]::ProcessorCount
            pid = [int]$ServerPid
        }
        gpu = [ordered]@{ pct = [double]$gpuPct; state = $gpuState }
        memory = $memory
        disk = $disk
        serverMemory = [ordered]@{ workingSetBytes = $serverMemoryBytes; privateBytes = $serverPrivateBytes }
        sampledAt = (Get-Date).ToString('o')
    }
}

function Get-BackupItems {
    $dir = Join-Path $Root 'backups\world'
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $items = New-Object System.Collections.Generic.List[object]
    $total = 0L
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    foreach ($file in $files) {
        $total += [int64]$file.Length
        if ($items.Count -ge 30) { continue }
        $full = [System.IO.Path]::GetFullPath($file.FullName)
        $relative = $full.Substring($rootFull.Length).TrimStart('\', '/')
        [void]$items.Add([ordered]@{
            name = $file.Name
            relativePath = $relative
            sizeBytes = [int64]$file.Length
            lastWrite = $file.LastWriteTime.ToString('o')
        })
    }
    return [ordered]@{ count = $files.Count; totalBytes = $total; items = @($items.ToArray()) }
}

function Get-StatusData {
    $props = Read-ServerProperties
    $serverPort = 25565
    $parsed = 0
    if ([int]::TryParse(([string]$props['server-port']).Trim(), [ref]$parsed) -and $parsed -gt 0) { $serverPort = $parsed }
    $serverPid = Get-ListeningPid $serverPort
    $serverListening = Test-ListeningPort $serverPort

    $rconPort = 0
    [void][int]::TryParse(([string]$props['rcon.port']).Trim(), [ref]$rconPort)
    $rconConfigured = (([string]$props['enable-rcon']).Trim().ToLowerInvariant() -eq 'true' -and -not [string]::IsNullOrWhiteSpace([string]$props['rcon.password']))

    $update = [ordered]@{ configured = $false; running = $false; port = 0 }
    $packPath = Join-Path $ToolsDir 'portable-pack.json'
    if (Test-Path -LiteralPath $packPath -PathType Leaf) {
        try {
            $pack = Get-Content -LiteralPath $packPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $updatePort = [int](Get-ConfigValue $pack.update 'port' 0)
            $update.configured = ($updatePort -gt 0)
            $update.port = $updatePort
            $update.running = ($updatePort -gt 0 -and (Test-ListeningPort $updatePort))
        } catch { }
    }

    $monitorDefinitions = @(
        @{ key = 'watch'; label = '日志/通知监控'; file = 'tmp\discord-watch.pid' },
        @{ key = 'discord'; label = 'Discord 反控'; file = 'tmp\discord-console.pid' },
        @{ key = 'qq'; label = 'QQ 反控'; file = 'tmp\qq-console.pid' },
        @{ key = 'backup'; label = '备份调度'; file = 'tmp\backup-scheduler.pid' },
        @{ key = 'perf'; label = '性能采样'; file = 'tmp\perf-sampler.pid' },
        @{ key = 'supervisor'; label = '运维看门狗'; file = 'tmp\ops-supervisor.pid' }
    )
    $monitors = New-Object System.Collections.Generic.List[object]
    foreach ($definition in $monitorDefinitions) {
        $pidValue = Get-PidFileAlive ([string]$definition.file)
        [void]$monitors.Add([ordered]@{ key = $definition.key; label = $definition.label; running = ($pidValue -gt 0); pid = $pidValue })
    }

    $backupItems = Get-BackupItems
    return [ordered]@{
        server = [ordered]@{ running = $serverListening; port = $serverPort; pid = $serverPid }
        rcon = [ordered]@{ configured = $rconConfigured; port = $rconPort; allowConsoleCommands = $script:AllowConsoleCommands }
        update = $update
        monitors = @($monitors.ToArray())
        backups = $backupItems
        performance = Get-PerformanceData $serverPid
        generatedAt = (Get-Date).ToString('o')
    }
}

function Get-LogMap {
    return [ordered]@{
        server = 'logs\latest.log'
        wrapper = 'logs\server-wrapper.log'
        operations = 'logs\ops-supervisor.log'
        discord = 'logs\discord-watch.log'
        qq = 'logs\qq-console.log'
        web = 'logs\portable-web-panel.log'
    }
}

function Get-LogTail([string]$Name, [int]$RequestedLines) {
    $map = Get-LogMap
    if (-not $map.Contains($Name)) { throw '不允许读取此日志。' }
    $lines = [Math]::Max(20, [Math]::Min($script:MaxLogLines, $RequestedLines))
    $path = Join-Path $Root $map[$Name]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { return ((Get-Content -LiteralPath $path -Tail $lines -Encoding UTF8 -ErrorAction Stop) -join "`r`n") } catch { return '[日志读取失败] ' + $_.Exception.Message }
}

function Resolve-BatPath([string]$BatName) {
    $path = Join-Path $Root (Join-Path '一键脚本' $BatName)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $path = Join-Path $Root $BatName }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "找不到一键脚本：$BatName" }
    return $path
}

function Start-BatEntry([string]$BatName) {
    $path = Resolve-BatPath $BatName
    $process = Start-Process -FilePath $env:ComSpec -WorkingDirectory $Root -ArgumentList @('/d', '/c', ('"' + $path + '"')) -PassThru
    Write-WebLog ("启动脚本 {0}，PID={1}" -f $BatName, $process.Id)
    return [ordered]@{ name = $BatName; pid = $process.Id }
}

function Start-ToolScript([string]$ScriptName, [string]$Label) {
    $path = Join-Path $ToolsDir $ScriptName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "找不到工具脚本：$ScriptName" }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $path + '"'))
    $process = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Root -ArgumentList $args -PassThru
    Write-WebLog ("启动工具 {0} ({1})，PID={2}" -f $ScriptName, $Label, $process.Id)
    return [ordered]@{ name = $Label; pid = $process.Id }
}

function Test-RconConfigured {
    $props = Read-ServerProperties
    return (([string]$props['enable-rcon']).Trim().ToLowerInvariant() -eq 'true' -and -not [string]::IsNullOrWhiteSpace([string]$props['rcon.password']))
}

function Invoke-RconCommand([string]$Command) {
    $clean = $Command.Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { throw 'RCON 命令为空。' }
    if ($clean.Length -gt 512) { throw 'RCON 命令不能超过 512 个字符。' }
    $scriptPath = Join-Path $ToolsDir 'rcon-command.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw '缺少 tools\rcon-command.ps1。' }
    try {
        $output = (& $scriptPath -Command $clean 2>&1 | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($output)) { $output = '(服务器没有返回内容)' }
        if ($output.Length -gt 60000) { $output = $output.Substring(0, 60000) + "`r`n...[输出已截断]" }
        Write-WebLog ("RCON 命令执行，长度={0}" -f $clean.Length)
        return $output
    } catch {
        throw ('RCON 执行失败：' + $_.Exception.Message)
    }
}

function Clear-MaintenanceStop {
    $path = Join-Path $Root 'maintenance.stop'
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -Confirm:$false -ErrorAction SilentlyContinue }
}

function Write-MaintenanceStop {
    $path = Join-Path $Root 'maintenance.stop'
    [System.IO.File]::WriteAllText($path, ('web panel stop ' + (Get-Date -Format 's') + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-PanelAction([string]$Name, [bool]$Confirm) {
    $dangerous = @('restartServer', 'stopServer', 'stopOps')
    if ($dangerous -contains $Name -and -not $Confirm) { throw '此操作需要页面二次确认。' }
    switch ($Name) {
        'startServer' {
            Clear-MaintenanceStop
            $started = Start-BatEntry '一键便携-启动服务端.bat'
            return [ordered]@{ ok = $true; message = '已启动服务端脚本。'; process = $started }
        }
        'restartServer' {
            if (-not (Test-RconConfigured)) { return [ordered]@{ ok = $false; message = '重启需要已启用且有密码的本地 RCON。' } }
            Clear-MaintenanceStop
            $reply = Invoke-RconCommand 'stop'
            return [ordered]@{ ok = $true; message = '已发送安全停服命令，看门狗将按原规则重新拉起服务端。'; output = $reply }
        }
        'stopServer' {
            Write-MaintenanceStop
            if (Test-RconConfigured) {
                $reply = Invoke-RconCommand 'stop'
                return [ordered]@{ ok = $true; message = '已写入停服标记并发送安全停服命令，不会自动重启。'; output = $reply }
            }
            return [ordered]@{ ok = $true; message = '已写入停服标记，但 RCON 未启用；需要在本机服务端控制台输入 stop。' }
        }
        'publishUpdate' {
            $started = Start-BatEntry '一键便携-仅发布更新.bat'
            return [ordered]@{ ok = $true; message = '已启动“仅发布更新”。它只发布主分发客户端增量文件，不会重启 Minecraft。'; process = $started }
        }
        'startOps' {
            $started = Start-BatEntry '一键便携-启动所有运维.bat'
            return [ordered]@{ ok = $true; message = '已启动所有运维脚本。若脚本请求 UAC，请在服务器本机确认。'; process = $started }
        }
        'restartOps' {
            $started = Start-BatEntry '一键便携-重启运维监控.bat'
            return [ordered]@{ ok = $true; message = '已启动运维监控重启脚本。'; process = $started }
        }
        'stopOps' {
            $started = Start-BatEntry '一键便携-停止所有运维.bat'
            return [ordered]@{ ok = $true; message = '已启动停止所有运维脚本。若脚本请求 UAC，请在服务器本机确认。'; process = $started }
        }
        'backupNow' {
            $started = Start-ToolScript 'backup-world.ps1' '立即备份世界'
            return [ordered]@{ ok = $true; message = '已启动立即备份。'; process = $started }
        }
        'healthCheck' {
            $started = Start-BatEntry '一键便携-健康体检.bat'
            return [ordered]@{ ok = $true; message = '已启动健康体检脚本。'; process = $started }
        }
        'weeklyReport' {
            $started = Start-BatEntry '一键便携-运行报告.bat'
            return [ordered]@{ ok = $true; message = '已启动运行报告脚本。'; process = $started }
        }
        'incidentPostmortem' {
            $started = Start-BatEntry '一键便携-事故自动复盘.bat'
            return [ordered]@{ ok = $true; message = '已启动事故复盘脚本。'; process = $started }
        }
        'verifyBackup' {
            $started = Start-BatEntry '一键便携-验证备份.bat'
            return [ordered]@{ ok = $true; message = '已启动备份验证脚本。'; process = $started }
        }
        default { throw "不允许的操作：$Name" }
    }
}

function Invoke-QuickCommand([string]$Name) {
    $props = Read-ServerProperties
    if (-not (Test-RconConfigured)) { throw '本地 RCON 未启用或密码为空。' }
    switch ($Name) {
        'list' { $command = 'list' }
        'day' { $command = 'time set day' }
        'weather' { $command = 'weather clear' }
        'save' { $command = 'save-all flush' }
        'tps' {
            $loader = ''
            $packPath = Join-Path $ToolsDir 'portable-pack.json'
            if (Test-Path -LiteralPath $packPath -PathType Leaf) {
                try { $pack = Get-Content -LiteralPath $packPath -Raw -Encoding UTF8 | ConvertFrom-Json; $loader = ([string]$pack.loader.type).Trim().ToLowerInvariant() } catch { }
            }
            if ($loader -eq 'forge') { $command = 'forge tps' } elseif ($loader -eq 'neoforge') { $command = 'neoforge tps' } else { $command = 'tps' }
        }
        default { throw '不允许的快捷命令。' }
    }
    return [ordered]@{ ok = $true; command = $command; output = (Invoke-RconCommand $command) }
}

function Get-WebPage {
    return @'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>服务器运维 Web 控制面板</title>
<style>
:root{color-scheme:dark;--bg:#11151b;--card:#1b222c;--line:#303b49;--text:#e8edf4;--muted:#9ba8b8;--accent:#39b982;--danger:#cf5a68;--warn:#e5b85c;--input:#10151b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,"Microsoft YaHei UI",sans-serif}
button,input,select{font:inherit}button{border:0;border-radius:8px;padding:9px 13px;background:#2a3542;color:var(--text);cursor:pointer}button:hover{filter:brightness(1.15)}button:disabled{opacity:.45;cursor:not-allowed}.primary{background:var(--accent);color:#07130e}.danger{background:var(--danger);color:#fff}.small{padding:6px 9px;font-size:12px}
.wrap{max-width:1280px;margin:0 auto;padding:24px}.head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:18px}.head h1{font-size:24px;margin:0}.head p{color:var(--muted);margin:4px 0 0}.head-actions{display:flex;gap:8px;flex-wrap:wrap}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:14px}.card h2{font-size:16px;margin:0 0 12px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px}.stat{border:1px solid var(--line);border-radius:9px;padding:12px;background:#171d25}.stat b{display:block;font-size:17px;margin-top:3px}.good{color:var(--accent)}.bad{color:var(--danger)}.warn{color:var(--warn)}.muted{color:var(--muted)}
.actions{display:flex;flex-wrap:wrap;gap:8px}.columns{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(300px,.8fr);gap:14px}@media(max-width:820px){.wrap{padding:13px}.columns{grid-template-columns:1fr}.head{align-items:flex-start;flex-direction:column}}
input,select{background:var(--input);color:var(--text);border:1px solid var(--line);border-radius:7px;padding:9px}.login{max-width:480px;margin:12vh auto}.login h1{margin-top:0}.login-row{display:flex;gap:8px}.login-row input{flex:1}.notice{border-left:3px solid var(--warn);background:#2a2518;padding:10px;color:#f3d98c;margin-bottom:14px}.hidden{display:none!important}.msg{min-height:24px;color:var(--muted);margin:8px 0}.msg.error{color:#ff9ca6}.msg.ok{color:#7de0af}
pre{white-space:pre-wrap;word-break:break-word;max-height:360px;overflow:auto;background:#0b0f14;border:1px solid var(--line);border-radius:8px;padding:12px;margin:10px 0 0;font:12px/1.55 Consolas,monospace}.rcon-row{display:flex;gap:8px}.rcon-row input{flex:1;font-family:Consolas,monospace}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;border-bottom:1px solid var(--line);padding:8px 6px;white-space:nowrap}th{color:var(--muted)}
.perf-head{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:12px}.perf-head h2{margin:0}.perf-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}.gauge-card{text-align:center;min-width:0}.gauge{--pct:0%;--gauge-color:var(--accent);width:112px;height:112px;border-radius:50%;margin:0 auto 8px;background:conic-gradient(from -90deg,var(--gauge-color) var(--pct),#3a2c38 0);display:grid;place-items:center;position:relative}.gauge::after{content:"";position:absolute;inset:10px;border-radius:50%;background:var(--card)}.gauge-inner{position:relative;z-index:1;display:flex;flex-direction:column;align-items:center;line-height:1.15}.gauge-value{font-size:23px;font-weight:700}.gauge-sub{font-size:12px;color:var(--muted);margin-top:4px;max-width:92px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.gauge-label{font-size:14px;color:var(--muted)}.perf-chart{margin-top:14px;padding:10px 12px 8px;border:1px solid var(--line);border-radius:10px;background:#151b23}.perf-chart canvas{display:block;width:100%;height:130px}.perf-legend{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:13px;flex-wrap:wrap}.legend-dot{width:9px;height:9px;border-radius:50%;display:inline-block}.legend-cpu{background:var(--accent)}.legend-mem{background:var(--warn)}.perf-details{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;margin-top:12px}.perf-detail{border:1px solid var(--line);border-radius:8px;padding:9px 10px;background:#171d25}.perf-detail span{display:block;color:var(--muted);font-size:12px}.perf-detail b{display:block;margin-top:2px;font-size:14px}.perf-status{min-height:20px;margin-top:8px;color:var(--muted);font-size:12px}@media(max-width:700px){.perf-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.gauge{width:96px;height:96px}.gauge::after{inset:9px}.gauge-value{font-size:20px}.perf-details{grid-template-columns:1fr}}
@media(max-width:700px){body{overflow-x:hidden}.wrap{padding:10px}.card{padding:12px;margin-bottom:10px;border-radius:10px}.head{gap:8px;margin-bottom:12px}.head h1{font-size:21px;line-height:1.25}.head p{font-size:13px}.head-actions{width:100%;display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.head-actions button{min-height:44px}.notice{padding:9px 10px;font-size:13px;line-height:1.55}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.stat{padding:10px}.stat b{font-size:14px;line-height:1.35}.stat small{font-size:11px}.actions{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.actions button{min-height:44px;padding:9px 8px}.rcon-row{flex-direction:column}.rcon-row button{min-height:44px}.login-row{flex-direction:column}.login-row button{min-height:44px}.perf-head{align-items:flex-start}.perf-grid{gap:8px}.perf-chart{margin-top:10px;padding:8px}.perf-chart canvas{height:110px}.perf-details{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.perf-detail{padding:8px}.perf-detail:last-child{grid-column:1/-1}.perf-detail b{font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}\n@media(max-width:380px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}.stat{padding:8px}.stat b{font-size:13px}.stat small{font-size:10px}.card h2{font-size:15px}.gauge{width:92px;height:92px}.gauge-value{font-size:19px}.gauge-sub{font-size:11px}}\n</style>
<style>
@media(max-width:380px){.gauge{width:92px;height:92px}.gauge-value{font-size:19px}.gauge-sub{font-size:11px}}
</style>
<style>
@media(max-width:700px){
  .columns{grid-template-columns:minmax(0,1fr);min-width:0}
  .columns>div,.card,.actions,.table-wrap,.perf-grid,.perf-chart{min-width:0}
  .actions{width:100%}
  .actions button,.actions select{width:100%;min-width:0;white-space:normal;overflow-wrap:anywhere}
  input,select{min-width:0;max-width:100%}
  .notice,.muted,#accessInfo,#consoleHint{overflow-wrap:anywhere;word-break:break-word}
  .table-wrap{width:100%;overflow-x:hidden}
  table{width:100%;table-layout:fixed}
  th,td{white-space:normal;overflow-wrap:anywhere;word-break:break-word}
  th:first-child,td:first-child{width:34%}
  th:nth-child(2),td:nth-child(2){width:50%}
  th:nth-child(3),td:nth-child(3){width:16%}
  #logName{font-size:13px}
  #logOutput,#rconOutput{max-width:100%;overflow-x:auto}
  .rcon-row{min-width:0;width:100%}
  .rcon-row input,.rcon-row button{width:100%;min-width:0}
}
</style>
</head>
<body>
<main class="wrap">
  <section id="loginView" class="card login">
    <h1>服务器运维 Web 控制面板</h1>
    <p class="muted">请输入本机生成的 Web 面板令牌。令牌不会出现在 URL 中。</p>
    <div class="login-row"><input id="tokenInput" type="password" autocomplete="current-password" placeholder="wp-..."><button id="loginBtn" class="primary">登录</button></div>
    <div id="loginMsg" class="msg"></div>
  </section>
  <section id="appView" class="hidden">
    <header class="head"><div><h1>服务器运维 Web 控制面板</h1><p id="updatedText">尚未刷新</p></div><div class="head-actions"><button id="refreshBtn">刷新</button><button id="logoutBtn">退出登录</button></div></header>
    <div class="notice">这是高权限运维入口。默认推荐通过 SSH/VPN 端口转发访问；如果直接把 HTTP 端口映射到公网，请务必限制来源、使用强令牌，并了解 HTTP 本身不加密。</div>
    <section class="card"><h2>运行状态</h2><div id="statusGrid" class="grid"></div><div id="statusMsg" class="msg"></div></section>
    <section class="card" id="performanceCard">
      <div class="perf-head"><h2>📊 性能监控</h2><span class="muted">每 5 秒刷新</span></div>
      <div class="perf-grid">
        <div class="gauge-card" title="Minecraft 服务端进程 CPU 占用，按全部核心折算"><div class="gauge" id="gaugeCpu"><div class="gauge-inner"><b class="gauge-value" id="perfCpuValue">—</b><small class="gauge-sub" id="perfCpuSub">等待采样</small></div></div><div class="gauge-label">CPU</div></div>
        <div class="gauge-card" title="整机 GPU 占用，取最忙引擎，口径接近任务管理器"><div class="gauge" id="gaugeGpu"><div class="gauge-inner"><b class="gauge-value" id="perfGpuValue">—</b><small class="gauge-sub" id="perfGpuSub">采样中</small></div></div><div class="gauge-label">GPU</div></div>
        <div class="gauge-card" title="整机物理内存占用"><div class="gauge" id="gaugeMemory"><div class="gauge-inner"><b class="gauge-value" id="perfMemoryValue">—</b><small class="gauge-sub" id="perfMemorySub">等待采样</small></div></div><div class="gauge-label">内存</div></div>
        <div class="gauge-card" title="服务端所在磁盘空间占用"><div class="gauge" id="gaugeDisk"><div class="gauge-inner"><b class="gauge-value" id="perfDiskValue">—</b><small class="gauge-sub" id="perfDiskSub">等待采样</small></div></div><div class="gauge-label">磁盘</div></div>
      </div>
      <div class="perf-chart"><canvas id="perfCanvas" height="130"></canvas><div class="perf-legend"><i class="legend-dot legend-cpu"></i><span>服务端 CPU</span><i class="legend-dot legend-mem"></i><span>系统内存</span><span>· 最近 5 分钟</span></div></div>
      <div class="perf-details"><div class="perf-detail"><span>服务端内存</span><b id="perfServerMemory">—</b></div><div class="perf-detail"><span>磁盘可用</span><b id="perfDiskFree">—</b></div><div class="perf-detail"><span>采样时间</span><b id="perfSampledAt">—</b></div></div>
      <div id="perfStatus" class="perf-status"></div>
    </section>
    <div class="columns">
      <div>
        <section class="card"><h2>服务端控制</h2><div class="actions"><button class="primary" data-action="startServer">启动服务端</button><button data-action="restartServer" data-danger="1">重启服务端</button><button class="danger" data-action="stopServer" data-danger="1">停止服务端</button><button class="primary" data-action="publishUpdate" title="只发布增量更新，不重启 Minecraft">仅发布更新</button><button data-action="backupNow">立即备份</button><button data-action="healthCheck">健康体检</button><button data-action="weeklyReport">运行报告</button><button data-action="incidentPostmortem">事故复盘</button><button data-action="verifyBackup">验证备份</button></div></section>
        <section class="card"><h2>运维监控</h2><p class="muted">启动/停止脚本可能触发服务器本机 UAC；远程浏览器无法点击本机 UAC 窗口。</p><div class="actions"><button class="primary" data-action="startOps">启动所有运维</button><button data-action="restartOps">重启运维监控</button><button class="danger" data-action="stopOps" data-danger="1">停止所有运维</button></div></section>
        <section class="card"><h2>备份概览</h2><div id="backupText" class="muted"></div><div class="table-wrap"><table><thead><tr><th>时间</th><th>文件</th><th>大小</th></tr></thead><tbody id="backupRows"></tbody></table></div></section>
        <section class="card"><h2>日志</h2><div class="actions"><select id="logName"><option value="server">服务端 latest.log</option><option value="wrapper">服务端包装器</option><option value="operations">运维看门狗</option><option value="discord">Discord 监控</option><option value="qq">QQ 反控</option><option value="web">Web 面板</option></select><button id="loadLogBtn">读取末尾日志</button></div><pre id="logOutput">点击读取日志。</pre></section>
      </div>
      <div>
        <section class="card"><h2>RCON 快捷操作</h2><div class="actions"><button data-quick="list">在线玩家</button><button data-quick="tps">TPS</button><button data-quick="day">设为白天</button><button data-quick="weather">放晴</button><button data-quick="save">立即存档</button></div><pre id="rconOutput">暂无输出。</pre></section>
        <section class="card" id="consoleCard"><h2>RCON 控制台</h2><p id="consoleHint" class="muted">配置文件中的 allowConsoleCommands 当前为 false。需要时在服务器本机编辑 tools\portable-web-panel.json 后重启 Web 面板。</p><div class="rcon-row"><input id="rconInput" placeholder="例如：list"><button id="rconBtn" class="primary">发送</button></div></section>
        <section class="card"><h2>访问信息</h2><div id="accessInfo" class="muted">加载中…</div></section>
      </div>
    </div>
  </section>
</main>
<script>
const $=id=>document.getElementById(id);
let panelConfig=null;
let perfHistory=[];
function setMsg(id,text,kind=''){const e=$(id);e.textContent=text;e.className='msg '+kind}
function fmtBytes(n){n=Number(n||0);if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(1)+' KB';if(n<1073741824)return (n/1048576).toFixed(1)+' MB';return (n/1073741824).toFixed(2)+' GB'}
function fmtTime(s){try{return new Date(s).toLocaleString()}catch(e){return s||''}}
function metricNumber(v){let n=Number(v);return Number.isFinite(n)?n:null}
function pctText(v){return v===null?'—':(v<10?v.toFixed(1):v.toFixed(0))+'%'}
function fmtGbPair(used,total){if(!total||total<0)return '—';return (used/1073741824).toFixed(1)+'/'+(total/1073741824).toFixed(1)+'G'}
function setGauge(gaugeId,valueId,subId,metric,subText,warnAt,badAt){let v=metricNumber(metric&&metric.pct);let ok=v!==null&&v>=0;let gauge=$(gaugeId);let color='var(--accent)';if(ok&&v>=badAt)color='var(--danger)';else if(ok&&v>=warnAt)color='var(--warn)';gauge.style.setProperty('--pct',(ok?Math.max(0,Math.min(100,v)):0)+'%');gauge.style.setProperty('--gauge-color',ok?color:'var(--muted)');$(valueId).textContent=ok?pctText(v):(metric&&metric.state==='sampling'?'…':'—');$(subId).textContent=subText||'';return ok?v:null}
function drawPerfChart(){let canvas=$('perfCanvas');if(!canvas)return;let w=Math.max(260,Math.floor(canvas.clientWidth||600)),h=130,dpr=Math.max(1,window.devicePixelRatio||1);canvas.width=w*dpr;canvas.height=h*dpr;let ctx=canvas.getContext('2d');ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,w,h);ctx.strokeStyle='rgba(155,168,184,.16)';ctx.lineWidth=1;for(let i=0;i<=4;i++){let y=8+(h-20)*i/4;ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke()}let n=perfHistory.length;function plot(key,color,width){ctx.strokeStyle=color;ctx.lineWidth=width;ctx.lineJoin='round';ctx.lineCap='round';let started=false;for(let i=0;i<n;i++){let v=perfHistory[i][key];if(v===null||v===undefined){started=false;continue}let x=n<2?w:i*(w/(Math.max(1,n-1)));let y=h-10-(Math.max(0,Math.min(100,v))/100)*(h-20);if(!started){ctx.beginPath();ctx.moveTo(x,y);started=true}else ctx.lineTo(x,y)}if(started)ctx.stroke()}plot('mem','rgba(229,184,92,.95)',1.8);plot('cpu','rgba(57,185,130,.98)',2.2);if(!perfHistory.some(x=>x.cpu!==null||x.mem!==null)){ctx.fillStyle='rgba(155,168,184,.8)';ctx.font='12px system-ui,\"Microsoft YaHei UI\",sans-serif';ctx.fillText('等待性能采样…',12,24)}}
function renderPerformance(p){p=p||{};let c=p.cpu||{},g=p.gpu||{},m=p.memory||{},d=p.disk||{},sm=p.serverMemory||{};let cpu=setGauge('gaugeCpu','perfCpuValue','perfCpuSub',c,(c.state==='offline'?'未开服':(c.state==='sampling'?'采样中':(c.cores||'')+' 核')),60,85);let gpu=setGauge('gaugeGpu','perfGpuValue','perfGpuSub',g,g.state==='unavailable'?'不可用':(g.state==='sampling'?'采样中':'整机'),70,90);let memSub=fmtGbPair(m.usedBytes||0,m.totalBytes||0);let mem=setGauge('gaugeMemory','perfMemoryValue','perfMemorySub',m,memSub,75,90);let diskSub=d.freeBytes?('余 '+fmtBytes(d.freeBytes)):'不可用';let disk=setGauge('gaugeDisk','perfDiskValue','perfDiskSub',d,diskSub,80,92);perfHistory.push({cpu:cpu,mem:mem});if(perfHistory.length>60)perfHistory.shift();drawPerfChart();$('perfServerMemory').textContent=sm.workingSetBytes?fmtBytes(sm.workingSetBytes):'未开服';$('perfDiskFree').textContent=d.freeBytes?fmtBytes(d.freeBytes):'—';$('perfSampledAt').textContent=p.sampledAt?fmtTime(p.sampledAt):'—';let notes=[];if(c.state==='sampling')notes.push('CPU 首次采样中');if(g.state==='unavailable')notes.push('GPU 计数器不可用');$('perfStatus').textContent=notes.join(' · ')}
async function api(path,options={}){options.credentials='same-origin';options.headers=Object.assign({'X-Panel-Request':'1'},options.headers||{});let r=await fetch(path,options);let data={};try{data=await r.json()}catch(e){}if(r.status===401){showLogin();throw new Error(data.message||'登录已过期')}if(!r.ok)throw new Error(data.message||('请求失败 HTTP '+r.status));return data}
function showLogin(){ $('loginView').classList.remove('hidden');$('appView').classList.add('hidden');$('tokenInput').focus() }
function showApp(){ $('loginView').classList.add('hidden');$('appView').classList.remove('hidden') }
async function login(){let token=$('tokenInput').value.trim();if(!token){setMsg('loginMsg','请输入令牌','error');return}setMsg('loginMsg','正在登录…');try{await api('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token})});showApp();$('tokenInput').value='';await loadConfig();await refresh()}catch(e){setMsg('loginMsg',e.message,'error')}}
function renderStatus(s){let m=(s.monitors||[]).map(x=>`<div class="stat"><span class="muted">${x.label}</span><b class="${x.running?'good':'muted'}">${x.running?'运行中':'未运行'}</b><small class="muted">${x.running?'PID '+x.pid:''}</small></div>`).join('');let base=`<div class="stat"><span class="muted">Minecraft 服务端</span><b class="${s.server.running?'good':'bad'}">${s.server.running?'运行中':'未运行'}</b><small class="muted">端口 ${s.server.port}${s.server.pid?' · PID '+s.server.pid:''}</small></div><div class="stat"><span class="muted">本地 RCON</span><b class="${s.rcon.configured?'good':'warn'}">${s.rcon.configured?'已配置':'未配置'}</b><small class="muted">端口 ${s.rcon.port||'—'}</small></div><div class="stat"><span class="muted">更新服务</span><b class="${s.update.running?'good':'muted'}">${s.update.running?'运行中':'未运行'}</b><small class="muted">端口 ${s.update.port||'—'}</small></div>`;$('statusGrid').innerHTML=base+m;$('updatedText').textContent='最后刷新：'+fmtTime(s.generatedAt);let b=s.backups||{};$('backupText').textContent=`共 ${b.count||0} 份 · 占用 ${fmtBytes(b.totalBytes||0)} · 仅显示最新 ${Math.min(30,b.items?.length||0)} 份`;$('backupRows').textContent='';for(const x of (b.items||[])){let tr=document.createElement('tr');for(const v of [fmtTime(x.lastWrite),x.name,fmtBytes(x.sizeBytes)]){let td=document.createElement('td');td.textContent=v;tr.appendChild(td)}$('backupRows').appendChild(tr)}}
async function refresh(){try{let s=await api('/api/status');renderStatus(s);renderPerformance(s.performance);setMsg('statusMsg','状态已刷新','ok')}catch(e){setMsg('statusMsg',e.message,'error')}}
async function loadConfig(){try{panelConfig=await api('/api/config');$('accessInfo').textContent=`监听：${panelConfig.bindAddress}:${panelConfig.port} · 会话 ${panelConfig.sessionMinutes} 分钟 · 任意 RCON：${panelConfig.allowConsoleCommands?'已开启':'关闭'}`;let enabled=!!panelConfig.allowConsoleCommands;$('rconInput').disabled=!enabled;$('rconBtn').disabled=!enabled;$('consoleHint').textContent=enabled?'已开启任意 RCON 命令，请把它当作完整服务器管理员权限使用。':'配置文件中的 allowConsoleCommands 当前为 false。需要时在服务器本机编辑 tools\\portable-web-panel.json 后重启 Web 面板。'}catch(e){setMsg('statusMsg',e.message,'error')}}
async function runAction(name,danger){if(danger&&!window.confirm('确认执行“'+name+'”？这可能导致停服或停止运维。'))return;try{let d=await api('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,confirm:!!danger})});setMsg('statusMsg',d.message||'操作已提交',d.ok===false?'error':'ok');if(d.output)$('rconOutput').textContent=d.output;setTimeout(refresh,1200)}catch(e){setMsg('statusMsg',e.message,'error')}}
async function quick(name){try{let d=await api('/api/quick',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name})});$('rconOutput').textContent=d.output||'(无输出)';setMsg('statusMsg','已执行：'+d.command,'ok');setTimeout(refresh,500)}catch(e){$('rconOutput').textContent=e.message;setMsg('statusMsg',e.message,'error')}}
async function sendRcon(){let command=$('rconInput').value.trim();if(!command)return;try{let d=await api('/api/rcon',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({command,confirm:window.confirm('确认把命令发送到服务器？')})});$('rconOutput').textContent=d.output||'(无输出)';$('rconInput').value=''}catch(e){$('rconOutput').textContent=e.message;setMsg('statusMsg',e.message,'error')}}
async function loadLog(){try{let d=await api('/api/logs?name='+encodeURIComponent($('logName').value));$('logOutput').textContent=d.text||'(日志为空或文件不存在)'}catch(e){$('logOutput').textContent=e.message}}
async function logout(){try{await api('/api/logout',{method:'POST'});showLogin()}catch(e){showLogin()}}
$('loginBtn').onclick=login;$('tokenInput').onkeydown=e=>{if(e.key==='Enter')login()};$('refreshBtn').onclick=refresh;$('logoutBtn').onclick=logout;$('loadLogBtn').onclick=loadLog;$('rconBtn').onclick=sendRcon;$('rconInput').onkeydown=e=>{if(e.key==='Enter')sendRcon()};document.querySelectorAll('[data-action]').forEach(b=>b.onclick=()=>runAction(b.dataset.action,b.dataset.danger==='1'));document.querySelectorAll('[data-quick]').forEach(b=>b.onclick=()=>quick(b.dataset.quick));
window.addEventListener('resize',drawPerfChart);showLogin();setInterval(()=>{if(!$('appView').classList.contains('hidden'))refresh()},5000);
</script>
</body>
</html>
'@
}

function Handle-WebRequest([System.Net.Sockets.TcpClient]$Client) {
    $remote = Get-RemoteAddress $Client
    $request = $null
    try {
        $request = Read-HttpRequest $Client
        if ($null -eq $request) { return }
        $request | Add-Member -NotePropertyName ClientAddress -NotePropertyValue $remote
        $parsed = Get-PathAndQuery $request.Target
        $path = $parsed.Path
        $stream = $request.Stream

        if ($path -eq '/healthz' -and $request.Method -eq 'GET') {
            Send-Json $stream 200 ([ordered]@{ ok = $true; service = 'portable-web-panel' })
            return
        }
        if ($path -eq '/' -and $request.Method -eq 'GET') {
            Send-Text $stream 200 (Get-WebPage) 'text/html; charset=utf-8'
            return
        }
        if ($path -eq '/api/login' -and $request.Method -eq 'POST') {
            if (-not (Test-PanelRequest $request)) { Send-Json $stream 403 @{ message = '缺少面板请求标记。' }; return }
            if (-not (Test-LoginRate $remote)) { Send-Json $stream 429 @{ message = '登录失败次数过多，请 60 秒后重试。' }; return }
            $body = Read-JsonBody $request
            $candidate = [string](Get-ConfigValue $body 'token' '')
            if (-not (Test-FixedToken $script:PanelToken $candidate)) {
                Record-FailedLogin $remote
                Write-WebLog "登录失败，来源=$remote"
                Send-Json $stream 401 @{ message = '令牌不正确。' }
                return
            }
            $sessionId = New-Session $remote
            [void]$script:FailedLogins.Remove($remote)
            Write-WebLog "登录成功，来源=$remote"
            $cookie = "portable_web_session=$sessionId; Max-Age=$([int]($script:SessionMinutes * 60)); HttpOnly; SameSite=Strict; Path=/"
            Send-Json $stream 200 @{ ok = $true } @{ 'Set-Cookie' = $cookie }
            return
        }
        if ($path -eq '/api/session' -and $request.Method -eq 'GET') {
            $session = Get-AuthenticatedSession $request
            Send-Json $stream 200 @{ authenticated = ($null -ne $session) }
            return
        }
        if ($path -eq '/api/logout' -and $request.Method -eq 'POST') {
            if (-not (Test-PanelRequest $request)) { Send-Json $stream 403 @{ message = '缺少面板请求标记。' }; return }
            $session = Get-AuthenticatedSession $request
            if ($session) { [void]$script:Sessions.Remove($session.Id) }
            Send-Json $stream 200 @{ ok = $true } @{ 'Set-Cookie' = 'portable_web_session=; Max-Age=0; HttpOnly; SameSite=Strict; Path=/' }
            return
        }

        $session = Get-AuthenticatedSession $request
        if ($path.StartsWith('/api/', [System.StringComparison]::OrdinalIgnoreCase) -and $null -eq $session) {
            Send-Json $stream 401 @{ message = '请先登录 Web 面板。' }
            return
        }
        if (-not $path.StartsWith('/api/', [System.StringComparison]::OrdinalIgnoreCase)) {
            Send-Text $stream 404 'Not Found'
            return
        }
        if ($request.Method -eq 'GET' -and $path -eq '/api/config') {
            Send-Json $stream 200 ([ordered]@{ bindAddress = $script:ListenAddressText; port = $script:ListenPort; allowConsoleCommands = $script:AllowConsoleCommands; sessionMinutes = $script:SessionMinutes })
            return
        }
        if ($request.Method -eq 'GET' -and $path -eq '/api/status') {
            Send-Json $stream 200 (Get-StatusData)
            return
        }
        if ($request.Method -eq 'GET' -and $path -eq '/api/logs') {
            $name = if ($parsed.Query.ContainsKey('name')) { [string]$parsed.Query['name'] } else { 'server' }
            $requestedLines = 120
            if ($parsed.Query.ContainsKey('lines')) { [void][int]::TryParse([string]$parsed.Query['lines'], [ref]$requestedLines) }
            Send-Json $stream 200 ([ordered]@{ name = $name; text = (Get-LogTail $name $requestedLines) })
            return
        }
        if ($request.Method -eq 'POST' -and $path -eq '/api/action') {
            if (-not (Test-PanelRequest $request)) { Send-Json $stream 403 @{ message = '缺少面板请求标记。' }; return }
            $body = Read-JsonBody $request
            $name = [string](Get-ConfigValue $body 'name' '')
            $confirm = [bool](Get-ConfigValue $body 'confirm' $false)
            $result = Invoke-PanelAction $name $confirm
            $status = if ($result.ok -eq $false) { 409 } else { 200 }
            Send-Json $stream $status $result
            return
        }
        if ($request.Method -eq 'POST' -and $path -eq '/api/quick') {
            if (-not (Test-PanelRequest $request)) { Send-Json $stream 403 @{ message = '缺少面板请求标记。' }; return }
            $body = Read-JsonBody $request
            $name = [string](Get-ConfigValue $body 'name' '')
            Send-Json $stream 200 (Invoke-QuickCommand $name)
            return
        }
        if ($request.Method -eq 'POST' -and $path -eq '/api/rcon') {
            if (-not (Test-PanelRequest $request)) { Send-Json $stream 403 @{ message = '缺少面板请求标记。' }; return }
            if (-not $script:AllowConsoleCommands) { Send-Json $stream 403 @{ message = '任意 RCON 控制台当前关闭，请在本机配置文件中显式开启。' }; return }
            $body = Read-JsonBody $request
            $command = [string](Get-ConfigValue $body 'command' '')
            $confirm = [bool](Get-ConfigValue $body 'confirm' $false)
            if ($command -match '(?i)^\s*(stop|restart|ban|pardon|op|deop|kick|whitelist|reload)\b' -and -not $confirm) {
                Send-Json $stream 409 @{ message = '该 RCON 命令需要二次确认。' }
                return
            }
            Send-Json $stream 200 ([ordered]@{ ok = $true; output = (Invoke-RconCommand $command) })
            return
        }
        Send-Json $stream 404 @{ message = 'API 不存在。' }
    } catch {
        $message = $_.Exception.Message
        Write-WebLog ("请求失败，来源={0}，错误={1}" -f $remote, $message)
        try { if ($request -and $request.Stream) { Send-Json $request.Stream 400 @{ message = $message } } } catch { }
    } finally {
        try { $Client.Close() } catch { }
    }
}

try {
    $script:Config = Read-PanelConfig
    $configBind = [string](Get-ConfigValue $script:Config 'bindAddress' '127.0.0.1')
    $configPort = 0
    [void][int]::TryParse(([string](Get-ConfigValue $script:Config 'port' 58080)), [ref]$configPort)
    if ([string]::IsNullOrWhiteSpace($BindAddress)) { $BindAddress = $configBind }
    if ($Port -le 0) { $Port = $configPort }
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Web 面板端口必须在 1024-65535 范围内。' }
    $listenIp = Resolve-ListenAddress $BindAddress
    $script:ListenAddressText = Format-ListenAddress $listenIp
    $script:ListenPort = $Port
    $script:AllowConsoleCommands = [bool](Get-ConfigValue $script:Config 'allowConsoleCommands' $false)
    $script:SessionMinutes = [Math]::Max(15, [int](Get-ConfigValue $script:Config 'sessionMinutes' 720))
    $script:MaxLogLines = [Math]::Max(20, [Math]::Min(1000, [int](Get-ConfigValue $script:Config 'maxLogLines' 200)))
    $script:PanelToken = Get-PanelToken
    Start-PerformanceSampling

    if ($ShowToken) {
        Write-Host "Web 面板令牌：$script:PanelToken" -ForegroundColor Green
        Write-Host "令牌文件：$TokenPath"
        exit 0
    }

    $oldPid = 0
    if (Test-Path -LiteralPath $PidPath -PathType Leaf) {
        [void][int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$oldPid)
        if ($oldPid -gt 0) {
            $oldProcess = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProcess) {
                $cmdline = ''
                try { $cmdline = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction Stop).CommandLine } catch { }
                if ($cmdline -match '(?i)portable-web-panel\.ps1') {
                    Write-Host "[Web] 面板已经在运行，PID=$oldPid。" -ForegroundColor Yellow
                    exit 0
                }
            }
        }
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    }

    $script:Listener = New-Object System.Net.Sockets.TcpListener($listenIp, $Port)
    try { $script:Listener.Start() } catch { throw "无法监听 $($script:ListenAddressText):$Port。端口可能已被占用，或 bindAddress 不属于本机网卡。`r`n$($_.Exception.Message)" }
    New-Item -ItemType Directory -Path (Split-Path -Parent $PidPath) -Force | Out-Null
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
    Write-WebLog ("Web 面板启动，监听 {0}:{1}" -f $script:ListenAddressText, $Port)

    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host '  便携服务端 Web 运维面板已启动' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host "本机访问：http://127.0.0.1:$Port/" -ForegroundColor Green
    Write-Host "监听地址：$($script:ListenAddressText):$Port"
    Write-Host "登录令牌：$script:PanelToken" -ForegroundColor Yellow
    Write-Host "令牌文件：$TokenPath"
    Write-Host ''
    Write-Host '安全建议：默认仅本机可访问；远程优先使用 SSH -L 或 VPN。' -ForegroundColor Yellow
    if ($listenIp.Equals([System.Net.IPAddress]::Any)) {
        Write-Host '警告：当前监听 0.0.0.0，路由器/防火墙放行后可能暴露到局域网或公网。' -ForegroundColor Red
    } elseif ($listenIp.Equals([System.Net.IPAddress]::IPv6Any)) {
        Write-Host '警告：当前监听 IPv6 ::，路由器/防火墙放行后可能暴露到局域网或公网。' -ForegroundColor Red
    }
    Write-Host '按 Ctrl+C 停止 Web 面板；也可运行 一键脚本\一键便携-停止Web控制面板.bat。'
    Write-Host ''

    while ($true) {
        $client = $null
        try {
            $client = $script:Listener.AcceptTcpClient()
            Handle-WebRequest $client
        } catch [System.Net.Sockets.SocketException] {
            if ($script:Listener -and -not $script:Listener.Server.IsBound) { break }
            Write-WebLog ('接收连接失败：' + $_.Exception.Message)
            try { if ($client) { $client.Close() } } catch { }
        } catch {
            Write-WebLog ('主循环异常：' + $_.Exception.Message)
            try { if ($client) { $client.Close() } } catch { }
        }
    }
} catch {
    Write-Host ('[Web] 启动失败：' + $_.Exception.Message) -ForegroundColor Red
    if (-not $NoPause) { Read-Host '按回车关闭窗口' | Out-Null }
    exit 1
} finally {
    Stop-PerformanceSampling
    try { if ($script:Listener) { $script:Listener.Stop() } } catch { }
    try {
        if (Test-Path -LiteralPath $PidPath -PathType Leaf) {
            $pidText = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ($pidText -eq [string]$PID) { Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
    if ($script:Listener) { Write-WebLog 'Web 面板停止。' }
}
