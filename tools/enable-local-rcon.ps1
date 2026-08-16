param(
    [int]$Port = 25575,
    [switch]$RotatePassword,
    [switch]$Disable,
    [switch]$DryRun,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '启用/修复本地 RCON' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
$PropsPath = Join-Path $Root "server.properties"

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch {}

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function New-StrongRconPassword([int]$Length = 32) {
    $chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789_-".ToCharArray()
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $out = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        [void]$out.Append($chars[[int]$b % $chars.Length])
    }
    return $out.ToString()
}

function Test-WeakRconPassword([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $s = $Value.Trim()
    if ($s.Length -lt 16) { return $true }
    if ($s -match '(?i)^(change-?me|replace-?me|password|pass|admin|rcon|minecraft|server|123456|your-password)$') { return $true }
    if ($s -match '(?i)example|CHANGE-ME|TODO') { return $true }
    return $false
}

function Get-PropValue([string[]]$Lines, [string]$Key) {
    foreach ($line in $Lines) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*!') { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $line.Substring(0, $eq).Trim().Trim([char]0xFEFF)
        if ([string]::Equals($k, $Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $line.Substring($eq + 1).Trim()
        }
    }
    return ''
}

function Set-PropValue([System.Collections.Generic.List[string]]$Lines, [string]$Key, [string]$Value) {
    $changed = $false
    $found = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = [string]$Lines[$i]
        if ($line -match '^\s*#' -or $line -match '^\s*!') { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $line.Substring(0, $eq).Trim().Trim([char]0xFEFF)
        if ([string]::Equals($k, $Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            $newLine = "$Key=$Value"
            if ($Lines[$i] -ne $newLine) {
                $Lines[$i] = $newLine
                $changed = $true
            }
            $found = $true
        }
    }
    if (-not $found) {
        $Lines.Add("$Key=$Value")
        $changed = $true
    }
    return $changed
}

if (-not (Test-Path -LiteralPath $PropsPath -PathType Leaf)) {
    throw "找不到 server.properties：$PropsPath"
}

$rawLines = [System.IO.File]::ReadAllLines($PropsPath, [System.Text.Encoding]::UTF8)
$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.AddRange([string[]]$rawLines)

$changed = $false
if ($Disable) {
    # 只关开关，端口和密码原样保留，下次「启用 RCON 反控」一键就能重开
    $changed = (Set-PropValue $lines 'enable-rcon' 'false') -or $changed
    Write-Host ''
    Write-Host '====== 本地 RCON 关闭 ======' -ForegroundColor Cyan
    Write-Host "服务端根目录        : $Root"
    Write-Host "server.properties   : $PropsPath"
    Write-Host "enable-rcon         : false"
    Write-Host '说明：rcon.port 和 rcon.password 保留未动；关闭后 Discord/QQ 反控与备份的 RCON 功能将不可用。' -ForegroundColor Yellow
} else {
    $oldPassword = Get-PropValue $rawLines 'rcon.password'
    $passwordAction = '保留现有强密码'
    $newPassword = $oldPassword
    if ($RotatePassword -or (Test-WeakRconPassword $oldPassword)) {
        $newPassword = New-StrongRconPassword 32
        $passwordAction = if ($RotatePassword) { '已轮换为新强密码' } else { '已生成新强密码' }
    }

    $changed = (Set-PropValue $lines 'enable-rcon' 'true') -or $changed
    $changed = (Set-PropValue $lines 'rcon.port' ([string]$Port)) -or $changed
    $changed = (Set-PropValue $lines 'rcon.password' $newPassword) -or $changed
    $changed = (Set-PropValue $lines 'broadcast-rcon-to-ops' 'false') -or $changed

    Write-Host ''
    Write-Host '====== 本地 RCON/Discord 反控配置 ======' -ForegroundColor Cyan
    Write-Host "服务端根目录        : $Root"
    Write-Host "server.properties   : $PropsPath"
    Write-Host "enable-rcon         : true"
    Write-Host "rcon.port           : $Port"
    Write-Host "rcon.password       : $passwordAction（明文不在控制台显示）"
    Write-Host "broadcast-rcon-to-ops: false"
    Write-Host '说明：RCON 密码只写在本机 server.properties；Discord 配置不需要再填这串密码。' -ForegroundColor Yellow
    Write-Host '提示：同一台电脑同时开多个服务端时，请给每个服错开 rcon.port（如 25576），避免端口冲突。' -ForegroundColor Yellow
}

if ($DryRun) {
    Write-Host '[portable] DryRun：未写入 server.properties。' -ForegroundColor Yellow
} elseif ($changed) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $Root "backups\rcon-config-$stamp"
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    $backupFile = Join-Path $backupDir 'server.properties'
    Copy-Item -LiteralPath $PropsPath -Destination $backupFile -Force
    Write-Utf8NoBom -Path $PropsPath -Value (($lines -join "`r`n") + "`r`n")
    Write-Host "[portable] RCON 配置已写入。写入前备份：$backupFile" -ForegroundColor Green
} else {
    Write-Host '[portable] RCON 配置已经符合要求，无需写入。' -ForegroundColor Green
}

Write-Host '[portable] 注意：Minecraft 服务端必须重启后，新的 enable-rcon/rcon.password 才会生效。' -ForegroundColor Yellow
Write-Host '=========================================' -ForegroundColor Cyan

if (-not $NoPause) {
    Write-Host ''
    Read-Host '按回车退出' | Out-Null
}
