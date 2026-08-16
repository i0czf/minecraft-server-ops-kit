param(
    [switch]$Restart,
    [switch]$Once,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
$ConfigPath = Join-Path $Root 'tools\ops-config.json'
$ScriptPath = Join-Path $Root 'tools\mod-release-manager.py'
$PidPath = Join-Path $Root 'tmp\mod-release-manager.pid'
$ManagerLockPath = Join-Path $Root 'tmp\mod-release\manager.lock'
$StarterLogPath = Join-Path $Root 'logs\mod-release-manager-starter.log'
$OutPath = Join-Path $Root 'logs\mod-release-manager.child.log'
$ErrPath = Join-Path $Root 'logs\mod-release-manager.child.err.log'

function Write-ManagerLog([string]$Message) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $StarterLogPath) | Out-Null
    Add-Content -LiteralPath $StarterLogPath -Value ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message") -Encoding UTF8
    Write-Host "[mod-release] $Message"
}

function Get-ManagerProcess([int]$ProcessId) {
    if ($ProcessId -le 0) { return $null }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($proc -and [string]$proc.CommandLine -match 'mod-release-manager\.py') { return $proc }
    # 以隐藏方式启动的 Python 在部分 Windows 权限边界下不会暴露
    # CommandLine/ExecutablePath；PID 文件仍是本管理器的受控身份凭据。
    $basic = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($basic -and $basic.ProcessName -match '^python(?:\.exe)?$') {
        try {
            if (Test-Path -LiteralPath $PidPath -PathType Leaf) {
                $pidStamp = (Get-Item -LiteralPath $PidPath -ErrorAction Stop).LastWriteTime
                if ($basic.StartTime -gt $pidStamp.AddSeconds(60)) { return $null }
            }
        } catch { return $null }
        return $basic
    }
    return $null
}

function Stop-StaleManagerFromLock {
    # 配置/脚本更新后，旧管理器可能仍持有 manager.lock，但由于权限边界
    # PID 文件已被失败的启动尝试清掉。只在锁 PID 是 Python、且启动早于
    # 最近配置/脚本修改，并有 starter 日志佐证时处理，避免误杀其它 Python。
    if (-not (Test-Path -LiteralPath $ManagerLockPath -PathType Leaf)) { return }
    $raw = (Get-Content -LiteralPath $ManagerLockPath -Raw -ErrorAction SilentlyContinue).Trim()
    $lockPid = 0
    if (-not [int]::TryParse($raw, [ref]$lockPid) -or $lockPid -le 0 -or $lockPid -eq $PID) { return }
    $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.ProcessName -notmatch '^python(?:\.exe)?$') { return }
    try { $started = $proc.StartTime } catch { return }
    $changed = @($ConfigPath, $ScriptPath) | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and ((Get-Item -LiteralPath $_).LastWriteTime -gt $started)
    }
    if (-not $changed) { return }
    $starterMatch = Select-String -LiteralPath $StarterLogPath -Pattern ("manager started PID=" + $lockPid) -ErrorAction SilentlyContinue
    if (-not $starterMatch) { return }
    Write-ManagerLog "stale manager lock after config/script update; stopping PID=$lockPid"
    try {
        Stop-Process -Id $lockPid -Force -ErrorAction Stop
    } catch {
        throw "cannot stop stale mod-release manager PID=${lockPid}: $($_.Exception.Message)"
    }
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
            Write-ManagerLog "stopped stale mod-release manager PID=$lockPid"
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "stale mod-release manager PID=$lockPid did not exit in time"
}

function Stop-Manager {
    if (-not (Test-Path -LiteralPath $PidPath -PathType Leaf)) { return }
    $id = 0
    try { [void][int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$id) } catch { }
    $proc = Get-ManagerProcess $id
    if ($proc) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        Write-ManagerLog "已停止旧发布管理器 PID=$id"
    }
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-ManagerLog 'missing tools\ops-config.json; skipped'
    exit 0
}
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    Write-ManagerLog 'missing tools\mod-release-manager.py; skipped'
    exit 0
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cfg.modRelease -or -not [bool]$cfg.modRelease.enabled) {
    Write-ManagerLog 'modRelease.enabled=false; staying disabled'
    exit 0
}

if ($Restart) { Stop-Manager }
Stop-StaleManagerFromLock
$existingId = 0
if (Test-Path -LiteralPath $PidPath -PathType Leaf) {
    try { [void][int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$existingId) } catch { }
    if (Get-ManagerProcess $existingId) {
        Write-ManagerLog "manager already running PID=$existingId"
        exit 0
    }
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

$python = $null
try { $python = (Get-Command python.exe -ErrorAction Stop).Source } catch { }
if (-not $python) {
    try { $python = (Get-Command py.exe -ErrorAction Stop).Source } catch { }
}
if (-not $python) {
    Write-ManagerLog 'python.exe/py.exe not found; cannot start manager'
    exit 1
}

$pythonArgs = @()
if ([IO.Path]::GetFileName($python).ToLowerInvariant() -eq 'py.exe') { $pythonArgs += '-3' }
$pythonArgs += @('-u', $ScriptPath, '--config', $ConfigPath)
if ($Once) { $pythonArgs += '--once' }
if ($DryRun) { $pythonArgs += '--dry-run' }
$proc = Start-Process -FilePath $python -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $OutPath -RedirectStandardError $ErrPath `
    -ArgumentList ($pythonArgs | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' })
Set-Content -LiteralPath $PidPath -Value $proc.Id -Encoding ASCII
Write-ManagerLog "manager started PID=$($proc.Id) mode=$($cfg.modRelease.mode)"
exit 0
