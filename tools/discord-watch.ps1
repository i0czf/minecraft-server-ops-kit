param(
    [string]$ConfigPath = ".\tools\ops-config.json"
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '通知监控 —— 服务端日志转 Discord/QQ 通知；关闭此窗口通知停发' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
New-Item -ItemType Directory -Force (Join-Path $Root "tmp") | Out-Null
try {
    $script:InstanceLockStream = [IO.File]::Open((Join-Path $Root "tmp\discord-watch.instance.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch {
    New-Item -ItemType Directory -Force (Join-Path $Root "logs") | Out-Null
    Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') another Discord monitor instance is already running; exiting") -Encoding UTF8
    return
}


function Resolve-RootPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Read-Config {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing config: $Path"
    }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

$script:LogEncodingCache = @{}
function Get-LogEncoding {
    param([string]$Path = '')
    # MC 日志编码取决于服务端 Java：17 及以下在中文 Windows 是 GBK，18+（JEP 400）是 UTF-8。
    # charset 留空或 auto 时按文件尾部字节严格试 UTF-8、失败回退 GBK（2026-07-07 实锤：写死 GBK 在 1.21.1/Java21 服上把聊天读成乱码）。
    # 纯 ASCII 内容用 UTF-8 读不会错（GBK 兼容 ASCII），出现中文字节后才缓存判定结果。
    $charset = [string]$script:Config.logWatch.charset
    if (-not [string]::IsNullOrWhiteSpace($charset) -and $charset -notmatch '^(?i)auto$') {
        try { return [Text.Encoding]::GetEncoding($charset) } catch { return [Text.Encoding]::UTF8 }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { return [Text.Encoding]::UTF8 }
    if ($script:LogEncodingCache.ContainsKey($Path)) { return $script:LogEncodingCache[$Path] }
    try {
        $probe = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $take = [int][Math]::Min(262144, $probe.Length)
            if ($probe.Length -gt $take) { [void]$probe.Seek(-$take, [System.IO.SeekOrigin]::End) }
            $buf = New-Object byte[] $take
            $read = $probe.Read($buf, 0, $take)
        } finally { $probe.Dispose() }
        $hasHighByte = $false
        for ($i = 0; $i -lt $read; $i++) { if ($buf[$i] -gt 0x7F) { $hasHighByte = $true; break } }
        if ($hasHighByte) {
            # 掐掉首尾可能被截断的多字节序列，避免边界误判
            $s = 0
            while ($s -lt $read -and (($buf[$s] -band 0xC0) -eq 0x80)) { $s++ }
            $e = $read
            $bt = 0
            while ($e -gt $s -and $bt -lt 4 -and (($buf[$e - 1] -band 0x80) -ne 0)) {
                $isLead = (($buf[$e - 1] -band 0xC0) -ne 0x80)
                $e--
                $bt++
                if ($isLead) { break }
            }
            $enc = $null
            try {
                $strict = New-Object System.Text.UTF8Encoding($false, $true)
                [void]$strict.GetString($buf, $s, ($e - $s))
                $enc = [Text.Encoding]::UTF8
            } catch {
                try { $enc = [Text.Encoding]::GetEncoding('GBK') } catch { $enc = [Text.Encoding]::UTF8 }
            }
            $script:LogEncodingCache[$Path] = $enc
            return $enc
        }
    } catch { }
    return [Text.Encoding]::UTF8
}

function New-WebProxyFromConfig {
    param($Config)
    if ($Config.discord.proxyHost -and [int]$Config.discord.proxyPort -gt 0) {
        return [Uri]("http://{0}:{1}" -f $Config.discord.proxyHost, [int]$Config.discord.proxyPort)
    }
    return $null
}

function Resolve-Java17 {
    # 扫目录而不是写死小版本号（Adoptium 升级一次就失配一次），取版本号最高的 jdk-17*
    $adoptium = 'C:\Program Files\Eclipse Adoptium'
    if (Test-Path -LiteralPath $adoptium -PathType Container) {
        $hit = Get-ChildItem -LiteralPath $adoptium -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\java.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($hit) { return $hit }
    }
    if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        return (Join-Path $env:JAVA_HOME "bin\java.exe")
    }
    return "java.exe"
}

function Invoke-DiscordWebhookViaSocks5 {
    param(
        [Parameter(Mandatory = $true)][string]$Webhook,
        [Parameter(Mandatory = $true)][string]$Payload,
        [Parameter(Mandatory = $true)][string]$ProxyHost,
        [Parameter(Mandatory = $true)][int]$ProxyPort
    )

    $payloadFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllBytes($payloadFile, [Text.Encoding]::UTF8.GetBytes($Payload))
        $java = Resolve-Java17
        $sender = Join-Path $Root "tools\DiscordWebhookSender.java"
        $output = & $java $sender $Webhook $ProxyHost $ProxyPort $payloadFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Out-String).Trim())
        }
    } finally {
        Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    }
}

function Send-Discord {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [switch]$Important
    )
    if (-not $script:Config.discord.enabled) { return }
    $webhook = [string]$script:Config.discord.webhookUrl
    if ([string]::IsNullOrWhiteSpace($webhook)) { return }

    if ($Important -and -not [string]::IsNullOrWhiteSpace($script:Config.discord.mentionOnCrash)) {
        $Content = "$($script:Config.discord.mentionOnCrash) $Content"
    }

    $payload = @{ content = $Content } | ConvertTo-Json -Depth 4 -Compress
    $proxyHost = [string]$script:Config.discord.proxyHost
    $proxyPort = [int]$script:Config.discord.proxyPort
    $proxyScheme = ([string]$script:Config.discord.proxyScheme).ToLowerInvariant()
    $useJavaProxySender = -not [string]::IsNullOrWhiteSpace($proxyHost) -and $proxyPort -gt 0

    if (-not $useJavaProxySender -and -not (Test-AndMarkDiscordMessage -Content $payload)) {
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Discord send skipped: 60 秒内重复消息。" -Encoding UTF8
        return
    }

    $params = @{
        Uri = $webhook
        Method = "Post"
        ContentType = "application/json; charset=utf-8"
        Body = $payload
        TimeoutSec = 12
    }
    $proxy = New-WebProxyFromConfig -Config $script:Config
    if ($proxy) { $params.Proxy = $proxy }

    try {
        if ($useJavaProxySender) {
            Invoke-DiscordWebhookViaSocks5 -Webhook $webhook -Payload $payload -ProxyHost $proxyHost -ProxyPort $proxyPort
            Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Discord send ok via proxy: ${proxyHost}:${proxyPort}" -Encoding UTF8
            return
        }
        Invoke-RestMethod @params | Out-Null
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Discord send ok." -Encoding UTF8
    } catch {
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Discord send failed: $($_.Exception.Message)"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    }
}
function Get-QQGroupIds {
    param($Raw)
    # groupId 兼容单个群号、逗号/分号分隔字符串和 JSON 数组，统一成可发送的数字字符串。
    $result = @()
    foreach ($value in @($Raw)) {
        if ($null -eq $value) { continue }
        foreach ($part in ([string]$value -split '[\s,;，；]+')) {
            $clean = $part.Trim()
            if ($clean -match '^\d{5,15}$' -and -not ($result -contains $clean)) {
                $result += $clean
            }
        }
    }
    return $result
}

function Send-QQGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [switch]$Important
    )
    if (-not $script:Config.qq.enabled) { return }
    $groupRaw = $script:Config.qq.groupId
    $groupIds = @(Get-QQGroupIds -Raw $groupRaw)
    if ($groupIds.Count -eq 0) { return }
    $onebotUrl = [string]$script:Config.qq.onebotUrl
    if ([string]::IsNullOrWhiteSpace($onebotUrl)) { $onebotUrl = "http://127.0.0.1:3001" }
    # OneBot 在本机回环接口上正常应在毫秒级返回；机器人异常时不要让一次通知
    # 把整个日志监控循环卡住原来的 8 秒。保留配置入口，默认收紧到 2 秒。
    $qqTimeout = 2
    $qqTimeoutProp = $script:Config.qq.PSObject.Properties["sendTimeoutSeconds"]
    if ($qqTimeoutProp) {
        $qqTimeoutValue = 0
        if ([int]::TryParse([string]$qqTimeoutProp.Value, [ref]$qqTimeoutValue) -and $qqTimeoutValue -ge 1) {
            $qqTimeout = [Math]::Min(8, $qqTimeoutValue)
        }
    }

    # QQ 群服务端重启通知精简：隐藏重启过程中的 [停服] / [启动] 中间态，
    # 保留 [重启] 和 [上线] 两个真正有用的节点；Discord 与本地日志不受影响。
    $compactRestartProp = $script:Config.qq.PSObject.Properties["compactRestartNotifications"]
    if ($compactRestartProp -and [bool]$compactRestartProp.Value -and $Content -match '^\[(?:停服|启动)\]') {
        return
    }

    # 事件过滤。配置里没写的事件键默认放行——此前缺键会被当成 false 静默丢弃，
    # 与 Discord 侧 Test-DiscordEventEnabled 的「缺键默认开」行为不一致（公开包用户容易踩）
    if ($script:Config.qq.events) {
        $ev = $script:Config.qq.events
        function Test-QQEventOn([string]$Name) {
            $prop = $ev.PSObject.Properties[$Name]
            if (-not $prop) { return $true }
            return [bool]$prop.Value
        }
        if ($Content -match '^\[加入\]' -and -not (Test-QQEventOn 'join')) { return }
        # 离开/连接失败 与 退出 同属 quit 开关（文案用「离开」，历史上也写过「退出」）
        if ($Content -match '^\[离开\]|^\[退出\]|^\[连接失败\]' -and -not (Test-QQEventOn 'quit')) { return }
        if ($Content -match '^\[聊天\]' -and -not (Test-QQEventOn 'chat')) { return }
        if ($Content -match '^\[死亡|^\[生物死亡|^\[求救' -and -not (Test-QQEventOn 'death')) { return }
        if ($Content -match '^\[进度|^\[目标|^\[挑战' -and -not (Test-QQEventOn 'advancement')) { return }
        if ($Content -match '^\[启动|^\[开服' -and -not (Test-QQEventOn 'startup')) { return }
        if ($Content -match '^\[停服|^\[重启' -and -not (Test-QQEventOn 'shutdown')) { return }
        if ($Content -match '^\[命令|^\[RCON' -and -not (Test-QQEventOn 'command')) { return }
        if ($Content -match '^\[备份\]' -and -not (Test-QQEventOn 'backup')) { return }
        if ($Content -match '^\[崩溃\]' -and -not (Test-QQEventOn 'crash')) { return }
        if ($Content -match '^\[公网IP\]|^\[DDNS\]' -and -not (Test-QQEventOn 'ip')) { return }
        if ($Content -match '^\[更新\]' -and -not (Test-QQEventOn 'update')) { return }
        if ($Content -match '^\[日志告警\]' -and -not (Test-QQEventOn 'logError')) { return }
    }

    # QQ 消息精简：去掉玩家连接端点、IP 归属地、断线原因等冗余信息。
    # Discord 保留完整判定供排查，QQ 群只保留必要的玩家名和在线摘要。
    if ($Content -match '^\[退出\]') {
        $Content = $Content -replace '(^\[退出\]\s+.+?离开了服务器。).*?(?=当前在线：|$)', '$1'
    } elseif ($Content -match '^\[连接失败\]') {
        # QQ 群的连接失败通知只保留玩家名；判定、在线摘要等细节不推到群里。
        if ($Content -match '^\[连接失败\]\s+(.+?)\s+未完成登录') {
            $failurePlayer = $matches[1]
            # 兼容旧格式：即使上游仍传入 GameProfile，也只提取 name 字段。
            if ($failurePlayer -match 'GameProfile@.+?name=([^,\]]+)') {
                $failurePlayer = $matches[1]
            }
            $Content = "[连接失败] $failurePlayer"
        }
    }
    # Java 日志会把玩家写成 "玩家名 (/IP:端口)"；QQ 群不展示该连接端点。
    # 只匹配带前导斜杠的括号段，避免误删 [公网IP] 等服务器地址通知。
    $Content = $Content -replace '\s+\(/\S+\)', ''
    $Content = $Content -replace '；IP：[^。]+', ''
    $Content = $Content -replace '；判定：[^。]+', ''
    # QQ 不渲染 Discord Markdown，去掉 **粗体** 和 `代码` 记号
    $Content = $Content -replace '\*\*', ''
    $Content = $Content -replace '`', ''

    if ($Content -match '^\[聊天\]') {
        if (-not (Test-ChatRelayEnabled)) { return }
        try {
            $rewritten = Convert-GameAtToCq -Text $Content
            if ($rewritten -and $rewritten -ne $Content) {
                $Content = $rewritten
                try {
                    Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
                        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') game-at rewritten to CQ"
                    ) -Encoding UTF8
                } catch {}
            }
        } catch { }
    }

    foreach ($groupId in $groupIds) {
        $body = @{
            group_id = [Int64]$groupId
            message  = $Content
        } | ConvertTo-Json -Depth 4 -Compress
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $bodyBytes = $utf8.GetBytes($body)

        # 首次调通时记一条调试日志
        if (-not $script:QQDebugLogged) {
            $script:QQDebugLogged = $true
            try {
                $dmsg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Send-QQGroup first call: groups=$($groupIds -join ',') url=$onebotUrl/send_group_msg body=$body"
                Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value $dmsg -Encoding UTF8
            } catch {}
        }

        try {
            $params = @{
                Uri         = "$onebotUrl/send_group_msg"
                Method      = "Post"
                ContentType = "application/json; charset=utf-8"
                Body        = $bodyBytes
                TimeoutSec  = $qqTimeout
            }
            $resp = Invoke-RestMethod @params
            if (-not $script:QQRespLogged) {
                $script:QQRespLogged = $true
                try {
                    $rmsg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Send-QQGroup response: group=$groupId $($resp | ConvertTo-Json -Depth 4 -Compress)"
                    Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value $rmsg -Encoding UTF8
                } catch {}
            }
            if ($null -ne $resp.retcode -and [int]$resp.retcode -ne 0) {
                throw "OneBot retcode=$($resp.retcode) status=$($resp.status)"
            }
        } catch {
            $now = Get-Date
            if (-not $script:LastQQErrorLogTime -or ($now - $script:LastQQErrorLogTime).TotalSeconds -ge 60) {
                $script:LastQQErrorLogTime = $now
                try {
                    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Send-QQGroup failed: group=$groupId $($_.Exception.Message)"
                    Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value $msg -Encoding UTF8
                } catch {}
            }
        }
    }
}


function Test-AndMarkDiscordMessage {
    param([Parameter(Mandatory = $true)][string]$Content)
    $tmpDir = Join-Path $Root "tmp"
    New-Item -ItemType Directory -Force $tmpDir | Out-Null
    $lockPath = Join-Path $tmpDir "discord-send-dedupe.lock"
    $statePath = Join-Path $tmpDir "discord-send-dedupe.tsv"
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
    } finally {
        $sha.Dispose()
    }

    $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $entries = @()
        if (Test-Path -LiteralPath $statePath) {
            foreach ($line in @(Get-Content -LiteralPath $statePath -ErrorAction SilentlyContinue)) {
                $parts = $line -split "`t", 2
                if ($parts.Count -ne 2) { continue }
                $ts = 0L
                if (-not [Int64]::TryParse($parts[0], [ref]$ts)) { continue }
                if (($now - $ts) -le 60) {
                    if ($parts[1] -eq $hash) { return $false }
                    $entries += "$ts`t$($parts[1])"
                }
            }
        }
        $entries += "$now`t$hash"
        Set-Content -LiteralPath $statePath -Value $entries -Encoding ASCII
        return $true
    } finally {
        $stream.Dispose()
    }
}
# 全文去重（$script:RecentMessages，10 分钟窗口）只对「可能双源重复」的消息生效。
# 依据：wrapper 日志与服务端日志会各自产出启动/停服/重启类消息，同一次事件可能被
# Watch-WrapperLogOnce 和 Watch-LogOnce 各报一次——这是去重表存在的唯一正当理由。
# 其余事件本就各有幂等机制：日志行由 $script:LogOffsets 按偏移量保证只处理一次，
# 崩溃/备份另有 SeenCrashes/SeenBackups 按文件去重，公网IP/DDNS 有自己的节流。
# 对它们做全文去重只会误吞真实事件——都是实锤过的：同一玩家退出后立刻重进（2026-07-31）、
# 群友复读同一句话、反复被同一只怪打死，文本逐字节相同即被静默丢弃。
function Test-NeedsFullTextDedupe {
    param([string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }
    foreach ($prefix in @('[启动]', '[上线]', '[开服]', '[启动失败]', '[停服]', '[重启]', '[监控]')) {
        if ($Content.StartsWith($prefix)) { return $true }
    }
    return $false
}

function Test-DiscordEventEnabled {
    param([string]$Name)
    if (-not $script:Config.discord.events) { return $true }
    $prop = $script:Config.discord.events.PSObject.Properties[$Name]
    if (-not $prop) { return $true }
    return [bool]$prop.Value
}

function Remove-MinecraftColor {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return (($Text -replace [char]0x00A7 + ".", "") -replace "\p{C}", "").Trim()
}

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, [Math]::Max(0, $Max - 3)) + "..."
}

function Test-ChatRelayEnabled {
    $now = Get-Date
    $path = Join-Path $Root 'logs\qq-chat-relay.json'
    if (-not $script:ChatRelayCheckedAt -or ($now - $script:ChatRelayCheckedAt).TotalSeconds -ge 5) {
        $script:ChatRelayCheckedAt = $now
        $script:ChatRelayEnabled = $true
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $obj = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $prop = $obj.PSObject.Properties['chatRelay']
                if ($prop -and $null -ne $prop.Value) {
                    $script:ChatRelayEnabled = [bool]$prop.Value
                }
            } catch {
                $script:ChatRelayEnabled = $true
            }
        }
    }
    return [bool]$script:ChatRelayEnabled
}

function Update-PlayerBindCache {
    $store = 'logs/qq-player-binds.json'
    try {
        if ($script:Config.qq.playerBind -and $script:Config.qq.playerBind.store) {
            $configured = [string]$script:Config.qq.playerBind.store
            if (-not [string]::IsNullOrWhiteSpace($configured)) { $store = $configured }
        }
    } catch { }
    $path = Resolve-RootPath $store
    $now = Get-Date
    $mtime = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $mtime = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    }
    $first = -not $script:PlayerBindLoadedAt
    $stale = $script:PlayerBindLoadedAt -and ($now - $script:PlayerBindLoadedAt).TotalSeconds -ge 30
    $changed = $mtime -and $script:PlayerBindMtime -and ($mtime -ne $script:PlayerBindMtime)
    if (-not ($first -or $stale -or $changed)) { return }
    $script:PlayerBindLoadedAt = $now
    $script:PlayerBindMtime = $mtime
    $map = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $obj = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($bind in @($obj.bindings)) {
                $name = [string]$bind.name
                $qq = [string]$bind.qq
                if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($qq)) { continue }
                if ($name -notmatch '^[A-Za-z0-9_]{1,16}$') { continue }
                $map[$name.ToLowerInvariant()] = $qq
            }
        } catch {
            $map = @{}
        }
    }
    $script:PlayerBindByName = $map
}

function Convert-GameAtToSegments {
    param([Parameter(Mandatory = $true)][string]$Text)
    Update-PlayerBindCache
    $segments = New-Object System.Collections.Generic.List[object]
    $hasAt = $false
    if ([string]::IsNullOrEmpty($Text)) {
        return [pscustomobject]@{
            HasAt    = $false
            Segments = @(@{ type = 'text'; data = @{ text = '' } })
        }
    }
    $regex = [regex]'(?<=^|[\s\[\(])@([A-Za-z0-9_]{1,16})(?![A-Za-z0-9_])'
    $last = 0
    foreach ($match in $regex.Matches($Text)) {
        if ($match.Index -gt $last) {
            $segments.Add(@{
                type = 'text'
                data = @{ text = $Text.Substring($last, $match.Index - $last) }
            })
        }
        $name = $match.Groups[1].Value
        $qq = $null
        if ($script:PlayerBindByName) {
            $qq = $script:PlayerBindByName[$name.ToLowerInvariant()]
        }
        if ($qq) {
            $segments.Add(@{
                type = 'at'
                data = @{ qq = [string]$qq }
            })
            $hasAt = $true
        } else {
            $segments.Add(@{
                type = 'text'
                data = @{ text = $match.Value }
            })
        }
        $last = $match.Index + $match.Length
    }
    if ($last -lt $Text.Length) {
        $segments.Add(@{
            type = 'text'
            data = @{ text = $Text.Substring($last) }
        })
    }
    if ($segments.Count -eq 0) {
        $segments.Add(@{
            type = 'text'
            data = @{ text = $Text }
        })
    }
    # 逗号运算符防止 PowerShell 把返回对象拆开。
    return ,([pscustomobject]@{
        HasAt    = $hasAt
        Segments = $segments.ToArray()
    })
}

function Convert-GameAtToCq {
    param([Parameter(Mandatory = $true)][string]$Text)
    $split = Convert-GameAtToSegments -Text $Text
    if ($split -is [System.Array]) {
        $split = @($split | Where-Object { $_ -and $_.PSObject.Properties['HasAt'] } | Select-Object -Last 1)[0]
    }
    if (-not $split -or -not $split.HasAt) { return $Text }
    $out = New-Object System.Text.StringBuilder
    foreach ($seg in @($split.Segments)) {
        if ($seg.type -eq 'at' -and $seg.data -and $seg.data.qq) {
            [void]$out.Append('[CQ:at,qq=').Append([string]$seg.data.qq).Append(']')
        } else {
            [void]$out.Append([string]$seg.data.text)
        }
    }
    $cq = $out.ToString()
    if ([string]::IsNullOrEmpty($cq)) { return $Text }
    return $cq
}

function Test-JoinIpEnabled {
    if (-not $script:Config.discord) { return $true }
    $prop = $script:Config.discord.PSObject.Properties["showJoinIp"]
    if (-not $prop) { return $true }
    return [bool]$prop.Value
}

function Test-JoinIpLocationEnabled {
    if (-not (Test-JoinIpEnabled)) { return $false }
    if (-not $script:Config.discord) { return $true }
    $prop = $script:Config.discord.PSObject.Properties["showJoinIpLocation"]
    if (-not $prop) { return $true }
    return [bool]$prop.Value
}

function Get-WrapperStartRegex {
    if ($script:Config.wrapperWatch) {
        $prop = $script:Config.wrapperWatch.PSObject.Properties["startRegex"]
        if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return [string]$prop.Value
        }
    }
    # TFCR 是旧周目 start.bat 写的措辞，保留纯为兼容历史 wrapper 日志——请勿删除，
    # 否则读到旧日志的启动行会漏报。现行看门狗写的是 PortableKit。
    return '(TFCR|PortableKit) server starting'
}

function Set-RecentLoginIp {
    param(
        [Parameter(Mandatory = $true)][string]$Player,
        [Parameter(Mandatory = $true)][string]$Ip
    )
    if ([string]::IsNullOrWhiteSpace($Player) -or [string]::IsNullOrWhiteSpace($Ip)) { return }
    $script:RecentLoginIps[$Player.ToLowerInvariant()] = [pscustomobject]@{
        Ip = $Ip.Trim("[]")
        Time = Get-Date
    }
}

function Get-RegisteredIpForPlayer {
    param([Parameter(Mandatory = $true)][string]$Player)
    $path = Join-Path $Root "config\ralp\ip-registrations.json"
    if (-not (Test-Path -LiteralPath $path)) { return "" }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $data.players) { return "" }
        foreach ($prop in $data.players.PSObject.Properties) {
            $record = $prop.Value
            if ($record.name -and $record.ip -and ([string]$record.name).Equals($Player, [StringComparison]::OrdinalIgnoreCase)) {
                return [string]$record.ip
            }
        }
    } catch {
        return ""
    }
    return ""
}

function Test-PublicIpAddress {
    param([Parameter(Mandatory = $true)][string]$Ip)
    $clean = $Ip.Trim().Trim("[]")
    if ([string]::IsNullOrWhiteSpace($clean)) { return $false }

    if ($clean -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $parts = @($clean.Split(".") | ForEach-Object { [int]$_ })
        if ($parts | Where-Object { $_ -lt 0 -or $_ -gt 255 }) { return $false }
        if ($parts[0] -eq 10) { return $false }
        if ($parts[0] -eq 127) { return $false }
        if ($parts[0] -eq 169 -and $parts[1] -eq 254) { return $false }
        if ($parts[0] -eq 172 -and $parts[1] -ge 16 -and $parts[1] -le 31) { return $false }
        if ($parts[0] -eq 192 -and $parts[1] -eq 168) { return $false }
        if ($parts[0] -eq 0) { return $false }
        return $true
    }

    if ($clean -match ':') {
        if ($clean -match '^(::1|fc|fd|fe80:)') { return $false }
        return $true
    }

    return $false
}

function Join-NonEmptyText {
    param([string[]]$Parts, [string]$Separator = " ")
    $items = @($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    return ($items -join $Separator).Trim()
}

function Format-IpLocationFromResponse {
    param($Data)
    if (-not $Data) { return "" }

    if ($Data.status -and ([string]$Data.status).ToLowerInvariant() -eq "fail") { return "" }

    $country = [string]$Data.country
    $region = [string]$Data.regionName
    if ([string]::IsNullOrWhiteSpace($region)) { $region = [string]$Data.region }
    if ([string]::IsNullOrWhiteSpace($region)) { $region = [string]$Data.province }
    $city = [string]$Data.city
    $district = [string]$Data.district
    $isp = [string]$Data.isp
    if ([string]::IsNullOrWhiteSpace($isp)) { $isp = [string]$Data.org }

    $place = Join-NonEmptyText -Parts @($country, $region, $city, $district)
    if ([string]::IsNullOrWhiteSpace($place)) { return "" }
    if (-not [string]::IsNullOrWhiteSpace($isp)) {
        return (Join-NonEmptyText -Parts @($place, $isp) -Separator "，")
    }
    return $place
}

function Get-JoinIpLocation {
    param([Parameter(Mandatory = $true)][string]$Ip)
    if (-not (Test-JoinIpLocationEnabled)) { return "" }

    $clean = $Ip.Trim().Trim("[]")
    if (-not (Test-PublicIpAddress -Ip $clean)) { return "" }

    if (-not $script:IpLocationCache) { $script:IpLocationCache = @{} }
    if ($script:IpLocationCache.ContainsKey($clean)) {
        $cached = $script:IpLocationCache[$clean]
        if ($cached.Time -and ((Get-Date) - $cached.Time).TotalHours -le 24) {
            return [string]$cached.Location
        }
    }

    $timeout = 5
    if ($script:Config.discord) {
        $timeoutProp = $script:Config.discord.PSObject.Properties["joinIpLocationTimeoutSeconds"]
        if ($timeoutProp -and [int]$timeoutProp.Value -gt 0) { $timeout = [int]$timeoutProp.Value }
    }

    $url = "http://ip-api.com/json/{0}?fields=status,message,country,regionName,city,district,isp,query&lang=zh-CN" -f [Uri]::EscapeDataString($clean)
    if ($script:Config.discord) {
        $endpointProp = $script:Config.discord.PSObject.Properties["joinIpLocationEndpoint"]
        if ($endpointProp -and -not [string]::IsNullOrWhiteSpace([string]$endpointProp.Value)) {
            $url = ([string]$endpointProp.Value).Replace("{ip}", [Uri]::EscapeDataString($clean))
        }
    }

    $params = @{
        Uri = $url
        Method = "Get"
        TimeoutSec = $timeout
    }
    $proxy = New-WebProxyFromConfig -Config $script:Config
    if ($proxy) { $params.Proxy = $proxy }

    try {
        $data = Invoke-RestMethod @params
        $location = Format-IpLocationFromResponse -Data $data
        $script:IpLocationCache[$clean] = [pscustomobject]@{
            Location = $location
            Time = Get-Date
        }
        return $location
    } catch {
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') IP location lookup skipped for ${clean}: $($_.Exception.Message)"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
        $script:IpLocationCache[$clean] = [pscustomobject]@{
            Location = ""
            Time = Get-Date
        }
        return ""
    }
}

function Get-JoinIpSuffix {
    param([Parameter(Mandatory = $true)][string]$Player)
    if (-not (Test-JoinIpEnabled)) { return "" }

    $key = $Player.ToLowerInvariant()
    $ip = ""
    if ($script:RecentLoginIps.ContainsKey($key)) {
        $entry = $script:RecentLoginIps[$key]
        if ($entry.Time -and ((Get-Date) - $entry.Time).TotalMinutes -le 10) {
            $ip = [string]$entry.Ip
        }
    }
    if ([string]::IsNullOrWhiteSpace($ip)) {
        $ip = Get-RegisteredIpForPlayer -Player $Player
    }
    if ([string]::IsNullOrWhiteSpace($ip)) { return "" }

    $location = ""
    if ($script:IpLocationCache -and $script:IpLocationCache.ContainsKey($ip.Trim().Trim("[]"))) {
        $cached = $script:IpLocationCache[$ip.Trim().Trim("[]")]
        if ($cached.Time -and ((Get-Date) - $cached.Time).TotalHours -le 24) {
            $location = [string]$cached.Location
        }
    }
    if ([string]::IsNullOrWhiteSpace($location)) {
        return "；IP：$ip"
    }
    return "；IP：$ip（$location）"
}

function Trim-RecentLoginIps {
    if (-not $script:RecentLoginIps) { return }
    $cutoff = (Get-Date).AddMinutes(-30)
    @($script:RecentLoginIps.Keys) | ForEach-Object {
        if ($script:RecentLoginIps[$_].Time -lt $cutoff) {
            $script:RecentLoginIps.Remove($_)
        }
    }

    if ($script:IpLocationCache) {
        $cacheCutoff = (Get-Date).AddHours(-24)
        @($script:IpLocationCache.Keys) | ForEach-Object {
            if ($script:IpLocationCache[$_].Time -lt $cacheCutoff) {
                $script:IpLocationCache.Remove($_)
            }
        }
    }
}
function ConvertFrom-LangJson {
    param([Parameter(Mandatory = $true)][string]$Json)

    # Windows PowerShell 5.1 的 ConvertFrom-Json 按不区分大小写的方式检查键名。
    # 一些汉化包同时含 minigolem / miniGolem 之类的合法 JSON 键；旧逻辑会因此
    # 把整份语言文件丢弃。JavaScriptSerializer 使用区分大小写的字典，可逐项保留。
    if (-not $script:LangJsonSerializer) {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $script:LangJsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $script:LangJsonSerializer.MaxJsonLength = [int]::MaxValue
        $script:LangJsonSerializer.RecursionLimit = 256
    }
    return $script:LangJsonSerializer.DeserializeObject($Json)
}

function Test-MinecraftAdvancementLangKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    return (
        $Key -match '(^|\.)(adv|advancements?|achievement)\.' -and
        $Key -notmatch '(?i)\.config\.'
    )
}

function Test-MinecraftAdvancementDescriptionKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    return (Test-MinecraftAdvancementLangKey -Key $Key) -and ($Key -match '(\.description|\.desc)$')
}

function Test-MinecraftAdvancementTitleKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    return (Test-MinecraftAdvancementLangKey -Key $Key) -and ($Key -notmatch '(\.description|\.desc)$')
}

function Get-MinecraftAdvancementKeyBase {
    param([Parameter(Mandatory = $true)][string]$Key)
    if ($Key -match '^(?s)(.+)\.(description|desc)$') { return [string]$Matches[1] }
    if ($Key -match '^(?s)(.+)\.title$') { return [string]$Matches[1] }
    return $Key
}

function Test-MinecraftNameTranslationKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    # 运行时会直接写入死亡消息的动态名称也要纳入：Goety 人名、女仆模型翻译键，
    # 以及 TaCZ 松散数据包里的枪械、弹药和配件名。
    return (
        $Key -match '^(entity|item|block|effect|enchantment|fluid)\.' -or
        $Key -match '^name\.[^.]+\.' -or
        $Key -match '^itemGroup\.[^.]+$' -or
        $Key -match '^mod\.[^.]+$' -or
        $Key -match '^model\.[^.]+\..+\.name$' -or
        $Key -match '^(?:tacz|fmic)\.(?:gun|ammo|attachment|block)\..+\.name$'
    )
}

function Import-LangJsonText {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)]$Target
    )
    try {
        $obj = ConvertFrom-LangJson -Json $Json
        $isDictionary = $obj -is [System.Collections.IDictionary]
        $properties = if ($isDictionary) { $obj.GetEnumerator() } else { $obj.PSObject.Properties }
        foreach ($prop in $properties) {
            $key = if ($isDictionary) { [string]$prop.Key } else { [string]$prop.Name }
            $value = [string]$prop.Value
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            # 成就键名不只有标准的 advancement(s).；部分模组（如拔刀剑）使用 adv.*。
            # 同时排除配置界面的 advancements.* 字段，避免把 UI 文案误当成成就标题。
            # 描述键（.description / .desc）也要收：QQ/Discord 通知会在进度名下展示具体内容。
            $isAdv = Test-MinecraftAdvancementLangKey -Key $key
            # 不限定键的段数：原版村民职业使用 entity.minecraft.villager.farmer 这类四段键。
            # name.* 是模组随机 Boss 的人名；itemGroup.* / mod.* 也常被用作成就根标题。
            $isName = Test-MinecraftNameTranslationKey -Key $key
            # title.* 既可能是 Boss 称号前缀，也可能是后缀；champion.mod.* 是精英怪修饰词。
            $isTitle = $key -match '^title\.[^.]+\.'
            $isModifier = $key -match '^champion\.mod\.'
            if ($isAdv -or $isName -or $isTitle -or $isModifier) {
                $Target[$key] = $value
            }
        }
    } catch {
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') lang load skipped: ${Source}: $($_.Exception.Message)"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    }
}

function Import-LangJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Target
    )
    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        Import-LangJsonText -Json $json -Source $Path -Target $Target
    } catch {
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') lang file load skipped: ${Path}: $($_.Exception.Message)"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    }
}

function Import-LangJson {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)]$Target
    )
    try {
        $stream = $Entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
            $json = $reader.ReadToEnd()
        } finally {
            $stream.Dispose()
        }
        Import-LangJsonText -Json $json -Source ("$($Archive.Name)!$($Entry.FullName)") -Target $Target
    } catch {
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') lang load skipped: $($Archive.Name)!$($Entry.FullName): $($_.Exception.Message)"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    }
}

function Get-AdvancementPackRoots {
    $result = @()
    $portableConfigPath = Join-Path $Root "tools\portable-pack.json"
    if (-not (Test-Path -LiteralPath $portableConfigPath -PathType Leaf)) { return $result }
    try {
        $portableConfig = Get-Content -LiteralPath $portableConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($rawBase in @([string]$portableConfig.sourceClient, [string]$portableConfig.publishDir)) {
            if ([string]::IsNullOrWhiteSpace($rawBase) -or $rawBase -match 'CHANGE-ME') { continue }
            $fullBase = if ([IO.Path]::IsPathRooted($rawBase)) {
                [IO.Path]::GetFullPath($rawBase)
            } else {
                [IO.Path]::GetFullPath((Join-Path $Root $rawBase))
            }
            if (Test-Path -LiteralPath $fullBase -PathType Container) { $result += $fullBase }
        }
    } catch {
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') portable config roots skipped: $($_.Exception.Message)"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    }
    return @($result | Sort-Object -Unique)
}

function Get-AdvancementLooseLanguageFiles {
    param([string[]]$PackRoots = @())

    # 不是所有资源都封装在 jar/zip 中。TaCZ 枪包、车万女仆模型包、KubeJS 和
    # OpenLoader 数据包常把语言文件直接放在目录里；旧扫描完全看不到这些名称。
    $roots = @(
        (Join-Path $Root 'kubejs'),
        (Join-Path $Root 'resourcepacks'),
        (Join-Path $Root 'datapacks'),
        (Join-Path $Root 'world\datapacks'),
        (Join-Path $Root 'moonlight-global-datapacks'),
        (Join-Path $Root 'config\openloader'),
        (Join-Path $Root 'config\global_packs'),
        (Join-Path $Root 'config\yes_steve_model'),
        (Join-Path $Root 'tacz'),
        (Join-Path $Root 'tlm_custom_pack')
    )
    foreach ($base in @($PackRoots)) {
        foreach ($relative in @('kubejs', 'resourcepacks', 'datapacks', 'config\openloader', 'config\global_packs', 'config\yes_steve_model', 'tacz', 'tlm_custom_pack')) {
            $roots += (Join-Path $base $relative)
        }
    }

    $files = @()
    foreach ($dir in @($roots | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $files += @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('en_us.json', 'zh_cn.json') })
    }
    return @($files | Sort-Object FullName -Unique)
}

function Get-AdvancementSourceSignature {
    # 汇总服务端、分发客户端、资源包、原版语言资产和人工覆盖文件的指纹。
    # 任一来源变化都热重建，避免客户端汉化包更新后仍沿用旧缓存。
    $sig = New-Object System.Text.StringBuilder
    $scanDirs = @(
        (Join-Path $Root "mods"),
        (Join-Path $Root "resourcepacks"),
        (Join-Path $Root "kubejs"),
        (Join-Path $Root "datapacks"),
        (Join-Path $Root "world\datapacks"),
        (Join-Path $Root "moonlight-global-datapacks"),
        (Join-Path $Root "config\openloader"),
        (Join-Path $Root "config\global_packs")
    )
    $packRoots = @(Get-AdvancementPackRoots)
    foreach ($base in $packRoots) {
        $scanDirs += (Join-Path $base "mods")
        $scanDirs += (Join-Path $base "resourcepacks")
        $scanDirs += (Join-Path $base "kubejs")
        $scanDirs += (Join-Path $base "datapacks")
        $scanDirs += (Join-Path $base "config\openloader")
        $scanDirs += (Join-Path $base "config\global_packs")
    }
    foreach ($p in @($scanDirs | Sort-Object -Unique)) {
        if (Test-Path -LiteralPath $p) {
            foreach ($fentry in @(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".jar", ".zip") } | Sort-Object FullName)) {
                [void]$sig.Append($fentry.FullName).Append('|').Append($fentry.Length).Append('|').Append($fentry.LastWriteTimeUtc.Ticks).Append(';')
            }
        }
    }

    foreach ($langFile in @(Get-AdvancementLooseLanguageFiles -PackRoots $packRoots)) {
        [void]$sig.Append($langFile.FullName).Append('|').Append($langFile.Length).Append('|').Append($langFile.LastWriteTimeUtc.Ticks).Append(';')
    }

    # 分发客户端实例根目录中的游戏 jar 提供原版 en_us；资产索引对象提供官方 zh_cn。
    foreach ($base in $packRoots) {
        foreach ($meta in @(Get-ChildItem -LiteralPath $base -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $gameJar = [IO.Path]::ChangeExtension($meta.FullName, '.jar')
            if (-not (Test-Path -LiteralPath $gameJar -PathType Leaf)) { continue }
            foreach ($sourceFile in @($meta.FullName, $gameJar)) {
                $fi = Get-Item -LiteralPath $sourceFile
                [void]$sig.Append($fi.FullName).Append('|').Append($fi.Length).Append('|').Append($fi.LastWriteTimeUtc.Ticks).Append(';')
            }
            try {
                $versionMeta = Get-Content -LiteralPath $meta.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $assetId = [string]$versionMeta.assetIndex.id
                $versionsDir = Split-Path -Parent $base
                if ([IO.Path]::GetFileName($versionsDir) -ne 'versions' -or [string]::IsNullOrWhiteSpace($assetId)) { continue }
                $minecraftRoot = Split-Path -Parent $versionsDir
                $indexPath = Join-Path $minecraftRoot ("assets\indexes\$assetId.json")
                if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { continue }
                $indexInfo = Get-Item -LiteralPath $indexPath
                [void]$sig.Append($indexInfo.FullName).Append('|').Append($indexInfo.Length).Append('|').Append($indexInfo.LastWriteTimeUtc.Ticks).Append(';')
                $assetIndex = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $zhProp = $assetIndex.objects.PSObject.Properties['minecraft/lang/zh_cn.json']
                if ($zhProp -and $zhProp.Value.hash) {
                    $hash = [string]$zhProp.Value.hash
                    $objectPath = Join-Path $minecraftRoot ("assets\objects\$($hash.Substring(0, 2))\$hash")
                    if (Test-Path -LiteralPath $objectPath -PathType Leaf) {
                        $objectInfo = Get-Item -LiteralPath $objectPath
                        [void]$sig.Append($objectInfo.FullName).Append('|').Append($objectInfo.Length).Append('|').Append($objectInfo.LastWriteTimeUtc.Ticks).Append(';')
                    }
                }
            } catch { }
        }
    }
    $ov = Join-Path $Root "tools\advancement-translations.json"
    if (Test-Path -LiteralPath $ov) {
        $oi = Get-Item -LiteralPath $ov
        [void]$sig.Append('OVERRIDE|').Append($oi.Length).Append('|').Append($oi.LastWriteTimeUtc.Ticks)
    }
    return $sig.ToString()
}

function Import-AdvancementOverrides {
    param(
        [Parameter(Mandatory = $true)]$Target,
        $EnglishSource,
        $ChineseSource
    )
    # 人工兜底：tools\advancement-translations.json，英文标题 → 中文，优先级最高（覆盖 jar 扫描与内置表）
    # 适用于「成就的中文只存在于客户端汉化包、服务端 jar 里没有 zh_cn」的 mod
    $path = Join-Path $Root "tools\advancement-translations.json"
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($json)) { return }
        $obj = $json | ConvertFrom-Json
        $n = 0
        foreach ($p in $obj.PSObject.Properties) {
            $k = [string]$p.Name
            $v = [string]$p.Value
            if ($k.StartsWith('_')) { continue }
            if (-not [string]::IsNullOrWhiteSpace($k) -and -not [string]::IsNullOrWhiteSpace($v)) {
                # 通知标题来自服务端日志，常带模组为对齐 UI 补上的尾部空格；
                # 兜底表统一按清理后的标题保存，避免「看起来相同」却查不到。
                $cleanKey = (Remove-MinecraftColor $k)
                $cleanValue = (Remove-MinecraftColor $v)
                # "Stone Age.desc" / advancements.xxx.description 记作成就内容，不覆盖标题表。
                if ((Test-MinecraftAdvancementDescriptionKey -Key $k) -or ($k -match '(\.description|\.desc)$')) {
                    if (-not $script:AdvancementDescriptions) { $script:AdvancementDescriptions = @{} }
                    $base = Get-MinecraftAdvancementKeyBase -Key $cleanKey
                    Register-AdvancementDescriptionAlias -Target $script:AdvancementDescriptions -Alias $base -Description $cleanValue
                    Register-AdvancementDescriptionAlias -Target $script:AdvancementDescriptions -Alias $cleanKey -Description $cleanValue
                    foreach ($sourceMap in @($EnglishSource, $ChineseSource)) {
                        if (-not $sourceMap) { continue }
                        foreach ($lookupKey in @($k, $base, ($base + '.title'))) {
                            if ($sourceMap.ContainsKey($lookupKey)) {
                                $alias = Remove-MinecraftColor ([string]$sourceMap[$lookupKey])
                                if (-not [string]::IsNullOrWhiteSpace($alias)) {
                                    Register-AdvancementDescriptionAlias -Target $script:AdvancementDescriptions -Alias $alias -Description $cleanValue
                                }
                            }
                        }
                    }
                    $n++
                    continue
                }
                $Target[$cleanKey] = $cleanValue
                # 人工兜底同样适用于实体/物品名（死亡通知里的凶手/武器英文名可写进同一文件）
                if ($null -ne $script:NameTranslations) { $script:NameTranslations[$cleanKey] = $cleanValue }

                # 覆盖文件优先按翻译键维护；自动派生该键在 en_us / zh_cn 中的显示文本别名。
                # 这样既能接住英文服务端日志，也能接住切换语言后可能出现的日文或残留英文，
                # 不必为同一成就手工维护三份重复条目。
                foreach ($sourceMap in @($EnglishSource, $ChineseSource)) {
                    if ($sourceMap -and $sourceMap.ContainsKey($k)) {
                        $alias = Remove-MinecraftColor ([string]$sourceMap[$k])
                        if (-not [string]::IsNullOrWhiteSpace($alias)) {
                            $Target[$alias] = $cleanValue
                            if ($null -ne $script:NameTranslations) { $script:NameTranslations[$alias] = $cleanValue }
                        }
                    }
                }
                $n++
            }
        }
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') loaded $n advancement title overrides from tools\advancement-translations.json"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    } catch {
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') advancement overrides skipped: $($_.Exception.Message)"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    }
}

function Initialize-AdvancementTranslations {
    # 首次构建；之后每 60 秒最多校验一次来源指纹，mods 变了就热重建（新增 mod 免重启监控即可翻译）
    $now = Get-Date
    if ($script:AdvancementTranslationsReady) {
        if ($script:AdvancementSignatureCheckedAt -and ($now - $script:AdvancementSignatureCheckedAt).TotalSeconds -lt 60) {
            return
        }
        $script:AdvancementSignatureCheckedAt = $now
        try {
            $sig = Get-AdvancementSourceSignature
        } catch {
            return
        }
        if ($sig -eq $script:AdvancementSignature) { return }
        $script:AdvancementSignature = $sig
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') advancement sources changed; rebuilding translation table"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    } else {
        $script:AdvancementSignatureCheckedAt = $now
        try { $script:AdvancementSignature = Get-AdvancementSourceSignature } catch { $script:AdvancementSignature = $null }
    }
    $script:AdvancementTranslationsReady = $true
    $script:AdvancementTranslations = @{}
    $script:AdvancementDescriptions = @{}
    $script:NameTranslations = @{}
    $script:TitleTranslations = @{}
    $script:ModifierTranslations = @{}

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $english = @{}
    $chinese = @{}
    $archives = @()
    $scanDirs = New-Object System.Collections.Generic.List[string]
    foreach ($dir in @("mods", "resourcepacks", ".fabric\processedMods", "versions", "kubejs", "datapacks", "world\datapacks", "moonlight-global-datapacks", "config\openloader", "config\global_packs")) { $scanDirs.Add($dir) }
    $packRoots = @(Get-AdvancementPackRoots)
    foreach ($base in $packRoots) {
        $scanDirs.Add((Join-Path $base "mods"))
        $scanDirs.Add((Join-Path $base "resourcepacks"))
        $scanDirs.Add((Join-Path $base "kubejs"))
        $scanDirs.Add((Join-Path $base "datapacks"))
        $scanDirs.Add((Join-Path $base "config\openloader"))
        $scanDirs.Add((Join-Path $base "config\global_packs"))

        # 启动器实例根目录的同名 jar 是原版/NeoForge 游戏 jar，内含完整 en_us。
        # 同名版本 JSON 指向 assets/indexes，再由哈希找到官方 zh_cn 资产对象。
        foreach ($meta in @(Get-ChildItem -LiteralPath $base -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $gameJar = [IO.Path]::ChangeExtension($meta.FullName, '.jar')
            if (-not (Test-Path -LiteralPath $gameJar -PathType Leaf)) { continue }
            $archives += @(Get-Item -LiteralPath $gameJar)
            try {
                $versionMeta = Get-Content -LiteralPath $meta.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $assetId = [string]$versionMeta.assetIndex.id
                $versionsDir = Split-Path -Parent $base
                if ([IO.Path]::GetFileName($versionsDir) -ne 'versions' -or [string]::IsNullOrWhiteSpace($assetId)) { continue }
                $minecraftRoot = Split-Path -Parent $versionsDir
                $indexPath = Join-Path $minecraftRoot ("assets\indexes\$assetId.json")
                if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { continue }
                $assetIndex = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($langInfo in @(
                    @{ Key = 'minecraft/lang/en_us.json'; Target = $english },
                    @{ Key = 'minecraft/lang/zh_cn.json'; Target = $chinese }
                )) {
                    $assetProp = $assetIndex.objects.PSObject.Properties[$langInfo.Key]
                    if (-not $assetProp -or -not $assetProp.Value.hash) { continue }
                    $hash = [string]$assetProp.Value.hash
                    $objectPath = Join-Path $minecraftRoot ("assets\objects\$($hash.Substring(0, 2))\$hash")
                    if (Test-Path -LiteralPath $objectPath -PathType Leaf) {
                        Import-LangJsonFile -Path $objectPath -Target $langInfo.Target
                    }
                }
            } catch {
                $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') vanilla client language scan skipped: $($meta.FullName): $($_.Exception.Message)"
                Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
            }
        }
    }
    foreach ($dir in @($scanDirs | Sort-Object -Unique)) {
        $scanPath = if ([IO.Path]::IsPathRooted($dir)) { $dir } else { Join-Path $Root $dir }
        if (Test-Path -LiteralPath $scanPath) {
            $archives += @(Get-ChildItem -LiteralPath $scanPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".jar", ".zip") })
        }
    }
    foreach ($archivePath in @($archives | Sort-Object FullName -Unique)) {
        $zip = $null
        try {
            $zip = [IO.Compression.ZipFile]::OpenRead($archivePath.FullName)
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName.Replace('\', '/')
                if ($name -match '/lang/en_us\.json$') {
                    Import-LangJson -Entry $entry -Archive $archivePath -Target $english
                } elseif ($name -match '/lang/zh_cn\.json$') {
                    Import-LangJson -Entry $entry -Archive $archivePath -Target $chinese
                }
            }
        } catch {
            $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') lang archive skipped: $($archivePath.FullName): $($_.Exception.Message)"
            Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
        } finally {
            if ($zip) { $zip.Dispose() }
        }
    }

    # 扫描未压缩资源包/数据包中的语言文件（例如 tlm_custom_pack、tacz）。
    foreach ($langFile in @(Get-AdvancementLooseLanguageFiles -PackRoots $packRoots)) {
        if ($langFile.Name -eq 'en_us.json') {
            Import-LangJsonFile -Path $langFile.FullName -Target $english
        } elseif ($langFile.Name -eq 'zh_cn.json') {
            Import-LangJsonFile -Path $langFile.FullName -Target $chinese
        }
    }

    Add-BuiltinAdvancementTranslations -Target $script:AdvancementTranslations

    # 先登记中文资源包里存在、但服务端 jar 没有 en_us 对应项的翻译键。
    # 这类情况下日志可能直接打印 advancements.xxx / itemGroup.xxx，不能等英文表配对。
    foreach ($key in $chinese.Keys) {
        $value = ([string]$chinese[$key]).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if (Test-MinecraftAdvancementTitleKey -Key $key) {
            $script:AdvancementTranslations[$key] = $value
        } elseif (Test-MinecraftNameTranslationKey -Key $key) {
            $script:NameTranslations[$key] = $value
        } elseif ($key -match '^champion\.mod\.') {
            $script:ModifierTranslations[$key] = $value
        }
    }

    foreach ($key in $english.Keys) {
        if (-not $chinese.ContainsKey($key)) { continue }
        $rawEnglish = [string]$english[$key]
        $rawChinese = [string]$chinese[$key]
        if ([string]::IsNullOrWhiteSpace($rawEnglish) -or [string]::IsNullOrWhiteSpace($rawChinese)) { continue }
        if ($rawEnglish -eq $rawChinese) { continue }

        if (Test-MinecraftNameTranslationKey -Key $key) {
            # 成就根节点经常直接复用物品名（例如拔刀剑的刀名），
            # 因此既按显示名映射，也按原始翻译键映射。
            $englishName = $rawEnglish.Trim()
            $chineseName = $rawChinese.Trim()
            $script:NameTranslations[$key] = $chineseName
            $script:NameTranslations[$englishName] = $chineseName
        } elseif ($key -match '^title\.') {
            # Boss 随机称号可能是前缀或后缀；保留原始空格，由组合翻译逻辑处理。
            $script:TitleTranslations[$rawEnglish] = $rawChinese
        } elseif ($key -match '^champion\.mod\.') {
            $englishModifier = $rawEnglish.Trim()
            $chineseModifier = $rawChinese.Trim()
            $script:ModifierTranslations[$key] = $chineseModifier
            $script:ModifierTranslations[$englishModifier] = $chineseModifier
        } elseif (Test-MinecraftAdvancementDescriptionKey -Key $key) {
            # 描述键留给 Import-AdvancementDescriptions，不要当成成就标题。
            continue
        } else {
            # 同时登记「显示文本」和「翻译键」：前者覆盖正常英文日志，
            # 后者覆盖服务端缺少 en_us 时直接把 advancements.xxx 打进日志的模组。
            $englishTitle = $rawEnglish.Trim()
            $chineseTitle = $rawChinese.Trim()
            $script:AdvancementTranslations[$key] = $chineseTitle
            $script:AdvancementTranslations[$englishTitle] = $chineseTitle
        }
    }

    Import-AdvancementDescriptions -Target $script:AdvancementDescriptions -EnglishSource $english -ChineseSource $chinese
    Import-AdvancementOverrides -Target $script:AdvancementTranslations -EnglishSource $english -ChineseSource $chinese

    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') loaded $($script:AdvancementTranslations.Count) advancement title translations, $($script:AdvancementDescriptions.Count) advancement descriptions, $($script:NameTranslations.Count) entity/item/name translations, $($script:TitleTranslations.Count) boss titles, $($script:ModifierTranslations.Count) champion modifiers"
    Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
}

function Add-BuiltinAdvancementTranslations {
    param([Parameter(Mandatory = $true)]$Target)
    $builtin = @{
        "Minecraft" = "Minecraft"
        "Stone Age" = "石器时代"
        "Getting an Upgrade" = "获得升级"
        "Acquire Hardware" = "来硬的"
        "Suit Up" = "整装上阵"
        "Hot Stuff" = "热腾腾的东西"
        "Isn't It Iron Pick" = "这不是铁镐么"
        "Not Today, Thank You" = "今天不行，谢谢"
        "Ice Bucket Challenge" = "冰桶挑战"
        "Diamonds!" = "钻石！"
        "We Need to Go Deeper" = "我们需要再深入些"
        "Cover Me With Diamonds" = "用钻石包裹我"
        "Enchanter" = "附魔师"
        "Zombie Doctor" = "僵尸科医生"
        "Eye Spy" = "隔墙有眼"
        "The End?" = "结束了？"
        "Nether" = "下界"
        "Return to Sender" = "见鬼去吧"
        "Those Were the Days" = "那些年的日子"
        "Hidden in the Depths" = "深藏不露"
        "Subspace Bubble" = "子空间泡泡"
        "A Terrible Fortress" = "阴森的要塞"
        "Who is Cutting Onions?" = "谁在切洋葱？"
        "Oh Shiny" = "哦，闪亮亮！"
        "This Boat Has Legs" = "这船有腿"
        "Uneasy Alliance" = "不稳定的同盟"
        "War Pigs" = "战猪"
        "Country Lode, Take Me Home" = "脉络带我回家"
        "Cover Me in Debris" = "残骸裹身"
        "Spooky Scary Skeleton" = "诡异又可怕的骷髅"
        "Into Fire" = "与火共舞"
        "Not Quite `"Nine`" Lives" = "还没到九条命"
        "Hot Tourist Destinations" = "热门景点"
        "Withering Heights" = "凋零山庄"
        "Local Brewery" = "本地的酿造厂"
        "Bring Home the Beacon" = "带信标回家"
        "A Furious Cocktail" = "狂乱的鸡尾酒"
        "Beaconator" = "信标工程师"
        "How Did We Get Here?" = "为什么会变成这样呢？"
        "The End" = "末地"
        "Free the End" = "解放末地"
        "The Next Generation" = "下一世代"
        "Remote Getaway" = "远程折跃"
        "The End... Again..." = "结束了……再一次……"
        "You Need a Mint" = "你需要来点薄荷"
        "The City at the End of the Game" = "游戏尽头的城市"
        "Sky's the Limit" = "天空即为极限"
        "Great View From Up Here" = "这上面的风景真不错"
        "Adventure" = "冒险"
        "Voluntary Exile" = "自我放逐"
        "Is It a Bird?" = "那是鸟吗？"
        "Monster Hunter" = "怪物猎人"
        "What a Deal!" = "这交易不错！"
        "Sticky Situation" = "胶着状态"
        "Ol' Betsy" = "老贝琪"
        "Sweet Dreams" = "甜蜜的梦"
        "Hero of the Village" = "村庄英雄"
        "Is It a Balloon?" = "那是气球吗？"
        "A Throwaway Joke" = "轻飘飘的笑话"
        "Take Aim" = "瞄准目标"
        "Monsters Hunted" = "怪物狩猎完成"
        "Postmortal" = "超越生死"
        "Hired Help" = "招兵买马"
        "Star Trader" = "星际商人"
        "Two Birds, One Arrow" = "一箭双雕"
        "Who's the Pillager Now?" = "现在谁才是掠夺者？"
        "Arbalistic" = "劲弩手"
        "Adventuring Time" = "探索的时光"
        "Sound of Music" = "音乐之声"
        "Light as a Rabbit" = "轻盈如兔"
        "Is It a Plane?" = "那是飞机吗？"
        "Very Very Frightening" = "非常非常可怕"
        "Sniper Duel" = "狙击手的对决"
        "Bullseye" = "正中靶心"
        "Husbandry" = "农牧业"
        "Bee Our Guest" = "宾至如归"
        "The Parrots and the Bats" = "鹦鹉和蝙蝠"
        "Best Friends Forever" = "永远的好朋友"
        "Fishy Business" = "腥味十足的生意"
        "Total Beelocation" = "举巢搬迁"
        "A Seedy Place" = "播种之地"
        "Two by Two" = "成双成对"
        "A Complete Catalogue" = "完整的目录"
        "Tactical Fishing" = "战术性钓鱼"
        "A Balanced Diet" = "均衡饮食"
        "Serious Dedication" = "终极奉献"
        "Bukkit Bukkit" = "桶桶桶桶"
        "Wax On" = "涂蜡"
        "Wax Off" = "脱蜡"
        "The Cutest Predator" = "最萌捕食者"
        "The Healing Power of Friendship!" = "友谊的治愈力！"
        "Glow and Behold!" = "眼前一亮！"
        "Whatever Floats Your Goat!" = "羊帆起航！"
        "Birthday Song" = "生日歌"
        "You've Got a Friend in Me" = "你有我这个朋友"
        "With Our Powers Combined!" = "我们聚力同行！"
        "Planting the Past" = "种下过去"
        "Careful Restoration" = "小心修复"
        "Crafting a New Look" = "打造新外观"
        "Smithing with Style" = "锻造有型"
        "The Power of Books" = "书籍的力量"
        # 1.21.1 新增/补漏的原版成就
        "It Spreads" = "它在蔓延"
        "Minecraft: Trial(s) Edition" = "Minecraft：试炼版"
        "Sneak 100" = "潜行 100"
        "Surge Protector" = "避雷针"
        "Under Lock and Key" = "珍藏密敛"
        "Revaulting" = "宝经磨炼"
        "Lighten Up" = "铜光焕发"
        "Over-Overkill" = "天赐良击"
        "Who Needs Rockets?" = "还要啥火箭啊？"
        "Crafters Crafting Crafters" = "合成器合成合成器"
    }
    foreach ($entry in $builtin.GetEnumerator()) {
        if (-not $Target.ContainsKey($entry.Key)) {
            $Target[$entry.Key] = $entry.Value
        }
    }
}

function Format-AdvancementNotificationTitle {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    # 许多模组为了在成就界面对齐而写入连续空格；QQ 单行通知不需要这种排版。
    return ((Remove-MinecraftColor $Text) -replace '[ \t]{2,}', ' ').Trim()
}

function Format-AdvancementDescriptionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $clean = Remove-MinecraftColor $Text
    # 语言文件里的 %s / %1$s 是物品名或按键占位；群通知没有运行时参数。
    $clean = $clean -replace '%(?:\d+\$)?[a-zA-Z]', '…'
    $clean = ($clean -replace '[\r\n]+', '；' -replace '[ \t]{2,}', ' ').Trim().Trim('；')
    if ([string]::IsNullOrWhiteSpace($clean)) { return "" }
    return (Limit-Text $clean 160)
}

function Register-AdvancementDescriptionAlias {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [string]$Alias,
        [string]$Description
    )
    $desc = Format-AdvancementDescriptionText $Description
    if ([string]::IsNullOrWhiteSpace($desc)) { return }
    $raw = Remove-MinecraftColor $Alias
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $pretty = Format-AdvancementNotificationTitle $raw
    if ($pretty -eq $desc) { return }
    $Target[$raw] = $desc
    if ($pretty -and $pretty -ne $raw) { $Target[$pretty] = $desc }
}

function Import-AdvancementDescriptions {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)]$EnglishSource,
        [Parameter(Mandatory = $true)]$ChineseSource
    )
    $descKeys = @{}
    foreach ($source in @($EnglishSource, $ChineseSource)) {
        foreach ($key in @($source.Keys)) {
            if (Test-MinecraftAdvancementDescriptionKey -Key $key) {
                $descKeys[$key] = $true
            }
        }
    }
    foreach ($descKey in @($descKeys.Keys)) {
        $desc = $null
        if ($ChineseSource.ContainsKey($descKey) -and -not [string]::IsNullOrWhiteSpace([string]$ChineseSource[$descKey])) {
            $desc = [string]$ChineseSource[$descKey]
        } elseif ($EnglishSource.ContainsKey($descKey)) {
            $desc = [string]$EnglishSource[$descKey]
        }
        if ([string]::IsNullOrWhiteSpace($desc)) { continue }

        $base = Get-MinecraftAdvancementKeyBase -Key $descKey
        Register-AdvancementDescriptionAlias -Target $Target -Alias $descKey -Description $desc
        Register-AdvancementDescriptionAlias -Target $Target -Alias $base -Description $desc
        Register-AdvancementDescriptionAlias -Target $Target -Alias ($base + '.title') -Description $desc
        foreach ($titleKey in @($base, ($base + '.title'))) {
            foreach ($source in @($ChineseSource, $EnglishSource)) {
                if ($source.ContainsKey($titleKey) -and -not [string]::IsNullOrWhiteSpace([string]$source[$titleKey])) {
                    Register-AdvancementDescriptionAlias -Target $Target -Alias ([string]$source[$titleKey]) -Description $desc
                }
            }
        }
    }
}

function Resolve-AdvancementDescription {
    param([string]$RawTitle, [string]$TranslatedTitle)
    if (-not $script:AdvancementDescriptions) { return "" }
    $seen = @{}
    foreach ($candidate in @(
        $RawTitle,
        (Remove-MinecraftColor $RawTitle),
        (Format-AdvancementNotificationTitle $RawTitle),
        $TranslatedTitle,
        (Format-AdvancementNotificationTitle $TranslatedTitle)
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($seen.ContainsKey($candidate)) { continue }
        $seen[$candidate] = $true
        if ($script:AdvancementDescriptions.ContainsKey($candidate)) {
            $desc = [string]$script:AdvancementDescriptions[$candidate]
            $prettyTitle = Format-AdvancementNotificationTitle $TranslatedTitle
            if (-not [string]::IsNullOrWhiteSpace($desc) -and $desc -ne $candidate -and $desc -ne $prettyTitle) {
                return $desc
            }
        }
    }
    return ""
}

function Format-AdvancementEvent {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('progress', 'goal', 'challenge')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Player,
        [Parameter(Mandatory = $true)][string]$RawTitle
    )
    $title = Translate-AdvancementTitle $RawTitle
    $desc = Resolve-AdvancementDescription -RawTitle $RawTitle -TranslatedTitle $title
    switch ($Kind) {
        'goal' { $head = "[目标] $Player 达成目标：$title" }
        'challenge' { $head = "[挑战] $Player 完成挑战：$title" }
        default { $head = "[进度] $Player 达成进度：$title" }
    }
    if ([string]::IsNullOrWhiteSpace($desc)) { return $head }
    return "$head`n$desc"
}

function Translate-AdvancementTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $Title }
    # 服务端日志里的拔刀剑标题会带格式填充空格；先去颜色码、控制字符并 Trim。
    $clean = Remove-MinecraftColor $Title
    if ([string]::IsNullOrWhiteSpace($clean)) { return $clean }
    Initialize-AdvancementTranslations
    if ($script:AdvancementTranslations.ContainsKey($clean)) {
        return (Format-AdvancementNotificationTitle $script:AdvancementTranslations[$clean])
    }
    # 一些模组的成就根节点直接使用 item.* 的显示名；沿用死亡通知的物品名翻译表。
    if ($script:NameTranslations -and $script:NameTranslations.ContainsKey($clean)) {
        return (Format-AdvancementNotificationTitle $script:NameTranslations[$clean])
    }
    # 未翻译标题不再静默漏出：同一标题每次监控进程只记一次，便于新增模组后继续补齐。
    # 纯数字、符号不算漏译；中英混排标题只要仍含拉丁字母或日文假名就进入审计日志。
    if ($clean -match '[A-Za-z\u3040-\u30ff\u31f0-\u31ff]') {
        if (-not $script:AdvancementTranslationMisses) { $script:AdvancementTranslationMisses = @{} }
        if (-not $script:AdvancementTranslationMisses.ContainsKey($clean)) {
            $script:AdvancementTranslationMisses[$clean] = $true
            Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value (
                "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') untranslated advancement title: $(Limit-Text $clean 240)"
            ) -Encoding UTF8
        }
    }
    return (Format-AdvancementNotificationTitle $clean)
}
function Translate-MinecraftName {
    param([string]$Name, [int]$Depth = 0)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
    $clean = (Remove-MinecraftColor $Name).Trim()
    if ($Depth -gt 6) { return $clean }
    $map = @{
        "Arrow" = "箭"; "Bee" = "蜜蜂"; "Blaze" = "烈焰人"; "Cave Spider" = "洞穴蜘蛛"; "Creeper" = "苦力怕"; "Drowned" = "溺尸"; "Elder Guardian" = "远古守卫者"; "Ender Dragon" = "末影龙"; "Enderman" = "末影人"; "Endermite" = "末影螨"; "Evoker" = "唤魔者"; "Falling Block" = "下落的方块"; "Fireball" = "火球"; "Ghast" = "恶魂"; "Guardian" = "守卫者"; "Husk" = "尸壳"; "Iron Golem" = "铁傀儡"; "Magma Cube" = "岩浆怪"; "Phantom" = "幻翼"; "Piglin" = "猪灵"; "Piglin Brute" = "猪灵蛮兵"; "Pillager" = "掠夺者"; "Ravager" = "劫掠兽"; "Shulker" = "潜影贝"; "Shulker Bullet" = "潜影贝导弹"; "Silverfish" = "蠹虫"; "Skeleton" = "骷髅"; "Slime" = "史莱姆"; "Small Fireball" = "小火球"; "Spider" = "蜘蛛"; "Stray" = "流浪者"; "Trident" = "三叉戟"; "Vex" = "恼鬼"; "Vindicator" = "卫道士"; "Warden" = "监守者"; "Witch" = "女巫"; "Wither" = "凋灵"; "Wither Skeleton" = "凋灵骷髅"; "Wither Skull" = "凋灵之首"; "Wolf" = "狼"; "Zoglin" = "僵尸疣猪兽"; "Zombie" = "僵尸"; "Zombie Villager" = "僵尸村民"; "Zombified Piglin" = "僵尸猪灵";
        "Allay" = "悦灵"; "Axolotl" = "美西螈"; "Bat" = "蝙蝠"; "Bogged" = "沼泽骷髅"; "Breeze" = "旋风人"; "Camel" = "骆驼"; "Cat" = "猫"; "Chicken" = "鸡"; "Cod" = "鳕鱼"; "Cow" = "牛"; "Dolphin" = "海豚"; "Donkey" = "驴"; "Fox" = "狐狸"; "Frog" = "青蛙"; "Giant" = "巨人"; "Glow Squid" = "发光鱿鱼"; "Goat" = "山羊"; "Hoglin" = "疣猪兽"; "Horse" = "马"; "Illusioner" = "幻术师"; "Lightning Bolt" = "闪电"; "Llama" = "羊驼"; "Mooshroom" = "哞菇"; "Mule" = "骡"; "Ocelot" = "豹猫"; "Panda" = "熊猫"; "Parrot" = "鹦鹉"; "Pig" = "猪"; "Polar Bear" = "北极熊"; "Pufferfish" = "河豚"; "Rabbit" = "兔子"; "Salmon" = "鲑鱼"; "Sheep" = "绵羊"; "Skeleton Horse" = "骷髅马"; "Sniffer" = "嗅探兽"; "Snow Golem" = "雪傀儡"; "Squid" = "鱿鱼"; "Strider" = "炽足兽"; "Tadpole" = "蝌蚪"; "The Killer Bunny" = "杀手兔"; "Trader Llama" = "行商羊驼"; "Tropical Fish" = "热带鱼"; "Turtle" = "海龟"; "Villager" = "村民"; "Wandering Trader" = "流浪商人"; "Zombie Horse" = "僵尸马"
    }
    if ($map.ContainsKey($clean)) { return $map[$clean] }
    # 模组生物/物品名：查 jar 语言文件派生的 entity./item. 翻译表（含人工兜底覆盖）
    Initialize-AdvancementTranslations
    if ($script:NameTranslations -and $script:NameTranslations.ContainsKey($clean)) { return $script:NameTranslations[$clean] }

    # 神秘时代精英怪名称由「精英修饰词 + 生物名」动态拼接，例如 Bold Enderman。
    # 先翻译修饰词，再递归翻译生物名，避免只能汉化其中一半。
    if ($script:ModifierTranslations) {
        $modifierKeys = @($script:ModifierTranslations.Keys | Where-Object { $_ -notmatch '\.' } | Sort-Object Length -Descending)
        foreach ($modifier in $modifierKeys) {
            $prefix = ([string]$modifier).Trim()
            if ([string]::IsNullOrWhiteSpace($prefix)) { continue }
            if ($clean.StartsWith($prefix + ' ', [StringComparison]::OrdinalIgnoreCase)) {
                $rest = $clean.Substring($prefix.Length).TrimStart()
                $translatedRest = Translate-MinecraftName -Name $rest -Depth ($Depth + 1)
                return ([string]$script:ModifierTranslations[$modifier]).Trim() + $translatedRest
            }
        }
    }

    # Goety 等模组的随机 Boss 名称由 title.* 与 name.* 动态拼接；称号既可能在前，
    # 也可能作为带前导空格的后缀。两侧都递归翻译，支持「称号 + 人名 + 后缀」组合。
    if ($script:TitleTranslations) {
        $titleKeys = @($script:TitleTranslations.Keys | Sort-Object Length -Descending)
        foreach ($t in $titleKeys) {
            $rawTitle = [string]$t
            if ([string]::IsNullOrWhiteSpace($rawTitle)) { continue }
            if ($rawTitle -match '^\s') {
                if ($clean.Length -gt $rawTitle.Length -and $clean.EndsWith($rawTitle, [StringComparison]::OrdinalIgnoreCase)) {
                    $base = $clean.Substring(0, $clean.Length - $rawTitle.Length).TrimEnd()
                    $translatedBase = Translate-MinecraftName -Name $base -Depth ($Depth + 1)
                    return $translatedBase + [string]$script:TitleTranslations[$t]
                }
                continue
            }

            $prefixTitle = $rawTitle.TrimEnd()
            if ($clean.StartsWith($prefixTitle + ' ', [StringComparison]::OrdinalIgnoreCase)) {
                $base = $clean.Substring($prefixTitle.Length).TrimStart()
                $translatedBase = Translate-MinecraftName -Name $base -Depth ($Depth + 1)
                return ([string]$script:TitleTranslations[$t]).Trim() + $translatedBase
            }
        }
    }
    return $clean
}

function Format-MinecraftDeathMessage {
    param([string]$Message, [int]$Max)
    $text = Remove-MinecraftColor $Message
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $p = '(.+?)'
    $e = '(.+?)'
    $i = '(.+?)'

    if ($text -match "^$p was slain by $e using \[$i\]$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])用「$(Translate-MinecraftName $matches[3])」击杀了" }
    if ($text -match "^$p was slain by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])击杀了" }
    if ($text -match "^$p was sliced in half by $e using \[$i\]$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])用「$(Translate-MinecraftName $matches[3])」一刀两断" }
    if ($text -match "^$p was sliced in half by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])一刀两断" }
    if ($text -match "^$p was shattered by $e using \[$i\]$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])用「$(Translate-MinecraftName $matches[3])」击碎了" }
    if ($text -match "^$p was shattered by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])击碎了" }
    if ($text -match "^$p was shot by $e using \[$i\]$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])用「$(Translate-MinecraftName $matches[3])」射杀了" }
    if ($text -match "^$p was shot by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])射杀了" }
    if ($text -match "^$p was fireballed by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])的火球击中身亡" }
    if ($text -match "^$p was killed by \[$i\] whil(?:e|st) trying to hurt $e$") { return "[死亡] $($matches[1]) 试图攻击$(Translate-MinecraftName $matches[3])时，被「$(Translate-MinecraftName $matches[2])」反伤致死" }
    if ($text -match "^$p was killed by $e using magic$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])用魔法击杀了" }
    if ($text -match "^$p was killed by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])击杀了" }
    if ($text -match "^$p was blown up by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])炸死了" }
    if ($text -match "^$p was blown up$") { return "[死亡] $($matches[1]) 被爆炸炸死了" }
    if ($text -match "^$p was impaled by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])刺穿了" }
    if ($text -match "^$p was squashed by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])压扁了" }
    if ($text -match "^$p hit the ground too hard whil(?:e|st) trying to escape $e$") { return "[死亡] $($matches[1]) 试图逃离$(Translate-MinecraftName $matches[2])时重重摔落身亡" }
    if ($text -match "^$p hit the ground too hard$") { return "[死亡] $($matches[1]) 重重摔落身亡" }
    if ($text -match "^$p fell from a high place$") { return "[死亡] $($matches[1]) 从高处坠落身亡" }
    if ($text -match "^$p fell off a ladder$") { return "[死亡] $($matches[1]) 从梯子上摔了下来" }
    if ($text -match "^$p fell off some vines$") { return "[死亡] $($matches[1]) 从藤蔓上摔了下来" }
    if ($text -match "^$p fell off some weeping vines$") { return "[死亡] $($matches[1]) 从垂泪藤上摔了下来" }
    if ($text -match "^$p fell off some twisting vines$") { return "[死亡] $($matches[1]) 从缠怨藤上摔了下来" }
    if ($text -match "^$p fell off scaffolding$") { return "[死亡] $($matches[1]) 从脚手架上摔了下来" }
    if ($text -match "^$p fell while climbing$") { return "[死亡] $($matches[1]) 攀爬时坠落身亡" }
    if ($text -match "^$p went up in flames$") { return "[死亡] $($matches[1]) 被火焰吞没了" }
    if ($text -match "^$p walked into fire whil(?:e|st) fighting $e$") { return "[死亡] $($matches[1]) 与$(Translate-MinecraftName $matches[2])战斗时走进火里身亡" }
    if ($text -match "^$p burned to death$") { return "[死亡] $($matches[1]) 被烧死了" }
    if ($text -match "^$p was burn(?:ed|t) to a crisp whil(?:e|st) fighting $e$") { return "[死亡] $($matches[1]) 与$(Translate-MinecraftName $matches[2])战斗时被烧成灰烬" }
    if ($text -match "^$p tried to swim in lava (?:to escape|whil(?:e|st) trying to escape) $e$") { return "[死亡] $($matches[1]) 试图在岩浆中逃离$(Translate-MinecraftName $matches[2])，结果没能活下来" }
    if ($text -match "^$p tried to swim in lava$") { return "[死亡] $($matches[1]) 试图在岩浆里游泳" }
    if ($text -match "^$p drowned whil(?:e|st) trying to escape $e$") { return "[死亡] $($matches[1]) 试图逃离$(Translate-MinecraftName $matches[2])时溺水身亡" }
    if ($text -match "^$p drowned$") { return "[死亡] $($matches[1]) 溺水身亡" }
    if ($text -match "^$p starved to death$") { return "[死亡] $($matches[1]) 饿死了" }
    if ($text -match "^$p suffocated in a wall$") { return "[死亡] $($matches[1]) 在墙里窒息身亡" }
    if ($text -match "^$p was squished too much$") { return "[死亡] $($matches[1]) 被挤压致死" }
    if ($text -match "^$p was pricked to death$") { return "[死亡] $($matches[1]) 被扎死了" }
    if ($text -match "^$p walked into a cactus whil(?:e|st) trying to escape $e$") { return "[死亡] $($matches[1]) 试图逃离$(Translate-MinecraftName $matches[2])时撞上仙人掌" }
    if ($text -match "^$p was struck by lightning$") { return "[死亡] $($matches[1]) 被闪电击中了" }
    if ($text -match "^$p froze to death$") { return "[死亡] $($matches[1]) 被冻死了" }
    if ($text -match "^$p was killed by magic$") { return "[死亡] $($matches[1]) 被魔法击杀了" }
    if ($text -match "^$p was killed while trying to hurt $e$") { return "[死亡] $($matches[1]) 试图攻击$(Translate-MinecraftName $matches[2]) 时反被击杀" }
    if ($text -match "^$p was poked to death by a sweet berry bush$") { return "[死亡] $($matches[1]) 被甜浆果丛扎死了" }
    if ($text -match "^$p went off with a bang$") { return "[死亡] $($matches[1]) 在烟花爆炸中身亡" }
    if ($text -match "^$p experienced kinetic energy$") { return "[死亡] $($matches[1]) 承受了过多动能" }
    if ($text -match "^$p fell out of the world$") { return "[死亡] $($matches[1]) 掉出了世界" }
    if ($text -match "^$p didn't want to live in the same world as $e$") { return "[死亡] $($matches[1]) 不想和$(Translate-MinecraftName $matches[2]) 待在同一个世界里" }
    if ($text -match "^$p died because of $e$") { return "[死亡] $($matches[1]) 因$(Translate-MinecraftName $matches[2]) 而死" }
    if ($text -match "^$p died$") { return "[死亡] $($matches[1]) 死亡了" }
    if ($text -match "^$p was doomed to fall by $e using \[$i\]$") { return "[死亡] $($matches[1]) 注定要被$(Translate-MinecraftName $matches[2])用「$(Translate-MinecraftName $matches[3])」摔死" }
    if ($text -match "^$p was doomed to fall by $e$") { return "[死亡] $($matches[1]) 注定要被$(Translate-MinecraftName $matches[2])摔死" }
    if ($text -match "^$p was doomed to fall$") { return "[死亡] $($matches[1]) 注定要摔死" }
    if ($text -match "^$p fell too far and was finished by $e using \[$i\]$") { return "[死亡] $($matches[1]) 摔伤后被$(Translate-MinecraftName $matches[2])用「$(Translate-MinecraftName $matches[3])」了结了" }
    if ($text -match "^$p fell too far and was finished by $e$") { return "[死亡] $($matches[1]) 摔伤后被$(Translate-MinecraftName $matches[2])了结了" }
    if ($text -match "^$p was skewered by a falling stalactite$") { return "[死亡] $($matches[1]) 被坠落的钟乳石刺穿了" }
    if ($text -match "^$p was impaled on a stalagmite$") { return "[死亡] $($matches[1]) 摔在了石笋上" }
    if ($text -match "^$p discovered the floor was lava$") { return "[死亡] $($matches[1]) 发现了地板是岩浆" }
    if ($text -match "^$p walked into the danger zone due to $e$") { return "[死亡] $($matches[1]) 因$(Translate-MinecraftName $matches[2]) 走进了危险地带" }
    if ($text -match "^$p was roasted in dragon's breath$") { return "[死亡] $($matches[1]) 被龙息烤熟了" }
    if ($text -match "^$p died from dehydration$") { return "[死亡] $($matches[1]) 脱水而死" }
    if ($text -match "^$p was frozen to death by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])冻死了" }
    if ($text -match "^$p was struck by lightning whil(?:e|st) fighting $e$") { return "[死亡] $($matches[1]) 与$(Translate-MinecraftName $matches[2])战斗时被闪电击中" }
    if ($text -match "^$p left the confines of this world$") { return "[死亡] $($matches[1]) 离开了这个世界的边界" }
    if ($text -match "^$p was obliterated by a sonically-charged shriek whil(?:e|st) trying to escape $e wielding \[$i\]$") { return "[死亡] $($matches[1]) 试图逃离$(Translate-MinecraftName $matches[2])时，被其用「$(Translate-MinecraftName $matches[3])」引发的音波尖啸震碎了" }
    if ($text -match "^$p was obliterated by a sonically-charged shriek whil(?:e|st) trying to escape $e$") { return "[死亡] $($matches[1]) 试图逃离$(Translate-MinecraftName $matches[2])时被音波尖啸震碎了" }
    if ($text -match "^$p was obliterated by a sonically-charged shriek$") { return "[死亡] $($matches[1]) 被音波尖啸震碎了" }
    if ($text -match "^$p was stung to death by $e using \[$i\]$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])用「$(Translate-MinecraftName $matches[3])」蜇死了" }
    if ($text -match "^$p was stung to death by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])蜇死了" }
    if ($text -match "^$p was stung to death$") { return "[死亡] $($matches[1]) 被蜇死了" }
    if ($text -match "^$p was pummeled by $e using danmaku$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])用弹幕击杀了" }
    if ($text -match "^$p was pummeled by $e using \[$i\]$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])用「$(Translate-MinecraftName $matches[3])」投掷物砸死了" }
    if ($text -match "^$p was pummeled by $e$") { return "[死亡] $($matches[1]) 被$(Translate-MinecraftName $matches[2])的投掷物砸死了" }
    if ($text -match "^$p withered away whil(?:e|st) fighting $e$") { return "[死亡] $($matches[1]) 与$(Translate-MinecraftName $matches[2])战斗时凋零殆尽" }
    if ($text -match "^$p withered away$") { return "[死亡] $($matches[1]) 凋零殆尽" }
    if ($text -match "^$p was killed$") { return "[死亡] $($matches[1]) 被抹杀了" }

    $deathMarkers = @(" was slain by ", " was shot by ", " was killed", " was blown up", " hit the ground too hard", " was doomed to fall", " fell from a high place", " fell too far", " fell off ", " fell while climbing", " fell out of the world", " went up in flames", " burned to death", " was burnt to a crisp", " walked into fire", " drowned", " starved to death", " suffocated", " was squished too much", " was squashed by ", " tried to swim in lava", " was pricked to death", " was poked to death", " walked into a cactus", " was struck by lightning", " froze to death", " was frozen to death", " was impaled", " was skewered by ", " discovered the floor was lava", " walked into the danger zone", " was roasted in dragon's breath", " died", " was fireballed by ", " went off with a bang", " experienced kinetic energy", " was stung to death", " was pummeled by ", " withered away", " was obliterated by ", " left the confines of this world")
    foreach ($marker in $deathMarkers) {
        if ($text.Contains($marker)) { return "[死亡] " + (Limit-Text $text $Max) }
    }
    return $null
}
function Invoke-Rcon {
    param([Parameter(Mandatory = $true)][string]$Command)
    $rcon = Join-Path $Root "tools\rcon-command.ps1"
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $rcon -Command $Command 2>&1
        if ($LASTEXITCODE -ne 0) { return "" }
        return (($out | Out-String).Trim())
    } catch {
        return ""
    }
}

function Get-OnlineSummary {
    $players = @($script:OnlinePlayers.Keys | Sort-Object)
    $names = if ($players.Count -gt 0) { $players -join ", " } else { "无" }
    return "当前在线：$($players.Count)/$($script:MaxPlayers)；玩家：$names"
}

function Add-OnlinePlayer {
    param([string]$Player)
    if (-not [string]::IsNullOrWhiteSpace($Player)) {
        $script:OnlinePlayers[$Player] = $true
    }
}

function Remove-OnlinePlayer {
    param([string]$Player)
    if (-not [string]::IsNullOrWhiteSpace($Player) -and $script:OnlinePlayers.ContainsKey($Player)) {
        $script:OnlinePlayers.Remove($Player)
    }
}

function Initialize-OnlinePlayersFromLog {
    $script:OnlinePlayers = @{}
    $script:RecentLoginIps = @{}
$script:IpLocationCache = @{}
    $logPath = Resolve-RootPath ([string]$script:Config.logWatch.logPath)
    if (-not (Test-Path -LiteralPath $logPath)) { return }
    $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($fs, (Get-LogEncoding -Path $logPath), $true)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $message = $line
            if ($line -match '\]:\s*(.+)$') { $message = $matches[1] }
            $message = Remove-MinecraftColor $message
            if ($message -match '^(.+?) joined the game$') {
                Add-OnlinePlayer -Player $matches[1]
            } elseif ($message -match '^(.+?) left the game$' -or $message -match '^(.+?) lost connection:') {
                Remove-OnlinePlayer -Player $matches[1]
            }
        }
    } finally {
        $fs.Dispose()
    }
}

function Register-Disconnect {
    param([string]$Player)
    if (-not $script:Config.disconnectWatch -or -not $script:Config.disconnectWatch.enabled) { return }
    $now = Get-Date
    $window = [int]$script:Config.disconnectWatch.windowSeconds
    if ($window -lt 10) { $window = 60 }
    $threshold = [int]$script:Config.disconnectWatch.threshold
    if ($threshold -lt 2) { $threshold = 3 }
    $cooldown = [int]$script:Config.disconnectWatch.cooldownSeconds
    if ($cooldown -lt 30) { $cooldown = 120 }

    $script:RecentDisconnects += [pscustomobject]@{ Time = $now; Player = $Player }
    $cutoff = $now.AddSeconds(-$window)
    $script:RecentDisconnects = @($script:RecentDisconnects | Where-Object { $_.Time -ge $cutoff })
    if ($script:RecentDisconnects.Count -ge $threshold -and (-not $script:LastDisconnectAlert -or $now -ge $script:LastDisconnectAlert.AddSeconds($cooldown))) {
        $script:LastDisconnectAlert = $now
        $players = ($script:RecentDisconnects | Select-Object -ExpandProperty Player -Unique) -join ", "
        Send-Discord -Important -Content "[掉线告警] 最近 $window 秒内出现 $($script:RecentDisconnects.Count) 次断开连接。涉及玩家：$players"
        Send-QQGroup -Content "[掉线告警] 最近 $window 秒内出现 $($script:RecentDisconnects.Count) 次断开连接。涉及玩家：$players"
    }
}


function Format-DisconnectReason {
    param([string]$Reason)
    $clean = Remove-MinecraftColor $Reason
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return "原因未知；服务端日志没有给出更具体信息"
    }

    $category = "其他原因"
    $hint = "请结合玩家客户端日志确认"

    if ($clean -match '(?i)^(Disconnected|disconnect\.disconnected)$') {
        $category = "主动断开/正常退出"
        $hint = "通常是玩家点击断开连接、关闭客户端，或客户端自行结束连接"
    } elseif ($clean -match '(?i)^Server closed$') {
        $category = "服务器关闭"
        $hint = "服务器正在停止或重启，待重新上线后即可连接"
    } elseif ($clean -match '(?i)^Kicked by an operator$') {
        $category = "管理员操作"
        $hint = "玩家被服务器管理员主动移出"
    } elseif ($clean -match '(?i)(60\s*秒内未完成登录|Took too long to log in)') {
        $category = "登录超时"
        $hint = "请检查客户端卡顿、网络连接和登录认证流程"
    } elseif ($clean -match '(?i)(Timed out|timeout|Connection reset|forcibly closed|远程主机.*强迫关闭|连接.*重置|Read timed out|Write timed out)') {
        $category = "网络异常/超时"
        $hint = "常见于网络波动、客户端卡死、代理/VPN 切换或服务器与玩家之间链路不稳定"
    } elseif ($clean -match '(?i)(missing.*mods?|mismatched.*mods?|mod.?mismatch|requires?.*mods?|incompatible.*(client|mods?)|channel.*mismatch|FML|(?:Neo)?Forge.*required|running (?:Neo)?Forge|Please (?:install|use) (?:Neo)?Forge|registry.*mismatch|fatally missing registry|拒绝.*模组|禁止.*模组|违禁模组|客户端不完整|mod_whitelist|not allowed|forbidden)') {
        $category = "模组不匹配/被服务器拒绝"
        $hint = "可能是缺少必需模组、版本不一致，或安装了服务器不允许的模组"
    } elseif ($clean -match '(?i)(You are banned|banned|not white-listed|not whitelisted|whitelist|黑名单|白名单)') {
        $category = "权限/白名单拒绝"
        $hint = "需要检查白名单、封禁列表或登录权限配置"
    } elseif ($clean -match '(?i)(Failed to verify username|Authentication servers|Invalid session|multiplayer.disconnect.unverified_username|身份验证|会话无效)') {
        $category = "登录验证失败"
        $hint = "常见于正版验证、会话失效或认证服务器不可达"
    } elseif ($clean -match '(?i)^Invalid player data$') {
        $category = "玩家数据异常"
        $hint = "请检查该玩家的存档、背包/能力数据及服务端模组版本，必要时从备份恢复玩家数据"
    } elseif ($clean -match '(?i)(Internal Exception|DecoderException|EncoderException|Bad packet|Packet too large|payload|protocol|ConnectionProtocol)') {
        $category = "协议/数据包异常"
        $hint = "可能由客户端模组、资源同步、网络代理或版本差异触发"
    }

    # 常见英文原因整句译成中文，未知原因保留原文供排查
    $display = $clean
    if ($clean -match '^(?i)Disconnected$') { $display = "客户端主动断开连接" }
    elseif ($clean -match '(?i)You logged in from another location') { $display = "账号在其他位置登录（被顶号）" }
    elseif ($clean -match '(?i)Took too long to log in') { $display = "登录耗时过长，被服务器断开" }
    elseif ($clean -match '(?i)An existing connection was forcibly closed') { $display = "连接被远端强制关闭" }
    elseif ($clean -match '(?i)Connection reset') { $display = "连接被重置" }
    elseif ($clean -match '(?i)timed out') { $display = "连接超时（网络无响应）" }
    elseif ($clean -match '(?i)Server closed') { $display = "服务器已关闭" }
    elseif ($clean -match '(?i)Kicked by an operator') { $display = "被管理员踢出" }
    elseif ($clean -match '(?i)Internal server error') { $display = "服务器内部错误" }
    elseif ($clean -match '(?i)You are not white-?listed') { $display = "不在服务器白名单中" }
    elseif ($clean -match '(?i)Failed to verify username') { $display = "正版用户名校验失败" }
    elseif ($clean -match '(?i)Invalid session') { $display = "登录会话无效（重启客户端重新登录即可）" }
    elseif ($clean -match '(?i)Flying is not enabled') { $display = "被判定飞行（服务器未开启允许飞行）" }
    elseif ($clean -match '^(?i)Incompatible client!\s*Please use NeoForge\s+(.+?)\s*$') { $display = "客户端版本不兼容：请使用 NeoForge $($matches[1])" }
    elseif ($clean -match '^(?i)You are trying to connect to a server that is running NeoForge, but you are not\..*?NeoForge Version:\s*([^\s]+)') { $display = "客户端未安装 NeoForge：请安装 NeoForge $($matches[1]) 后再连接" }
    elseif ($clean -match '^(?i)Invalid player data$') { $display = "玩家数据无效（可能已损坏或与当前模组版本不兼容）" }
    elseif ($clean -match '(?i)60\s*秒内未完成登录') { $display = "登录未在 60 秒内完成，已被服务器移出" }

    return "$category：$(Limit-Text $display 180)（$hint）"
}


function Parse-WrapperTimestamp {
    param([string]$Line)
    if ($Line -match '^\[(\d{4})/(\d{2})/(\d{2})\s+\S+\s+(\d{1,2}):(\d{2}):(\d{2})\.(\d{1,2})\]') {
        $centis = $matches[7].PadRight(2, '0')
        return [datetime]::new([int]$matches[1], [int]$matches[2], [int]$matches[3], [int]$matches[4], [int]$matches[5], [int]$matches[6], [int]$centis * 10)
    }
    return $null
}

function Format-ElapsedSeconds {
    param([double]$Seconds)
    if ($Seconds -lt 0) { return $null }
    if ($Seconds -lt 60) { return ("{0:N1}秒" -f $Seconds) }
    $whole = [int][Math]::Round($Seconds)
    $minutes = [int][Math]::Floor($whole / 60)
    $seconds = [int]($whole % 60)
    if ($minutes -lt 60) { return (("{0}分" -f $minutes) + $seconds.ToString("00") + "秒") }
    $hours = [int][Math]::Floor($minutes / 60)
    $minutes = [int]($minutes % 60)
    return (("{0}小时{1}分" -f $hours, $minutes) + $seconds.ToString("00") + "秒")
}

function Initialize-LastJavaStartTime {
    $script:LastJavaStartTime = $null
    $wrapperLog = Join-Path $Root "logs\server-wrapper.log"
    if (-not (Test-Path -LiteralPath $wrapperLog)) { return }
    foreach ($line in Get-Content -LiteralPath $wrapperLog -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue) {
        if ($line -match (Get-WrapperStartRegex)) {
            $ts = Parse-WrapperTimestamp -Line $line
            if ($ts) { $script:LastJavaStartTime = $ts }
        }
    }
}
function Format-LogLine {
    param([string]$Line)
    $max = [int]$script:Config.logWatch.maxMessageLength
    if ($max -lt 80) { $max = 300 }

    $message = $Line
    if ($Line -match '\]:\s*(.+)$') {
        $message = $matches[1]
    }
    $message = Remove-MinecraftColor $message
    # MC 1.19+ 聊天签名标签剥离
    $message = $message -replace '^\[(?:Not Secure|System)\]\s*', ''
    if ([string]::IsNullOrWhiteSpace($message)) { return $null }

    if ($message -match '^Starting Minecraft server on\s+(.+)$') {
        return $null
    }

    if ($message -match '^Starting minecraft server version\s+(.+)$') {
        # 新会话开始：清空在线集，避免上次会话残留（服务端崩溃/被杀不发 left the game）成为幽灵在线
        $script:OnlinePlayers = @{}
        if (-not (Test-DiscordEventEnabled "startup")) { return $null }
        return "[启动] $($script:Config.serverName) 正在启动 Minecraft $($matches[1])"
    }
    if ($message -match '^Done \(([^)]+)\)! For help, type "help"$') {
        if (-not (Test-DiscordEventEnabled "startup")) { return $null }
        $duration = $matches[1]
        if ($script:LastJavaStartTime) {
            $elapsed = ((Get-Date) - $script:LastJavaStartTime).TotalSeconds
            $formatted = Format-ElapsedSeconds -Seconds $elapsed
            if ($formatted) { $duration = "$formatted（Minecraft 内部阶段：$($matches[1])）" }
        }
        return "[上线] $($script:Config.serverName) 已启动完成，用时 $duration。地址：$($script:Config.serverAddress)"
    }
    if ($message -match '^Stopping server$') {
        if (-not (Test-DiscordEventEnabled "shutdown")) { return $null }
        return "[停服] $($script:Config.serverName) 正在关闭"
    }

    if ($message -match '^(.+?)\[/(\[[^\]]+\]|[^:]+):(\d+)\] logged in with entity id\b') {
        Set-RecentLoginIp -Player $matches[1] -Ip $matches[2]
        return $null
    }
    if ($message -match 'GameProfile@.+?name=([^,\]]+).*?lost connection:\s*(.+)$') {
        if (-not (Test-DiscordEventEnabled "quit")) { return $null }
        $player = $matches[1]
        $reason = $matches[2]
        Register-Disconnect -Player $player
        return "[连接失败] $player 未完成登录；判定：$(Format-DisconnectReason $reason)。$(Get-OnlineSummary)"
    }

    if ($script:Config.logWatch.forwardJoinQuit) {
        if ($message -match '^(.+?) joined the game$') {
            if (-not (Test-DiscordEventEnabled "join")) { return $null }
            $player = $matches[1]
            Add-OnlinePlayer -Player $player
            $ipSuffix = Get-JoinIpSuffix -Player $player
            return "[加入] $player 进入了服务器$ipSuffix。$(Get-OnlineSummary)"
        }
        # 正常下线几乎总是先 "lost connection" 再 "left the game"。
        # 以前只在 left 时推送：若监控进程在两行之间挂掉、或 left 行被漏读，就会「有上线无下线」。
        # 现在在 lost connection 时立刻推退出；随后的 left 若人已不在在线表则跳过，避免双发。
        if ($message -match '^(.+?) lost connection:\s*(.+)$') {
            if (-not (Test-DiscordEventEnabled "quit")) { return $null }
            $player = $matches[1]
            $reason = $matches[2]
            $wasOnline = $script:OnlinePlayers.ContainsKey($player)
            Remove-OnlinePlayer -Player $player
            Register-Disconnect -Player $player
            if (-not $wasOnline) {
                # 未完成进服就断线：走连接失败口径（与上面 GameProfile 路径一致）
                return "[连接失败] $player 未完成登录；判定：$(Format-DisconnectReason $reason)。$(Get-OnlineSummary)"
            }
            $reasonCn = Format-DisconnectReason $reason
            return "[退出] $player 离开了服务器。$reasonCn$(Get-OnlineSummary)"
        }
        if ($message -match '^(.+?) left the game$') {
            if (-not (Test-DiscordEventEnabled "quit")) { return $null }
            $player = $matches[1]
            if (-not $script:OnlinePlayers.ContainsKey($player)) {
                # 已在 lost connection 推过退出
                return $null
            }
            Remove-OnlinePlayer -Player $player
            return "[退出] $player 离开了服务器。$(Get-OnlineSummary)"
        }
    }

    if ($script:Config.logWatch.forwardChat -and $message -match '^<([^>]+)>\s*(.+)$') {
        if (-not (Test-DiscordEventEnabled "chat")) { return $null }
        $chatBody = Limit-Text $matches[2] $max
        return "[聊天] **$($matches[1])**： " + $chatBody
    }

    if ($script:Config.logWatch.forwardCommands -and $message -match '^(.+?) issued server command:\s*(.+)$') {
        if (-not (Test-DiscordEventEnabled "command")) { return $null }
        $cmd = $matches[2]
        if ($cmd -match '^/(login|l|register|reg|changepassword|cp)\b') {
            $cmd = ($cmd -replace '\s+.*$', ' ******')
        }
        return "[命令] $($matches[1]) 执行：$cmd"
    }

    if ($script:Config.logWatch.forwardCommands -and $message -match '^Rcon connection from:\s*(.+)$') {
        if (-not (Test-DiscordEventEnabled "command")) { return $null }
        return "[RCON] 收到远程控制台连接：$($matches[1])"
    }

    if ($message -match '^(.+?) has made the advancement \[(.+)\]$') {
        if (-not (Test-DiscordEventEnabled "advancement")) { return $null }
        return (Format-AdvancementEvent -Kind progress -Player $matches[1] -RawTitle $matches[2])
    }
    if ($message -match '^(.+?) has reached the goal \[(.+)\]$') {
        if (-not (Test-DiscordEventEnabled "advancement")) { return $null }
        return (Format-AdvancementEvent -Kind goal -Player $matches[1] -RawTitle $matches[2])
    }
    if ($message -match '^(.+?) has completed the challenge \[(.+)\]$') {
        if (-not (Test-DiscordEventEnabled "advancement")) { return $null }
        return (Format-AdvancementEvent -Kind challenge -Player $matches[1] -RawTitle $matches[2])
    }

    if ($script:Config.logWatch.forwardDeaths) {
        # 原版会给村民/被命名生物记两种格式的死亡日志：
        #   "Villager Villager['Villager'/40492, l='ServerLevel[world]', x=.., y=.., z=..] died, message: 'Villager suffocated in a wall'"
        #   "Named entity Apostle['Kim'Se the Pyre Lord'/15817, l='ServerLevel[world]', x=.., y=.., z=..] died: Kim'Se the Pyre Lord was slain by Xxx"
        # 提取名字/坐标，内层死因复用玩家死亡消息翻译器
        if ($message -match "^.*?\['(.+?)'/\d+.*?x=(-?[\d.]+), y=(-?[\d.]+), z=(-?[\d.]+)\] died(?:: (.+)|, message: '(.+)')?`$") {
            if (-not (Test-DiscordEventEnabled "death")) { return $null }
            $rawName = $matches[1]
            $who = Translate-MinecraftName $rawName
            $pos = "坐标 $([Math]::Round([double]$matches[2])), $([Math]::Round([double]$matches[3])), $([Math]::Round([double]$matches[4]))"
            $detail = ""
            $inner = [string]$matches[5]
            if ([string]::IsNullOrWhiteSpace($inner) -and $matches.ContainsKey(6)) { $inner = [string]$matches[6] }
            if (-not [string]::IsNullOrWhiteSpace($inner)) {
                $t = Format-MinecraftDeathMessage -Message $inner -Max $max
                if ($t) { $detail = ($t -replace '^\[死亡\] ', '').Replace($rawName, $who) }
                else { $detail = Limit-Text $inner $max }
            }
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "$who 死亡了" }
            return "[生物死亡] $detail（$pos）"
        }
        if ($message -match '^(.+?) was crushed$') {
            if (-not (Test-DiscordEventEnabled "death")) { return $null }
            return "[死亡] $($matches[1]) 被粉碎了"
        }
        if ($message -match '^(.+?) fell into the sawmill$') {
            if (-not (Test-DiscordEventEnabled "death")) { return $null }
            return "[死亡] $($matches[1]) 掉进了锯木机"
        }
        if ($message -match '^(.+?)重伤倒地，需要救助$') {
            if (-not (Test-DiscordEventEnabled "death")) { return $null }
            return "[求救] $($matches[1]) 重伤倒地，需要救助"
        }
        if ($message -match '^(.+?)被粉碎了$') {
            if (-not (Test-DiscordEventEnabled "death")) { return $null }
            return "[死亡] $($matches[1]) 被粉碎了"
        }
        if ($message -match '^(.+?)(重伤倒地|需要救助|被粉碎了|死亡了|死了|阵亡了)') {
            if (-not (Test-DiscordEventEnabled "death")) { return $null }
            return "[死亡/求救] " + (Limit-Text $message $max)
        }
        if (-not (Test-DiscordEventEnabled "death")) { return $null }
        $deathText = Format-MinecraftDeathMessage -Message $message -Max $max
        if ($deathText) { return $deathText }
    }

    if ($message -match '^\[Server\]\s*(.+)$') {
        return "[服务器] " + (Limit-Text $matches[1] $max)
    }

    return $null
}

# 日志 ERROR/WARN 指纹告警：与 health-check 共用 tools/log-fingerprint.ps1。
# 同一指纹在 cooldownSeconds 内只推一次，附累计次数；落盘 logs/error-fingerprints.jsonl。
. (Join-Path $PSScriptRoot 'log-fingerprint.ps1')

function Get-ErrorWatchConfig {
    $ew = $script:Config.errorWatch
    $enabled = $true
    $minLevel = 'ERROR'
    $cooldown = 600
    $maxSample = 160
    $jsonlRel = 'logs/error-fingerprints.jsonl'
    $ignore = @()
    if ($ew) {
        if ($null -ne $ew.enabled) { $enabled = [bool]$ew.enabled }
        if ($ew.minLevel) { $minLevel = [string]$ew.minLevel }
        if ($ew.cooldownSeconds) {
            $c = 0
            if ([int]::TryParse([string]$ew.cooldownSeconds, [ref]$c) -and $c -ge 30) { $cooldown = $c }
        }
        if ($ew.maxSampleLength) {
            $m = 0
            if ([int]::TryParse([string]$ew.maxSampleLength, [ref]$m) -and $m -ge 40) { $maxSample = $m }
        }
        if ($ew.jsonlPath) { $jsonlRel = [string]$ew.jsonlPath }
        if ($ew.ignorePatterns) {
            $ignore = @($ew.ignorePatterns | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }
    }
    return [pscustomobject]@{
        Enabled         = $enabled
        MinLevel        = $minLevel
        CooldownSeconds = $cooldown
        MaxSampleLength = $maxSample
        JsonlPath       = $jsonlRel
        IgnorePatterns  = $ignore
    }
}

function Write-ErrorFingerprintJsonl {
    param([hashtable]$Row)
    try {
        $cfg = Get-ErrorWatchConfig
        $path = Resolve-RootPath $cfg.JsonlPath
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $line = ($Row | ConvertTo-Json -Compress -Depth 4)
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch { }
}

function Register-ErrorFingerprintHit {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][string]$Level
    )
    $cfg = Get-ErrorWatchConfig
    if (-not $cfg.Enabled) { return }

    if (Test-McLogSoftNoise -Line $Line) { return }
    foreach ($pat in $cfg.IgnorePatterns) {
        if ($pat -and $Line -match $pat) { return }
    }
    if (-not (Test-McLogLevelAtLeast -Level $Level -MinLevel $cfg.MinLevel)) { return }

    $fp = Get-McLogFingerprint -Line $Line
    if ([string]::IsNullOrWhiteSpace($fp) -or $fp -match '^at ') { return }

    $now = Get-Date
    if (-not $script:ErrorFpState) { $script:ErrorFpState = @{} }
    if (-not $script:ErrorFpState.ContainsKey($fp)) {
        $script:ErrorFpState[$fp] = @{
            Level           = $Level
            TotalCount      = 0
            SinceAlertCount = 0
            FirstSeen       = $now
            LastSeen        = $now
            LastAlert       = $null
            Sample          = ''
        }
    }
    $st = $script:ErrorFpState[$fp]
    $st.TotalCount++
    $st.SinceAlertCount++
    $st.LastSeen = $now
    if ([string]::IsNullOrWhiteSpace($st.Sample)) {
        $sample = $Line.Trim()
        if ($sample.Length -gt $cfg.MaxSampleLength) {
            $sample = $sample.Substring(0, $cfg.MaxSampleLength) + '…'
        }
        $st.Sample = $sample
    }

    $shouldAlert = $false
    $isFirst = ($null -eq $st.LastAlert)
    if ($isFirst) {
        $shouldAlert = $true
    } elseif ($now -ge $st.LastAlert.AddSeconds($cfg.CooldownSeconds)) {
        $shouldAlert = $true
    }

    if (-not $shouldAlert) {
        # 节流期间只记 jsonl 的 suppress 抽样：每 20 次写一条，避免刷盘
        if (($st.SinceAlertCount % 20) -eq 0) {
            Write-ErrorFingerprintJsonl @{
                ts      = $now.ToString('o')
                action  = 'suppress'
                level   = $Level
                fp      = $fp
                count   = $st.SinceAlertCount
                total   = $st.TotalCount
                cooldown = $cfg.CooldownSeconds
            }
        }
        return
    }

    $n = [int]$st.SinceAlertCount
    $st.LastAlert = $now
    $st.SinceAlertCount = 0

    $fpShow = $fp
    if ($fpShow.Length -gt 140) { $fpShow = $fpShow.Substring(0, 140) + '…' }
    if ($isFirst) {
        $head = "[日志告警] 新 $Level"
    } else {
        $mins = [math]::Max(1, [int][math]::Round($cfg.CooldownSeconds / 60.0))
        $head = "[日志告警] 重复 $Level ×$n（约 ${mins} 分钟窗口）"
    }
    $msg = @(
        $head
        "样例：$($st.Sample)"
        "指纹：$fpShow"
        "累计：$($st.TotalCount) 次 · 详情：!体检 或 logs/error-fingerprints.jsonl"
    ) -join "`n"

    if (Test-DiscordEventEnabled 'logError') {
        Send-Discord -Important -Content $msg
    }
    Send-QQGroup -Content $msg

    Write-ErrorFingerprintJsonl @{
        ts     = $now.ToString('o')
        action = $(if ($isFirst) { 'first' } else { 'alert' })
        level  = $Level
        fp     = $fp
        count  = $n
        total  = $st.TotalCount
        sample = $st.Sample
    }
}

function Process-LogLineForErrorWatch {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $level = Get-McLogLevel -Line $Line
    if (-not $level) { return }
    Register-ErrorFingerprintHit -Line $Line -Level $level
}

function Watch-LogOnce {
    $logPath = Resolve-RootPath ([string]$script:Config.logWatch.logPath)
    if (-not (Test-Path -LiteralPath $logPath)) { return }

    $len = (Get-Item -LiteralPath $logPath).Length
    if (-not $script:LogOffsets.ContainsKey($logPath)) {
        $script:LogOffsets[$logPath] = $len
        return
    }
    if ($len -lt $script:LogOffsets[$logPath]) {
        $script:LogOffsets[$logPath] = 0
    }
    if ($len -eq $script:LogOffsets[$logPath]) { return }

    $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $fs.Seek([int64]$script:LogOffsets[$logPath], [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object System.IO.StreamReader($fs, (Get-LogEncoding -Path $logPath), $true)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            # 首次扫描时记几条原始日志行样本
            if (-not $script:WatchLogDebugDone -and $script:WatchLogDebugCount -lt 5) {
                if (-not $script:WatchLogDebugCount) { $script:WatchLogDebugCount = 0 }
                $script:WatchLogDebugCount++
                try {
                    $s = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Watch-LogOnce raw[$($script:WatchLogDebugCount)]: $line"
                    Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value $s -Encoding UTF8
                } catch {}
                if ($script:WatchLogDebugCount -ge 5) { $script:WatchLogDebugDone = $true }
            }
            # 指纹告警：不依赖 Format-LogLine（那条只转玩家事件），ERROR 行在此处理
            try { Process-LogLineForErrorWatch -Line $line } catch { }
            $out = Format-LogLine -Line $line
            if ($out -and -not $script:WatchLogOutDebugDone) {
                if (-not $script:WatchLogOutDebugCount) { $script:WatchLogOutDebugCount = 0 }
                $script:WatchLogOutDebugCount++
                try {
                    $s = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Watch-LogOnce out[$($script:WatchLogOutDebugCount)]: $out"
                    Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value $s -Encoding UTF8
                } catch {}
                if ($script:WatchLogOutDebugCount -ge 3) { $script:WatchLogOutDebugDone = $true }
            }
            # 只有启动/停服类才走全文去重（理由见 Test-NeedsFullTextDedupe）：
            # 加入/离开/聊天/死亡/进度等都是可合法重复的真实事件，偏移量已保证每行只处理一次。
            if ($out -and (-not (Test-NeedsFullTextDedupe -Content $out) -or -not $script:RecentMessages.ContainsKey($out))) {
                $script:RecentMessages[$out] = Get-Date
                # QQ 是本服即时通知的主要出口，先发本地 OneBot，避免 Discord 代理/网络
                # 往返把 QQ 通知排在后面；两路仍各自独立失败，不影响日志偏移提交。
                Send-QQGroup -Content $out
                Send-Discord -Content $out
            }
        }
        $script:LogOffsets[$logPath] = $fs.Position
    } finally {
        $fs.Dispose()
    }
}

function Test-LocalGamePortOpen {
    $port = 25565
    try {
        $props = Join-Path $Root 'server.properties'
        foreach ($line in [System.IO.File]::ReadAllLines($props)) {
            if ($line -match '^\s*server-port\s*=\s*(\d+)') { $port = [int]$matches[1]; break }
        }
    } catch {}
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(400)
        $up = $ok -and $c.Connected
        try { $c.Close() } catch {}
        return [bool]$up
    } catch {
        return $false
    }
}

function Format-WrapperLogLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    if ($Line -match (Get-WrapperStartRegex)) {
        $ts = Parse-WrapperTimestamp -Line $Line
        if ($ts) { $script:LastJavaStartTime = $ts }
        return $null
    }
    # 兼容两种措辞：旧版 start.bat 写 "Java process exited with code"，
    # 现行 portable-run-server.ps1 写 "Java exited with code"——此前只匹配前者，停服通知从未触发
    if ($Line -match 'Java (?:process )?exited with code\s+(-?\d+)') {
        if (-not (Test-DiscordEventEnabled "shutdown")) { return $null }
        $code = [int]$matches[1]
        if ($code -eq 0) {
            return "[停服] $($script:Config.serverName) Java 进程已正常退出，退出码 0。"
        }
        return "[停服] $($script:Config.serverName) Java 进程已退出，退出码 $code。"
    }
    if ($Line -match 'world\\session\.lock is still locked after Java exit; not restarting') {
        if (-not (Test-DiscordEventEnabled "shutdown")) { return $null }
        return "[停服] $($script:Config.serverName) Java 已退出，但 world\session.lock 仍被占用，自动重启已停止。"
    }
    if ($Line -match 'skipping duplicate start') {
        return $null
    }
    if ($Line -match 'world\\session\.lock is locked before start; aborting') {
        if (Test-LocalGamePortOpen) { return $null }
        if (-not (Test-DiscordEventEnabled "shutdown")) { return $null }
        return "[启动失败] $($script:Config.serverName) world\session.lock 被占用，start.bat 已中止。"
    }
    if ($Line -match 'Restarting in 10 seconds') {
        if (-not (Test-DiscordEventEnabled "startup")) { return $null }
        return "[重启] $($script:Config.serverName) 将在 10 秒后自动拉起。"
    }
    return $null
}

function Watch-WrapperLogOnce {
    $logPath = Resolve-RootPath "logs/server-wrapper.log"
    if (-not (Test-Path -LiteralPath $logPath)) { return }

    $len = (Get-Item -LiteralPath $logPath).Length
    if (-not $script:LogOffsets.ContainsKey($logPath)) {
        $script:LogOffsets[$logPath] = $len
        return
    }
    if ($len -lt $script:LogOffsets[$logPath]) {
        $script:LogOffsets[$logPath] = 0
    }
    if ($len -eq $script:LogOffsets[$logPath]) { return }

    $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $fs.Seek([int64]$script:LogOffsets[$logPath], [System.IO.SeekOrigin]::Begin) | Out-Null
        # wrapper 日志由 portable-run-server.ps1 以 UTF-8 写入
        $reader = New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            $out = Format-WrapperLogLine -Line $line
            # wrapper 侧产出的正是启动/停服类，去重在这里才真正起作用（与服务端日志双源互斥）
            if ($out -and (-not (Test-NeedsFullTextDedupe -Content $out) -or -not $script:RecentMessages.ContainsKey($out))) {
                $script:RecentMessages[$out] = Get-Date
                Send-Discord -Content $out
                Send-QQGroup -Content $out
            }
        }
        $script:LogOffsets[$logPath] = $fs.Position
    } finally {
        $fs.Dispose()
    }
}
function Watch-CrashesOnce {
    $dir = Resolve-RootPath ([string]$script:Config.crashWatch.directory)
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -File -Filter "*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($script:SeenCrashes.ContainsKey($_.FullName)) { return }
        $script:SeenCrashes[$_.FullName] = $true
        $summary = Get-CrashSummary -Path $_.FullName
        if (Test-DiscordEventEnabled "crash") {
            Send-Discord -Important -Content "[崩溃] 服务器生成了崩溃报告：$($_.Name)`n$summary"
            Send-QQGroup -Content "[崩溃] 服务器生成了崩溃报告：$($_.Name)`n$summary"
        }
    }
}

function Get-CrashSummary {
    param([Parameter(Mandatory = $true)][string]$Path)
    $description = ""
    $exception = ""
    $topFrame = ""
    try {
        foreach ($line in Get-Content -LiteralPath $Path -TotalCount 220 -Encoding UTF8) {
            $t = $line.Trim()
            if (-not $description -and $t.StartsWith("Description:")) {
                $description = $t.Substring("Description:".Length).Trim()
            } elseif (-not $exception -and $t -match '^(java|net|com|org|io|Caused by:)\.') {
                $exception = Limit-Text $t 180
            } elseif (-not $topFrame -and $t.StartsWith("at ")) {
                $topFrame = Limit-Text $t.Substring(3).Trim() 160
            }
        }
    } catch {
        return "无法读取崩溃报告：$($_.Exception.Message)"
    }
    if (-not $description) { $description = "(未知)" }
    if (-not $exception) { $exception = "(未知异常)" }
    if (-not $topFrame) { $topFrame = "(无堆栈帧)" }
    return "描述：$description`n异常：$exception`n位置：$topFrame"
}

function Get-StableFileSize {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = -1L
    $sameCount = 0
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $Path)) { return -1L }
        try {
            $current = (Get-Item -LiteralPath $Path).Length
        } catch {
            Start-Sleep -Seconds 2
            continue
        }
        if ($current -gt 0 -and $current -eq $last) {
            $sameCount++
            if ($sameCount -ge 2) { return $current }
        } else {
            $sameCount = 0
            $last = $current
        }
        Start-Sleep -Seconds 2
    }
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).Length }
    return -1L
}
function Format-WatchFileSize {
    param([long]$Bytes)
    if ($Bytes -lt 1MB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    return ("{0:N2} GB" -f ($Bytes / 1GB))
}

function Test-ManualBackupSuppressed {
    param([string]$Path)
    $markerPath = Join-Path $Root "tmp\manual-backup-suppress.txt"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $remaining = New-Object System.Collections.Generic.List[string]
        $matched = $false
        foreach ($line in (Get-Content -LiteralPath $markerPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $item = [string]$line
            if ([string]::IsNullOrWhiteSpace($item)) { continue }
            $itemFull = [System.IO.Path]::GetFullPath($item.Trim())
            if ($itemFull.Equals($full, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matched = $true
            } else {
                $remaining.Add($item) | Out-Null
            }
        }
        if ($matched) {
            Set-Content -LiteralPath $markerPath -Value $remaining.ToArray() -Encoding UTF8
            return $true
        }
    } catch {}
    return $false
}
function Watch-BackupsOnce {
    $dir = Resolve-RootPath ([string]$script:Config.backupWatch.directory)
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -Recurse -File -Filter "*.zip" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($script:SeenBackups.ContainsKey($_.FullName)) { return }
        $script:SeenBackups[$_.FullName] = $true
        if (Test-ManualBackupSuppressed -Path $_.FullName) { return }
        $size = Get-StableFileSize -Path $_.FullName -TimeoutSeconds 120
        if ($size -lt 0) { return }
        $displaySize = Format-WatchFileSize -Bytes $size
        if (Test-DiscordEventEnabled "backup") {
            Send-Discord -Content "[备份] 备份完成：$($_.Name) ($displaySize)"
            Send-QQGroup -Content "[备份] 备份完成：$($_.Name) ($displaySize)"
        }
    }
}

function Get-DirectUrlText {
    param([Parameter(Mandatory = $true)][string]$Uri, [int]$TimeoutSec = 8)
    # 查公网 IP 必须绕过系统代理直连：走 Clash 等代理会拿到代理出口 IP，产生“IP 变化”误报（2026-07-07 实锤）。
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Proxy = $null
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = "portable-server-kit-ipwatch/1.0"
    $resp = $req.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    } finally { $resp.Dispose() }
}

function Get-WatchedPublicIp {
    param(
        [Parameter(Mandatory = $true)][string[]]$Endpoints,
        [Parameter(Mandatory = $true)][ValidateSet("IPv4", "IPv6")][string]$Family
    )
    foreach ($endpoint in $Endpoints) {
        try {
            $text = Get-DirectUrlText -Uri ([string]$endpoint)
            $addr = $null
            if (-not [System.Net.IPAddress]::TryParse($text, [ref]$addr)) { continue }
            if ($Family -eq "IPv4" -and $addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            if ($Family -eq "IPv6" -and $addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { continue }
            return $addr.ToString()
        } catch { continue }
    }
    return ""
}

function Get-Ipv6Prefix64 {
    param([string]$Ip)
    # 只比较 /64 前缀：Windows 出站走的临时 IPv6 地址约一天轮换一次，按整地址比较会天天误报
    try {
        $addr = [System.Net.IPAddress]::Parse($Ip)
        if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return "" }
        $b = $addr.GetAddressBytes()
        $parts = @()
        # [int] 强转必须有：PS5.1 的 -shl 结果跟随左操作数类型，[byte] 左移 8 位在 byte 内溢出归零（2026-07-10 实锤）
        for ($i = 0; $i -lt 8; $i += 2) { $parts += ("{0:x}" -f (([int]$b[$i] -shl 8) -bor [int]$b[$i + 1])) }
        return ($parts -join ":")
    } catch { return "" }
}

function Save-IpWatchState {
    # 状态落盘：监控停机期间发生的 IP 变化，重启后第一轮就能对出差异并补报/补同步
    try {
        @{ ip4 = $script:LastIp; ip6Prefix = $script:LastIp6Prefix } | ConvertTo-Json -Compress |
            Set-Content -LiteralPath (Join-Path $Root "tmp\ipwatch-state.json") -Encoding UTF8
    } catch {}
}

function Watch-IpOnce {
    if (-not $script:Config.ipWatch.enabled) { return }
    $now = Get-Date
    if ($script:NextIpCheck -and $now -lt $script:NextIpCheck) { return }
    $minutes = [int]$script:Config.ipWatch.pollMinutes
    if ($minutes -lt 1) { $minutes = 5 }
    $script:NextIpCheck = $now.AddMinutes($minutes)

    $ip4 = Get-WatchedPublicIp -Endpoints ([string[]]$script:Config.ipWatch.endpoints) -Family IPv4
    if ($ip4) {
        if (-not $script:LastIp) {
            $script:LastIp = $ip4
            Save-IpWatchState
        } elseif ($script:LastIp -ne $ip4) {
            $old = $script:LastIp
            $script:LastIp = $ip4
            Save-IpWatchState
            if (Test-DiscordEventEnabled "ip") {
                Send-Discord -Important -Content "[公网IP] 发生变化：$old -> $ip4。域名/DDNS 可能需要刷新。"
                Send-QQGroup -Content "[公网IP] 发生变化：$old -> $ip4。域名/DDNS 可能需要刷新。"
            }
            $script:NextDdnsCheck = $null # IPv4 变了：立即触发 DDNS 同步，不等下个周期
        }
    }

    $watch6 = $true
    if ($script:Config.ipWatch.PSObject.Properties["watchIpv6"]) { $watch6 = [bool]$script:Config.ipWatch.watchIpv6 }
    if (-not $watch6) { return }
    $endpoints6 = @("https://6.ipw.cn", "https://ipv6.icanhazip.com")
    if ($script:Config.ipWatch.PSObject.Properties["endpoints6"] -and $script:Config.ipWatch.endpoints6) { $endpoints6 = [string[]]$script:Config.ipWatch.endpoints6 }
    $ip6 = Get-WatchedPublicIp -Endpoints $endpoints6 -Family IPv6
    if (-not $ip6) { return } # 家宽 IPv6 说没就没，拿不到不告警不误报
    $prefix = Get-Ipv6Prefix64 -Ip $ip6
    if (-not $prefix) { return }
    if (-not $script:LastIp6Prefix) {
        $script:LastIp6Prefix = $prefix
        Save-IpWatchState
    } elseif ($script:LastIp6Prefix -ne $prefix) {
        $old6 = $script:LastIp6Prefix
        $script:LastIp6Prefix = $prefix
        Save-IpWatchState
        if (Test-DiscordEventEnabled "ip") {
            Send-Discord -Important -Content "[公网IP] IPv6 前缀变化：${old6}:: -> ${prefix}::。AAAA 解析可能需要刷新。"
            Send-QQGroup -Content "[公网IP] IPv6 前缀变化：${old6}:: -> ${prefix}::。AAAA 解析可能需要刷新。"
        }
        $script:NextDdnsCheck = $null
    }
}

function Watch-DdnsOnce {
    # ddns.enabled 时：周期性在进程内调 ddns-update.ps1 把 DNSPod 解析同步成当前公网 IP，并转发结果；
    # 未启用时：退化为“解析一致性哨兵”，发现域名解析 ≠ 本机公网 IP 才告警（连续两次确认，避开 TTL 收敛期）。
    $ddnsEnabled = $false
    if ($script:Config.PSObject.Properties["ddns"] -and $script:Config.ddns -and [bool]$script:Config.ddns.enabled) { $ddnsEnabled = $true }
    $now = Get-Date

    if ($ddnsEnabled) {
        if ($script:NextDdnsCheck -and $now -lt $script:NextDdnsCheck) { return }
        $minutes = 5
        if ($script:Config.ddns.PSObject.Properties["checkMinutes"] -and [int]$script:Config.ddns.checkMinutes -ge 1) { $minutes = [int]$script:Config.ddns.checkMinutes }
        $script:NextDdnsCheck = $now.AddMinutes($minutes)

        $lines = @()
        try {
            # 用独立 powershell 进程跑 DDNS，避免脚本里的 exit / 异常状态污染甚至结束本监控。
            # 对照：child 日志约每 5 分钟（checkMinutes）少一截就没了——与 DDNS 周期一致（2026-08-06）。
            $ddnsScript = Join-Path $PSScriptRoot "ddns-update.ps1"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "powershell.exe"
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ddnsScript`" -ConfigPath `"$ConfigPath`" -AsJson"
            $psi.WorkingDirectory = $Root
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            # PowerShell 子进程明确输出 UTF-8；重定向流也必须显式按 UTF-8 解码。
            # 否则隐藏窗口下 .NET 默认按系统代码页读取，中文会在发送前变成乱码。
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $stdout = $p.StandardOutput.ReadToEnd()
            $stderr = $p.StandardError.ReadToEnd()
            if (-not $p.WaitForExit(120000)) {
                try { $p.Kill() } catch { }
                throw "ddns-update.ps1 超时（120s）"
            }
            $lines = @(($stdout + "`n" + $stderr) -split "`r?`n" | Where-Object { $_ -ne '' })
        } catch {
            $lines = @("DDNSERR:" + $_.Exception.Message)
            Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value (
                "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') DDNS 调用异常（监控继续运行）：$($_.Exception.Message)"
            ) -Encoding UTF8
        }
        $jsonLine = $lines | Where-Object { $_ -like "DDNSJSON:*" } | Select-Object -Last 1
        $data = $null
        if ($jsonLine) {
            try { $data = $jsonLine.Substring("DDNSJSON:".Length) | ConvertFrom-Json } catch {}
        }
        if (-not $data) {
            if (-not $script:LastDdnsErrorNotify -or ($now - $script:LastDdnsErrorNotify).TotalMinutes -ge 30) {
                $script:LastDdnsErrorNotify = $now
                if (Test-DiscordEventEnabled "ip") {
                    Send-Discord -Important -Content "[DDNS] 自动同步脚本没有返回结果，请查看 logs\ddns-update.log。"
                    Send-QQGroup -Content "[DDNS] 自动同步脚本没有返回结果，请查看 logs\ddns-update.log。"
                }
            }
            return
        }
        foreach ($change in @($data.changes)) {
            if (-not $change) { continue }
            if ([string]$change.action -eq "created") {
                $msg = "[DDNS] 已新建 $($change.type) 解析记录 -> $($change.new)。"
            } else {
                $msg = "[DDNS] 解析已自动更新（$($change.type)）：$($change.old) -> $($change.new)。旧地址玩家最多等约 10 分钟 DNS 缓存过期。"
            }
            if (Test-DiscordEventEnabled "ip") {
                Send-Discord -Important -Content $msg
                Send-QQGroup -Content $msg
            }
            Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -Encoding UTF8
        }
        if (-not [bool]$data.ok) {
            if (-not $script:LastDdnsErrorNotify -or ($now - $script:LastDdnsErrorNotify).TotalMinutes -ge 30) {
                $script:LastDdnsErrorNotify = $now
                $errText = (@($data.errors) -join "；")
                if (Test-DiscordEventEnabled "ip") {
                    Send-Discord -Important -Content "[DDNS] 自动同步失败：$errText"
                    Send-QQGroup -Content "[DDNS] 自动同步失败：$errText"
                }
            }
        }
        return
    }

    # ---- 未启用 DDNS：解析一致性哨兵 ----
    $checkDns = $true
    if ($script:Config.ipWatch.PSObject.Properties["dnsMismatchAlert"]) { $checkDns = [bool]$script:Config.ipWatch.dnsMismatchAlert }
    if (-not $checkDns) { return }
    if (-not $script:LastIp) { return }
    $address = ([string]$script:Config.serverAddress).Trim()
    if ([string]::IsNullOrWhiteSpace($address)) { return }
    $address = $address -replace ':\d+$', ''
    $literal = $null
    if ([System.Net.IPAddress]::TryParse($address, [ref]$literal)) { return } # 直连 IP 没有 DNS 可言
    if ($script:NextDnsConsistencyCheck -and $now -lt $script:NextDnsConsistencyCheck) { return }
    $script:NextDnsConsistencyCheck = $now.AddMinutes(15)
    $resolved = @()
    try {
        $resolved = @(Resolve-DnsName -Name $address -Type A -Server 223.5.5.5 -DnsOnly -ErrorAction Stop |
            Where-Object { $_.Type -eq "A" } | ForEach-Object { [string]$_.IPAddress })
    } catch { return }
    if ($resolved.Count -eq 0) { return }
    if ($resolved -contains $script:LastIp) { $script:DnsMismatchStrikes = 0; return }
    $script:DnsMismatchStrikes++
    if ($script:DnsMismatchStrikes -lt 2) { return }
    if ($script:LastDnsMismatchNotify -and ($now - $script:LastDnsMismatchNotify).TotalHours -lt 6) { return }
    $script:LastDnsMismatchNotify = $now
    $msg = "[DDNS] 检测到解析未同步：$address 当前解析为 $($resolved -join '/')，但本机公网 IP 是 $($script:LastIp)。玩家会连到旧地址！请检查路由器/DDNS，或在 ops-config.json 的 ddns 段启用自动同步。"
    Send-Discord -Important -Content $msg
    Send-QQGroup -Content $msg
}

function Trim-RecentMessages {
    $cutoff = (Get-Date).AddMinutes(-10)
    @($script:RecentMessages.Keys) | ForEach-Object {
        if ($script:RecentMessages[$_] -lt $cutoff) {
            $script:RecentMessages.Remove($_)
        }
    }
    Trim-RecentLoginIps
}

function Watch-PendingNotifyDir {
    param(
        [Parameter(Mandatory = $true)][string]$PendingRel,
        [Parameter(Mandatory = $true)][string]$DoneRel,
        [Parameter(Mandatory = $true)][string]$Label,
        [bool]$PushQq = $true,
        [bool]$PushDiscord = $true,
        [string]$FallbackPrefix = ''
    )
    $pendingDir = Join-Path $Root $PendingRel
    $doneDir = Join-Path $Root $DoneRel
    if (-not (Test-Path -LiteralPath $pendingDir -PathType Container)) { return }
    $files = @(Get-ChildItem -LiteralPath $pendingDir -File -Filter '*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime)
    if ($files.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $doneDir)) {
        New-Item -ItemType Directory -Path $doneDir -Force | Out-Null
    }
    foreach ($f in $files) {
        $data = $null
        try {
            $data = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
                "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Label pending 解析失败：$($f.Name)"
            ) -Encoding UTF8
            try { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $doneDir ($f.BaseName + '.bad.json')) -Force } catch { }
            continue
        }
        $summary = [string]$data.summary
        if ([string]::IsNullOrWhiteSpace($summary)) {
            $prefix = if ($FallbackPrefix) { $FallbackPrefix } else { "[$Label]" }
            $summary = "$prefix 已生成 $($data.stamp)"
        }
        if ($PushDiscord) { Send-Discord -Important -Content $summary }
        if ($PushQq) { Send-QQGroup -Content $summary }
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Label 已推送 stamp=$($data.stamp)"
        ) -Encoding UTF8
        try {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $doneDir $f.Name) -Force
        } catch {
            try { Remove-Item -LiteralPath $f.FullName -Force } catch { }
        }
    }
}

function Watch-LagForensicsOnce {
    # lag-forensics.ps1 写完取证包后在 tmp/lag-forensics/pending/*.json 放通知；本函数推送后移到 done。
    $pendingDir = Join-Path $Root 'tmp\lag-forensics\pending'
    $doneDir = Join-Path $Root 'tmp\lag-forensics\done'
    if (-not (Test-Path -LiteralPath $pendingDir -PathType Container)) { return }
    $files = @(Get-ChildItem -LiteralPath $pendingDir -File -Filter '*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime)
    if ($files.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $doneDir)) {
        New-Item -ItemType Directory -Path $doneDir -Force | Out-Null
    }

    $pushQq = $true
    $pushDiscord = $true
    try {
        if ($script:Config.PSObject.Properties['lagWatch'] -and $script:Config.lagWatch) {
            $lw = $script:Config.lagWatch
            if ($lw.PSObject.Properties['pushQq']) { $pushQq = [bool]$lw.pushQq }
            if ($lw.PSObject.Properties['pushDiscord']) { $pushDiscord = [bool]$lw.pushDiscord }
            if ($lw.PSObject.Properties['enabled'] -and -not [bool]$lw.enabled) { return }
        }
    } catch { }

    foreach ($f in $files) {
        $data = $null
        try {
            $data = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
                "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') lag-forensics pending 解析失败：$($f.Name)"
            ) -Encoding UTF8
            try { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $doneDir ($f.BaseName + '.bad.json')) -Force } catch { }
            continue
        }
        $summary = [string]$data.summary
        if ([string]::IsNullOrWhiteSpace($summary)) {
            $summary = "[卡顿取证] 已生成证据包 $($data.stamp) · 见 tmp\lag-forensics\$($data.stamp)"
        }
        if ($pushDiscord) { Send-Discord -Important -Content $summary }
        if ($pushQq) { Send-QQGroup -Content $summary }
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') lag-forensics 已推送 stamp=$($data.stamp)"
        ) -Encoding UTF8
        try {
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $doneDir $f.Name) -Force
        } catch {
            try { Remove-Item -LiteralPath $f.FullName -Force } catch { }
        }
    }
}

function Watch-WeeklyReportOnce {
    # weeklyReport.enabled 时：到 dayOfWeek + hourLocal 后生成并推送运行报告（同日一次）。
    # 用独立子进程跑 weekly-report.ps1，避免污染本监控；失败只记日志不退出。
    if (-not $script:Config.PSObject.Properties['weeklyReport']) { return }
    $wr = $script:Config.weeklyReport
    if (-not $wr -or -not [bool]$wr.enabled) { return }

    $now = Get-Date
    # 每分钟最多检查一次是否到点
    if ($script:NextWeeklyReportCheck -and $now -lt $script:NextWeeklyReportCheck) { return }
    $script:NextWeeklyReportCheck = $now.AddMinutes(1)

    $hour = 9
    $minute = 0
    if ($wr.PSObject.Properties['hourLocal']) {
        try { $hour = [int]$wr.hourLocal } catch { }
    }
    if ($wr.PSObject.Properties['minuteLocal']) {
        try { $minute = [int]$wr.minuteLocal } catch { }
    }
    if ($hour -lt 0) { $hour = 0 }
    if ($hour -gt 23) { $hour = 23 }
    if ($minute -lt 0) { $minute = 0 }
    if ($minute -gt 59) { $minute = 59 }
    if ($now.Hour -lt $hour) { return }
    if ($now.Hour -eq $hour -and $now.Minute -lt $minute) { return }

    $dowCfg = 'Monday'
    if ($wr.PSObject.Properties['dayOfWeek'] -and $wr.dayOfWeek) {
        $dowCfg = [string]$wr.dayOfWeek
    }
    $daily = $dowCfg -match '^(?i)(\*|daily|everyday|每天|每日)$'
    if (-not $daily) {
        $want = $dowCfg.Trim()
        $todayEn = $now.DayOfWeek.ToString() # Monday ... Sunday
        if ($want -notmatch "^(?i)$([regex]::Escape($todayEn))$") {
            # 也接受中文星期（一…日 / 周一…）
            $cnMap = @{
                '一' = 'Monday'; '周一' = 'Monday'; '星期一' = 'Monday'
                '二' = 'Tuesday'; '周二' = 'Tuesday'; '星期二' = 'Tuesday'
                '三' = 'Wednesday'; '周三' = 'Wednesday'; '星期三' = 'Wednesday'
                '四' = 'Thursday'; '周四' = 'Thursday'; '星期四' = 'Thursday'
                '五' = 'Friday'; '周五' = 'Friday'; '星期五' = 'Friday'
                '六' = 'Saturday'; '周六' = 'Saturday'; '星期六' = 'Saturday'
                '日' = 'Sunday'; '天' = 'Sunday'; '周日' = 'Sunday'; '周天' = 'Sunday'
                '星期日' = 'Sunday'; '星期天' = 'Sunday'
            }
            $mapped = $null
            if ($cnMap.ContainsKey($want)) { $mapped = $cnMap[$want] }
            if (-not $mapped -or $mapped -ne $todayEn) { return }
        }
    }

    $stateRel = 'tmp/weekly-report-state.json'
    if ($wr.PSObject.Properties['statePath'] -and $wr.statePath) {
        $stateRel = [string]$wr.statePath
    }
    $statePath = Resolve-RootPath $stateRel
    $todayKey = $now.ToString('yyyy-MM-dd')
    try {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.PSObject.Properties['lastPushDate'] -and [string]$st.lastPushDate -eq $todayKey) {
                return
            }
        }
    } catch { }

    $window = '7d'
    if ($wr.PSObject.Properties['window'] -and $wr.window) {
        $w = ([string]$wr.window).Trim().ToLowerInvariant()
        if ($w -in @('1d', '7d', '30d')) { $window = $w }
    }

    $reportScript = Join-Path $PSScriptRoot 'weekly-report.ps1'
    if (-not (Test-Path -LiteralPath $reportScript -PathType Leaf)) {
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') weeklyReport: 缺少 tools\weekly-report.ps1"
        ) -Encoding UTF8
        return
    }

    $summary = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$reportScript`" -Window $window -QqSummary"
        $psi.WorkingDirectory = $Root
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # 周报脚本通过 stdout 返回中文摘要；固定 UTF-8，避免 GBK/UTF-8 错配后再推 QQ/Discord。
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(180000)) {
            try { $p.Kill() } catch { }
            throw 'weekly-report.ps1 超时（180s）'
        }
        $summary = ($stdout | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($summary) -and -not [string]::IsNullOrWhiteSpace($stderr)) {
            throw $stderr.Trim()
        }
    } catch {
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') weeklyReport 生成失败：$($_.Exception.Message)"
        ) -Encoding UTF8
        return
    }

    if ([string]::IsNullOrWhiteSpace($summary)) {
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') weeklyReport 无输出，跳过推送"
        ) -Encoding UTF8
        return
    }

    $pushQq = $true
    $pushDiscord = $true
    if ($wr.PSObject.Properties['pushQq']) { $pushQq = [bool]$wr.pushQq }
    if ($wr.PSObject.Properties['pushDiscord']) { $pushDiscord = [bool]$wr.pushDiscord }

    if ($pushDiscord) {
        Send-Discord -Content $summary
    }
    if ($pushQq) {
        Send-QQGroup -Content $summary
    }

    try {
        $dir = Split-Path -Parent $statePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $stateObj = [ordered]@{
            lastPushDate = $todayKey
            window       = $window
            pushedAt     = $now.ToString('o')
        }
        [System.IO.File]::WriteAllText(
            $statePath,
            ($stateObj | ConvertTo-Json -Compress),
            (New-Object System.Text.UTF8Encoding $false)
        )
    } catch { }

    Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') weeklyReport 已推送 window=$window"
    ) -Encoding UTF8
}

function Watch-BackupVerifyPendingOnce {
    $pushQq = $true
    $pushDiscord = $true
    try {
        if ($script:Config.PSObject.Properties['backupVerify'] -and $script:Config.backupVerify) {
            $bv = $script:Config.backupVerify
            if ($bv.PSObject.Properties['pushQq']) { $pushQq = [bool]$bv.pushQq }
            if ($bv.PSObject.Properties['pushDiscord']) { $pushDiscord = [bool]$bv.pushDiscord }
        }
    } catch { }
    Watch-PendingNotifyDir -PendingRel 'tmp\backup-verify\pending' -DoneRel 'tmp\backup-verify\done' `
        -Label 'backup-verify' -PushQq:$pushQq -PushDiscord:$pushDiscord -FallbackPrefix '[备份验证]'
}

function Watch-BackupVerifyOnce {
    # backupVerify.enabled：到 dayOfWeek+hourLocal 跑 verify-backup.ps1；失败可推（pushOnFail），也可 pushAlways。
    if (-not $script:Config.PSObject.Properties['backupVerify']) { return }
    $bv = $script:Config.backupVerify
    if (-not $bv -or -not [bool]$bv.enabled) { return }

    $now = Get-Date
    if ($script:NextBackupVerifyCheck -and $now -lt $script:NextBackupVerifyCheck) { return }
    $script:NextBackupVerifyCheck = $now.AddMinutes(1)

    $hour = 10; $minute = 0
    if ($bv.PSObject.Properties['hourLocal']) { try { $hour = [int]$bv.hourLocal } catch { } }
    if ($bv.PSObject.Properties['minuteLocal']) { try { $minute = [int]$bv.minuteLocal } catch { } }
    if ($hour -lt 0) { $hour = 0 }; if ($hour -gt 23) { $hour = 23 }
    if ($minute -lt 0) { $minute = 0 }; if ($minute -gt 59) { $minute = 59 }
    if ($now.Hour -lt $hour) { return }
    if ($now.Hour -eq $hour -and $now.Minute -lt $minute) { return }

    $dowCfg = 'Sunday'
    if ($bv.PSObject.Properties['dayOfWeek'] -and $bv.dayOfWeek) { $dowCfg = [string]$bv.dayOfWeek }
    $daily = $dowCfg -match '^(?i)(\*|daily|everyday|每天|每日)$'
    if (-not $daily) {
        $want = $dowCfg.Trim()
        $todayEn = $now.DayOfWeek.ToString()
        if ($want -notmatch "^(?i)$([regex]::Escape($todayEn))$") {
            $cnMap = @{
                '一' = 'Monday'; '周一' = 'Monday'; '星期一' = 'Monday'
                '二' = 'Tuesday'; '周二' = 'Tuesday'; '星期二' = 'Tuesday'
                '三' = 'Wednesday'; '周三' = 'Wednesday'; '星期三' = 'Wednesday'
                '四' = 'Thursday'; '周四' = 'Thursday'; '星期四' = 'Thursday'
                '五' = 'Friday'; '周五' = 'Friday'; '星期五' = 'Friday'
                '六' = 'Saturday'; '周六' = 'Saturday'; '星期六' = 'Saturday'
                '日' = 'Sunday'; '天' = 'Sunday'; '周日' = 'Sunday'; '周天' = 'Sunday'
                '星期日' = 'Sunday'; '星期天' = 'Sunday'
            }
            $mapped = $null
            if ($cnMap.ContainsKey($want)) { $mapped = $cnMap[$want] }
            if (-not $mapped -or $mapped -ne $todayEn) { return }
        }
    }

    $stateRel = 'tmp/backup-verify-state.json'
    if ($bv.PSObject.Properties['statePath'] -and $bv.statePath) { $stateRel = [string]$bv.statePath }
    $statePath = Resolve-RootPath $stateRel
    $todayKey = $now.ToString('yyyy-MM-dd')
    try {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.PSObject.Properties['lastRunDate'] -and [string]$st.lastRunDate -eq $todayKey) { return }
        }
    } catch { }

    $count = 1
    if ($bv.PSObject.Properties['count']) {
        try { $count = [Math]::Max(1, [int]$bv.count) } catch { $count = 1 }
    }
    $deep = $false
    if ($bv.PSObject.Properties['deep']) { $deep = [bool]$bv.deep }

    $scriptPath = Join-Path $PSScriptRoot 'verify-backup.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') backupVerify: 缺少 tools\verify-backup.ps1"
        ) -Encoding UTF8
        return
    }

    $pushAlways = $false
    $pushOnFail = $true
    if ($bv.PSObject.Properties['pushAlways']) { $pushAlways = [bool]$bv.pushAlways }
    if ($bv.PSObject.Properties['pushOnFail']) { $pushOnFail = [bool]$bv.pushOnFail }
    $pushQq = $true; $pushDiscord = $true
    if ($bv.PSObject.Properties['pushQq']) { $pushQq = [bool]$bv.pushQq }
    if ($bv.PSObject.Properties['pushDiscord']) { $pushDiscord = [bool]$bv.pushDiscord }

    $summary = ''
    $exitCode = -1
    try {
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Count $count -QqSummary -Quiet"
        if ($deep) { $args += ' -Deep' }
        if ($pushAlways -or $pushOnFail) { $env:BACKUP_VERIFY_PUSH = '1' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = $args
        $psi.WorkingDirectory = $Root
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # 验证脚本同样可能返回中文，所有重定向 PowerShell 流统一按 UTF-8 解码。
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(600000)) {
            try { $p.Kill() } catch { }
            throw 'verify-backup.ps1 超时（600s）'
        }
        $exitCode = $p.ExitCode
        $summary = ($stdout | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($summary) -and -not [string]::IsNullOrWhiteSpace($stderr)) {
            $summary = $stderr.Trim()
        }
    } catch {
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') backupVerify 失败：$($_.Exception.Message)"
        ) -Encoding UTF8
        $summary = "[备份验证] 执行失败：$($_.Exception.Message)"
        $exitCode = 1
    } finally {
        Remove-Item Env:\BACKUP_VERIFY_PUSH -ErrorAction SilentlyContinue
    }

    $failed = ($exitCode -ne 0)
    $shouldPush = $pushAlways -or ($failed -and $pushOnFail)
    if ($shouldPush -and -not [string]::IsNullOrWhiteSpace($summary)) {
        if ($pushDiscord) { Send-Discord -Important -Content $summary }
        if ($pushQq) { Send-QQGroup -Content $summary }
    }

    try {
        $dir = Split-Path -Parent $statePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $stateObj = [ordered]@{
            lastRunDate = $todayKey
            exitCode    = $exitCode
            failed      = $failed
            ranAt       = $now.ToString('o')
        }
        [System.IO.File]::WriteAllText(
            $statePath,
            ($stateObj | ConvertTo-Json -Compress),
            (New-Object System.Text.UTF8Encoding $false)
        )
    } catch { }

    Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') backupVerify 完成 exit=$exitCode push=$shouldPush"
    ) -Encoding UTF8
}

try {
$script:Config = Read-Config -Path (Resolve-RootPath $ConfigPath)
$script:ChatRelayEnabled = $true
$script:ChatRelayCheckedAt = $null
$script:PlayerBindByName = @{}
$script:PlayerBindLoadedAt = $null
$script:PlayerBindMtime = $null
try { Update-PlayerBindCache } catch { $script:PlayerBindByName = @{} }
$script:LogOffsets = @{}
$script:RecentMessages = @{}
$script:SeenCrashes = @{}
$script:SeenBackups = @{}
$script:LastIp = ""
$script:LastIp6Prefix = ""
$script:NextIpCheck = $null
$script:NextDdnsCheck = $null
$script:NextDnsConsistencyCheck = $null
$script:NextWeeklyReportCheck = $null
$script:NextBackupVerifyCheck = $null
$script:DnsMismatchStrikes = 0
$script:LastDdnsErrorNotify = $null
$script:LastDnsMismatchNotify = $null
# 加载上次落盘的 IP 状态：监控停机期间的 IP 变化重启后第一轮就能对出差异
try {
    $ipStatePath = Join-Path $Root "tmp\ipwatch-state.json"
    if (Test-Path -LiteralPath $ipStatePath) {
        $ipState = Get-Content -LiteralPath $ipStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ipState.PSObject.Properties['ip4'] -and $ipState.ip4) { $script:LastIp = [string]$ipState.ip4 }
        if ($ipState.PSObject.Properties['ip6Prefix'] -and $ipState.ip6Prefix) { $script:LastIp6Prefix = [string]$ipState.ip6Prefix }
    }
} catch {}
$script:RecentDisconnects = @()
$script:LastDisconnectAlert = $null
$script:OnlinePlayers = @{}
$script:RecentLoginIps = @{}
$script:IpLocationCache = @{}
$script:ErrorFpState = @{}
$script:QQDebugLogged = $true
$script:QQRespLogged = $true
$script:WatchLogDebugDone = $true
$script:WatchLogOutDebugDone = $true
$script:MaxPlayers = 0
try {
    $serverProps = Get-Content -LiteralPath (Join-Path $Root "server.properties") -Encoding UTF8
    foreach ($line in $serverProps) {
        if ($line -match '^max-players=(\d+)') { $script:MaxPlayers = [int]$matches[1] }
    }
} catch {
    $script:MaxPlayers = 0
}
if ($script:MaxPlayers -le 0) { $script:MaxPlayers = 88 }
Initialize-LastJavaStartTime
Initialize-OnlinePlayersFromLog

# 成就翻译表会扫描模组/资源包中的语言文件，首次按需构建可能阻塞通知 10~20 秒。
# 在进入主循环前预热；先记住当前日志偏移，预热期间新追加的日志仍会在首轮被处理，
# 不会因为监控启动时的预热而漏掉成就或聊天事件。
if ($script:Config.logWatch.enabled) {
    try {
        $warmLogPath = Resolve-RootPath ([string]$script:Config.logWatch.logPath)
        if (Test-Path -LiteralPath $warmLogPath -PathType Leaf) {
            $script:LogOffsets[$warmLogPath] = [int64](Get-Item -LiteralPath $warmLogPath).Length
        }
    } catch {}
    try {
        $warmupWatch = [Diagnostics.Stopwatch]::StartNew()
        Initialize-AdvancementTranslations
        $warmupWatch.Stop()
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') advancement translations warmed in $($warmupWatch.Elapsed.TotalSeconds.ToString('F1'))s"
        ) -Encoding UTF8
    } catch {
        Add-Content -LiteralPath (Join-Path $Root 'logs\discord-watch.log') -Value (
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') advancement translation warmup failed: $($_.Exception.Message)"
        ) -Encoding UTF8
    }
}

New-Item -ItemType Directory -Force (Join-Path $Root "logs") | Out-Null
if ($script:Config.crashWatch.enabled) {
    $crashDir = Resolve-RootPath ([string]$script:Config.crashWatch.directory)
    if (Test-Path -LiteralPath $crashDir) {
        Get-ChildItem -LiteralPath $crashDir -File -Filter "*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
            $script:SeenCrashes[$_.FullName] = $true
        }
    }
}
if ($script:Config.backupWatch.enabled) {
    $backupDir = Resolve-RootPath ([string]$script:Config.backupWatch.directory)
    if (Test-Path -LiteralPath $backupDir) {
        Get-ChildItem -LiteralPath $backupDir -Recurse -File -Filter "*.zip" -ErrorAction SilentlyContinue | ForEach-Object {
            $script:SeenBackups[$_.FullName] = $true
        }
    }
}

Send-Discord -Content "[监控] $($script:Config.serverName) Discord 监控已启动。服务器地址：$($script:Config.serverAddress)"
Send-QQGroup -Content "[监控] $($script:Config.serverName) 监控已启动。服务器地址：$($script:Config.serverAddress)"

while ($true) {
    try {
        $stage = "log"
        if ($script:Config.logWatch.enabled) { Watch-LogOnce }
        $stage = "wrapper-log"
        Watch-WrapperLogOnce
        $stage = "crash"
        if ($script:Config.crashWatch.enabled) { Watch-CrashesOnce }
        $stage = "backup"
        if ($script:Config.backupWatch.enabled) { Watch-BackupsOnce }
        $stage = "ip"
        Watch-IpOnce
        $stage = "ddns"
        Watch-DdnsOnce
        $stage = "weekly-report"
        Watch-WeeklyReportOnce
        $stage = "lag-forensics"
        Watch-LagForensicsOnce
        $stage = "backup-verify"
        Watch-BackupVerifyOnce
        $stage = "backup-verify-pending"
        Watch-BackupVerifyPendingOnce
        $stage = "dedupe-trim"
        Trim-RecentMessages   # 内部已连带 Trim-RecentLoginIps
    } catch {
        $where = $_.InvocationInfo.PositionMessage
        if ([string]::IsNullOrWhiteSpace($where)) { $where = "(no invocation info)" }
        $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') monitor loop failed at ${stage}: $($_.Exception.Message)`n$where"
        Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    }
    $sleep = [int]$script:Config.logWatch.pollSeconds
    if ($sleep -lt 1) { $sleep = 1 }
    Start-Sleep -Seconds $sleep
}
} catch {
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') monitor fatal failed: $($_.Exception.Message)"
    Add-Content -LiteralPath (Join-Path $Root "logs\discord-watch.log") -Value $msg -Encoding UTF8
    throw
}








