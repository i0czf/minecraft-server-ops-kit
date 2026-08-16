param(
    [string]$PublishDir = "",
    [int]$Port = 0,
    [string]$PublicHost = "",
    [string]$Bind = "::",
    [string]$CertFile = "",
    [string]$KeyFile = ""
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '整合包更新服务 —— 玩家同步的下载源；关闭此窗口会停止更新服务' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

# 未显式传参时优先读 tools\portable-pack.json；公开工具包内不预设任何私人域名/目录。
$packConfig = $null
$packConfigPath = Join-Path $PSScriptRoot 'portable-pack.json'
if (Test-Path -LiteralPath $packConfigPath -PathType Leaf) {
    try { $packConfig = Get-Content -LiteralPath $packConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $packConfig = $null }
}
if ([string]::IsNullOrWhiteSpace($PublishDir)) { $PublishDir = [string]$packConfig.publishDir }
if ([string]::IsNullOrWhiteSpace($PublishDir)) { $PublishDir = '.\modpack-public\portable' }
if ($Port -le 0) { $Port = [int]$packConfig.update.port }
if ($Port -le 0) { $Port = 18088 }
if ([string]::IsNullOrWhiteSpace($PublicHost)) { $PublicHost = [string]$packConfig.update.host }
if ([string]::IsNullOrWhiteSpace($PublicHost) -or $PublicHost -match 'CHANGE-ME') {
    $PublicHost = '127.0.0.1'
    Write-Host "提示：尚未在 tools\portable-pack.json 里配置对外域名（update.host），玩家包更新地址将暂用 127.0.0.1，仅本机可用。"
}
# HTTPS 可选：-CertFile/-KeyFile 或 portable-pack.json 的 update.certFile/update.keyFile。
# 不配置则维持 HTTP，行为与旧版完全一致。
if ([string]::IsNullOrWhiteSpace($CertFile)) { $CertFile = [string]$packConfig.update.certFile }
if ([string]::IsNullOrWhiteSpace($KeyFile)) { $KeyFile = [string]$packConfig.update.keyFile }
$useTls = $false
if (-not [string]::IsNullOrWhiteSpace($CertFile)) {
    if (Test-Path -LiteralPath $CertFile -PathType Leaf) {
        $useTls = $true
        if (-not [string]::IsNullOrWhiteSpace($KeyFile) -and -not (Test-Path -LiteralPath $KeyFile -PathType Leaf)) {
            throw "keyFile 不存在：$KeyFile"
        }
    } else {
        Write-Host "警告：certFile 不存在，本次回退为 HTTP：$CertFile"
    }
}

function Get-Cn {
    param([Parameter(Mandatory = $true)][string]$Base64)
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64))
}

function Write-Cn {
    param(
        [Parameter(Mandatory = $true)][string]$Base64,
        [object[]]$Args = @()
    )
    $text = Get-Cn -Base64 $Base64
    if ($Args.Count -gt 0) {
        $text = [string]::Format($text, $Args)
    }
    Write-Host $text
}

$publish = if ([System.IO.Path]::IsPathRooted($PublishDir)) {
    [System.IO.Path]::GetFullPath($PublishDir)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $Root $PublishDir))
}

if (-not $publish.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to serve outside server root: $publish"
}
if (-not (Test-Path -LiteralPath (Join-Path $publish "server-manifest.json"))) {
    Write-Host ''
    Write-Host "[便携] 更新源还没有内容：$publish 里没有 server-manifest.json。" -ForegroundColor Red
    Write-Host '这是新服务端的正常状态，先发布一次就好：' -ForegroundColor Yellow
    Write-Host '  1. 确认已设置主分发客户端（面板点「选择分发客户端目录」或跑初始化配置向导）；' -ForegroundColor Yellow
    Write-Host '  2. 面板「④ 发布与拉新」点「仅发布更新」（或双击 一键脚本\一键便携-仅发布更新.bat）；' -ForegroundColor Yellow
    Write-Host '  3. 发布完成后再回来点「开启更新服务」。' -ForegroundColor Yellow
    exit 1
}

$tokenPath = Join-Path $Root ".update-server-token"
if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
    $token = (Get-Content -LiteralPath $tokenPath -Raw -Encoding ASCII).Trim()
} else {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = "u-" + ([System.BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant())
    Set-Content -LiteralPath $tokenPath -Value $token -Encoding ASCII
}
if ($token -notmatch "^[-A-Za-z0-9_]{24,80}$") {
    throw ([string]::Format((Get-Cn -Base64 "5pu05paw5pyN5Yqh5Y+j5Luk5qC85byP5byC5bi477yaezB9"), $tokenPath))
}

$manifestPath = "$token/server-manifest.json"
$scheme = if ($useTls) { 'https' } else { 'http' }
$localUrl = "${scheme}://127.0.0.1:$Port/$manifestPath"
$publicUrl = "${scheme}://$PublicHost`:$Port/$manifestPath"
if ($useTls) { Write-Host "HTTPS 已启用，证书：$CertFile" }

Write-Cn -Base64 "576k5bOm6YeN55SfIDMuMiDmm7TmlrDmnI3liqHnm67lvZXvvJo="
Write-Host "  $publish"
Write-Host ""
Write-Cn -Base64 "5a6J5YWo5qih5byP77ya"
Write-Cn -Base64 "ICDlt7LlkK/nlKjpmo/mnLrorr/pl67ot6/lvoTvvJvmnKrluKbov5nkuKrot6/lvoTnmoTmiavmj4/or7fmsYLkvJrov5Tlm54gNDA044CC"
Write-Cn -Base64 "ICDlj6Pku6Tmlofku7bvvJp7MH0=" -Args @($tokenPath)
Write-Host ""
Write-Cn -Base64 "5pys5py65rWL6K+V5Zyw5Z2A77ya"
Write-Host "  $localUrl"
Write-Host ""
Write-Cn -Base64 "546p5a625YyFIFRGQ1ItdXBkYXRlLXVybC50eHQg5bqU5aGr5YaZ77ya"
Write-Host "  $publicUrl"
Write-Host ""
Write-Cn -Base64 "546p5a625pu05paw5pe26K+35L+d5oyB6L+Z5Liq56qX5Y+j5omT5byA44CC5oyJIEN0cmwrQyDlj6/ku6XlgZzmraLjgII="
Write-Host ""
Write-Host "提示：这个服务会实时读取 modpack-public\hmcl-serverpack；后续选项 1 只发布更新时，保持本窗口打开即可，不用重启。"
Write-Host ""
Write-Cn -Base64 "5rOo5oSP77ya5pys5pW05ZCI5YyF6buY6K6k5L2/55SoIDE4MDg4IOerr+WPo++8jOmBv+WFjeWSjOaXp+S4gOWRqOebriA4MDg4IOabtOaWsOacjeWKoeWGsueqgeOAgg=="
Write-Cn -Base64 "5rOo5oSP77ya6ZW/5oyC5pe26K+35Y+q6L2s5Y+RIDE4MDg4L1RDUO+8m+S4jeimgeW8gOaUviBSRFDjgIFSQ09OIOaIluaWh+S7tuWFseS6q+err+WPo+OAgg=="

$serverScript = Join-Path $PSScriptRoot "secure-update-server.py"
$serverArgs = @('--directory', $publish, '--port', $Port, '--bind', $Bind, '--token', $token)
# 工具包自更新公开通道：生成精简工具包时会发布到这里，外发的工具包用它做「检查更新」
$kitChannel = Join-Path $Root 'modpack-public\kit-update'
# 服务可能早于第一次精简工具包构建启动；若只在目录已存在时才注册路由，
# 后续即使文件生成了，/kit/ 仍会一直 404 到人工重启。启动时先创建空目录并始终注册。
New-Item -ItemType Directory -Path $kitChannel -Force | Out-Null
$serverArgs += @('--kitdir', $kitChannel)
Write-Host "工具包更新通道（无令牌公开）：${scheme}://$PublicHost`:$Port/kit/portable-server-kit-lite-latest.zip"
Write-Host ""
if ($useTls) {
    $serverArgs += @('--certfile', $CertFile)
    if (-not [string]::IsNullOrWhiteSpace($KeyFile)) { $serverArgs += @('--keyfile', $KeyFile) }
}
python $serverScript @serverArgs

