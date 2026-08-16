param(
    [string]$ConfigPath = ".\tools\portable-pack.json",
    [string]$Version = "",
    [switch]$NoNotify
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '发布更新 —— 刷新玩家更新源' } catch { }
$ProgressPreference = "SilentlyContinue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Value)
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Resolve-AnyPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Resolve-InRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Resolve-AnyPath -Path $Path
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝写入服务端根目录之外：$full"
    }
    return $full
}

function Test-RelativePathSafe {
    # 注意 '\' 与 '\\'：PowerShell 单引号不转义，String.Replace 是字面替换而非正则。
    # 必须是单反斜杠——写成 '\\' 只替换「连续两个反斜杠」，形如 ..\..\x 的路径不会被规范化，
    # 下面按 '/' 切分就看不到 '..' 段，安全检查形同虚设。
    param([Parameter(Mandatory = $true)][string]$Rel)
    $normalized = $Rel.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:') { return $false }
    foreach ($part in $normalized.Split('/')) {
        if ($part -eq '..') { return $false }
    }
    return $true
}

function Join-SafeRelativePath {
    param([Parameter(Mandatory = $true)][string]$RootPath, [Parameter(Mandatory = $true)][string]$Rel)
    if (-not (Test-RelativePathSafe -Rel $Rel)) { throw "Unsafe relative path: $Rel" }
    return Join-Path $RootPath ($Rel.Replace('/', '\'))
}

function Get-ConfigArray {
    param($Object, [string]$Name, [object[]]$Default = @())
    if ($Object -and $Object.PSObject.Properties[$Name]) { return @($Object.PSObject.Properties[$Name].Value) }
    return $Default
}

function Get-ConfigValue {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $Default
}

function Test-GlobMatch {
    param([Parameter(Mandatory = $true)][string]$Rel, $Globs)
    $normalized = $Rel.Replace('\', '/')
    foreach ($glob in @($Globs)) {
        $g = ([string]$glob).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($g)) { continue }
        if ($normalized -like $g) { return $true }
    }
    return $false
}

function Copy-ManagedTree {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$PublishRoot,
        [Parameter(Mandatory = $true)][string]$RootName,
        $ExcludeGlobs
    )
    $sourceDir = Join-Path $SourceRoot $RootName
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) { return 0 }
    $count = 0
    Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Force | ForEach-Object {
        $localRel = $_.FullName.Substring($sourceDir.Length).TrimStart('\', '/') -replace '\\', '/'
        $rel = if ([string]::IsNullOrWhiteSpace($localRel)) { $RootName } else { ($RootName.Replace('\', '/') + '/' + $localRel) }
        if (Test-GlobMatch -Rel $rel -Globs $ExcludeGlobs) { return }
        $dest = Join-SafeRelativePath -RootPath $PublishRoot -Rel $rel
        Copy-FileIncremental -Source $_.FullName -Dest $dest -Rel $rel
        $count++
    }
    return $count
}

function Copy-ManagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$PublishRoot,
        [Parameter(Mandatory = $true)][string]$Rel,
        $ExcludeGlobs
    )
    if (-not (Test-RelativePathSafe -Rel $Rel)) { throw "Unsafe include file: $Rel" }
    if (Test-GlobMatch -Rel $Rel -Globs $ExcludeGlobs) { return }
    $source = Join-SafeRelativePath -RootPath $SourceRoot -Rel $Rel
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return }
    $dest = Join-SafeRelativePath -RootPath $PublishRoot -Rel $Rel
    Copy-FileIncremental -Source $source -Dest $dest -Rel $Rel
}

function Copy-ToolFile {
    param([string]$SourceName, [string]$DestinationName, [string]$DestinationRoot)
    $source = Join-Path $Root (Join-Path 'tools' $SourceName)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少便携工具文件：$source" }
    $dest = Join-Path $DestinationRoot $DestinationName
    $rel = [System.IO.Path]::GetFullPath($dest).Substring([System.IO.Path]::GetFullPath($publishDir).TrimEnd('\', '/').Length).TrimStart('\', '/')
    Copy-FileIncremental -Source $source -Dest $dest -Rel $rel
}

function Copy-RootFile {
    param([string]$SourceRel, [string]$DestinationName, [string]$DestinationRoot)
    if (-not (Test-RelativePathSafe -Rel $SourceRel)) { throw "不安全的服务端源路径：$SourceRel" }
    if (-not (Test-RelativePathSafe -Rel $DestinationName)) { throw "不安全的发布目标路径：$DestinationName" }
    $source = Join-SafeRelativePath -RootPath $Root -Rel $SourceRel
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少便携发布文件：$source" }
    $dest = Join-SafeRelativePath -RootPath $DestinationRoot -Rel $DestinationName
    $publishFull = [System.IO.Path]::GetFullPath($publishDir).TrimEnd('\', '/')
    $destFull = [System.IO.Path]::GetFullPath($dest)
    if (-not $destFull.StartsWith($publishFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝把便携发布文件写到发布目录之外：$destFull"
    }
    $rel = $destFull.Substring($publishFull.Length).TrimStart('\', '/')
    Copy-FileIncremental -Source $source -Dest $destFull -Rel $rel
}

function Find-PortableSourceFile {
    param([Parameter(Mandatory = $true)][string]$BaseDir, [Parameter(Mandatory = $true)][string]$Rel)
    $candidates = New-Object System.Collections.Generic.List[string]
    $current = [System.IO.Path]::GetFullPath($BaseDir)
    while ($true) {
        $candidates.Add((Join-SafeRelativePath -RootPath $current -Rel $Rel))
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    $candidates.Add((Join-SafeRelativePath -RootPath (Join-Path $Root 'tools\launchers') -Rel $Rel))
    $candidates.Add((Join-SafeRelativePath -RootPath (Join-Path $Root '客户端') -Rel $Rel))
    $candidates.Add((Join-SafeRelativePath -RootPath $Root -Rel $Rel))
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-UpdateToken {
    param([string]$TokenFile)
    $tokenPath = Resolve-InRoot -Path $TokenFile
    if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
        $existing = (Get-Content -LiteralPath $tokenPath -Raw -Encoding ASCII).Trim()
        if (-not [string]::IsNullOrWhiteSpace($existing)) { return $existing }
    }
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $token = ([System.BitConverter]::ToString($bytes).Replace("-", "")).ToLowerInvariant()
    Write-Utf8NoBom -Path $tokenPath -Value ($token + "`r`n")
    return $token
}

function Get-FileSha1 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant()
}

function Assert-PublishedManifestIntegrity {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$PublishRoot
    )
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($row in @($Manifest.files)) {
        $rel = ([string]$row.path).Replace('\', '/')
        if (-not (Test-RelativePathSafe -Rel $rel)) {
            [void]$errors.Add("不安全路径：$rel")
            continue
        }
        $path = Join-SafeRelativePath -RootPath $PublishRoot -Rel $rel
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$errors.Add("缺失：$rel")
            continue
        }
        try {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            $actualSize = [int64]$item.Length
            $expectedSize = [int64]$row.size
            if ($actualSize -ne $expectedSize) {
                [void]$errors.Add("大小：$rel（清单 $expectedSize，实际 $actualSize）")
                continue
            }
            $actualSha1 = Get-FileSha1 -Path $path
            $expectedSha1 = ([string]$row.sha1).ToLowerInvariant()
            if ($actualSha1 -ne $expectedSha1) {
                [void]$errors.Add("SHA1：$rel（清单 $expectedSha1，实际 $actualSha1）")
            }
        } catch {
            [void]$errors.Add("读取失败：$rel（$($_.Exception.Message)）")
        }
    }
    if ($errors.Count -gt 0) {
        $preview = (@($errors | Select-Object -First 20) -join '; ')
        throw "发布完整性校验失败，共 $($errors.Count) 项：$preview"
    }
    Write-Host "[便携] 发布完整性校验通过：$(@($Manifest.files).Count) 个文件。"
}

function Test-OfficialLookupEligible {
    # 与 mrpack 混源同一批对象：模组 / 资源包 / 光影。配置、启动器、汉化挥发包不查。
    param([string]$Rel)
    $n = ([string]$Rel).Replace('\', '/')
    if ($n -like 'mods/*.jar') { return $true }
    if ($n -like 'resourcepacks/*.zip') { return $true }
    if ($n -like 'shaderpacks/*.zip') { return $true }
    return $false
}

function Get-ModrinthUrlMap {
    # sha1 -> cdn.modrinth.com URL。API 失败返回已查到的部分，绝不打断发布。
    param([string[]]$Sha1List)
    $map = @{}
    $hashes = @($Sha1List | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($hashes.Count -eq 0) { return $map }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}
    $chunkSize = 800
    for ($i = 0; $i -lt $hashes.Count; $i += $chunkSize) {
        $end = [Math]::Min($i + $chunkSize - 1, $hashes.Count - 1)
        $chunk = [string[]]@($hashes[$i..$end])
        try {
            $lookupBody = @{ hashes = $chunk; algorithm = 'sha1' } | ConvertTo-Json -Depth 3 -Compress
            $resp = Invoke-RestMethod -Uri 'https://api.modrinth.com/v2/version_files' -Method Post -Body $lookupBody -ContentType 'application/json' -Headers @{ 'User-Agent' = 'portable-server-kit (Minecraft ops toolkit; incremental-sync)' } -TimeoutSec 40
            if (-not $resp) { continue }
            foreach ($prop in $resp.PSObject.Properties) {
                $want = $prop.Name.ToLowerInvariant()
                foreach ($vf in @($prop.Value.files)) {
                    if (([string]$vf.hashes.sha1).ToLowerInvariant() -eq $want) {
                        $u = [string]$vf.url
                        if ($u -match '^https://') { $map[$want] = $u }
                        break
                    }
                }
            }
        } catch {
            Write-Host ("[便携] 警告：Modrinth 官方源反查失败（{0}），未命中文件仍走自建更新服务。" -f $_.Exception.Message) -ForegroundColor Yellow
            break
        }
    }
    return $map
}

# ---------------------------------------------------------------
# 增量发布核心：不再整删重建发布目录。
# 玩家可能正通过更新服务下载文件（句柄被占用），整删重建的 Remove-Item
# 会卡死在被占用文件上，且中途失败会留下"半删除"的更新源
# （2026-07-08 实锤：mods/ 已删、旧清单还在，玩家同步大面积 404）。
# 现在：内容相同的文件不碰盘，不同才覆盖（带占用重试），
# 结尾清理多余旧文件（失败只警告），server-manifest.json 永远最后写。
# ---------------------------------------------------------------
$script:DesiredRelKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:ShaCache = @{}

function Register-PublishedRel {
    param([Parameter(Mandatory = $true)][string]$Rel)
    [void]$script:DesiredRelKeys.Add($Rel.Replace('\', '/'))
}

function Copy-FileWithRetry {
    param([string]$Source, [string]$Dest, [int]$Attempts = 5, [int]$DelaySec = 2)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Dest -Force
            return
        } catch {
            if ($i -ge $Attempts) {
                throw ("文件被其它进程占用，多次重试仍失败：$Dest。多半是玩家正通过更新服务下载文件，稍等几分钟再点「仅发布更新」即可；本次发布已中止，旧清单未被破坏。原始错误：" + $_.Exception.Message)
            }
            Write-Host "[便携] 目标文件被占用，$DelaySec 秒后重试（$i/$Attempts）：$Dest"
            Start-Sleep -Seconds $DelaySec
        }
    }
}

function Copy-FileIncremental {
    # 内容相同不写盘（不打扰正在下载的玩家），不同才覆盖；顺手缓存 SHA1 给清单复用。
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Dest, [Parameter(Mandatory = $true)][string]$Rel)
    $relKey = $Rel.Replace('\', '/')
    Register-PublishedRel -Rel $relKey
    $srcItem = Get-Item -LiteralPath $Source
    $srcSha = $null
    if (Test-Path -LiteralPath $Dest -PathType Leaf) {
        $dstItem = Get-Item -LiteralPath $Dest
        if ($dstItem.Length -eq $srcItem.Length) {
            $srcSha = Get-FileSha1 -Path $Source
            if ((Get-FileSha1 -Path $Dest) -eq $srcSha) {
                $script:ShaCache[$relKey] = $srcSha
                return
            }
        }
    }
    if (-not $srcSha) { $srcSha = Get-FileSha1 -Path $Source }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Dest) | Out-Null
    Copy-FileWithRetry -Source $Source -Dest $Dest
    $script:ShaCache[$relKey] = $srcSha
    $script:CopiedFiles++
}

$configFullPath = Resolve-AnyPath -Path $ConfigPath
if (-not (Test-Path -LiteralPath $configFullPath -PathType Leaf)) {
    throw "缺少便携配置：$configFullPath。请先复制 tools\portable-pack.example.json 为 tools\portable-pack.json。"
}
$config = Get-Content -LiteralPath $configFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string](Get-ConfigValue -Object $config -Name 'version' -Default '') }
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = Get-Date -Format 'yyyyMMdd-HHmmss' }

$packId = [string](Get-ConfigValue -Object $config -Name 'packId' -Default '')
$packName = [string](Get-ConfigValue -Object $config -Name 'packName' -Default $packId)
if ([string]::IsNullOrWhiteSpace($packId) -or $packId -match 'CHANGE-ME') {
    Write-Host ''
    Write-Host '[便携] 还不能发布：portable-pack.json 里整合包身份是空的（packId/packName 未填写）。' -ForegroundColor Red
    Write-Host '这是新服务端（私包出厂即中性）的正常状态，先补两步：' -ForegroundColor Yellow
    Write-Host '  1. 面板①配置点「初始化配置向导」（或双击 一键脚本\一键便携-初始化配置.bat）——自动识别本服版本/加载器，并让你自定义整合包名称；' -ForegroundColor Yellow
    Write-Host '  2. 确认主分发客户端已设置（向导里选，或面板点「选择分发客户端目录」）。' -ForegroundColor Yellow
    Write-Host '完成后再点「仅发布更新」。' -ForegroundColor Yellow
    exit 1
}
if ([string]::IsNullOrWhiteSpace($packName)) { $packName = $packId }

$sourceClientRaw = [string](Get-ConfigValue -Object $config -Name 'sourceClient' -Default '')
if ([string]::IsNullOrWhiteSpace($sourceClientRaw)) { $sourceClientRaw = '.\main-client' }
$sourceClient = Resolve-AnyPath -Path $sourceClientRaw
if (-not (Test-Path -LiteralPath $sourceClient -PathType Container)) {
    Write-Host ''
    Write-Host "[便携] 还不能发布：主分发客户端目录不存在：$sourceClient" -ForegroundColor Red
    Write-Host '发布就是把主分发客户端的 mods/config 等复制到更新源，所以必须先有客户端：' -ForegroundColor Yellow
    Write-Host '  - 已有客户端：在面板点「选择主客户端…」指定它的实例目录（可以在服务端目录外）；' -ForegroundColor Yellow
    Write-Host '  - 还没有客户端：在服务端根目录新建「客户端」文件夹，放入整合包客户端实例后重跑初始化配置向导。' -ForegroundColor Yellow
    exit 1
}
$publishDir = Resolve-InRoot -Path ([string](Get-ConfigValue -Object $config -Name 'publishDir' -Default '.\modpack-public\portable'))
if ([System.IO.Path]::GetFullPath($publishDir).TrimEnd('\', '/') -ieq [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')) {
    throw '拒绝把服务端根目录直接作为 publishDir。'
}
$publishLockPath = Join-Path $Root 'tmp\portable-publish.lock'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $publishLockPath) | Out-Null
try {
    $script:PublishLockStream = [System.IO.File]::Open(
        $publishLockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $lockBytes = [System.Text.Encoding]::ASCII.GetBytes("PID=$PID`r`n")
    $script:PublishLockStream.SetLength(0)
    $script:PublishLockStream.Write($lockBytes, 0, $lockBytes.Length)
    $script:PublishLockStream.Flush()
} catch {
    if ($script:PublishLockStream) { $script:PublishLockStream.Dispose(); $script:PublishLockStream = $null }
    throw "已有另一个便携发布任务正在运行，已停止本次发布：$publishLockPath"
}
# ---------------------------------------------------------------
# 变更对比：发布前先读取旧的 server-manifest.json
# 保存旧文件列表 (path -> sha1)，用于后续对比哪些 mod/配置变了
# ---------------------------------------------------------------
$oldManifestPath = Join-Path $publishDir 'server-manifest.json'
$oldFiles = @{}
$oldUrlBySha1 = @{}
$oldVersion = ''
$oldManifest = $null
$oldManifestText = $null
if (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
    try {
        $oldManifestText = Get-Content -LiteralPath $oldManifestPath -Raw -Encoding UTF8
        $oldManifest = $oldManifestText | ConvertFrom-Json
        $oldVersion = [string]$oldManifest.version
        foreach ($f in @($oldManifest.files)) {
            $oldFiles[[string]$f.path] = [string]$f.sha1
            $oldSha = ([string]$f.sha1).ToLowerInvariant()
            if ($oldSha -and $f.PSObject.Properties['url'] -and ([string]$f.url -match '^https://')) {
                $oldUrlBySha1[$oldSha] = [string]$f.url
            }
        }
        Write-Host "[便携] 已读取上一版清单：$oldVersion（$($oldFiles.Count) 个文件）"
    } catch {
        Write-Host "[便携] 读取旧清单失败，跳过变更对比：$($_.Exception.Message)"
        $oldFiles = @{}
        $oldUrlBySha1 = @{}
        $oldManifest = $null
    }
}

# 增量发布：不删除发布目录，逐文件比对写入；过期文件在所有复制完成后统一清理。
New-Item -ItemType Directory -Force $publishDir | Out-Null

$excludeGlobs = Get-ConfigArray -Object $config -Name 'excludeGlobs' -Default @()
$includeRoots = Get-ConfigArray -Object $config -Name 'includeRoots' -Default @('mods', 'config', 'defaultconfigs', 'data', 'resourcepacks', 'datapacks', 'kubejs', 'scripts')
$includeFiles = Get-ConfigArray -Object $config -Name 'includeFiles' -Default @('options.txt', 'servers.dat')
$script:CopiedFiles = 0
foreach ($rootName in $includeRoots) {
    $name = [string]$rootName
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if (-not (Test-RelativePathSafe -Rel $name)) { throw "Unsafe include root: $name" }
    [void](Copy-ManagedTree -SourceRoot $sourceClient -PublishRoot $publishDir -RootName $name -ExcludeGlobs $excludeGlobs)
}
foreach ($file in $includeFiles) {
    Copy-ManagedFile -SourceRoot $sourceClient -PublishRoot $publishDir -Rel ([string]$file) -ExcludeGlobs $excludeGlobs
}

if ($config.launchers -and [bool](Get-ConfigValue -Object $config.launchers -Name 'include' -Default $true)) {
    $launcherRoot = Join-Path $publishDir '_launchers'
    $launcherDefaults = @('PCL.exe', 'PCL/LatestLaunch.bat', 'PCL/Setup.ini', 'HMCL.jar', 'Plain Craft Launcher.exe', 'SakuraLauncher.exe')
    foreach ($launcher in (Get-ConfigArray -Object $config.launchers -Name 'files' -Default $launcherDefaults)) {
        $rel = ([string]$launcher).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($rel) -or -not (Test-RelativePathSafe -Rel $rel)) { continue }
        $src = Find-PortableSourceFile -BaseDir $sourceClient -Rel $rel
        if (-not [string]::IsNullOrWhiteSpace($src) -and (Test-Path -LiteralPath $src -PathType Leaf)) {
            $dest = Join-SafeRelativePath -RootPath $launcherRoot -Rel $rel
            Copy-FileIncremental -Source $src -Dest $dest -Rel ('_launchers/' + $rel)
            Write-Host "[便携] 已纳入启动器文件：_launchers/$rel"
        } else {
            Write-Host "[便携] 启动器文件不存在，跳过：$rel"
        }
    }
}

$updaterRoot = Join-Path $publishDir '_updater'
New-Item -ItemType Directory -Force $updaterRoot | Out-Null
Copy-ToolFile -SourceName 'player-update-generic.ps1' -DestinationName 'player-update-generic.ps1' -DestinationRoot $updaterRoot
Copy-ToolFile -SourceName 'player-update-generic.py' -DestinationName 'player-update-generic.py' -DestinationRoot $updaterRoot
Copy-ToolFile -SourceName 'portable-stage-daemon.ps1' -DestinationName 'portable-stage-daemon.ps1' -DestinationRoot $updaterRoot
Copy-ToolFile -SourceName 'portable-stage-daemon.py' -DestinationName 'portable-stage-daemon.py' -DestinationRoot $updaterRoot
Copy-ToolFile -SourceName 'portable-windows-sync.bat' -DestinationName 'Windows-sync.bat' -DestinationRoot $updaterRoot
Copy-ToolFile -SourceName 'portable-windows-sync.bat' -DestinationName '更新mod-Windows端.bat' -DestinationRoot $publishDir
Copy-ToolFile -SourceName 'portable-macos-sync.command' -DestinationName 'macOS-sync.command' -DestinationRoot $updaterRoot
Copy-ToolFile -SourceName 'portable-macos-sync.command' -DestinationName '更新mod-Mac端.command' -DestinationRoot $publishDir
Copy-ToolFile -SourceName 'player-self-repair.ps1' -DestinationName 'player-self-repair.ps1' -DestinationRoot $updaterRoot
Copy-RootFile -SourceRel '一键脚本\一键客户端自助修复.bat' -DestinationName '一键客户端自助修复.bat' -DestinationRoot $publishDir

$update = $config.update
$scheme = [string](Get-ConfigValue -Object $update -Name 'scheme' -Default 'http')
$hostName = [string](Get-ConfigValue -Object $update -Name 'host' -Default '127.0.0.1')
$port = [int](Get-ConfigValue -Object $update -Name 'port' -Default 18088)
$tokenFile = [string](Get-ConfigValue -Object $update -Name 'tokenFile' -Default '.update-server-token')
$token = Get-UpdateToken -TokenFile $tokenFile
$manifestUrl = $scheme + "://" + $hostName + ":" + $port + "/" + $token + "/server-manifest.json"
Write-Utf8NoBom -Path (Join-Path $publishDir 'UPDATE-URL.txt') -Value ($manifestUrl + "`r`n")
Write-Utf8NoBom -Path (Join-Path $publishDir 'PORTABLE-UPDATE-URL.txt') -Value ($manifestUrl + "`r`n")
$serverName = [string](Get-ConfigValue -Object $config.server -Name 'name' -Default $packName)
$serverAddress = [string](Get-ConfigValue -Object $config.server -Name 'address' -Default $hostName)
Write-Utf8NoBom -Path (Join-Path $publishDir 'SERVER.txt') -Value ($serverAddress + "`r`n")
Write-Utf8NoBom -Path (Join-Path $publishDir 'README-sync.txt') -Value @"
$packName player sync pack

Windows: run 更新mod-Windows端.bat.
macOS: run 更新mod-Mac端.command if python3 is available.
Self repair: run 一键客户端自助修复.bat; use -Fix only when repair is needed.
Update URL: $manifestUrl
Server: $serverAddress
"@

$base = $publishDir.TrimEnd('\', '/')

# 每次发布都重新生成的元文件也算"本次应有"，其余未登记的文件即上一版遗留，统一清理。
foreach ($meta in @('UPDATE-URL.txt', 'PORTABLE-UPDATE-URL.txt', 'SERVER.txt', 'README-sync.txt', 'server-manifest.json', 'update-log.txt')) {
    Register-PublishedRel -Rel $meta
}
Get-ChildItem -LiteralPath $publishDir -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
    if ($script:DesiredRelKeys.Contains($rel)) { return }
    try {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Host "[便携] 已清理过期文件：$rel"
    } catch {
        # 被占用的过期文件不会进新清单，留在盘上无害，下次发布再清。
        Write-Host "[便携] 过期文件被占用，暂时保留（不影响本次发布）：$rel"
    }
}
Get-ChildItem -LiteralPath $publishDir -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

$files = @()
$lookupHashes = New-Object System.Collections.Generic.List[string]
$fileRows = New-Object System.Collections.Generic.List[object]
Get-ChildItem -LiteralPath $publishDir -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
    $rel = $_.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
    # server-manifest.json / update-log.txt 在清单生成之后才写入，不能进清单，
    # 否则增量发布时旧内容的哈希会跟着进清单、随后又被覆盖，玩家端校验必失败。
    if ($rel -in @('server-manifest.json', 'update-log.txt')) { return }
    # 清单必须以发布目录当前字节为准，不能复用复制阶段的源文件缓存哈希；
    # 否则发布后被其它流程改写的文件可能带着旧缓存进入清单。
    $hash = Get-FileSha1 -Path $_.FullName
    $row = [ordered]@{
        path = $rel
        size = $_.Length
        sha1 = $hash
    }
    if (Test-OfficialLookupEligible $rel) {
        if ($oldUrlBySha1.ContainsKey($hash)) {
            $row.url = $oldUrlBySha1[$hash]
        } else {
            [void]$lookupHashes.Add($hash)
        }
    }
    [void]$fileRows.Add($row)
}
$freshMap = Get-ModrinthUrlMap -Sha1List @($lookupHashes)
$officialEligible = 0
$officialReused = 0
$officialFresh = 0
foreach ($row in $fileRows) {
    if (Test-OfficialLookupEligible ([string]$row.path)) { $officialEligible++ }
    if ($row.Contains('url')) {
        $officialReused++
    } else {
        $h = [string]$row.sha1
        if ($h -and $freshMap.ContainsKey($h)) {
            $row.url = $freshMap[$h]
            $officialFresh++
        }
    }
    $files += [pscustomobject]$row
}
Write-Host ("[便携] Modrinth 官方源：命中 {0} / {1}（沿用 {2}，新查 {3}）。未命中的汉化/私有文件仍走自建更新服务。" -f ($officialReused + $officialFresh), $officialEligible, $officialReused, $officialFresh)

$manifest = [ordered]@{
    format = 2
    packId = $packId
    pack = $packId
    packName = $packName
    name = $packId
    version = $Version
    minecraftVersion = [string](Get-ConfigValue -Object $config -Name 'minecraftVersion' -Default '')
    loader = $config.loader
    generatedAt = (Get-Date).ToString('s')
    updateUrl = $manifestUrl
    serverName = $serverName
    serverAddress = $serverAddress
    sourceClient = $sourceClient
    preservePlayerCustomizations = $true
    preserveLocalChangeGlobs = Get-ConfigArray -Object $config -Name 'preserveLocalChangeGlobs' -Default @()
    preserveLocalDeletionGlobs = Get-ConfigArray -Object $config -Name 'preserveLocalDeletionGlobs' -Default @()
    additiveDirs = Get-ConfigArray -Object $config -Name 'additiveDirs' -Default @('shaderpacks', 'resourcepacks', 'schematics', 'saves', 'screenshots')
    adoptExistingFiles = [bool](Get-ConfigValue -Object $config -Name 'adoptExistingFiles' -Default $true)
    cleanup = Get-ConfigValue -Object $config -Name 'cleanup' -Default ([pscustomobject]@{ removeConnectorCache = $true; disableLauncherRepairIndex = $true; disableDuplicateMods = $true })
    playerOptions = Get-ConfigValue -Object $config -Name 'playerOptions' -Default $null
    serverList = Get-ConfigValue -Object $config -Name 'serverList' -Default ([pscustomobject]@{ enabled = $true; target = 'servers.dat'; name = $serverName; address = $serverAddress; writeIfMissingOnly = $true })
    launcher = [ordered]@{
        instanceName = [string](Get-ConfigValue -Object $config.pcl -Name 'instanceName' -Default $packName)
        packName = $packName
        minecraftVersion = [string](Get-ConfigValue -Object $config -Name 'minecraftVersion' -Default '')
        loader = $config.loader
    }
    forceDeleteGlobs = Get-ConfigArray -Object $config -Name 'forceDeleteGlobs' -Default @()
    forceSyncGlobs = Get-ConfigArray -Object $config -Name 'forceSyncGlobs' -Default @()
    platformExcludeGlobs = Get-ConfigValue -Object $config -Name 'platformExcludeGlobs' -Default $null
    files = $files
}
$manifestPath = Join-Path $publishDir 'server-manifest.json'
$manifestNextPath = Join-Path $publishDir '.server-manifest.json.next'
$manifestText = (($manifest | ConvertTo-Json -Depth 10) + "`r`n")
try {
    Write-Utf8NoBom -Path $manifestNextPath -Value $manifestText
    Assert-PublishedManifestIntegrity -Manifest $manifest -PublishRoot $publishDir
    Copy-FileWithRetry -Source $manifestNextPath -Dest $manifestPath
    $writtenManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PublishedManifestIntegrity -Manifest $writtenManifest -PublishRoot $publishDir
} catch {
    if ($oldManifestText -ne $null) {
        try { Write-Utf8NoBom -Path $manifestPath -Value $oldManifestText } catch { Write-Host "[便携] 警告：新清单失败且旧清单恢复失败：$($_.Exception.Message)" -ForegroundColor Red }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $manifestNextPath -PathType Leaf) { Remove-Item -LiteralPath $manifestNextPath -Force -ErrorAction SilentlyContinue }
}
Write-Utf8NoBom -Path (Join-Path $publishDir 'update-log.txt') -Value "便携发布 $Version`r`n整合包：$packName`r`n源客户端：$sourceClient`r`n更新地址：$manifestUrl`r`n文件数量：$($files.Count)`r`n官方源命中：$($officialReused + $officialFresh) / $officialEligible`r`n"
Write-Host "[便携] 已发布 $packName $Version"
Write-Host "[便携] 源客户端：$sourceClient"
Write-Host "[便携] 发布目录：$publishDir"
Write-Host "[便携] 清单地址：$manifestUrl"
Write-Host "[便携] 文件数：$($files.Count)，从源客户端复制：$script:CopiedFiles"

# ---------------------------------------------------------------
# 变更对比：生成本次发布的新增/删除/修改文件列表
# 分类汇总 mods 和 config 变化，写入摘要文件并通知 Discord/QQ
# ---------------------------------------------------------------
if ($oldFiles.Count -gt 0) {
    # 排除每次发布都会重新生成的元文件，避免误报
    $metaFiles = @{
        'update-log.txt' = $true
        'UPDATE-URL.txt' = $true
        'PORTABLE-UPDATE-URL.txt' = $true
        'SERVER.txt' = $true
        'README-sync.txt' = $true
    }
    $newFileMap = @{}
    foreach ($f in $files) {
        $p = [string]$f.path
        if ($metaFiles.ContainsKey($p)) { continue }
        $newFileMap[$p] = [string]$f.sha1
    }
    # 旧文件列表也排除元文件
    $oldFilesFiltered = @{}
    foreach ($k in $oldFiles.Keys) {
        if (-not $metaFiles.ContainsKey($k)) { $oldFilesFiltered[$k] = $oldFiles[$k] }
    }

    $added = @()
    $removed = @()
    $modified = @()

    foreach ($path in ($newFileMap.Keys | Sort-Object)) {
        if (-not $oldFilesFiltered.ContainsKey($path)) {
            $added += $path
        } elseif ($oldFilesFiltered[$path] -ne $newFileMap[$path]) {
            $modified += $path
        }
    }
    foreach ($path in ($oldFilesFiltered.Keys | Sort-Object)) {
        if (-not $newFileMap.ContainsKey($path)) {
            $removed += $path
        }
    }

    # 把"同一 mod 的旧版删除 + 新版新增"配对识别成一次"版本变更"——mod jar 文件名带版本号，
    # 版本一变文件名就变，diff 只会看成 add+remove（非 modify）。摘要和 RCON 广播共用这份配对结果，
    # 摘要再按版本数值方向区分为升级、回退或方向未知，而不是把所有变化都叫成升级。
    # 去掉文件名开头的"装饰前缀"：排序号 + 中文标签，如 "8.4[神秘时代]" / "[更多箱子] " / "[玉 🔍] "。
    # 前缀只是给人看的分类标记，改标签、改排序号不代表换了一个 mod，所以不能进身份。
    function Get-ModBaseName {
        param([string]$FileName)
        $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
        return ($name -replace '^\s*[\d.]*\s*(\[[^\]]*\]\s*)+', '')
    }
    # mod 身份 = 基名去掉版本尾巴。判据是一条硬不变量：mod 名的分段不会以数字开头，
    # 版本段一定以数字开头（v21.1.52 / mc1.21.1 同理）。旧写法用"段内含数字"判断，
    # 会被 appliedenergistics2、8.4[神秘时代]thaumcraft、L_Ender's Cataclysm 这类名字误判。
    function Get-ModKey {
        param([string]$FileName)
        $base = Get-ModBaseName $FileName
        $segs = @($base -split '[- ]')
        $keep = New-Object System.Collections.Generic.List[string]
        foreach ($seg in $segs) {
            if ($seg -match '^(v|mc)?\d') { break }   # 以数字（或 v/mc + 数字）开头即视为版本，截断
            [void]$keep.Add($seg)
        }
        # 名字本身就以数字开头（3dskinlayers 之类）：退回第一段，绝不能返回带版本的整名，
        # 否则版本一变 key 就变，等于关掉了配对。
        if ($keep.Count -eq 0) { return $segs[0].ToLowerInvariant() }
        return ($keep -join '-').ToLowerInvariant()
    }
    $removedModsByKey = @{}
    foreach ($r in @($removed | Where-Object { $_ -like 'mods/*.jar' })) {
        $k = Get-ModKey (Split-Path -Leaf $r)
        if (-not $removedModsByKey.ContainsKey($k)) { $removedModsByKey[$k] = New-Object System.Collections.Generic.List[string] }
        [void]$removedModsByKey[$k].Add($r)
    }
    $modVersionChanges = New-Object System.Collections.Generic.List[object]   # 版本变了，每项 @{ Old = 旧路径; New = 新路径 }
    $modRenames  = New-Object System.Collections.Generic.List[object]   # 只有装饰前缀变了，版本没变（加中文标签/改排序号）
    $addedFinal = New-Object System.Collections.Generic.List[string]
    foreach ($a in $added) {
        if ($a -like 'mods/*.jar') {
            $k = Get-ModKey (Split-Path -Leaf $a)
            if ($removedModsByKey.ContainsKey($k) -and $removedModsByKey[$k].Count -gt 0) {
                $oldPath = $removedModsByKey[$k][0]
                $removedModsByKey[$k].RemoveAt(0)
                # 配上对之后再分类：基名（去掉装饰前缀）相同 = 只是改名，不同 = 版本变更。
                if ((Get-ModBaseName (Split-Path -Leaf $oldPath)) -eq (Get-ModBaseName (Split-Path -Leaf $a))) {
                    [void]$modRenames.Add(@{ Old = $oldPath; New = $a })
                } else {
                    [void]$modVersionChanges.Add(@{ Old = $oldPath; New = $a })
                }
                continue
            }
        }
        [void]$addedFinal.Add($a)
    }
    $versionChangedOldSet = @{}
    foreach ($u in $modVersionChanges) { $versionChangedOldSet[$u.Old] = $true }
    foreach ($u in $modRenames)  { $versionChangedOldSet[$u.Old] = $true }
    $removedFinal = @($removed | Where-Object { -not $versionChangedOldSet.ContainsKey($_) })
    $addedFinal = @($addedFinal)

    # 从新旧文件名中提取真正变化的版本片段。只在 - _ 空格 + 边界截公共前后缀，
    # 避免把 Minecraft/加载器等固定片段当作模组版本；摘要显示和方向判断共用这份结果。
    function Get-ModVersionChangeParts {
        param([string]$OldPath, [string]$NewPath)
        $sep = @('-', '_', ' ', '+')
        $oldFile = Split-Path -Leaf $OldPath
        $newFile = Split-Path -Leaf $NewPath
        $old = [System.IO.Path]::GetFileNameWithoutExtension($oldFile)
        $new = [System.IO.Path]::GetFileNameWithoutExtension($newFile)
        if ([string]::IsNullOrWhiteSpace($old) -or [string]::IsNullOrWhiteSpace($new)) { return $null }
        $p = 0
        $maxP = [Math]::Min($old.Length, $new.Length)
        while ($p -lt $maxP -and $old[$p] -eq $new[$p]) { $p++ }
        while ($p -gt 0 -and $sep -notcontains [string]$old[$p - 1]) { $p-- }
        $base = $old.Substring(0, $p).TrimEnd('-', '_', ' ', '+')
        $oldRest = $old.Substring($p)
        $newRest = $new.Substring($p)
        if ([string]::IsNullOrWhiteSpace($base) -or [string]::IsNullOrWhiteSpace($oldRest) -or [string]::IsNullOrWhiteSpace($newRest)) {
            return $null
        }
        # 再截公共后缀（如 -forge+mc1.20.1-all），同样只在分隔符边界截，且新旧各留至少 1 字符。
        $s = 0
        $maxS = [Math]::Min($oldRest.Length, $newRest.Length) - 1
        while ($s -lt $maxS -and $oldRest[$oldRest.Length - 1 - $s] -eq $newRest[$newRest.Length - 1 - $s]) { $s++ }
        while ($s -gt 0 -and $sep -notcontains [string]$oldRest[$oldRest.Length - $s]) { $s-- }
        if ($s -gt 0) {
            $oldRest = $oldRest.Substring(0, $oldRest.Length - $s)
            $newRest = $newRest.Substring(0, $newRest.Length - $s)
        }
        return [pscustomobject]@{
            Base = $base
            OldText = $oldRest
            NewText = $newRest
        }
    }

    function Get-NumericVersionParts {
        param([string]$Text)
        $numbers = New-Object System.Collections.Generic.List[int]
        $matches = [regex]::Matches([string]$Text, '(?<![A-Za-z])(?:v|mc)?\d+(?:\.\d+)*')
        foreach ($match in $matches) {
            $numberText = $match.Value -replace '^(?:v|mc)', ''
            foreach ($token in $numberText.Split('.')) {
                try {
                    [void]$numbers.Add([int]$token)
                } catch {
                    return @()
                }
            }
        }
        return @($numbers)
    }

    function Compare-ModVersionDirection {
        param([string]$OldPath, [string]$NewPath)
        $parts = Get-ModVersionChangeParts $OldPath $NewPath
        if ($null -eq $parts) { return $null }
        $oldParts = @(Get-NumericVersionParts $parts.OldText)
        $newParts = @(Get-NumericVersionParts $parts.NewText)
        if ($oldParts.Count -eq 0 -or $newParts.Count -eq 0) { return $null }
        $count = [Math]::Max($oldParts.Count, $newParts.Count)
        for ($i = 0; $i -lt $count; $i++) {
            $oldValue = 0
            $newValue = 0
            if ($i -lt $oldParts.Count) { $oldValue = [int]$oldParts[$i] }
            if ($i -lt $newParts.Count) { $newValue = [int]$newParts[$i] }
            if ($oldValue -lt $newValue) { return 1 }
            if ($oldValue -gt $newValue) { return -1 }
        }
        return 0
    }

    $modUpgrades = New-Object System.Collections.Generic.List[object]
    $modDowngrades = New-Object System.Collections.Generic.List[object]
    $modVersionUnknown = New-Object System.Collections.Generic.List[object]
    foreach ($u in $modVersionChanges) {
        $direction = Compare-ModVersionDirection $u.Old $u.New
        if ($null -ne $direction -and $direction -gt 0) {
            [void]$modUpgrades.Add($u)
        } elseif ($null -ne $direction -and $direction -lt 0) {
            [void]$modDowngrades.Add($u)
        } else {
            [void]$modVersionUnknown.Add($u)
        }
    }

    # 版本变更行显示：压成"基名：旧版本 → 新版本"。
    # 例：xaeroworldmap-forge-1.20.1-1.41.2.jar + 1.42.0.jar → "xaeroworldmap-forge-1.20.1：1.41.2 → 1.42.0"。
    function Format-ModVersionChangeLine {
        param([string]$OldPath, [string]$NewPath)
        $oldFile = Split-Path -Leaf $OldPath
        $newFile = Split-Path -Leaf $NewPath
        $parts = Get-ModVersionChangeParts $OldPath $NewPath
        if ($null -eq $parts) {
            return "$oldFile → $newFile"
        }
        return "$($parts.Base)：$($parts.OldText) → $($parts.NewText)"
    }

    # 分类汇总：Mod 保留逐条详情（最多 20 条，超出折叠）；配置/其他只报数量。
    # 逐条列配置既不直观、又会把 QQ/Discord 通知刷成长串（2026-07-08 tacz、配置刷屏实锤）。
    function Group-Changes {
        param([string[]]$Paths, [string]$Label, [string]$Symbol = '+')
        if (-not $Paths -or $Paths.Count -eq 0) { return @() }
        $maxList = 20
        $mods = @($Paths | Where-Object { $_ -like 'mods/*' } | ForEach-Object { $_ -replace 'mods/', '' })
        $configs = @($Paths | Where-Object { $_ -like 'config/*' -or $_ -like 'defaultconfigs/*' })
        $others = @($Paths | Where-Object { $_ -notlike 'mods/*' -and $_ -notlike 'config/*' -and $_ -notlike 'defaultconfigs/*' })
        $lines = @()
        if ($mods.Count -gt 0) {
            $lines += "  Mod $Label（$($mods.Count) 个）："
            foreach ($item in ($mods | Select-Object -First $maxList)) { $lines += "    $Symbol $item" }
            if ($mods.Count -gt $maxList) { $lines += "    … 以及另外 $($mods.Count - $maxList) 个" }
        }
        if ($configs.Count -gt 0) { $lines += "  配置 $Label：$($configs.Count) 项" }
        if ($others.Count -gt 0)  { $lines += "  其他 $Label：$($others.Count) 项" }
        return $lines
    }

    $hasChanges = ($added.Count -gt 0 -or $removed.Count -gt 0 -or $modified.Count -gt 0)

    if ($hasChanges) {
        $summaryLines = @()
        $summaryLines += "[更新] $packName 已发布新版本 $Version"
        if ($oldVersion) { $summaryLines += "上一版本：$oldVersion" }
        $summaryLines += ""
        $summaryLines += "本次变更："
        $maxVersionChangeList = 20
        foreach ($group in @(
            @{ Items = $modUpgrades; Label = '升级' }
            @{ Items = $modDowngrades; Label = '回退' }
            @{ Items = $modVersionUnknown; Label = '版本变更（方向无法判断）' }
        )) {
            # 泛型 List 不能直接套数组子表达式，显式展开后再统计/遍历。
            $items = @($group['Items'] | ForEach-Object { $_ })
            if ($items.Count -gt 0) {
                $summaryLines += "  Mod $($group['Label'])（$($items.Count) 个）："
                foreach ($u in ($items | Select-Object -First $maxVersionChangeList)) {
                    $summaryLines += ("    ~ " + (Format-ModVersionChangeLine $u.Old $u.New))
                }
                if ($items.Count -gt $maxVersionChangeList) { $summaryLines += "    … 以及另外 $($items.Count - $maxVersionChangeList) 个" }
            }
        }
        if ($modRenames.Count -gt 0) {
            $maxRenameList = 20
            $summaryLines += "  Mod 改名（$($modRenames.Count) 个，版本未变）："
            foreach ($u in ($modRenames | Select-Object -First $maxRenameList)) {
                $summaryLines += ("    ~ " + (Split-Path -Leaf $u.Old) + " → " + (Split-Path -Leaf $u.New))
            }
            if ($modRenames.Count -gt $maxRenameList) { $summaryLines += "    … 以及另外 $($modRenames.Count - $maxRenameList) 个" }
        }
        if ($addedFinal.Count -gt 0)   { $summaryLines += (Group-Changes $addedFinal   '新增' '+') }
        if ($modified.Count -gt 0)     { $summaryLines += (Group-Changes $modified     '更新' '~') }
        if ($removedFinal.Count -gt 0) { $summaryLines += (Group-Changes $removedFinal '删除' '-') }
        $summaryLines += ""
        $summaryLines += "玩家可运行同步脚本自动更新。服务器：$serverAddress"

        $summaryText = ($summaryLines -join "`r`n")

        # 写入摘要文件
        $summaryPath = Join-Path $Root "tmp\update-change-summary.txt"
        $stableSummary = Join-Path $Root "logs\last-mod-update.txt"
        New-Item -ItemType Directory -Force (Split-Path -Parent $summaryPath) | Out-Null
        New-Item -ItemType Directory -Force (Split-Path -Parent $stableSummary) | Out-Null
        Write-Utf8NoBom -Path $summaryPath -Value ($summaryText + "`r`n")
        Write-Utf8NoBom -Path $stableSummary -Value ($summaryText + "`r`n")

        Write-Host ""
        Write-Host "[便携] 变更摘要："
        Write-Host $summaryText
        Write-Host ""

        if ($NoNotify) {
            Write-Host "[便携] 本次使用 -NoNotify：已刷新清单，但跳过 Discord / QQ 与游戏内广播。"
        } else {
            # 调用通知脚本转发到 Discord/QQ（best-effort，失败不阻断发布）
            $notifyScript = Join-Path $PSScriptRoot 'send-update-notify.ps1'
            if (Test-Path -LiteralPath $notifyScript -PathType Leaf) {
                Write-Host "[便携] 正在发送更新通知到 Discord / QQ …"
                try {
                    $prevErrorAction = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notifyScript -SummaryFile $summaryPath 2>&1 | ForEach-Object { Write-Host $_ }
                    $ErrorActionPreference = $prevErrorAction
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "[便携] 通知发送未完全成功（退出码 $LASTEXITCODE），发布流程继续。"
                    }
                } catch {
                    Write-Host "[便携] 通知发送异常：$($_.Exception.Message)，发布流程继续。"
                }
            } else {
                Write-Host "[便携] 未找到通知脚本 send-update-notify.ps1，跳过通知。"
            }

            # 发布即时提醒：通过 RCON 向在线玩家广播一条游戏内消息（tellraw @a）。
            # 这是"发布即时通知"的主通道——瞬时、游戏内、必达；后台 daemon 随后 30s 内开始预下载。
            # best-effort：服务器没开/未启用 RCON/没在线玩家都不阻断发布。
            $rconScript = Join-Path $PSScriptRoot 'rcon-command.ps1'
            if (Test-Path -LiteralPath $rconScript -PathType Leaf) {
                # 三份名单复用上面按 Get-ModKey 配对好的结果：更新（配对成功的 add+remove、以及同名 modify）、纯新增、纯移除。
                $updatedPaths = New-Object System.Collections.Generic.List[string]
                foreach ($u in $modVersionChanges) { [void]$updatedPaths.Add($u.New) }
                foreach ($u in $modRenames)  { [void]$updatedPaths.Add($u.New) }   # 改名也要重下，对玩家等价于"更新"
                foreach ($m in @($modified | Where-Object { $_ -like 'mods/*.jar' })) { [void]$updatedPaths.Add($m) }
                $addedPaths   = @($addedFinal   | Where-Object { $_ -like 'mods/*.jar' })
                $removedPaths = @($removedFinal | Where-Object { $_ -like 'mods/*.jar' })

            # 公屏名单：去掉 mods/ 前缀与 .jar 后缀，最多列 6 个，多余折叠成"…等 N 个"。
            function Format-ModLine {
                param($Paths, [int]$Max = 6)
                $names = @($Paths | ForEach-Object { ($_ -replace '^mods/', '') -replace '\.jar$', '' })
                if ($names.Count -le $Max) { return ($names -join '、') }
                return (($names[0..($Max - 1)] -join '、') + " …等 " + $names.Count + " 个")
            }

                $rawComponents = @(
                    "",
                    @{ text = "`n[整合包更新] "; color = "gold"; bold = $true },
                    @{ text = "服务器已发布新版本，你的客户端会在后台自动下载。`n"; color = "yellow" }
                )
                if ($addedPaths.Count -gt 0)   { $rawComponents += @{ text = ("  新增：" + (Format-ModLine $addedPaths) + "`n"); color = "green" } }
                if ($updatedPaths.Count -gt 0) { $rawComponents += @{ text = ("  更新：" + (Format-ModLine $updatedPaths) + "`n"); color = "aqua" } }
                if ($removedPaths.Count -gt 0) { $rawComponents += @{ text = ("  移除：" + (Format-ModLine $removedPaths) + "`n"); color = "red" } }
                if (($addedPaths.Count + $updatedPaths.Count + $removedPaths.Count) -eq 0) { $rawComponents += @{ text = "  本次为配置 / 资源更新`n"; color = "gray" } }
                $rawComponents += @{ text = "退出游戏后重新双击脚本启动即可用上新内容（无需再等下载）。`n"; color = "gray" }
                $tellrawJson = ($rawComponents | ConvertTo-Json -Compress -Depth 5)
                try {
                    [void](& $rconScript -Command ("tellraw @a " + $tellrawJson))
                    Write-Host "[便携] 已通过 RCON 向在线玩家广播更新提示。"
                } catch {
                    Write-Host "[便携] RCON 广播跳过（服务器未运行 / 未开 RCON / 无在线玩家）：$($_.Exception.Message)"
                }
            }
        }
    } else {
        Write-Host "[便携] 本次发布与上一版无文件变化，跳过通知。"
    }
}

if ($script:PublishLockStream) { $script:PublishLockStream.Dispose(); $script:PublishLockStream = $null }

