param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$PidPath = Join-Path $Root 'tmp\portable-web-panel.pid'

try {
    if (-not (Test-Path -LiteralPath $PidPath -PathType Leaf)) {
        Write-Host '[Web] 没有找到 Web 面板 PID 文件，可能已经停止。' -ForegroundColor Yellow
        exit 0
    }
    $panelPid = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$panelPid) -or $panelPid -le 0) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        throw 'Web 面板 PID 文件格式错误，已清理。'
    }
    $process = Get-Process -Id $panelPid -ErrorAction SilentlyContinue
    if (-not $process) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        Write-Host '[Web] Web 面板进程已经退出，已清理旧 PID 文件。' -ForegroundColor Yellow
        exit 0
    }
    $cmdline = ''
    try { $cmdline = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$panelPid" -ErrorAction Stop).CommandLine } catch { }
    $owned = ($cmdline -match '(?i)portable-web-panel\.ps1')
    if (-not $owned) {
        # 某些 Windows 安全策略会禁止普通用户读取自身 CIM CommandLine。
        # 退回到「PowerShell 进程 + PID 文件写入时间」判据，避免 PID 被回收后误杀别的进程。
        try {
            $pidStamp = (Get-Item -LiteralPath $PidPath -ErrorAction Stop).LastWriteTime
            $owned = ($process.ProcessName -match '(?i)^(powershell|pwsh)$' -and $process.StartTime -le $pidStamp.AddSeconds(60))
        } catch { $owned = $false }
    }
    if (-not $owned) {
        throw "拒绝停止 PID=$panelPid：PID 文件对应的进程不是 portable-web-panel.ps1。"
    }
    Stop-Process -Id $panelPid -Force -ErrorAction Stop
    Wait-Process -Id $panelPid -Timeout 5 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    Write-Host "[Web] 已停止 Web 面板，PID=$panelPid。" -ForegroundColor Green
} catch {
    Write-Host ('[Web] 停止失败：' + $_.Exception.Message) -ForegroundColor Red
    if (-not $NoPause) { Read-Host '按回车关闭窗口' | Out-Null }
    exit 1
}
