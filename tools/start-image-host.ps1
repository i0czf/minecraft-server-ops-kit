param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root 'tools\ops-config.json'
$ServerPath = Join-Path $Root 'tools\image-host-server.py'
$PidPath = Join-Path $Root 'tmp\image-host.pid'
$LogDir = Join-Path $Root 'logs'
$StdOutPath = Join-Path $LogDir 'image-host.out.log'
$StdErrPath = Join-Path $LogDir 'image-host.err.log'

function Stop-ForPause {
    if (-not $NoPause) { pause }
}

function Get-ImageHostStatusResponse {
    param([Parameter(Mandatory = $true)][int]$Port)
    try {
        return Invoke-WebRequest -UseBasicParsing -Uri ("http://127.0.0.1:{0}/status" -f $Port) -TimeoutSec 2
    } catch {
        return $null
    }
}

function Test-ImageHostStatusResponse {
    param($Response)
    if (-not $Response) { return $false }
    try {
        $payload = $Response.Content | ConvertFrom-Json
        $native = ($payload.ok -eq $true -and [string]$payload.service -eq 'image-host')
        # 兼容仓库外已经运行的 MCImageHost/2.x：它同样使用 /upload、token、file 和 /i/<name> 协议。
        $legacy = ($payload.uploads_enabled -eq $true -and [string]$Response.Headers['Server'] -match '(?i)MCImageHost')
        return ($native -or $legacy)
    } catch {
        return $false
    }
}

try {
    if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) {
        throw "未找到 $ServerPath"
    }

    $config = $null
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $imageHost = if ($config -and $config.imageHost) { $config.imageHost } else { $null }
    $bindHost = if ($imageHost -and [string]$imageHost.bindHost) { [string]$imageHost.bindHost } else { '127.0.0.1' }
    $port = if ($imageHost -and $imageHost.port) { [int]$imageHost.port } else { 38080 }
    $maxBytes = if ($imageHost -and $imageHost.maxBytes) { [int]$imageHost.maxBytes } else { 20971520 }
    $hostRoot = if ($imageHost -and [string]$imageHost.root) { [string]$imageHost.root } else { 'tmp\image-host' }
    $tokenFile = if ($imageHost -and [string]$imageHost.tokensFile) { [string]$imageHost.tokensFile } else { 'tools\image-host-tokens.json' }
    $hostRootPath = if ([System.IO.Path]::IsPathRooted($hostRoot)) { $hostRoot } else { Join-Path $Root $hostRoot }
    $tokenFilePath = if ([System.IO.Path]::IsPathRooted($tokenFile)) { $tokenFile } else { Join-Path $Root $tokenFile }
    New-Item -ItemType Directory -Force -Path $hostRootPath, $LogDir, (Join-Path $Root 'tmp') | Out-Null

    $status = Get-ImageHostStatusResponse -Port $port
    if (Test-ImageHostStatusResponse -Response $status) {
        Write-Host "[图床] 已在运行，端口 $port。"
        exit 0
    }
    if ($status) {
        throw "端口 $port 已被其它 HTTP 服务占用，且 /status 不是本机图床；为避免串传，已拒绝启动。"
    }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    $pythonArgs = @()
    if (-not $python) {
        $python = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($python) { $pythonArgs += '-3' }
    }
    if (-not $python) {
        throw '未找到 Python 3（python.exe 或 py.exe），无法启动本机图床。'
    }

    $pythonArgs += @(
        '-u', $ServerPath,
        '--bind', $bindHost,
        '--port', [string]$port,
        '--root', $hostRootPath,
        '--token-file', $tokenFilePath,
        '--pid-file', $PidPath,
        '--max-bytes', [string]$maxBytes
    )
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $pythonArgs += @('--config', $ConfigPath)
    }

    $process = Start-Process -FilePath $python.Source `
        -WorkingDirectory $Root `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath `
        -ArgumentList $pythonArgs

    Start-Sleep -Milliseconds 700
    if ($process.HasExited) {
        throw "图床进程启动后退出（exit=$($process.ExitCode)），请查看 $StdErrPath"
    }
    $status = Get-ImageHostStatusResponse -Port $port
    if (-not (Test-ImageHostStatusResponse -Response $status)) {
        throw "图床进程已启动但 /status 身份校验失败，请查看 $StdErrPath"
    }
    if (-not (Test-Path -LiteralPath $tokenFilePath -PathType Leaf) -and
        -not ($imageHost -and [string]$imageHost.token)) {
        Write-Warning "未找到图床令牌文件 $tokenFilePath；上传会返回 401。请复制 image-host-tokens.example.json 并修改令牌。"
    }
    Write-Host "[图床] 已启动，监听 $bindHost`:$port，静态地址 /i/<sha256>.<ext>。"
    exit 0
} catch {
    Write-Host "[图床] 启动失败：$($_.Exception.Message)" -ForegroundColor Red
    Stop-ForPause
    exit 1
}
