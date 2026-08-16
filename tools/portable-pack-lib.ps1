# ============================================================
# 便携打包公共函数库（portable-pack-lib.ps1）
# 各打包脚本 dot-source 本文件复用，逻辑只此一份，换周目/换版本/换加载器不必改各脚本：
#   . (Join-Path $PSScriptRoot 'portable-pack-lib.ps1')
#
# 核心约定一：凡是打出「.minecraft\versions\<实例>」结构的客户端包，
# 必须包含 <实例>.json 版本描述文件——PCL/HMCL 全靠它识别实例，缺了启动器列表为空。
# 本库负责从主客户端实例目录找到版本 json/jar 并正确落位，完全通用：
#   - 不假设实例名、MC 版本、加载器；json 文件名与目录名不一致（手动改过名）也能识别
#   - 合并式 json（PCL/HMCL 安装的常态）与带 inheritsFrom 的分体式 json 都支持，
#     后者自动连带父版本 json/jar 一起入包（父版本缺失只警告，启动器可自行补全）
#
# 核心约定二：Forge/NeoForge 的加载器补丁 jar（如 neoforge-<版本>-universal.jar）存放在
# 共享目录 .minecraft\libraries（与 versions 同级，不是每实例私有），且不在版本 json 的
# libraries 列表里——启动器不知道去哪下载它，必须整个 libraries 目录随包带走，否则 FML 的
# PathBasedLocator 在目标机器上找不到这个 jar，直接报"缺失 neoforge/minecraft 前置"崩溃退出
# （2026-07-20 完整包实测复现：mods/config 全部就位、json/jar 也补上了，仍在这一步崩溃）。
# 本库的 Copy-InstanceSharedLibraries 负责把这份共享库整体带上，同样不假设实例名/版本号。
# ============================================================

function Write-PackLibText([string]$Path, [string]$Value) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Test-VersionManifestObject($Json) {
    # 版本描述 json 的特征：有 id，且有 mainClass（合并式）或 inheritsFrom（分体式）
    if (-not $Json) { return $false }
    if (-not $Json.PSObject.Properties['id']) { return $false }
    return [bool]($Json.PSObject.Properties['mainClass'] -or $Json.PSObject.Properties['inheritsFrom'])
}

function Find-InstanceVersionJson([string]$SourceClient) {
    # 在实例目录顶层定位版本描述 json。返回 @{ Json; Stem; Parsed }（Parsed 解析失败为 $null），找不到返回 $null。
    $leaf = Split-Path -Leaf $SourceClient
    $preferred = Join-Path $SourceClient ($leaf + '.json')
    if (Test-Path -LiteralPath $preferred -PathType Leaf) {
        $parsed = $null
        try { $parsed = Get-Content -LiteralPath $preferred -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        return @{ Json = $preferred; Stem = $leaf; Parsed = $parsed }
    }
    # 目录被手动改过名等情况：扫描顶层全部 json，认「长得像版本描述」的候选
    $candidates = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $SourceClient -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if (Test-VersionManifestObject $j) {
                $candidates += , @{ Json = $f.FullName; Stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name); Parsed = $j }
            }
        } catch { }
    }
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -gt 1) {
        Write-Host ("[打包库] 实例目录有 {0} 个疑似版本 json，取第一个：{1}（如不对请把正确的一个改成与目录同名）" -f $candidates.Count, $candidates[0].Stem) -ForegroundColor Yellow
    }
    return $candidates[0]
}

function Copy-InstanceVersionFiles {
    <#
      把主客户端实例的版本描述 json（顶层 id 对齐包内实例名）与主 jar 复制进包内版本目录。
      分体式 json 会连带父版本。任何打出 .minecraft\versions 结构的打包脚本都应调用本函数。
        -SourceClient      主客户端实例目录（.minecraft\versions 下的那个目录）
        -TargetVersionDir  包内 .minecraft\versions\<实例名> 目录
        -InstanceName      包内实例名
        -Tag               日志前缀（如 完整包 / 便携），仅影响输出样式
      找不到版本 json 时抛异常（否则打出的包启动器识别不到，宁可失败也不出废包）。
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$SourceClient,
        [Parameter(Mandatory = $true)] [string]$TargetVersionDir,
        [Parameter(Mandatory = $true)] [string]$InstanceName,
        [string]$Tag = '打包'
    )
    $found = Find-InstanceVersionJson $SourceClient
    if (-not $found) {
        throw ("[{0}] 主客户端缺少版本描述文件（实例目录顶层没有任何含 id+mainClass/inheritsFrom 的 json）：{1}。sourceClient 必须指向 .minecraft\versions 下的实例目录，否则打出的包无法被 PCL/HMCL 识别。" -f $Tag, $SourceClient)
    }
    $jsonText = Get-Content -LiteralPath $found.Json -Raw -Encoding UTF8
    $parsed = $found.Parsed
    if ($parsed) {
        try {
            if ($parsed.PSObject.Properties['id']) { $parsed.id = $InstanceName }
            $jsonText = $parsed | ConvertTo-Json -Depth 100
        } catch {
            Write-Host ("[{0}] 版本 json 重写失败，按原样纳入（id 保持 '{1}'，启动器一般也能识别）：{2}" -f $Tag, $found.Stem, $_.Exception.Message) -ForegroundColor Yellow
        }
    } else {
        Write-Host ("[{0}] 版本 json 解析失败，按原样纳入（id 未对齐实例名，启动器一般也能识别）。" -f $Tag) -ForegroundColor Yellow
    }
    Write-PackLibText (Join-Path $TargetVersionDir ($InstanceName + '.json')) $jsonText
    Write-Host ("[{0}] 已纳入实例版本描述：{1}.json" -f $Tag, $InstanceName)

    $jarCopied = $false
    foreach ($stem in @($found.Stem, (Split-Path -Leaf $SourceClient)) | Select-Object -Unique) {
        $jar = Join-Path $SourceClient ([string]$stem + '.jar')
        if (Test-Path -LiteralPath $jar -PathType Leaf) {
            New-Item -ItemType Directory -Force $TargetVersionDir | Out-Null
            Copy-Item -LiteralPath $jar -Destination (Join-Path $TargetVersionDir ($InstanceName + '.jar')) -Force
            Write-Host ("[{0}] 已纳入客户端主 jar：{1}.jar" -f $Tag, $InstanceName)
            $jarCopied = $true
            break
        }
    }
    if (-not $jarCopied) {
        Write-Host ("[{0}] 主客户端没有实例 jar，跳过（启动器会在首次启动时自动补全下载）。" -f $Tag) -ForegroundColor Yellow
    }

    # 分体式 json：连带父版本（如原版 1.21.1），父版本 id 不改名
    if ($parsed -and $parsed.PSObject.Properties['inheritsFrom'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.inheritsFrom)) {
        $parentId = [string]$parsed.inheritsFrom
        $sourceVersionsDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($SourceClient))
        $parentSrc = Join-Path $sourceVersionsDir $parentId
        $parentJson = Join-Path $parentSrc ($parentId + '.json')
        if (Test-Path -LiteralPath $parentJson -PathType Leaf) {
            $parentTarget = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($TargetVersionDir))) $parentId
            New-Item -ItemType Directory -Force $parentTarget | Out-Null
            Copy-Item -LiteralPath $parentJson -Destination (Join-Path $parentTarget ($parentId + '.json')) -Force
            $parentJar = Join-Path $parentSrc ($parentId + '.jar')
            if (Test-Path -LiteralPath $parentJar -PathType Leaf) {
                Copy-Item -LiteralPath $parentJar -Destination (Join-Path $parentTarget ($parentId + '.jar')) -Force
            }
            Write-Host ("[{0}] 版本为分体式（inheritsFrom={1}），已连带父版本入包。" -f $Tag, $parentId)
        } else {
            Write-Host ("[{0}] 版本为分体式（inheritsFrom={1}）但源客户端缺父版本，启动器首次启动会自动下载父版本。" -f $Tag, $parentId) -ForegroundColor Yellow
        }
    }
    return $true
}

function Write-InstanceIsolationConfigs {
    <#
      写入 HMCL / PCL 的「版本隔离」配置，强制两家启动器都以实例目录为游戏运行目录。
      背景：包内 mods / servers.dat 等全部在 .minecraft\versions\<实例>\ 下（版本隔离结构）。
      PCL 默认「自动隔离含 mod 的版本」所以 Windows 端一直没事；HMCL 默认不隔离，直接拿
      .minecraft 根目录当运行目录——结果是 0 个 mod 被加载、服务器列表为空，进服因缺全部
      模组网络通道被踢（2026-07-20 Mac 端 latest.log 实锤：Mod List 只有 minecraft+neoforge）。
        -TargetVersionDir  包内 .minecraft\versions\<实例名> 目录
        -Tag               日志前缀，仅影响输出样式
      已存在的同名文件不覆盖（尊重源客户端/管理员手动放入的配置）。
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$TargetVersionDir,
        [string]$Tag = '打包'
    )
    $hmclCfg = Join-Path $TargetVersionDir 'hmclversion.cfg'
    if (-not (Test-Path -LiteralPath $hmclCfg -PathType Leaf)) {
        # gameDirType：0=共用 .minecraft 根目录，1=版本目录隔离。只写这两个键，其余走 HMCL 默认。
        Write-PackLibText $hmclCfg "{`n  `"usesGlobal`": false,`n  `"gameDirType`": 1`n}`n"
    }
    $pclSetup = Join-Path (Join-Path $TargetVersionDir 'PCL') 'Setup.ini'
    if (-not (Test-Path -LiteralPath $pclSetup -PathType Leaf)) {
        # 防玩家把 PCL 全局设置改成「关闭版本隔离」：按版本强制隔离，其余键 PCL 自行补全。
        Write-PackLibText $pclSetup "VersionArgumentIndieV2:True`r`n"
    }
    Write-Host ("[{0}] 已写入版本隔离配置（hmclversion.cfg + PCL\Setup.ini），HMCL/PCL 均从实例目录加载 mods 与服务器列表。" -f $Tag)
    return $true
}

function Write-RootLaunchScripts {
    <#
      在解压根目录生成「更新mod-Windows端.bat / 更新mod-Mac端.command」两个入口，
      自动定位 .minecraft\versions\<实例>\_updater\ 下的同步脚本并转交执行。
      不写死实例名（换周目/实例改名照常工作）；转交后由原同步脚本自行定位实例目录、
      把启动器落位到 .minecraft 同级目录再拉起，启动器里的实例显示逻辑完全不受影响。
        -PackRoot  打包临时目录（解压后即玩家看到的根目录）
        -Tag       日志前缀，仅影响输出样式
      注意：bat 必须 CRLF + UTF-8 无 BOM 且 cmd 解析行全 ASCII（中文一律走 powershell
      Write-Host，详见 portable-windows-sync.bat 头部维护说明）；.command 必须 LF + shebang
      开头，zip-with-unix-mode.py 打包时会给 .command 落 0755 可执行位并做格式校验。
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$PackRoot,
        [string]$Tag = '打包'
    )
    $batLines = @(
        '@echo off',
        'setlocal EnableExtensions',
        'chcp 65001 >nul',
        'rem Root entry: locate the instance updater script and delegate to it.',
        'rem Keep CRLF + UTF-8 no BOM; keep every cmd-parsed line ASCII-only.',
        'cd /d "%~dp0"',
        'set "INNER="',
        'for /d %%D in (".minecraft\versions\*") do if not defined INNER if exist "%%~fD\_updater\Windows-sync.bat" set "INNER=%%~fD\_updater\Windows-sync.bat"',
        'if defined INNER goto :Run',
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''[错误] 未找到实例同步脚本（.minecraft\versions\实例\_updater\Windows-sync.bat）。''; Write-Host ''请确认压缩包已完整解压（不要在压缩软件里直接双击运行）。''; Write-Host ''按回车键关闭窗口...''"',
        'pause >nul',
        'exit /b 1',
        ':Run',
        'call "%INNER%"',
        'exit /b %ERRORLEVEL%'
    )
    Write-PackLibText (Join-Path $PackRoot '更新mod-Windows端.bat') (($batLines -join "`r`n") + "`r`n")
    $cmdLines = @(
        '#!/usr/bin/env bash',
        '# 根目录启动入口：定位 .minecraft/versions/<实例>/_updater/macOS-sync.command 并转交执行。',
        '# 同步脚本会从 .minecraft 上层目录拉起 HMCL，启动器里的实例显示不受影响。',
        'set -e',
        'cd "$(dirname "$0")"',
        'for d in .minecraft/versions/*/; do',
        '  inner="${d}_updater/macOS-sync.command"',
        '  if [ -f "$inner" ]; then',
        '    exec bash "$inner"',
        '  fi',
        'done',
        'echo "[错误] 未找到实例同步脚本：.minecraft/versions/<实例>/_updater/macOS-sync.command"',
        'echo "请确认压缩包已完整解压后再运行本脚本。"',
        'read -r -p "按回车关闭。"',
        'exit 1'
    )
    Write-PackLibText (Join-Path $PackRoot '更新mod-Mac端.command') (($cmdLines -join "`n") + "`n")
    Write-Host ("[{0}] 已生成根目录玩家更新脚本：更新mod-Windows端.bat / 更新mod-Mac端.command（自动定位实例并转交原同步脚本）。" -f $Tag)
    return $true
}

function Get-MinecraftRootFromVersionDir([string]$VersionDir) {
    # 从 .minecraft\versions\<实例> 反推 .minecraft 根目录（两级向上）。
    # 目录不叫 versions/.minecraft（改过名等）时按位置推断仍然生效，只是跳过校验提示。
    $full = [System.IO.Path]::GetFullPath($VersionDir)
    $versionsDir = Split-Path -Parent $full
    $mcRoot = Split-Path -Parent $versionsDir
    if ((Split-Path -Leaf $versionsDir) -ine 'versions') {
        Write-Host ("[打包库] 目录结构不是标准的 .minecraft\versions\<实例>（上级目录名是 '{0}'），按位置继续推断共享库目录，如不对请检查 sourceClient 配置。" -f (Split-Path -Leaf $versionsDir)) -ForegroundColor Yellow
    }
    return $mcRoot
}

function Copy-InstanceSharedLibraries {
    <#
      把主客户端 .minecraft\libraries（共享库，含 Forge/NeoForge 加载器补丁 jar 等版本 json
      里查不到下载地址的本地专属文件）整体复制进包内 .minecraft\libraries。
      任何打出 .minecraft\versions 结构、且要求"解压即用/无需玩家自装加载器"的打包脚本都应调用本函数
      （包括「打包完整包」和"PCL 客户端压缩包"这类自带更新器/启动器、期待开箱即用的包；
      走 mrpack/规范导入协议的包不需要——那条路径本来就是靠启动器自己安装加载器）。
        -SourceClient      主客户端实例目录（.minecraft\versions 下的那个目录）
        -TargetVersionDir  包内 .minecraft\versions\<实例名> 目录（用来推出包内 .minecraft 根）
        -Tag               日志前缀，仅影响输出样式
      源客户端没有 libraries 目录时只警告不报错（走绿色路径的纯 vanilla 测试环境可能没有）。
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$SourceClient,
        [Parameter(Mandatory = $true)] [string]$TargetVersionDir,
        [string]$Tag = '打包'
    )
    $srcRoot = Get-MinecraftRootFromVersionDir $SourceClient
    $srcLibs = Join-Path $srcRoot 'libraries'
    if (-not (Test-Path -LiteralPath $srcLibs -PathType Container)) {
        Write-Host ("[{0}] 主客户端没有 libraries 共享库目录，跳过（若目标加载器需要本地专属 jar，缺了会导致玩家端启动崩溃，请确认 sourceClient 指向的是完整安装过的客户端）：{1}" -f $Tag, $srcLibs) -ForegroundColor Yellow
        return $false
    }
    $targetRoot = Get-MinecraftRootFromVersionDir $TargetVersionDir
    $targetLibs = Join-Path $targetRoot 'libraries'
    $files = Get-ChildItem -LiteralPath $srcLibs -Recurse -File -Force
    $srcFull = [System.IO.Path]::GetFullPath($srcLibs)
    $totalBytes = 0L
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($srcFull.Length).TrimStart('\', '/')
        $dest = Join-Path $targetLibs $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        $totalBytes += $f.Length
    }
    Write-Host ("[{0}] 已纳入共享库目录 libraries：{1} 个文件，约 {2:N0} MB（含加载器补丁 jar，启动器无法自动下载的部分）" -f $Tag, $files.Count, ($totalBytes / 1MB))
    return $true
}
