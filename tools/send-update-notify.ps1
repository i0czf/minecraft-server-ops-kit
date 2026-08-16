param(
    [Parameter(Mandatory = $true)][string]$SummaryFile,
    [string]$ConfigPath = ".\tools\ops-config.json"
)

# ============================================================
#  发布更新通知脚本
#  读取 ops-config.json 中的 Discord/QQ 配置，把发布变更摘要
#  转发到 Discord webhook 和 QQ 群。
#  独立运行，不依赖 discord-watch.ps1。
# ============================================================

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# 强制启用 TLS 1.2（Discord API 要求；兼容旧版 Windows/.NET）
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
catch { Write-Host "[通知] 警告：无法设置 TLS 1.2，网络请求可能失败" }

$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

# ---------- 路径与配置 ----------

function Resolve-AnyPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

$configFull = Resolve-AnyPath $ConfigPath
if (-not (Test-Path -LiteralPath $configFull -PathType Leaf)) {
    Write-Host "[通知] 未找到 ops-config.json，跳过通知：$configFull"
    exit 0
}
$config = Get-Content -LiteralPath $configFull -Raw -Encoding UTF8 | ConvertFrom-Json

$summaryFull = Resolve-AnyPath $SummaryFile
if (-not (Test-Path -LiteralPath $summaryFull -PathType Leaf)) {
    Write-Host "[通知] 未找到变更摘要文件，跳过通知：$summaryFull"
    exit 0
}
$summary = (Get-Content -LiteralPath $summaryFull -Raw -Encoding UTF8).TrimEnd()

# 如果摘要为空（没有任何变更），不发通知
if ([string]::IsNullOrWhiteSpace($summary)) {
    Write-Host "[通知] 变更摘要为空，跳过通知。"
    exit 0
}

# ---------- 辅助函数 ----------

function Get-ConfigValue {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $Default
}

function Test-EventEnabled {
    param($Events, [string]$Name)
    if (-not $Events) { return $true }
    $prop = $Events.PSObject.Properties[$Name]
    if (-not $prop) { return $true }
    return [bool]$prop.Value
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

function Resolve-Java17 {
    $candidates = @(
        "C:\Program Files\Eclipse Adoptium\jdk-17.0.13.11-hotspot\bin\java.exe",
        "C:\Program Files\Eclipse Adoptium\jdk-17.0.12.7-hotspot\bin\java.exe",
        "C:\Program Files\Eclipse Adoptium\jdk-17.0.19.10-hotspot\bin\java.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        return (Join-Path $env:JAVA_HOME "bin\java.exe")
    }
    return "java.exe"
}

function Test-JavaAvailable {
    $java = Resolve-Java17
    try {
        $null = & $java -version 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Invoke-DiscordWebhookViaProxy {
    param(
        [Parameter(Mandatory = $true)][string]$Webhook,
        [Parameter(Mandatory = $true)][string]$Payload,
        [Parameter(Mandatory = $true)][string]$ProxyHost,
        [Parameter(Mandatory = $true)][int]$ProxyPort
    )

    Write-Host "  [Discord] 尝试使用 Java 代理发送..."

    # 检查 Java 是否可用
    if (-not (Test-JavaAvailable)) {
        Write-Host "  [Discord] Java 不可用，尝试使用 PowerShell 系统代理..."
        $success = Invoke-DiscordWebhookViaSystemProxy -Webhook $Webhook -Payload $Payload -ProxyHost $ProxyHost -ProxyPort $ProxyPort
        if (-not $success) { throw "系统代理发送失败" }
        return
    }

    # 检查是否有编译后的类文件
    $classDir = Join-Path $Root "tools\tmp\java-classes"
    $classFile = Join-Path $classDir "DiscordWebhookSender.class"
    $javaFile = Join-Path $Root "tools\DiscordWebhookSender.java"

    if (-not (Test-Path -LiteralPath $classFile)) {
        Write-Host "  [Discord] 未找到编译后的类文件，尝试编译 Java 源码..."
        try {
            New-Item -ItemType Directory -Force $classDir | Out-Null
            $java = Resolve-Java17
            $javacExe = $java -replace 'java\.exe$', 'javac.exe'
            $javacOutput = & $javacExe -encoding UTF-8 -cp $classDir -d $classDir $javaFile 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [Discord] Java 编译失败：$javacOutput"
                Write-Host "  [Discord] 回退到 PowerShell 系统代理方式..."
                $success = Invoke-DiscordWebhookViaSystemProxy -Webhook $Webhook -Payload $Payload -ProxyHost $ProxyHost -ProxyPort $ProxyPort
                if (-not $success) { throw "系统代理发送失败" }
                return
            }
            Write-Host "  [Discord] Java 编译成功"
        } catch {
            Write-Host "  [Discord] Java 编译异常：$($_.Exception.Message)"
            Write-Host "  [Discord] 回退到 PowerShell 系统代理方式..."
            $success = Invoke-DiscordWebhookViaSystemProxy -Webhook $Webhook -Payload $Payload -ProxyHost $ProxyHost -ProxyPort $ProxyPort
            if (-not $success) { throw "系统代理发送失败" }
            return
        }
    }

    $payloadFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllBytes($payloadFile, [Text.Encoding]::UTF8.GetBytes($Payload))
        $java = Resolve-Java17
        $output = & $java -cp $classDir DiscordWebhookSender $Webhook $ProxyHost $ProxyPort $payloadFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errorMsg = ($output | Out-String).Trim()
            Write-Host "  [Discord] Java 调用失败：$errorMsg"
            Write-Host "  [Discord] 回退到 PowerShell 系统代理方式..."
            $success = Invoke-DiscordWebhookViaSystemProxy -Webhook $Webhook -Payload $Payload -ProxyHost $ProxyHost -ProxyPort $ProxyPort
            if (-not $success) { throw "系统代理发送失败" }
        }
    } finally {
        Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DiscordWebhookViaSystemProxy {
    param(
        [Parameter(Mandatory = $true)][string]$Webhook,
        [Parameter(Mandatory = $true)][string]$Payload,
        [Parameter(Mandatory = $true)][string]$ProxyHost,
        [Parameter(Mandatory = $true)][int]$ProxyPort
    )

    Write-Host ("  [Discord] 使用 Invoke-RestMethod 代理发送（" + $ProxyHost + ":" + $ProxyPort + "）...")
    $proxyUri = "http://" + $ProxyHost + ":" + $ProxyPort

    try {
        $splat = @{
            Uri         = $Webhook
            Method      = "Post"
            ContentType = "application/json; charset=utf-8"
            Body        = $Payload
            Proxy       = $proxyUri
        }
        Invoke-RestMethod @splat | Out-Null
        Write-Host "  [Discord] 代理发送成功"
        return $true
    } catch {
        Write-Host "  [Discord] 代理发送失败：$($_.Exception.Message)"
        return $false
    }
}

# ---------- Discord 发送 ----------

function Send-Discord {
    param([string]$Content)
    $discord = $config.discord
    if (-not $discord -or -not (Get-ConfigValue $discord 'enabled' $false)) { return }
    $webhook = [string](Get-ConfigValue $discord 'webhookUrl' '')
    if ([string]::IsNullOrWhiteSpace($webhook)) { return }
    if (-not (Test-EventEnabled $discord.events 'update')) { return }

    # Discord 消息上限 2000 字符，留余量
    if ($Content.Length -gt 1900) {
        $Content = $Content.Substring(0, 1897) + "..."
    }

    $payload = @{ content = $Content } | ConvertTo-Json -Depth 4 -Compress
    $proxyHost = [string](Get-ConfigValue $discord 'proxyHost' '')
    $proxyPort = [int](Get-ConfigValue $discord 'proxyPort' 0)
    $useProxy = -not [string]::IsNullOrWhiteSpace($proxyHost) -and $proxyPort -gt 0

    $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [发布通知] Discord"
    try {
        if ($useProxy) {
            # 使用代理方式（优先 Java，失败则回退到系统代理）
            Invoke-DiscordWebhookViaProxy -Webhook $webhook -Payload $payload -ProxyHost $proxyHost -ProxyPort $proxyPort
            Write-Host "$logLine 发送成功。"
        } else {
            # 直接发送，不使用代理（PS 5.1 兼容：不用 TimeoutSec，改用 WebClient）
            Write-Host "  [Discord] 直接发送（无代理）..."
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("Content-Type", "application/json; charset=utf-8")
            $webClient.Headers.Add("User-Agent", "PortableServerKit-UpdateNotify/1.0")
            $response = $webClient.UploadString($webhook, "POST", $payload)
            Write-Host "$logLine 发送成功。"
        }
    } catch {
        Write-Host "$logLine 发送失败：$($_.Exception.Message)"
        # 不抛出异常，允许继续发送 QQ 通知
    }
}

# ---------- QQ 群发送 ----------

function Send-QQGroup {
    param([string]$Content)
    $qq = $config.qq
    if (-not $qq -or -not (Get-ConfigValue $qq 'enabled' $false)) { return }
    $groupRaw = Get-ConfigValue $qq 'groupId' ''
    $groupIds = @(Get-QQGroupIds -Raw $groupRaw)
    if ($groupIds.Count -eq 0) { return }
    if (-not (Test-EventEnabled $qq.events 'update')) { return }

    $onebotUrl = [string](Get-ConfigValue $qq 'onebotUrl' 'http://127.0.0.1:3001')

    # QQ 群消息不宜过长，截断到 1500 字符
    if ($Content.Length -gt 1500) {
        $Content = $Content.Substring(0, 1497) + "..."
    }

    $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [发布通知] QQ"
    $sent = 0
    foreach ($groupId in $groupIds) {
        try {
            $body = @{
                group_id = [Int64]$groupId
                message  = $Content
            } | ConvertTo-Json -Depth 4 -Compress
            $utf8 = New-Object System.Text.UTF8Encoding $false
            $bodyBytes = $utf8.GetBytes($body)

            # PS 5.1 兼容：用 WebClient 替代 Invoke-RestMethod（避免 TimeoutSec 不可用）
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("Content-Type", "application/json; charset=utf-8")
            $webClient.Headers.Add("User-Agent", "PortableServerKit-UpdateNotify/1.0")
            $respBytes = $webClient.UploadData("$onebotUrl/send_group_msg", "POST", $bodyBytes)
            $respText = [System.Text.Encoding]::UTF8.GetString($respBytes)
            if ($respText) {
                $resp = $respText | ConvertFrom-Json
                if ($null -ne $resp.retcode -and [int]$resp.retcode -ne 0) {
                    throw "OneBot retcode=$($resp.retcode) status=$($resp.status)"
                }
            }
            $sent++
            Write-Host "$logLine 群 $groupId 发送成功。"
        } catch {
            Write-Host "$logLine 群 $groupId 发送失败：$($_.Exception.Message)"
        }
    }
    Write-Host "$logLine 主群发送结果：$sent/$($groupIds.Count) 成功。"
}

# ---------- 发送通知 ----------

Write-Host "[通知] 开始发送更新通知..."
Send-Discord -Content $summary
Send-QQGroup -Content $summary
Write-Host "[通知] 通知发送完成。"
