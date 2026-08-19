<##
    portable-bootstrap-refresh.ps1 —— Windows 启动器自刷新

    只负责一件事：在真正的同步器启动前，把 _updater 下的工具安全刷新到本地。
    这里不使用 Get-FileHash（部分 PowerShell 5.1 以 -File 运行时无法自动加载该命令），
    也不把网络异常按每个文件重复打印；先探测一次清单，成功后再批量下载。
    主更新器仍会再次校验清单和 SHA1，这个脚本不能绕过同步器的安全策略。
##>
param(
    [string]$InstanceDir = ".",
    [string]$ScriptDir = ".",
    [string]$ManifestUrl = ""
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $OutputEncoding = [Console]::OutputEncoding } catch {}

function Get-Sha1 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    $hash = [System.Security.Cryptography.SHA1]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        return ([System.BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($stream) { $stream.Dispose() }
        $hash.Dispose()
    }
}

function Read-UpdateUrls {
    param([string]$Root, [string]$ToolsRoot, [string]$Override)
    $urls = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param([string]$Value)
        $v = ([string]$Value).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v) -and -not $v.StartsWith('#') -and $seen.Add($v)) { [void]$urls.Add($v) }
    }
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        & $add $Override
        return @($urls.ToArray())
    }
    $relative = @(
        'UPDATE-URL.txt', 'PORTABLE-UPDATE-URL.txt', 'TFCR-update-url.txt'
    )
    foreach ($base in @($Root, $ToolsRoot)) {
        foreach ($rel in $relative) {
            $path = Join-Path $base $rel
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try {
                foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)) { & $add $line }
            } catch {}
        }
    }
    return @($urls.ToArray())
}

function Test-PrivateUpdateUrl {
    param([string]$Url)
    try { $hostName = ([Uri]$Url).Host.ToLowerInvariant() } catch { return $false }
    if ($hostName -in @('localhost', '127.0.0.1', '::1') -or $hostName.EndsWith('.local')) { return $true }
    if ($hostName -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.)') { return $true }
    if ($hostName -match '^(fc|fd|fe80:)') { return $true }
    return $false
}

function Save-DirectFile {
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutSec = 8)
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
    $request = [System.Net.HttpWebRequest]::Create($target)
    if ($hostHeader) { $request.Host = $hostHeader }
    $request.Proxy = $null
    $request.Method = 'GET'
    $request.Timeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.ReadWriteTimeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.KeepAlive = $false
    $request.UserAgent = 'portable-server-kit-bootstrap/2.0'
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        try { $request.Abort() } catch {}
    }
}

function Test-ManifestUrl {
    param([string]$Url, [int]$TimeoutSec = 8)
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('portable-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Save-DirectFile -Url $Url -Path $temp -TimeoutSec $TimeoutSec
        $manifest = Get-Content -LiteralPath $temp -Raw -Encoding UTF8 | ConvertFrom-Json
        return ($null -ne $manifest -and $null -ne $manifest.files)
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-PowerShellSyntax {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw 'PowerShell syntax check failed' }
}

function Install-RefreshedFile {
    param([string]$Source, [string]$Destination, [string]$Name)
    if ((Get-Sha1 -Path $Source) -eq (Get-Sha1 -Path $Destination)) { return $false }
    if ($Name.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) { Assert-PowerShellSyntax -Path $Source }
    $swap = Join-Path (Split-Path -Parent $Destination) ('.' + [IO.Path]::GetFileName($Destination) + '.portable-new-' + [guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $Source -Destination $swap -Force
        Move-Item -LiteralPath $swap -Destination $Destination -Force
        return $true
    } finally {
        if (Test-Path -LiteralPath $swap -PathType Leaf) { Remove-Item -LiteralPath $swap -Force -ErrorAction SilentlyContinue }
    }
}

$instanceRoot = [IO.Path]::GetFullPath($InstanceDir)
$toolsRoot = [IO.Path]::GetFullPath($ScriptDir)
$urls = @(Read-UpdateUrls -Root $instanceRoot -ToolsRoot $toolsRoot -Override $ManifestUrl)
if ($urls.Count -eq 0) {
    Write-Host '[更新器] 未找到更新地址，跳过自刷新。'
    exit 0
}
$lastGood = ''
$statePath = Join-Path $instanceRoot '.portable-sync-state.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.lastManifestUrl) { $lastGood = [string]$state.lastManifestUrl }
        elseif ($state.manifestUrl) { $lastGood = [string]$state.manifestUrl }
    } catch {}
}
$ordered = New-Object System.Collections.Generic.List[string]
$seenUrl = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$addUrl = {
    param([string]$Value)
    $v = ([string]$Value).Trim()
    if (-not [string]::IsNullOrWhiteSpace($v) -and $seenUrl.Add($v)) { [void]$ordered.Add($v) }
}
if (-not [string]::IsNullOrWhiteSpace($lastGood) -and -not (Test-PrivateUpdateUrl $lastGood)) { & $addUrl $lastGood }
$publicUrls = @($urls | Where-Object { -not (Test-PrivateUpdateUrl $_) })
$candidates = if ($publicUrls.Count -gt 0) { $publicUrls } else { @($urls) }
foreach ($u in $candidates) { & $addUrl $u }
$urls = @($ordered)
$selected = ''
$selectedIndex = -1
for ($i = 0; $i -lt $urls.Count; $i++) {
    if (Test-ManifestUrl -Url ([string]$urls[$i]) -TimeoutSec 8) {
        $selected = [string]$urls[$i]
        $selectedIndex = $i
        break
    }
}
if ([string]::IsNullOrWhiteSpace($selected)) {
    Write-Host '[更新器] 更新源暂时不可达，跳过自刷新；本地同步器会继续尝试备用地址。'
    exit 0
}
if ($selectedIndex -gt 0) { Write-Host '[更新器] 已切换到备用更新地址。' }
$base = $selected.Substring(0, $selected.LastIndexOf('/'))
$names = @('player-update-generic.ps1', 'player-update-generic.py', 'portable-stage-daemon.ps1', 'portable-stage-daemon.py', 'portable-bootstrap-refresh.ps1', 'macOS-sync.command', 'Windows-sync.bat')
foreach ($name in $names) {
    $url = $base + '/_updater/' + [Uri]::EscapeDataString($name) + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $destination = Join-Path $toolsRoot $name
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('portable-refresh-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $done = $false
    try {
        for ($attempt = 1; $attempt -le 2 -and -not $done; $attempt++) {
            try {
                Save-DirectFile -Url $url -Path $temp -TimeoutSec 8
                if ((Get-Item -LiteralPath $temp).Length -le 0) { throw 'empty download' }
                $done = $true
            } catch {
                if ($attempt -eq 2) { Write-Host ("[更新器] 跳过自刷新 $name（更新源暂时不可达或文件校验失败）。") }
                else { Start-Sleep -Seconds 1 }
            }
        }
        if ($done) {
            try {
                if (Install-RefreshedFile -Source $temp -Destination $destination -Name $name) { Write-Host "[更新器] 已刷新 $name" }
                else { Write-Host "[更新器] 已是最新 $name" }
            } catch {
                Write-Host ("[更新器] 跳过自刷新 $name（文件校验失败）。")
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
exit 0
