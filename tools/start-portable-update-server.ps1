param(
    [string]$ConfigPath = ".\tools\portable-pack.json",
    [int]$Port = 0,
    [string]$PublicHost = "",
    [string]$Bind = "::"
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '整合包更新服务 —— 玩家同步的下载源；关闭此窗口会停止更新服务' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

function Resolve-AnyPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

$configFull = Resolve-AnyPath $ConfigPath
if (-not (Test-Path -LiteralPath $configFull -PathType Leaf)) {
    throw "缺少便携配置：$configFull。请先复制 tools\portable-pack.example.json 为 tools\portable-pack.json。"
}

$config = Get-Content -LiteralPath $configFull -Raw -Encoding UTF8 | ConvertFrom-Json
$publishDir = [string]$config.publishDir
if ([string]::IsNullOrWhiteSpace($publishDir)) { $publishDir = '.\modpack-public\portable' }
if ($Port -le 0) { $Port = [int]$config.update.port }
if ($Port -le 0) { $Port = 18088 }
if ([string]::IsNullOrWhiteSpace($PublicHost)) { $PublicHost = [string]$config.update.host }
if ([string]::IsNullOrWhiteSpace($PublicHost)) { $PublicHost = '127.0.0.1' }

Write-Host "[便携] 配置文件：$configFull"
Write-Host "[便携] 发布目录：$publishDir"
Write-Host "[便携] 对外主机：$PublicHost"
Write-Host "[便携] 端口：$Port"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\start-update-server.ps1') -PublishDir $publishDir -Port $Port -PublicHost $PublicHost -Bind $Bind
exit $LASTEXITCODE


