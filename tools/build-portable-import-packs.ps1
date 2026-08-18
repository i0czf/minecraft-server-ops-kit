param(
    [string]$ConfigPath = ".\tools\portable-pack.json",
    [string]$Version = "",
    [switch]$SkipPublish,
    [switch]$PlayerOnly,
    [switch]$NoNotify
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '生成规范导入包 —— mrpack + PCL 客户端压缩包' } catch { }
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

function Copy-Children([string]$Source, [string]$Dest) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    New-Item -ItemType Directory -Force $Dest | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Dest -Recurse -Force
    }
}

function Copy-FileIfExists([string]$Source, [string]$Dest) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Dest) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Dest -Force
}

function Zip-Children([string]$SourceDir, [string]$ZipPath) {
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $zipTool = Join-Path $Root 'tools\zip-with-unix-mode.py'
    if (-not (Test-Path -LiteralPath $zipTool -PathType Leaf)) { throw "缺少压缩辅助脚本：$zipTool" }
    & python $zipTool ([System.IO.Path]::GetFullPath($SourceDir)) ([System.IO.Path]::GetFullPath($ZipPath))
    if ($LASTEXITCODE -ne 0) { throw "压缩工具执行失败，退出码 $LASTEXITCODE" }
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

function Test-NeedsAutoConfig($Cfg) {
    $sourceClientRaw = [string](Get-Value $Cfg 'sourceClient' '')
    $packIdRaw = [string](Get-Value $Cfg 'packId' '')
    $mcVersion = [string](Get-Value $Cfg 'minecraftVersion' '')
    $loaderType = [string](Get-Value $Cfg.loader 'type' '')
    $loaderVersion = [string](Get-Value $Cfg.loader 'version' '')
    foreach ($f in @($sourceClientRaw, $packIdRaw, $mcVersion, $loaderType, $loaderVersion)) {
        if ($f -match 'CHANGE-ME' -or [string]::IsNullOrWhiteSpace($f)) { return $true }
    }
    $sourceClientPath = Resolve-AnyPath $sourceClientRaw
    if (-not (Test-Path -LiteralPath $sourceClientPath -PathType Container)) { return $true }
    return $false
}

# 兜底：如果 ConfigPath 为空（常见于 bat 编码异常），回退到默认配置
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = '.\tools\portable-pack.json'
    Write-Host "[便携] ConfigPath 为空，已回退到默认配置：$ConfigPath"
}

$configFull = Resolve-AnyPath $ConfigPath
$configureScript = Join-Path $Root 'tools\configure-portable-server.ps1'

# 如果配置文件缺失，先自动生成
if (-not (Test-Path -LiteralPath $configFull -PathType Leaf)) {
    if (Test-Path -LiteralPath $configureScript -PathType Leaf) {
        Write-Host "[便携] 未找到配置文件，正在根据当前服务端自动生成..."
        $configureArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configureScript, '-Auto', '-PackConfigPath', $configFull)
        if ($PlayerOnly) { $configureArgs += '-PlayerOnly' }
        & powershell @configureArgs
        if ($LASTEXITCODE -ne 0) { throw "自动配置失败，退出码 $LASTEXITCODE" }
        if (-not (Test-Path -LiteralPath $configFull -PathType Leaf)) { throw "自动配置未生成 portable-pack.json" }
    } else {
        throw "缺少便携配置：$configFull。请先复制 tools\portable-pack.example.json 为 tools\portable-pack.json。"
    }
}

$config = Get-Content -LiteralPath $configFull -Raw -Encoding UTF8 | ConvertFrom-Json

# 继续前自动检测并填充 CHANGE-ME 占位项
if (Test-NeedsAutoConfig $config) {
    if (Test-Path -LiteralPath $configureScript -PathType Leaf) {
        Write-Host "[便携] 检测到 CHANGE-ME 占位项或 sourceClient 缺失，正在自动配置..."
        $configureArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $configureScript, '-Auto', '-PackConfigPath', $configFull)
        if ($PlayerOnly) { $configureArgs += '-PlayerOnly' }
        & powershell @configureArgs
        if ($LASTEXITCODE -ne 0) { throw "自动配置失败，退出码 $LASTEXITCODE" }
        $config = Get-Content -LiteralPath $configFull -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "[便携] 自动配置完成，正在重新读取 portable-pack.json。"
    } else {
        Write-Host "[便携] 警告：未找到 configure-portable-server.ps1，CHANGE-ME 值可能导致失败。"
    }
}

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
# 临时目录刻意用短名：pcl-client 分支要拼 .minecraft\versions\实例名\tacz\枪包名\...，
# 长名会顶到 Windows 260 字符路径上限（消费端机器未必开了 LongPathsEnabled）。
$tmp = Join-Path $Root 'tmp\pip'
$packId = [string](Get-Value $config 'packId' 'portable-pack')
$packName = [string](Get-Value $config 'packName' $packId)
$safeStem = Get-SafeStem $packName
$standardPackageName = [string](Get-Value $config 'standardPackageName' '')
$standardSafeStem = if ([string]::IsNullOrWhiteSpace($standardPackageName)) { $safeStem + '-standard-import' } else { Get-SafeStem $standardPackageName }
$pclSafeStem = if ([string]::IsNullOrWhiteSpace($standardPackageName)) { $safeStem + '-PCL-client' } else { Get-SafeStem $standardPackageName }
New-Item -ItemType Directory -Force $dist | Out-Null
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null

if ([bool](Get-Value $config.mrpack 'enabled' $true)) {
    $mrRoot = Join-Path $tmp 'mrpack'
    $overrides = Join-Path $mrRoot 'overrides'
    New-Item -ItemType Directory -Force $overrides | Out-Null

    # ---- 规范模式：mods 等大文件进 modrinth.index.json 清单（URL+sha1/sha512+体积），启动器导入时自行下载 ----
    # 下载源就是我们的更新服务（玩家同步走同一条通道）；导入时更新服务必须在线。
    # 若发布配置还没有公网地址（127.0.0.1/CHANGE-ME），自动退回「全内嵌 overrides」模式，保证离线也能导入（体积大）。
    $downloadBase = ''
    foreach ($urlFile in @('PORTABLE-UPDATE-URL.txt', 'UPDATE-URL.txt')) {
        $urlPath = Join-Path $publish $urlFile
        if (Test-Path -LiteralPath $urlPath -PathType Leaf) {
            $manifestUrl = (Get-Content -LiteralPath $urlPath -Raw -Encoding UTF8).Trim()
            if ($manifestUrl -match '^(https?://.+/)server-manifest\.json$') { $downloadBase = $matches[1]; break }
        }
    }
    if ($downloadBase -match '://(127\.0\.0\.1|localhost)[:/]') { $downloadBase = '' }
    $mrFiles = New-Object System.Collections.Generic.List[object]
    $mrCandidates = New-Object System.Collections.Generic.List[object]
    $remoteBytes = [int64]0
    # 挥发文件必须内嵌 overrides：I18n 汉化包这类「文件名不变、内容每次开客户端都重新生成」
    # 的文件，写成 URL+固定 SHA1 的清单条目必炸——服务端一重发布内容就变，旧 mrpack 导入
    # 校验失败（2026-07-08 实锤：0d95→d5fd→4e90 一小时三代）。可在 mrpack.embedGlobs 追加。
    $script:MrEmbedGlobs = Get-Array $config.mrpack 'embedGlobs' @('resourcepacks/Minecraft-Mod-Language-Modpack-Converted-*.zip')
    function Test-MrEmbedForced([string]$Rel) {
        foreach ($glob in @($script:MrEmbedGlobs)) {
            $g = ([string]$glob).Replace('\', '/')
            if (-not [string]::IsNullOrWhiteSpace($g) -and $Rel -like $g) { return $true }
        }
        return $false
    }
    function Test-MrRemoteEligible([string]$Rel) {
        # 清单化对象：模组 jar、资源包/光影包 zip——占体积的大头；配置等小杂项留在 overrides
        if (Test-MrEmbedForced $Rel) { return $false }
        if ($Rel -like 'mods/*.jar') { return $true }
        if ($Rel -like 'resourcepacks/*.zip') { return $true }
        if ($Rel -like 'shaderpacks/*.zip') { return $true }
        return $false
    }
    foreach ($name in Get-Array $config 'includeRoots' @('mods', 'config', 'defaultconfigs', 'data', 'resourcepacks', 'datapacks', 'kubejs', 'scripts')) {
        $srcRoot = Join-Path $publish ([string]$name)
        if (-not (Test-Path -LiteralPath $srcRoot -PathType Container)) { continue }
        $srcRootFull = [System.IO.Path]::GetFullPath($srcRoot)
        Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Force | ForEach-Object {
            $rel = ([string]$name + '/' + $_.FullName.Substring($srcRootFull.Length + 1)) -replace '\\', '/'
            if (Test-MrRemoteEligible $rel) {
                [void]$mrCandidates.Add([pscustomobject]@{
                    Rel = $rel
                    Full = $_.FullName
                    Size = [int64]$_.Length
                    Sha1 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA1).Hash.ToLowerInvariant()
                    Sha512 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA512).Hash.ToLowerInvariant()
                })
            } else {
                $dest = Join-Path $overrides ($rel -replace '/', '\')
                New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            }
        }
    }

    # ---- 混合下载源：先拿 sha1 批量反查 Modrinth，公开发行的 mod/资源包/光影直接用官方 CDN（cdn.modrinth.com），
    # 带宽走 Modrinth 且对 Prism 等白名单启动器友好；查不到的（汉化包、私有转换文件）回退自建更新服务；
    # API 不可达时全部回退自建源，绝不因此打断构建。 ----
    $modrinthMap = @{}
    if ($mrCandidates.Count -gt 0) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
            $lookupBody = @{ hashes = [string[]]($mrCandidates | ForEach-Object { $_.Sha1 }); algorithm = 'sha1' } | ConvertTo-Json -Depth 3
            $resp = Invoke-RestMethod -Uri 'https://api.modrinth.com/v2/version_files' -Method Post -Body $lookupBody -ContentType 'application/json' -Headers @{ 'User-Agent' = 'portable-server-kit (Minecraft ops toolkit; QQ modpack)' } -TimeoutSec 40
            foreach ($prop in $resp.PSObject.Properties) {
                foreach ($vf in $prop.Value.files) {
                    if (([string]$vf.hashes.sha1).ToLowerInvariant() -eq $prop.Name.ToLowerInvariant()) {
                        $modrinthMap[$prop.Name.ToLowerInvariant()] = [string]$vf.url
                        break
                    }
                }
            }
            Write-Host ("[便携] Modrinth 官方源反查：命中 {0} / {1} 个文件。" -f $modrinthMap.Count, $mrCandidates.Count)
        } catch {
            Write-Host ("[便携] 警告：Modrinth API 查询失败（{0}），本次清单全部使用自建更新服务地址。" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    $viaModrinth = 0
    $viaSelf = 0
    $embedded = 0
    foreach ($cand in $mrCandidates) {
        $url = ''
        if ($modrinthMap.ContainsKey($cand.Sha1)) {
            $url = $modrinthMap[$cand.Sha1]
            $viaModrinth++
        } elseif ($downloadBase) {
            $url = $downloadBase + ((($cand.Rel -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
            $viaSelf++
        }
        if ($url) {
            [void]$mrFiles.Add([ordered]@{
                path = $cand.Rel
                hashes = [ordered]@{ sha1 = $cand.Sha1; sha512 = $cand.Sha512 }
                downloads = @($url)
                fileSize = $cand.Size
            })
            $remoteBytes += $cand.Size
        } else {
            # 既没匹配 Modrinth 也没有自建公网地址：内嵌兜底，保证包可用
            $dest = Join-Path $overrides ($cand.Rel -replace '/', '\')
            New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $cand.Full -Destination $dest -Force
            $embedded++
        }
    }
    foreach ($file in Get-Array $config 'includeFiles' @('options.txt', 'servers.dat')) {
        # 实例版本 jar/json 是 PCL 离线客户端包专属：mrpack 的 dependencies 已声明加载器版本，启动器会自行安装
        if ([string]$file -match '\.(jar|json)$') { continue }
        Copy-FileIfExists (Join-Path $publish ([string]$file)) (Join-Path $overrides ([string]$file))
    }
    Copy-Children (Join-Path $publish '_updater') (Join-Path $overrides '_updater')
    # 注意：_launchers（PCL/HMCL 启动器本体，50+MB）不进 mrpack——导入 mrpack 的用户手里必然已有启动器
    foreach ($file in @('UPDATE-URL.txt', 'PORTABLE-UPDATE-URL.txt', 'UPDATE-URL-LAN.txt', 'SERVER.txt', 'README-sync.txt', '一键客户端自助修复.bat')) {
        Copy-FileIfExists (Join-Path $publish $file) (Join-Path $overrides $file)
    }
    foreach ($pair in @(
        @{ Source = '_updater\Windows-sync.bat'; Target = '更新mod-Windows端.bat' },
        @{ Source = '_updater\macOS-sync.command'; Target = '更新mod-Mac端.command' },
        @{ Source = '_updater\player-update-generic.ps1'; Target = 'player-update-generic.ps1' },
        @{ Source = '_updater\player-update-generic.py'; Target = 'player-update-generic.py' }
    )) {
        Copy-FileIfExists (Join-Path $publish $pair.Source) (Join-Path $overrides $pair.Target)
    }
    foreach ($required in @('_updater\player-self-repair.ps1', '一键客户端自助修复.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $overrides $required) -PathType Leaf)) {
            throw "Modrinth 导入包缺少客户端自助修复组件：$required。请先用新版 portable-publish.ps1 发布。"
        }
    }
    $deps = [ordered]@{ minecraft = [string](Get-Value $config 'minecraftVersion' '') }
    $loaderType = [string](Get-Value $config.loader 'type' '')
    $loaderVersion = [string](Get-Value $config.loader 'version' '')
    if ($loaderType -and $loaderVersion) {
        $loaderKey = switch ($loaderType.ToLowerInvariant()) {
            'forge'    { 'forge' }
            'neoforge' { 'neoforge' }
            default    { $loaderType + '-loader' }
        }
        $deps[$loaderKey] = $loaderVersion
    }
    $mrInstanceName = [string](Get-Value $config.mrpack 'instanceName' ([string](Get-Value $config.pcl 'instanceName' $packName)))
    if ([string]::IsNullOrWhiteSpace($mrInstanceName)) { $mrInstanceName = $packName }
    # PS5.1 坑：[ordered] 字面量里内联 @($list)（甚至单独 @($list)）会抛 Argument types do not match，必须用 .ToArray()
    $mrFilesArray = $mrFiles.ToArray()
    $index = [ordered]@{
        formatVersion = 1
        game = 'minecraft'
        versionId = $Version
        name = $mrInstanceName
        summary = [string](Get-Value $config.mrpack 'summary' ("$packName 便携规范导入包。"))
        files = $mrFilesArray
        dependencies = $deps
    }
    Write-Utf8NoBom (Join-Path $mrRoot 'modrinth.index.json') (($index | ConvertTo-Json -Depth 8) + "`n")
    Write-Utf8NoBom (Join-Path $overrides 'README-import.txt') "Imported $packName. Run 更新mod-Windows端.bat or 更新mod-Mac端.command after import when updates are announced.`r`n"
    $mrpack = Join-Path $dist ($standardSafeStem + '-' + $Version + '.mrpack')
    Zip-Children $mrRoot $mrpack
    Write-Host "[便携] 规范导入包：$mrpack"
    if ($mrFiles.Count -gt 0) {
        Write-Host ("[便携] 规范清单：{0} 个文件（约 {1} MB）——Modrinth 官方源 {2} 个，自建更新服务 {3} 个。" -f $mrFiles.Count, [math]::Round($remoteBytes / 1MB, 1), $viaModrinth, $viaSelf)
        if ($viaSelf -gt 0) {
            Write-Host ("[便携] 有 {0} 个文件走自建源——玩家导入期间请保持「开启更新服务」在线。" -f $viaSelf)
        } else {
            Write-Host '[便携] 全部清单文件都由 Modrinth 官方 CDN 提供，导入不依赖你的更新服务。'
        }
    }
    if ($embedded -gt 0) {
        Write-Host ("[便携] 提示：{0} 个文件未匹配 Modrinth 且未配置公网更新地址，已内嵌进包内兜底（体积因此变大）。" -f $embedded) -ForegroundColor Yellow
    }
}

if ([bool](Get-Value $config.pcl 'enabled' $true)) {
    $pclRoot = Join-Path $tmp 'pcl-client'
    $instanceName = [string](Get-Value $config.pcl 'instanceName' $packName)
    if ([string]::IsNullOrWhiteSpace($instanceName)) { $instanceName = $packName }
    $target = Join-Path (Join-Path (Join-Path $pclRoot '.minecraft') 'versions') $instanceName
    New-Item -ItemType Directory -Force $target | Out-Null
    foreach ($name in Get-Array $config 'includeRoots' @('mods', 'config', 'defaultconfigs', 'data', 'resourcepacks', 'datapacks', 'kubejs', 'scripts')) {
        Copy-Children (Join-Path $publish ([string]$name)) (Join-Path $target ([string]$name))
    }
    foreach ($file in Get-Array $config 'includeFiles' @('options.txt', 'servers.dat')) {
        Copy-FileIfExists (Join-Path $publish ([string]$file)) (Join-Path $target ([string]$file))
    }
    foreach ($file in @('UPDATE-URL.txt', 'PORTABLE-UPDATE-URL.txt', 'UPDATE-URL-LAN.txt', 'SERVER.txt', 'README-sync.txt', '一键客户端自助修复.bat')) {
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
    Copy-Children (Join-Path $publish '_updater') (Join-Path $target '_updater')
    Copy-Children (Join-Path $publish '_launchers') (Join-Path $target '_launchers')
    foreach ($required in @('_updater\player-self-repair.ps1', '一键客户端自助修复.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $target $required) -PathType Leaf)) {
            throw "PCL 客户端包缺少客户端自助修复组件：$required。请先用新版 portable-publish.ps1 发布。"
        }
    }
    # 实例版本描述文件：PCL/HMCL 靠 versions\<实例>\<实例>.json 识别实例，缺了它启动器打开后列表是空的。
    # 通用逻辑在 portable-pack-lib.ps1 里维护（各打包脚本共用一份，换周目/版本不必重改）。
    . (Join-Path $PSScriptRoot 'portable-pack-lib.ps1')
    $pclSourceClient = Resolve-AnyPath ([string](Get-Value $config 'sourceClient' '.\main-client'))
    if (Test-Path -LiteralPath $pclSourceClient -PathType Container) {
        Copy-InstanceVersionFiles -SourceClient $pclSourceClient -TargetVersionDir $target -InstanceName $instanceName -Tag '便携' | Out-Null
        Copy-InstanceSharedLibraries -SourceClient $pclSourceClient -TargetVersionDir $target -Tag '便携' | Out-Null
    } else {
        Write-Host "[便携] 未找到主客户端目录（sourceClient），PCL 压缩包未纳入版本 json/共享库，启动器可能识别不到实例或启动崩溃：$pclSourceClient" -ForegroundColor Yellow
    }
    Write-InstanceIsolationConfigs -TargetVersionDir $target -Tag '便携' | Out-Null
    Write-RootLaunchScripts -PackRoot $pclRoot -Tag '便携' | Out-Null
    Write-Utf8NoBom (Join-Path $pclRoot 'README-PCL-import.txt') "PCL client compressed package for $packName. Instance: $instanceName.`r`nWindows 双击根目录「更新mod-Windows端.bat」、Mac 双击「更新mod-Mac端.command」即可自动同步并启动（Mac 首次被拦截时右键→打开）。`r`n"
    $pclZip = Join-Path $dist ($pclSafeStem + '-' + $Version + '.zip')
    Zip-Children $pclRoot $pclZip
    Write-Host "[便携] PCL 客户端压缩包：$pclZip"
}

