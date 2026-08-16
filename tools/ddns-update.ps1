param(
    [string]$ConfigPath = ".\tools\ops-config.json",
    [switch]$Loop,
    [int]$IntervalMinutes = 0,
    [switch]$AsJson
)

# DNSPod DDNS 更新器：把 ops-config.json 里 ddns 配置的域名 A/AAAA 记录同步成本机当前公网 IP。
# - 双击「一键便携-同步DDNS解析.bat」或直接跑本脚本 = 立即同步一次；-Loop = 常驻轮询。
# - discord-watch.ps1 会在 ddns.enabled 时按周期在进程内调用本脚本（-AsJson），并把结果转发 Discord/QQ。
# - 查公网 IP 一律绕过系统代理直连：走 Clash 等代理会拿到代理出口 IP（2026-07-07 实锤），DDNS 会被写错。
# - 本文件必须保存为 UTF-8 带 BOM（Windows PowerShell 5 无 BOM 会按 GBK 解析中文导致语法错误）。

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '同步 DDNS 解析' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$script:DefaultIpv4Endpoints = @(
    "http://ip.3322.net",
    "https://4.ipw.cn",
    "https://ipv4.icanhazip.com",
    "https://api.ipify.org"
)
$script:DefaultIpv6Endpoints = @(
    "https://6.ipw.cn",
    "https://ipv6.icanhazip.com"
)

function Resolve-DdnsRootPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Write-DdnsLog {
    param([string]$Message, [switch]$Quiet)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    try {
        New-Item -ItemType Directory -Force (Join-Path $Root "logs") | Out-Null
        Add-Content -LiteralPath (Join-Path $Root "logs\ddns-update.log") -Value $line -Encoding UTF8
    } catch {}
    if (-not $Quiet) { Write-Host $Message }
}

function Get-MaskedToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return "(空)" }
    $parts = $Token.Split(",")
    if ($parts.Count -ge 2) { return ($parts[0] + ",****") }
    if ($Token.Length -le 4) { return "****" }
    return ($Token.Substring(0, 4) + "****")
}

function Invoke-DirectHttp {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = "GET",
        [string]$FormBody = "",
        [int]$TimeoutSec = 10
    )
    # Proxy = $null 强制直连；公网 IP 探测和 dnsapi.cn 都是国内直连快路径，绝不能被系统代理劫走。
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Proxy = $null
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = "portable-server-kit-ddns/1.0"
    $req.Method = $Method
    if ($Method -eq "POST") {
        $req.ContentType = "application/x-www-form-urlencoded; charset=utf-8"
        $bytes = [Text.Encoding]::UTF8.GetBytes($FormBody)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    $resp = $req.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $resp.Dispose() }
}

function Test-GlobalIpAddress {
    param([Parameter(Mandatory = $true)][System.Net.IPAddress]$Address)
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $Address.GetAddressBytes()
        if ($b[0] -eq 10) { return $false }
        if ($b[0] -eq 127) { return $false }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $false }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false } # CGNAT 100.64/10：运营商大内网，端口映射进不来
        return $true
    }
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($Address.IsIPv6LinkLocal -or $Address.IsIPv6SiteLocal -or [System.Net.IPAddress]::IsLoopback($Address)) { return $false }
        $b = $Address.GetAddressBytes()
        if (($b[0] -band 0xFE) -eq 0xFC) { return $false } # fc00::/7 ULA
        return $true
    }
    return $false
}

function Get-ObservedPublicIp {
    param(
        [Parameter(Mandatory = $true)][string[]]$Endpoints,
        [Parameter(Mandatory = $true)][ValidateSet("IPv4", "IPv6")][string]$Family
    )
    foreach ($endpoint in $Endpoints) {
        try {
            $text = (Invoke-DirectHttp -Uri ([string]$endpoint) -TimeoutSec 8).Trim()
            $addr = $null
            if (-not [System.Net.IPAddress]::TryParse($text, [ref]$addr)) { continue }
            if ($Family -eq "IPv4" -and $addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            if ($Family -eq "IPv6" -and $addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { continue }
            if (-not (Test-GlobalIpAddress -Address $addr)) { continue }
            return $addr.ToString()
        } catch { continue }
    }
    return ""
}

function Get-StableIpv6Address {
    param([string]$ObservedIp = "")
    # AAAA 应指向本机“稳定”IPv6 地址而不是出站临时地址：Windows 临时地址约一天换一次，
    # 用它当解析值会天天改 DNS。启发式：同为路由通告的全局地址里，PreferredLifetime 最长的
    # 就是稳定地址（临时地址首选生存期上限 24 小时）。拿不到再退回出站观测值。
    try {
        $candidates = @(Get-NetIPAddress -AddressFamily IPv6 -PrefixOrigin RouterAdvertisement -ErrorAction Stop | Where-Object {
            $_.AddressState -eq "Preferred" -and $_.PreferredLifetime -gt [TimeSpan]::Zero
        } | Where-Object {
            $addr = $null
            [System.Net.IPAddress]::TryParse($_.IPAddress, [ref]$addr) -and (Test-GlobalIpAddress -Address $addr)
        })
        if ($candidates.Count -gt 0) {
            $best = $candidates | Sort-Object PreferredLifetime -Descending | Select-Object -First 1
            return ([System.Net.IPAddress]::Parse($best.IPAddress)).ToString()
        }
    } catch {}
    return $ObservedIp
}

function Invoke-DnspodApi {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][hashtable]$Fields
    )
    $pairs = New-Object System.Collections.Generic.List[string]
    $pairs.Add("login_token=" + [Uri]::EscapeDataString([string]$script:DdnsConfig.loginToken))
    $pairs.Add("format=json")
    $pairs.Add("lang=cn")
    foreach ($key in $Fields.Keys) {
        $pairs.Add([Uri]::EscapeDataString([string]$key) + "=" + [Uri]::EscapeDataString([string]$Fields[$key]))
    }
    $body = [string]::Join("&", $pairs.ToArray())
    $raw = Invoke-DirectHttp -Uri ("https://dnsapi.cn/" + $Action) -Method POST -FormBody $body -TimeoutSec 12
    $data = $raw | ConvertFrom-Json
    return $data
}

function Sync-DnspodRecord {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("A", "AAAA")][string]$RecordType,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $domain = [string]$script:DdnsConfig.domain
    $subDomain = [string]$script:DdnsConfig.subDomain
    if ([string]::IsNullOrWhiteSpace($subDomain)) { $subDomain = "@" }
    $ttl = 600
    if ($script:DdnsConfig.PSObject.Properties["ttl"] -and [int]$script:DdnsConfig.ttl -gt 0) { $ttl = [int]$script:DdnsConfig.ttl }

    $list = Invoke-DnspodApi -Action "Record.List" -Fields @{ domain = $domain; sub_domain = $subDomain; record_type = $RecordType }
    $code = [string]$list.status.code
    $records = @()
    if ($code -eq "1") {
        $records = @($list.records)
    } elseif ($code -ne "10") {
        # code 10 = 记录列表为空（正常，走新建）；其余都是真错误（token 无效/域名不在账号下等）
        throw ("Record.List 失败（code=" + $code + "）：" + [string]$list.status.message)
    }

    if ($records.Count -eq 0) {
        $create = Invoke-DnspodApi -Action "Record.Create" -Fields @{
            domain = $domain; sub_domain = $subDomain; record_type = $RecordType
            record_line_id = "0"; value = $Value; ttl = [string]$ttl
        }
        if ([string]$create.status.code -ne "1") {
            throw ("Record.Create 失败（code=" + [string]$create.status.code + "）：" + [string]$create.status.message)
        }
        return @{ type = $RecordType; action = "created"; old = ""; new = $Value }
    }

    # 优先管理默认线路的记录；找不到就用第一条（多线路场景只动一条，不越权清理）
    $target = $records | Where-Object { [string]$_.line_id -eq "0" } | Select-Object -First 1
    if (-not $target) { $target = $records | Select-Object -First 1 }
    $oldValue = [string]$target.value
    if ($oldValue -eq $Value) {
        return @{ type = $RecordType; action = "none"; old = $oldValue; new = $Value }
    }

    $modify = Invoke-DnspodApi -Action "Record.Modify" -Fields @{
        domain = $domain; record_id = [string]$target.id; sub_domain = $subDomain
        record_type = $RecordType; record_line_id = [string]$target.line_id; value = $Value; ttl = [string]$ttl
    }
    if ([string]$modify.status.code -ne "1") {
        throw ("Record.Modify 失败（code=" + [string]$modify.status.code + "）：" + [string]$modify.status.message)
    }
    return @{ type = $RecordType; action = "updated"; old = $oldValue; new = $Value }
}

function Invoke-DdnsSyncOnce {
    $result = @{ ok = $true; ip4 = ""; ip6 = ""; changes = @(); errors = @(); notes = @() }

    $host4Name = [string]$script:DdnsConfig.subDomain
    if ([string]::IsNullOrWhiteSpace($host4Name) -or $host4Name -eq "@") {
        $fqdn = [string]$script:DdnsConfig.domain
    } else {
        $fqdn = $host4Name + "." + [string]$script:DdnsConfig.domain
    }

    $update4 = $true
    if ($script:DdnsConfig.PSObject.Properties["updateIpv4"]) { $update4 = [bool]$script:DdnsConfig.updateIpv4 }
    $update6 = $false
    if ($script:DdnsConfig.PSObject.Properties["updateIpv6"]) { $update6 = [bool]$script:DdnsConfig.updateIpv6 }

    $endpoints4 = $script:DefaultIpv4Endpoints
    if ($script:DdnsConfig.PSObject.Properties["ipv4Endpoints"] -and $script:DdnsConfig.ipv4Endpoints) { $endpoints4 = [string[]]$script:DdnsConfig.ipv4Endpoints }
    $endpoints6 = $script:DefaultIpv6Endpoints
    if ($script:DdnsConfig.PSObject.Properties["ipv6Endpoints"] -and $script:DdnsConfig.ipv6Endpoints) { $endpoints6 = [string[]]$script:DdnsConfig.ipv6Endpoints }

    if ($update4) {
        $ip4 = Get-ObservedPublicIp -Endpoints $endpoints4 -Family IPv4
        $result.ip4 = $ip4
        if ([string]::IsNullOrWhiteSpace($ip4)) {
            $result.ok = $false
            $result.errors += "未能获取本机公网 IPv4（所有探测源都失败，或出口是内网/CGNAT 地址）。"
        } else {
            try {
                $change = Sync-DnspodRecord -RecordType "A" -Value $ip4
                if ($change.action -ne "none") { $result.changes += $change }
                Write-DdnsLog ("A 记录 " + $fqdn + "：" + $change.action + "（" + $ip4 + "）") -Quiet
            } catch {
                $result.ok = $false
                $result.errors += ("A 记录同步失败：" + $_.Exception.Message)
            }
        }
    }

    if ($update6) {
        $observed6 = Get-ObservedPublicIp -Endpoints $endpoints6 -Family IPv6
        $ip6 = Get-StableIpv6Address -ObservedIp $observed6
        $result.ip6 = $ip6
        if ([string]::IsNullOrWhiteSpace($ip6)) {
            # 家宽 IPv6 说没就没（光猫/路由器改桥接、运营商关 PD 都会导致），只记备注不算失败
            $result.notes += "本机当前没有全局 IPv6 地址，跳过 AAAA 记录。"
        } else {
            try {
                $change = Sync-DnspodRecord -RecordType "AAAA" -Value $ip6
                if ($change.action -ne "none") { $result.changes += $change }
                Write-DdnsLog ("AAAA 记录 " + $fqdn + "：" + $change.action + "（" + $ip6 + "）") -Quiet
            } catch {
                $result.ok = $false
                $result.errors += ("AAAA 记录同步失败：" + $_.Exception.Message)
            }
        }
    }

    # 人类可读输出
    if ($result.ip4) { Write-Host ("当前公网 IPv4：" + $result.ip4) }
    if ($result.ip6) { Write-Host ("当前稳定 IPv6：" + $result.ip6) }
    foreach ($change in $result.changes) {
        if ($change.action -eq "created") {
            $line = "[DDNS] 已新建 " + $change.type + " 记录 " + $fqdn + " -> " + $change.new
        } else {
            $line = "[DDNS] 已更新 " + $change.type + " 记录 " + $fqdn + "：" + $change.old + " -> " + $change.new
        }
        Write-DdnsLog $line
    }
    if ($result.changes.Count -eq 0 -and $result.errors.Count -eq 0) {
        Write-Host ("[DDNS] " + $fqdn + " 解析已是最新，无需更新。")
    }
    foreach ($note in $result.notes) { Write-Host ("[提示] " + $note) }
    foreach ($err in $result.errors) { Write-DdnsLog ("[DDNS] " + $err) }

    return $result
}

function Write-DdnsJsonLine {
    param([Parameter(Mandatory = $true)]$Result)
    # 机器可读结果行：discord-watch 捕获输出流解析这一行转发通知。
    # 注意：必须在脚本顶层调用（函数内 Write-Output 会被 $x = 函数调用 捕获吞掉，2026-07-10 实测）。
    Write-Output ("DDNSJSON:" + (@{
        ok = $Result.ok; ip4 = $Result.ip4; ip6 = $Result.ip6
        changes = @($Result.changes); errors = @($Result.errors); notes = @($Result.notes)
    } | ConvertTo-Json -Depth 5 -Compress))
}

# ---- 主流程 ----
# 重要：discord-watch 用 & 调用本脚本（-AsJson）。PowerShell 的 exit 会结束整个宿主进程，
# 从而把日志监控一起干掉——表现就是「监控跑约一个 DDNS 周期（默认 5 分钟）就挂」
# （2026-08-06 对照 child 日志：每次恰 1~2 次 DDNS 输出后进程没了）。
# 被 -AsJson 嵌入调用时只能 return / 写 DDNSJSON，绝不能 exit。
function Exit-DdnsOrReturn {
    param([int]$Code = 0, [string]$JsonError = '')
    if ($AsJson) {
        if ($JsonError) {
            Write-Output ("DDNSJSON:" + (@{
                ok = $false; ip4 = ''; ip6 = ''; changes = @(); errors = @($JsonError); notes = @()
            } | ConvertTo-Json -Depth 4 -Compress))
        }
        return
    }
    exit $Code
}

$configFull = Resolve-DdnsRootPath $ConfigPath
if (-not (Test-Path -LiteralPath $configFull)) {
    Write-Host "[跳过] 找不到运维配置：$configFull"
    Write-Host "请先运行「一键便携-初始化配置」生成 tools\ops-config.json。"
    Exit-DdnsOrReturn -Code 1 -JsonError "找不到运维配置"
    return
}
$opsConfig = Get-Content -LiteralPath $configFull -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $opsConfig.PSObject.Properties["ddns"]) {
    Write-Host "[跳过] ops-config.json 里还没有 ddns 配置段。"
    Write-Host "参照 tools\portable-ops-config.example.json 的 ddns 段补上：DNSPod 控制台（console.dnspod.cn）创建 API Token，"
    Write-Host "把「ID,Token」填进 loginToken，domain 填主域名（如 example.com），subDomain 填记录前缀（如 mc）。"
    Exit-DdnsOrReturn -Code 1 -JsonError "缺少 ddns 配置段"
    return
}
$script:DdnsConfig = $opsConfig.ddns
if (-not [bool]$script:DdnsConfig.enabled) {
    Write-Host "[跳过] ddns.enabled = false，未开启 DDNS 自动同步。"
    Write-Host "在 tools\ops-config.json 的 ddns 段把 enabled 改为 true 并填好 loginToken 即可启用。"
    Exit-DdnsOrReturn -Code 1 -JsonError "ddns.enabled=false"
    return
}
if ([string]::IsNullOrWhiteSpace([string]$script:DdnsConfig.loginToken) -or [string]$script:DdnsConfig.loginToken -notmatch ",") {
    Write-Host "[失败] ddns.loginToken 未配置或格式不对（应为 DNSPod 的「ID,Token」，当前：$(Get-MaskedToken ([string]$script:DdnsConfig.loginToken))）。"
    Write-Host "到 console.dnspod.cn -> 用户中心 -> API 密钥 创建后填入。"
    Exit-DdnsOrReturn -Code 2 -JsonError "loginToken 无效"
    return
}
if ([string]::IsNullOrWhiteSpace([string]$script:DdnsConfig.domain)) {
    Write-Host "[失败] ddns.domain 未配置（填 DNSPod 托管的主域名，例如 example.com）。"
    Exit-DdnsOrReturn -Code 2 -JsonError "domain 未配置"
    return
}

if ($Loop) {
    $interval = $IntervalMinutes
    if ($interval -lt 1 -and $script:DdnsConfig.PSObject.Properties["checkMinutes"]) { $interval = [int]$script:DdnsConfig.checkMinutes }
    if ($interval -lt 1) { $interval = 5 }
    Write-DdnsLog "[DDNS] 常驻模式启动，每 $interval 分钟同步一次（域名：$($script:DdnsConfig.domain)，token：$(Get-MaskedToken ([string]$script:DdnsConfig.loginToken))）。"
    while ($true) {
        try { Invoke-DdnsSyncOnce | Out-Null } catch { Write-DdnsLog ("[DDNS] 本轮同步异常：" + $_.Exception.Message) }
        Start-Sleep -Seconds ($interval * 60)
    }
} else {
    $once = Invoke-DdnsSyncOnce
    if ($AsJson) {
        Write-DdnsJsonLine -Result $once
        # 嵌入调用：返回给 discord-watch，不要 exit
        return
    }
    if ($once.ok) { exit 0 } else { exit 2 }
}
