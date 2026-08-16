param(
    [string]$ConfigPath = ".\tools\portable-pack.json",
    [string]$Version = "",
    [switch]$SkipPublish,
    [switch]$NoNotify
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '打包完整包 —— 含枪皮/光影的完整客户端 zip' } catch { }
$ProgressPreference = "SilentlyContinue"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

function Resolve-AnyPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}
function Resolve-InRoot([string]$Path) {
    $full = Resolve-AnyPath $Path
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw "拒绝写入服务端根目录之外：$full" }
    return $full
}
function Write-Utf8NoBom([string]$Path, [string]$Value) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}
function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $Default
}
function Get-Array($Object, [string]$Name, [object[]]$Default = @()) {
    if ($Object -and $Object.PSObject.Properties[$Name]) { return @($Object.PSObject.Properties[$Name].Value) }
    return $Default
}
function Get-SafeStem([string]$Name) {
    $safe = $Name.Trim()
    foreach ($bad in [System.IO.Path]::GetInvalidFileNameChars()) { $safe = $safe.Replace($bad, '-') }
    $safe = $safe -replace '\s+', '-'
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'portable-pack' }
    return $safe
}
function Test-RelativePathSafe([string]$Rel) {
    $normalized = ([string]$Rel).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:') { return $false }
    foreach ($part in $normalized.Split('/')) { if ($part -eq '..') { return $false } }
    return $true
}
function Test-GlobMatch([string]$Rel, $Globs) {
    $normalized = ([string]$Rel).Replace('\', '/')
    foreach ($glob in @($Globs)) {
        $g = ([string]$glob).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($g)) { continue }
        if ($normalized -like $g) { return $true }
    }
    return $false
}
function Copy-FileIfExists([string]$Source, [string]$Dest) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Dest) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Dest -Force
}
function Copy-Children([string]$Source, [string]$Dest) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    New-Item -ItemType Directory -Force $Dest | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Dest -Recurse -Force }
}
function Copy-RootFromClient([string]$SourceRoot, [string]$DestRoot, [string]$Name, $ExcludeGlobs) {
    # 从主客户端整目录复制到完整包，逐文件套 excludeGlobs（排除 tacz_default_gun、日志、存档等）。
    $srcDir = Join-Path $SourceRoot $Name
    if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) { return 0 }
    $srcFull = [System.IO.Path]::GetFullPath($srcDir)
    $count = 0
    Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force | ForEach-Object {
        $localRel = $_.FullName.Substring($srcFull.Length).TrimStart('\', '/') -replace '\\', '/'
        $rel = if ([string]::IsNullOrWhiteSpace($localRel)) { $Name } else { ($Name + '/' + $localRel) }
        if (Test-GlobMatch $rel $ExcludeGlobs) { return }
        $dest = Join-Path $DestRoot ($rel -replace '/', '\')
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        $count++
    }
    return $count
}
function Zip-Children([string]$SourceDir, [string]$ZipPath) {
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $zipTool = Join-Path $Root 'tools\zip-with-unix-mode.py'
    if (-not (Test-Path -LiteralPath $zipTool -PathType Leaf)) { throw "缺少压缩辅助脚本：$zipTool" }
    & python $zipTool ([System.IO.Path]::GetFullPath($SourceDir)) ([System.IO.Path]::GetFullPath($ZipPath))
    if ($LASTEXITCODE -ne 0) { throw "压缩工具执行失败，退出码 $LASTEXITCODE" }
}

$configFull = Resolve-AnyPath $ConfigPath
if (-not (Test-Path -LiteralPath $configFull -PathType Leaf)) { throw "缺少便携配置：$configFull。请先运行初始化配置向导。" }
$config = Get-Content -LiteralPath $configFull -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string](Get-Value $config 'version' '') }
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = Get-Date -Format 'yyyyMMdd-HHmmss' }

# 完整包依赖一次发布：_updater / UPDATE-URL / server-manifest.json 从发布源取，
# 玩家装完完整包后仍能走日常增量同步（枪皮等大件已在本地、不随更新变动）。
if (-not $SkipPublish) {
    $publishArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'tools\portable-publish.ps1'), '-ConfigPath', $configFull, '-Version', $Version)
    if ($NoNotify) { $publishArgs += '-NoNotify' }
    & powershell @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "便携发布失败，退出码 $LASTEXITCODE" }
}

$sourceClientRaw = [string](Get-Value $config 'sourceClient' '')
if ([string]::IsNullOrWhiteSpace($sourceClientRaw)) { $sourceClientRaw = '.\main-client' }
$sourceClient = Resolve-AnyPath $sourceClientRaw
if (-not (Test-Path -LiteralPath $sourceClient -PathType Container)) {
    Write-Host ''
    Write-Host "[完整包] 还不能打包：主分发客户端目录不存在：$sourceClient" -ForegroundColor Red
    Write-Host '完整包直接从主客户端打包全部大件（枪皮/光影/材质/资源包），必须先设置主客户端：' -ForegroundColor Yellow
    Write-Host '  - 面板点「选择主客户端…」指定实例目录，或运行初始化配置向导。' -ForegroundColor Yellow
    exit 1
}

$publish = Resolve-InRoot ([string](Get-Value $config 'publishDir' '.\modpack-public\portable'))
$dist = Resolve-InRoot ([string](Get-Value $config 'distDir' '.\dist'))
$packId = [string](Get-Value $config 'packId' 'portable-pack')
$packName = [string](Get-Value $config 'packName' $packId)
$safeStem = Get-SafeStem $packName
$fullPackageName = [string](Get-Value $config 'fullPackageName' '')
$fullSafeStem = if ([string]::IsNullOrWhiteSpace($fullPackageName)) { $safeStem + '-full-client' } else { Get-SafeStem $fullPackageName }
$instanceName = [string](Get-Value $config.pcl 'instanceName' $packName)
if ([string]::IsNullOrWhiteSpace($instanceName)) { $instanceName = $packName }

$excludeGlobs = Get-Array $config 'excludeGlobs' @()
$includeRoots = Get-Array $config 'includeRoots' @('mods', 'config', 'defaultconfigs', 'data', 'resourcepacks', 'datapacks', 'kubejs', 'scripts', 'shaderpacks')
$fullPack = Get-Value $config 'fullPack' $null
$extraRoots = Get-Array $fullPack 'extraRoots' @('tacz')
$allRoots = @(@($includeRoots) + @($extraRoots) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

# 临时目录用短名 tmp\fp：完整包内 .minecraft\versions\实例\tacz\枪包\...\很深，长名会顶到 260 上限。
$tmp = Join-Path $Root 'tmp\fp'
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
$target = Join-Path (Join-Path (Join-Path $tmp '.minecraft') 'versions') $instanceName
New-Item -ItemType Directory -Force $target | Out-Null
New-Item -ItemType Directory -Force $dist | Out-Null

Write-Host "[完整包] 正在从主客户端打包完整资源（含枪皮/光影/材质/资源包），体积较大请耐心等待…"
$copied = 0
foreach ($name in $allRoots) {
    $n = [string]$name
    if (-not (Test-RelativePathSafe $n)) { continue }
    $c = Copy-RootFromClient $sourceClient $target $n $excludeGlobs
    if ($c -gt 0) { Write-Host ("[完整包] 已纳入 {0}：{1} 个文件" -f $n, $c) }
    $copied += $c
}
foreach ($file in Get-Array $config 'includeFiles' @('options.txt', 'servers.dat')) {
    Copy-FileIfExists (Join-Path $sourceClient ([string]$file)) (Join-Path $target ([string]$file))
}

# 实例版本描述文件：PCL/HMCL 靠 versions\<实例>\<实例>.json 识别实例，缺了它启动器打开后列表是空的。
# 通用逻辑在 portable-pack-lib.ps1 里维护（各打包脚本共用一份，换周目/版本不必重改）。
. (Join-Path $PSScriptRoot 'portable-pack-lib.ps1')
Copy-InstanceVersionFiles -SourceClient $sourceClient -TargetVersionDir $target -InstanceName $instanceName -Tag '完整包' | Out-Null
Copy-InstanceSharedLibraries -SourceClient $sourceClient -TargetVersionDir $target -Tag '完整包' | Out-Null
Write-InstanceIsolationConfigs -TargetVersionDir $target -Tag '完整包' | Out-Null

# 更新器 / 更新地址 / 清单 / 启动器：从发布源取，装完能继续增量同步
Copy-Children (Join-Path $publish '_updater') (Join-Path $target '_updater')
Copy-Children (Join-Path $publish '_launchers') (Join-Path $target '_launchers')
foreach ($file in @('UPDATE-URL.txt', 'PORTABLE-UPDATE-URL.txt', 'SERVER.txt', 'README-sync.txt', 'server-manifest.json', '一键客户端自助修复.bat')) {
    Copy-FileIfExists (Join-Path $publish $file) (Join-Path $target $file)
}
foreach ($pair in @(
    @{ Source = '_updater\Windows-sync.bat'; Target = '更新mod-Windows端.bat' },
    @{ Source = '_updater\macOS-sync.command'; Target = '更新mod-Mac端.command' },
    @{ Source = '_updater\player-update-generic.ps1'; Target = 'player-update-generic.ps1' },
    @{ Source = '_updater\player-update-generic.py'; Target = 'player-update-generic.py' }
)) {
    Copy-FileIfExists (Join-Path $publish $pair.Source) (Join-Path $target $pair.Target)
}
foreach ($required in @('_updater\player-self-repair.ps1', '一键客户端自助修复.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $target $required) -PathType Leaf)) {
        throw "完整客户端包缺少客户端自助修复组件：$required。请先用新版 portable-publish.ps1 发布。"
    }
}

Write-RootLaunchScripts -PackRoot $tmp -Tag '完整包' | Out-Null

Write-Utf8NoBom (Join-Path $tmp 'README-完整包.txt') @"
$packName 完整客户端包（自带枪皮 / 光影 / 材质 / 各类资源包等全部大件）。

用法：
  1. 解压到任意目录（路径不要太深、别放桌面同步盘）。
  2. Windows 双击根目录的「更新mod-Windows端.bat」，
     Mac 双击根目录的「更新mod-Mac端.command」（首次被系统拦截时右键→打开），
     自动同步更新并拉起启动器，在启动器里选择 $instanceName 实例即可进服。
     也可用自己的 PCL / HMCL 手动打开 .minecraft\versions\$instanceName 实例。

之后更新：无需再下大件，日常更新只要再次运行同步脚本，自动增量更新 mods / config 等；
枪皮等大件不随日常更新变动，也不会被同步删除。
服务器地址见 SERVER.txt。
"@

$zip = Join-Path $dist ($fullSafeStem + '-' + $Version + '.zip')
Zip-Children $tmp $zip
Write-Host ''
Write-Host "[完整包] 已生成完整客户端包：$zip"
Write-Host ("[完整包] 打包目录 {0} 个大类，共复制 {1} 个源文件。" -f $allRoots.Count, $copied)
Write-Host "[完整包] 这个包发给拉新玩家一次装好；日常增量更新照旧点「仅发布更新」，玩家跑同步脚本即可。"
