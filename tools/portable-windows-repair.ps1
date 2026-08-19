param(
    [string]$RepairHome = '',
    [string]$StartDir = '',
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

if ($env:PORTABLE_REPAIR_NO_LAUNCH -eq '1') { $NoLaunch = $true }
if ([string]::IsNullOrWhiteSpace($RepairHome)) {
    $RepairHome = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}
$RepairHome = [IO.Path]::GetFullPath($RepairHome.TrimEnd('\', '/'))
if ([string]::IsNullOrWhiteSpace($StartDir)) { $StartDir = $RepairHome }
$StartDir = [IO.Path]::GetFullPath($StartDir.TrimEnd('\', '/'))

function Test-LfOnly([byte[]]$Bytes) {
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 10 -and ($i -eq 0 -or $Bytes[$i - 1] -ne 13)) { return $true }
    }
    return $false
}

function Test-GoodSyncBat([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 2000) { return $false }
    if (Test-LfOnly $bytes) { return $false }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    return ($text -match 'PORTABLE_SYNC_BOOTSTRAPPED' -and $text -match 'player-update-generic')
}

function Find-UpdaterHits([string]$Root) {
    $found = New-Object System.Collections.Generic.List[string]
    $versions = Join-Path $Root '.minecraft\versions'
    if (-not (Test-Path -LiteralPath $versions -PathType Container)) { return @() }
    Get-ChildItem -LiteralPath $versions -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $inner = Join-Path $_.FullName '_updater\Windows-sync.bat'
        if (Test-Path -LiteralPath $inner -PathType Leaf) { [void]$found.Add($inner) }
    }
    return @($found)
}

function Find-InstanceUpdater([string]$Start) {
    $hits = New-Object System.Collections.Generic.List[string]
    $cursor = $Start
    for ($i = 0; $i -lt 5; $i++) {
        foreach ($hit in (Find-UpdaterHits $cursor)) { [void]$hits.Add($hit) }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    if ($hits.Count -eq 0) {
        Get-ChildItem -LiteralPath $Start -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($hit in (Find-UpdaterHits $_.FullName)) { [void]$hits.Add($hit) }
        }
    }
    if ($hits.Count -eq 0) {
        $parent = Split-Path -Parent $Start
        if (-not [string]::IsNullOrWhiteSpace($parent) -and $parent -ne $Start) {
            Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                foreach ($hit in (Find-UpdaterHits $_.FullName)) { [void]$hits.Add($hit) }
            }
        }
    }
    return @($hits | Select-Object -Unique)
}

function Save-DirectFile {
    param([string]$Url, [string]$Path, [int]$TimeoutSec = 25)
    $target = $Url
    $hostHeader = $null
    try {
        $uri = [Uri]$Url
        if ($uri.HostNameType -eq [UriHostNameType]::Dns) {
            $ipv4 = [Net.Dns]::GetHostAddresses($uri.Host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($ipv4) {
                $builder = New-Object UriBuilder $uri
                $builder.Host = $ipv4.IPAddressToString
                $target = $builder.Uri.AbsoluteUri
                $hostHeader = $uri.Host
            }
        }
    } catch {}
    $request = [Net.HttpWebRequest]::Create($target)
    if ($hostHeader) { $request.Host = $hostHeader }
    $request.Proxy = $null
    $request.Timeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.ReadWriteTimeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.UserAgent = 'portable-windows-repair/1.0'
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Read-UpdateUrl([string]$InstanceDir, [string]$KitHome) {
    foreach ($p in @(
            (Join-Path $InstanceDir 'UPDATE-URL.txt'),
            (Join-Path $InstanceDir 'PORTABLE-UPDATE-URL.txt'),
            (Join-Path $InstanceDir 'TFCR-update-url.txt'),
            (Join-Path $KitHome 'UPDATE-URL.txt')
        )) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $u = (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim()
            if (-not [string]::IsNullOrWhiteSpace($u)) { return $u }
        }
    }
    return ''
}

function Install-Bat([string]$Source, [string]$Dest) {
    if (Test-Path -LiteralPath $Dest -PathType Leaf) {
        $srcBytes = [IO.File]::ReadAllBytes($Source)
        $dstBytes = [IO.File]::ReadAllBytes($Dest)
        if ($srcBytes.Length -eq $dstBytes.Length -and -not (Test-LfOnly $dstBytes)) {
            $same = $true
            for ($i = 0; $i -lt $srcBytes.Length; $i++) {
                if ($srcBytes[$i] -ne $dstBytes[$i]) { $same = $false; break }
            }
            if ($same) { return $false }
        }
    }
    $dir = Split-Path -Parent $Dest
    New-Item -ItemType Directory -Force $dir | Out-Null
    $tmp = Join-Path $dir ('.Windows-sync.portable-new-' + [guid]::NewGuid().ToString('N') + '.bat')
    try {
        Copy-Item -LiteralPath $Source -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $Dest -Force
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    return $true
}

Write-Host '============================================================'
Write-Host '  修复 Windows 更新脚本'
Write-Host '============================================================'

$hits = @(Find-InstanceUpdater $StartDir)
if ($hits.Count -eq 0) {
    Write-Host '[错误] 没有找到 .minecraft\versions\<实例>\_updater\Windows-sync.bat' -ForegroundColor Red
    Write-Host '把本文件夹放到整合包解压根目录（和「更新mod-Windows端.bat」放一起）再双击。' -ForegroundColor Yellow
    if (-not $NoLaunch) { Read-Host '按回车关闭' | Out-Null }
    exit 1
}
if ($hits.Count -gt 1) {
    Write-Host '[错误] 找到多个整合包，请把本脚本放到要修的那个包根目录再运行：' -ForegroundColor Red
    foreach ($h in $hits) { Write-Host ("  " + $h) }
    if (-not $NoLaunch) { Read-Host '按回车关闭' | Out-Null }
    exit 1
}

$inner = [string]$hits[0]
$updaterDir = Split-Path -Parent $inner
$instanceDir = Split-Path -Parent $updaterDir
Write-Host ("实例: " + $instanceDir)
Write-Host ("脚本: " + $inner)

$source = $null
$tempDownload = $null
foreach ($cand in @(
        (Join-Path $RepairHome 'Windows-sync.bat'),
        (Join-Path $RepairHome '_updater\Windows-sync.bat')
    )) {
    if (Test-GoodSyncBat $cand) {
        $source = $cand
        Write-Host '[修复] 使用随包的好脚本'
        break
    }
}

if (-not $source) {
    $manifestUrl = Read-UpdateUrl -InstanceDir $instanceDir -KitHome $RepairHome
    if ([string]::IsNullOrWhiteSpace($manifestUrl)) {
        Write-Host '[错误] 没有随包好脚本，也没有 UPDATE-URL.txt。请使用群里发的完整修复包。' -ForegroundColor Red
        if (-not $NoLaunch) { Read-Host '按回车关闭' | Out-Null }
        exit 1
    }
    $base = $manifestUrl.Substring(0, $manifestUrl.LastIndexOf('/'))
    $fileUrl = $base + '/_updater/' + [Uri]::EscapeDataString('Windows-sync.bat')
    $tempDownload = Join-Path ([IO.Path]::GetTempPath()) ('portable-repair-' + [guid]::NewGuid().ToString('N') + '.bat')
    Write-Host '[修复] 正在从更新源下载好脚本（直连）...'
    $ok = $false
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        try {
            Save-DirectFile -Url $fileUrl -Path $tempDownload -TimeoutSec 25
            if (Test-GoodSyncBat $tempDownload) { $ok = $true } else { throw 'downloaded file failed validation' }
        } catch {
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }
    if (-not $ok) {
        Write-Host '[错误] 下载失败，或下到的脚本仍是坏的。同一 Wi-Fi 可改用群里带 Windows-sync.bat 的修复包。' -ForegroundColor Red
        if (-not $NoLaunch) { Read-Host '按回车关闭' | Out-Null }
        exit 1
    }
    $source = $tempDownload
}

if (Install-Bat -Source $source -Dest $inner) {
    Write-Host '[修复] 已写入 _updater\Windows-sync.bat' -ForegroundColor Green
} else {
    Write-Host '[修复] _updater\Windows-sync.bat 已是好脚本'
}

$instanceCopy = Join-Path $instanceDir '更新mod-Windows端.bat'
if (Test-Path -LiteralPath $instanceCopy -PathType Leaf) {
    $copyBytes = [IO.File]::ReadAllBytes($instanceCopy)
    $copyText = [Text.Encoding]::UTF8.GetString($copyBytes)
    if ($copyBytes.Length -gt 2000 -or $copyText -match 'PORTABLE_SYNC_BOOTSTRAPPED') {
        if (Install-Bat -Source $source -Dest $instanceCopy) {
            Write-Host '[修复] 已写入实例目录的 更新mod-Windows端.bat' -ForegroundColor Green
        }
    }
}

if ($tempDownload -and (Test-Path -LiteralPath $tempDownload -PathType Leaf)) {
    Remove-Item -LiteralPath $tempDownload -Force -ErrorAction SilentlyContinue
}

if ($NoLaunch) { exit 0 }

Write-Host '[修复] 完成，正在启动正常更新...'
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
& $cmd /d /c "`"$inner`""
exit $LASTEXITCODE
