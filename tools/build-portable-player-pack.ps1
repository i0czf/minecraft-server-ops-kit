param(
    [string]$ConfigPath = ".\tools\portable-pack.json",
    [string]$Version = "",
    [switch]$SkipImportPacks,
    [switch]$SkipPublish,
    [switch]$PlayerOnly,
    [switch]$NoNotify
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '生成玩家包' } catch { }
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

function Zip-Children([string]$SourceDir, [string]$ZipPath) {
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $zipTool = Join-Path $Root 'tools\zip-with-unix-mode.py'
    & python $zipTool ([System.IO.Path]::GetFullPath($SourceDir)) ([System.IO.Path]::GetFullPath($ZipPath))
    if ($LASTEXITCODE -ne 0) { throw "压缩工具执行失败，退出码 $LASTEXITCODE" }
}

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $Default
}

function Get-SafeStem([string]$Name) {
    $safe = $Name.Trim()
    foreach ($bad in [System.IO.Path]::GetInvalidFileNameChars()) { $safe = $safe.Replace($bad, '-') }
    $safe = $safe -replace '\s+', '-'
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'portable-pack' }
    return $safe
}

$configFull = Resolve-AnyPath $ConfigPath
if (-not (Test-Path -LiteralPath $configFull -PathType Leaf)) { throw "缺少便携配置：$configFull" }
$config = Get-Content -LiteralPath $configFull -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string](Get-Value $config 'version' '') }
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = Get-Date -Format 'yyyyMMdd-HHmmss' }

if (-not $SkipPublish) {
    $publishArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'tools\portable-publish.ps1'), '-ConfigPath', $configFull, '-Version', $Version)
    if ($NoNotify) { $publishArgs += '-NoNotify' }
    & powershell @publishArgs
    if ($LASTEXITCODE -ne 0) { throw "便携发布失败，退出码 $LASTEXITCODE" }
}

$publish = Resolve-InRoot ([string](Get-Value $config 'publishDir' '.\modpack-public\portable'))
$dist = Resolve-InRoot ([string](Get-Value $config 'distDir' '.\dist'))
$tmp = Join-Path $Root 'tmp\portable-player-pack'
$packName = [string](Get-Value $config 'packName' (Get-Value $config 'packId' 'portable-pack'))
$safeStem = Get-SafeStem $packName
$packRoot = Join-Path $tmp $safeStem
New-Item -ItemType Directory -Force $dist | Out-Null
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $packRoot | Out-Null

Copy-Children (Join-Path $publish '_updater') (Join-Path $packRoot '_updater')
foreach ($pair in @(
    @{ Source = '_updater\Windows-sync.bat'; Target = 'Windows-sync.bat' },
    @{ Source = '_updater\macOS-sync.command'; Target = 'macOS-sync.command' },
    @{ Source = '_updater\player-update-generic.ps1'; Target = 'player-update-generic.ps1' },
    @{ Source = '_updater\player-update-generic.py'; Target = 'player-update-generic.py' },
    @{ Source = 'UPDATE-URL.txt'; Target = 'UPDATE-URL.txt' },
    @{ Source = 'PORTABLE-UPDATE-URL.txt'; Target = 'PORTABLE-UPDATE-URL.txt' },
    @{ Source = 'SERVER.txt'; Target = 'SERVER.txt' },
    @{ Source = 'server-manifest.json'; Target = 'server-manifest.json' },
    @{ Source = 'README-sync.txt'; Target = 'README-sync.txt' },
    @{ Source = '一键客户端自助修复.bat'; Target = '一键客户端自助修复.bat' }
)) {
    Copy-FileIfExists (Join-Path $publish $pair.Source) (Join-Path $packRoot $pair.Target)
}
foreach ($required in @('_updater\player-self-repair.ps1', '一键客户端自助修复.bat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $packRoot $required) -PathType Leaf)) {
        throw "玩家同步包缺少客户端自助修复组件：$required。请先用新版 portable-publish.ps1 发布。"
    }
}
Write-Utf8NoBom (Join-Path $packRoot 'README-first.txt') "请运行 Windows-sync.bat 或 macOS-sync.command，把 $packName 下载到当前文件夹。服务器地址见 SERVER.txt；客户端异常时可双击 一键客户端自助修复.bat。`r`n"
$zip = Join-Path $dist ($safeStem + '-player-sync-pack-' + $Version + '.zip')
Zip-Children $packRoot $zip
Write-Host "[便携] 玩家同步包：$zip"

if (-not $SkipImportPacks) {
    $importArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'tools\build-portable-import-packs.ps1'), '-ConfigPath', $configFull, '-Version', $Version, '-SkipPublish')
    if ($PlayerOnly) { $importArgs += '-PlayerOnly' }
    if ($NoNotify) { $importArgs += '-NoNotify' }
    & powershell @importArgs
    if ($LASTEXITCODE -ne 0) { throw "生成规范导入包失败，退出码 $LASTEXITCODE" }
}

