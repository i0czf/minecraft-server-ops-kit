param(
    [string]$PackConfigPath = ".\tools\portable-pack.json",
    [string]$OpsConfigPath = ".\tools\ops-config.json",
    [switch]$Auto,
    [switch]$DryRun,
    [switch]$PlayerOnly
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '初始化配置向导 —— 自动识别本服版本并生成配置' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch {}

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Resolve-RootPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Get-RelativeDisplayPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $full = [System.IO.Path]::GetFullPath((Resolve-RootPath $Path))
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($rootFull.Length).TrimStart('\', '/')
        if ([string]::IsNullOrWhiteSpace($rel)) { return "." }
        return ".\$rel"
    }
    return $full
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-JsonFile([string]$Path, $Object) {
    Write-Utf8NoBom -Path $Path -Value (($Object | ConvertTo-Json -Depth 80) + "`r`n")
}

function Merge-MissingJsonProperties($Target, $Template) {
    if (-not $Target -or -not $Template) { return }
    foreach ($prop in @($Template.PSObject.Properties)) {
        if (-not $Target.PSObject.Properties[$prop.Name]) {
            # Clone the subtree so editing the generated config never mutates the template object.
            $clone = ($prop.Value | ConvertTo-Json -Depth 80) | ConvertFrom-Json
            $Target | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $clone
        } elseif ($prop.Value -is [pscustomobject] -and $Target.PSObject.Properties[$prop.Name].Value -is [pscustomobject]) {
            Merge-MissingJsonProperties -Target $Target.PSObject.Properties[$prop.Name].Value -Template $prop.Value
        }
    }
}

function Set-JsonValue($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-JsonValue($Object, [string]$Name, $Default = $null) {
    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $Default
}

function Test-UsefulValue($Value) {
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    if ($s -match 'CHANGE-ME|example\.com|My Minecraft Server|My Server Pack|my-server-pack|A Minecraft Server|A-Minecraft-Server') { return $false }
    return $true
}

function Get-FirstUseful([object[]]$Values, [string]$Fallback) {
    foreach ($v in $Values) { if (Test-UsefulValue $v) { return [string]$v } }
    return $Fallback
}

function ConvertTo-PackId([string]$Name) {
    $s = ([string]$Name).Trim()
    $s = $s -replace '\s+', '-'
    $s = $s -replace '[^A-Za-z0-9._-]', '-'
    $s = $s.Trim('-')
    $s = $s -replace '-{2,}', '-'
    if ([string]::IsNullOrWhiteSpace($s)) { return 'server-pack' }
    return $s
}

function Read-ServerProperties([string]$Path) {
    $props = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $props }
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) { continue }
        if ($line.StartsWith('!')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim().Trim([char]0xFEFF)
        $value = $line.Substring($eq + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $props[$key] = $value
    }
    return $props
}

function Get-Prop($Props, [string]$Name, [string]$Default = '') {
    if ($Props.Contains($Name)) { return [string]$Props[$Name] }
    return $Default
}

function Test-IsInsideServerRoot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath((Resolve-RootPath $Path)).TrimEnd('\', '/')
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        return ($full -ieq $rootFull) -or $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Add-Candidate($List, [string]$Path, [string]$Reason, [bool]$External = $false) {
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $full = Resolve-RootPath $Path
        if (Test-Path -LiteralPath $full -PathType Container) {
            $hasMods = Test-Path -LiteralPath (Join-Path $full 'mods') -PathType Container
            $hasMcMods = Test-Path -LiteralPath (Join-Path $full '.minecraft\mods') -PathType Container
            if ($hasMods -or $hasMcMods) {
                $exists = $false
                foreach ($item in $List) {
                    if ([string]::Equals([System.IO.Path]::GetFullPath($item.FullPath), $full, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $exists = $true
                        break
                    }
                }
                if (-not $exists) {
                    [void]$List.Add([pscustomobject]@{ FullPath = $full; Display = Get-RelativeDisplayPath $full; Reason = $Reason; External = $External })
                }
            }
        }
    }
}

function Add-ScopedCandidate($LocalList, $ExternalList, [string]$Path, [string]$Reason) {
    if (Test-IsInsideServerRoot $Path) {
        Add-Candidate $LocalList $Path $Reason
    } else {
        Add-Candidate $ExternalList $Path ("$Reason（外部路径，仅候选）") $true
    }
}

function Add-LauncherVersionCandidates($LocalList, $ExternalList, [string]$BasePath, [string]$Reason) {
    if ([string]::IsNullOrWhiteSpace($BasePath)) { return }
    $baseFull = Resolve-RootPath $BasePath
    $versionsDir = Join-Path $baseFull '.minecraft\versions'
    if (-not (Test-Path -LiteralPath $versionsDir -PathType Container)) { return }
    Get-ChildItem -LiteralPath $versionsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Add-ScopedCandidate $LocalList $ExternalList $_.FullName "$Reason：.minecraft\versions\$($_.Name)"
    }
}

function Find-SourceClientCandidates($Pack) {
    $local = New-Object System.Collections.ArrayList
    $external = New-Object System.Collections.ArrayList

    $existing = [string](Get-JsonValue $Pack 'sourceClient' '')
    if (Test-UsefulValue $existing) { Add-ScopedCandidate $local $external $existing '现有 portable-pack.json' }

    foreach ($name in @('main-client', 'client', 'clients', '客户端', '分发客户端', '主分发客户端', 'modpack', 'modpack-client', 'instance')) {
        $candidateBase = Join-Path $Root $name
        Add-Candidate $local $candidateBase "服务端根目录内常见客户端目录 $name"
        Add-LauncherVersionCandidates $local $external $candidateBase "服务端根目录内常见客户端目录 $name"
    }

    $skip = @('mods','config','defaultconfigs','libraries','versions','world','logs','crash-reports','tools','backups','dist','tmp','modpack-public','.git','.fabric','data','resourcepacks')
    Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not ($skip -contains $_.Name)) {
            Add-Candidate $local $_.FullName '服务端根目录内含 mods 的候选目录'
            Add-LauncherVersionCandidates $local $external $_.FullName '服务端根目录内启动器目录'
        }
    }

    Add-Candidate $local $Root '服务端根目录本身含 mods，可临时作为 sourceClient'

    $sourceFile = Join-Path $Root 'SOURCE-CLIENT.txt'
    if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
        $fromFile = (Get-Content -LiteralPath $sourceFile -Raw -Encoding UTF8).Trim()
        Add-ScopedCandidate $local $external $fromFile 'SOURCE-CLIENT.txt'
        Add-LauncherVersionCandidates $local $external $fromFile 'SOURCE-CLIENT.txt 指向的启动器目录'
    }

    $appVersions = Join-Path $env:APPDATA '.minecraft\versions'
    if (Test-Path -LiteralPath $appVersions -PathType Container) {
        Get-ChildItem -LiteralPath $appVersions -Directory -ErrorAction SilentlyContinue | Select-Object -First 80 | ForEach-Object {
            Add-Candidate $external $_.FullName '启动器版本目录（外部路径，仅候选）' $true
        }
    }

    $result = @()
    $result += @($local.ToArray())
    $result += @($external.ToArray())
    return $result
}
function Read-ClientJsonInfo([string]$Dir) {
    $result = [ordered]@{ MinecraftVersion = ''; LoaderType = ''; LoaderVersion = '' }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $result }
    $jsons = @(Get-ChildItem -LiteralPath $Dir -File -Filter *.json -ErrorAction SilentlyContinue | Select-Object -First 8)
    foreach ($jsonFile in $jsons) {
        try {
            $json = Get-Content -LiteralPath $jsonFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $id = [string](Get-JsonValue $json 'id' '')
            $clientVersion = [string](Get-JsonValue $json 'clientVersion' '')
            $inherits = [string](Get-JsonValue $json 'inheritsFrom' '')
            if (-not $result.MinecraftVersion -and (Test-UsefulValue $clientVersion)) { $result.MinecraftVersion = $clientVersion }
            if (-not $result.MinecraftVersion -and $inherits -match '^[0-9]+(\.[0-9]+){1,2}$') { $result.MinecraftVersion = $inherits }
            if (-not $result.MinecraftVersion -and $id -match '^(?<mc>[0-9]+(\.[0-9]+){1,2})') { $result.MinecraftVersion = $matches.mc }
            if ($id -match '(?i)fabric\s*(?<ver>[0-9][A-Za-z0-9.+_-]*)') { $result.LoaderType = 'fabric'; $result.LoaderVersion = $matches.ver }
            if ($id -match '(?i)forge\s*(?<ver>[0-9][A-Za-z0-9.+_-]*)') { $result.LoaderType = 'forge'; $result.LoaderVersion = $matches.ver }
            if ($id -match '(?i)neoforge\s*(?<ver>[0-9][A-Za-z0-9.+_-]*)') { $result.LoaderType = 'neoforge'; $result.LoaderVersion = $matches.ver }
            if ($id -match '(?i)quilt\s*(?<ver>[0-9][A-Za-z0-9.+_-]*)') { $result.LoaderType = 'quilt'; $result.LoaderVersion = $matches.ver }
        } catch {}
    }
    return $result
}

function Read-FmlMcVersion([string]$LoaderVersionDir) {
    # Forge/NeoForge 现代安装会在 libraries\...\<版本>\win_args.txt 里写 --fml.mcVersion，最权威。
    foreach ($argsName in @('win_args.txt', 'unix_args.txt')) {
        $argsFile = Join-Path $LoaderVersionDir $argsName
        if (Test-Path -LiteralPath $argsFile -PathType Leaf) {
            try {
                $content = Get-Content -LiteralPath $argsFile -Raw -Encoding UTF8
                if ($content -match '--fml\.mcVersion\s+(\S+)') { return $matches[1] }
            } catch {}
        }
    }
    return ''
}

function Detect-LoaderInfo([object[]]$SourceCandidates) {
    $info = [ordered]@{ MinecraftVersion = ''; LoaderType = ''; LoaderVersion = ''; Notes = New-Object System.Collections.Generic.List[string] }

    # 本机服务端实测（libraries/启动参数/jar）绝对优先；客户端候选目录只做兜底，
    # 且外部启动器目录（%APPDATA%\.minecraft\versions 等）绝不参与版本识别——
    # 否则启动器里别的整合包实例会把身份「上任」到本服（2026-07-11 26.1.1 NeoForge 新服被 26.2-Fabric 顶替实锤）。
    $neoRoot = Join-Path $Root 'libraries\net\neoforged\neoforge'
    if (Test-Path -LiteralPath $neoRoot -PathType Container) {
        $latest = @(Get-ChildItem -LiteralPath $neoRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1)
        if ($latest.Count -gt 0) {
            $ver = $latest[0].Name
            if (-not $info.LoaderType) { $info.LoaderType = 'neoforge'; $info.Notes.Add('从 libraries\net\neoforged\neoforge 识别 NeoForge') | Out-Null }
            if (-not $info.LoaderVersion) { $info.LoaderVersion = $ver }
            if (-not $info.MinecraftVersion) {
                $mcFromArgs = Read-FmlMcVersion $latest[0].FullName
                if (Test-UsefulValue $mcFromArgs) {
                    $info.MinecraftVersion = $mcFromArgs
                    $info.Notes.Add('从 NeoForge 启动参数（--fml.mcVersion）识别 Minecraft 版本') | Out-Null
                } elseif ($ver -match '^(?<a>\d+)\.(?<b>\d+)\.(?<c>\d+)') {
                    # 与 portable-run-server 的 Get-DetectedMcVersion 同一套反推：
                    # 26.x 新纪年 NeoForge = MC版本.构建号（26.1.2.78 → 26.1.2；26.2.0.x → 26.2）；1.x 时代 21.1.x → 1.21.1。
                    $a = [int]$matches.a; $b = [int]$matches.b; $c = [int]$matches.c
                    if ($a -ge 26) {
                        $info.MinecraftVersion = $(if ($c -eq 0) { '{0}.{1}' -f $a, $b } else { '{0}.{1}.{2}' -f $a, $b, $c })
                    } elseif ($b -eq 0) { $info.MinecraftVersion = '1.' + $a } else { $info.MinecraftVersion = '1.{0}.{1}' -f $a, $b }
                    $info.Notes.Add('从 NeoForge 版本号反推 Minecraft 版本') | Out-Null
                }
            }
        }
    }

    $fabricLoaderRoot = Join-Path $Root 'libraries\net\fabricmc\fabric-loader'
    if (Test-Path -LiteralPath $fabricLoaderRoot -PathType Container) {
        $ver = @(Get-ChildItem -LiteralPath $fabricLoaderRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
        if (-not $info.LoaderType) { $info.LoaderType = 'fabric'; $info.Notes.Add('从 libraries\net\fabricmc\fabric-loader 识别 Fabric') | Out-Null }
        if (-not $info.LoaderVersion) { $info.LoaderVersion = $ver }
    }

    $forgeRoot = Join-Path $Root 'libraries\net\minecraftforge\forge'
    if (Test-Path -LiteralPath $forgeRoot -PathType Container) {
        $latest = @(Get-ChildItem -LiteralPath $forgeRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1)
        if ($latest.Count -gt 0) {
            $folder = $latest[0].Name
            if ($folder -match '^(?<mc>[0-9]+(\.[0-9]+){1,2})-(?<loader>.+)$') {
                if (-not $info.MinecraftVersion) { $info.MinecraftVersion = $matches.mc }
                if (-not $info.LoaderType) { $info.LoaderType = 'forge'; $info.Notes.Add('从 Forge libraries 识别 Forge') | Out-Null }
                if (-not $info.LoaderVersion) { $info.LoaderVersion = $matches.loader }
            }
            if (-not $info.MinecraftVersion) {
                $mcFromArgs = Read-FmlMcVersion $latest[0].FullName
                if (Test-UsefulValue $mcFromArgs) {
                    $info.MinecraftVersion = $mcFromArgs
                    $info.Notes.Add('从 Forge 启动参数（--fml.mcVersion）识别 Minecraft 版本') | Out-Null
                }
            }
        }
    }

    $quiltRoot = Join-Path $Root 'libraries\org\quiltmc\quilt-loader'
    if (Test-Path -LiteralPath $quiltRoot -PathType Container) {
        $ver = @(Get-ChildItem -LiteralPath $quiltRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
        if (-not $info.LoaderType) { $info.LoaderType = 'quilt'; $info.Notes.Add('从 Quilt libraries 识别 Quilt') | Out-Null }
        if (-not $info.LoaderVersion) { $info.LoaderVersion = $ver }
    }

    if (-not $info.MinecraftVersion) {
        $versionDirs = @(Get-ChildItem -LiteralPath (Join-Path $Root 'versions') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9]+(\.[0-9]+){1,2}$' })
        if ($versionDirs.Count -eq 1) { $info.MinecraftVersion = $versionDirs[0].Name; $info.Notes.Add('从服务端 versions 目录识别 Minecraft 版本') | Out-Null }
    }

    foreach ($jar in @(Get-ChildItem -LiteralPath $Root -File -Filter *.jar -ErrorAction SilentlyContinue)) {
        if ($jar.Name -match '(?i)^forge-(?<mc>[0-9]+(\.[0-9]+){1,2})-(?<ver>.+)\.jar$') {
            if (-not $info.MinecraftVersion) { $info.MinecraftVersion = $matches.mc }
            if (-not $info.LoaderType) { $info.LoaderType = 'forge' }
            if (-not $info.LoaderVersion) { $info.LoaderVersion = $matches.ver }
        }
        if ($jar.Name -match '(?i)^neoforge-(?<ver>[0-9][A-Za-z0-9.+_-]*?)(?:-installer)?\.jar$') {
            if (-not $info.LoaderType) { $info.LoaderType = 'neoforge'; $info.Notes.Add("从根目录 jar 识别 NeoForge：$($jar.Name)") | Out-Null }
            if (-not $info.LoaderVersion) { $info.LoaderVersion = $matches.ver }
        }
        if ($jar.Name -match '(?i)fabric') {
            if (-not $info.LoaderType) { $info.LoaderType = 'fabric' }
        }
    }

    # 客户端候选目录兜底：只用服务端根目录内的本地候选。
    # 外部启动器目录（External）只做主分发客户端候选，不决定本服版本/加载器。
    foreach ($cand in $SourceCandidates) {
        if ($cand.External) { continue }
        $leaf = Split-Path -Leaf $cand.FullPath
        if ($leaf -match '^(?<mc>[0-9]+(\.[0-9]+){1,2})(?:[-_ ](?<loader>Fabric|Forge|NeoForge|Quilt)[-_ ]?(?<ver>[0-9][A-Za-z0-9.+_-]*)?)?') {
            if (-not $info.MinecraftVersion) { $info.MinecraftVersion = $matches.mc; $info.Notes.Add("从客户端目录名识别 Minecraft 版本：$leaf") | Out-Null }
            if ($matches.loader -and -not $info.LoaderType) { $info.LoaderType = $matches.loader.ToLowerInvariant(); $info.Notes.Add("从客户端目录名识别加载器：$leaf") | Out-Null }
            if ($matches.ver -and -not $info.LoaderVersion) { $info.LoaderVersion = $matches.ver }
        }
        $jsonInfo = Read-ClientJsonInfo $cand.FullPath
        if (-not $info.MinecraftVersion -and $jsonInfo.MinecraftVersion) { $info.MinecraftVersion = $jsonInfo.MinecraftVersion; $info.Notes.Add("从客户端 JSON 识别 Minecraft 版本") | Out-Null }
        if (-not $info.LoaderType -and $jsonInfo.LoaderType) { $info.LoaderType = $jsonInfo.LoaderType; $info.Notes.Add("从客户端 JSON 识别加载器") | Out-Null }
        if (-not $info.LoaderVersion -and $jsonInfo.LoaderVersion) { $info.LoaderVersion = $jsonInfo.LoaderVersion }
    }

    return $info
}

function Get-ConfigSuggestion($Pack, $Ops, $Props) {
    $sourceCandidates = @(Find-SourceClientCandidates $Pack)
    $loader = Detect-LoaderInfo $sourceCandidates
    $rootName = Split-Path -Leaf $Root
    $motd = Get-Prop $Props 'motd' ''
    $serverIp = Get-Prop $Props 'server-ip' ''
    $serverPort = Get-Prop $Props 'server-port' '25565'
    $levelName = Get-Prop $Props 'level-name' 'world'

    $detectedPackName = $rootName
    if ((Test-UsefulValue $loader.MinecraftVersion) -and (Test-UsefulValue $loader.LoaderType) -and (Test-UsefulValue $loader.LoaderVersion)) {
        $detectedPackName = "$($loader.MinecraftVersion) $($loader.LoaderType) $($loader.LoaderVersion)"
    }
    $packName = Get-FirstUseful @((Get-JsonValue $Pack 'packName' ''), $motd, $detectedPackName, $rootName) $rootName
    $packId = Get-FirstUseful @((Get-JsonValue $Pack 'packId' '')) (ConvertTo-PackId $packName)
    # 版本/加载器以本机实测优先：配置文件里的值可能是私包/旧服带来的身份，实测才代表当前这台服务端。
    $minecraftVersion = Get-FirstUseful @($loader.MinecraftVersion, (Get-JsonValue $Pack 'minecraftVersion' '')) 'CHANGE-ME'
    $loaderType = Get-FirstUseful @($loader.LoaderType, (Get-JsonValue $Pack.loader 'type' '')) 'CHANGE-ME'
    $loaderVersion = Get-FirstUseful @($loader.LoaderVersion, (Get-JsonValue $Pack.loader 'version' '')) 'CHANGE-ME'
    # 配置里的 sourceClient 只有在本机真实存在时才沿用；旧服路径在新机器上不存在，直接忽略换候选扫描。
    $packSourceClient = [string](Get-JsonValue $Pack 'sourceClient' '')
    if (Test-UsefulValue $packSourceClient) {
        $packSourceClientFull = if ([System.IO.Path]::IsPathRooted($packSourceClient)) { $packSourceClient } else { Join-Path $Root $packSourceClient }
        if (-not (Test-Path -LiteralPath $packSourceClientFull -PathType Container)) { $packSourceClient = '' }
    }
    # 自动选主分发客户端：本地候选优先；外部启动器目录只有目录名与本服实测版本/加载器匹配才自动选中，
    # 不匹配的仅留在候选列表里供手选（避免把启动器里别的整合包实例当成本服客户端）。
    $autoCandidate = $null
    foreach ($cand in $sourceCandidates) {
        if (-not $cand.External) { $autoCandidate = $cand; break }
    }
    if ((-not $autoCandidate) -and (Test-UsefulValue $loader.MinecraftVersion)) {
        foreach ($cand in $sourceCandidates) {
            $leaf = Split-Path -Leaf $cand.FullPath
            if ($leaf -notmatch ('^' + [regex]::Escape($loader.MinecraftVersion) + '([-_ .]|$)')) { continue }
            if ($leaf -match '(?i)(neoforge|fabric|quilt|forge)') {
                if ((Test-UsefulValue $loader.LoaderType) -and ($matches[1].ToLowerInvariant() -ne $loader.LoaderType)) { continue }
            }
            $autoCandidate = $cand
            break
        }
    }
    $sourceClient = Get-FirstUseful @($packSourceClient, ($(if($autoCandidate){ $autoCandidate.Display }))) '.\CHANGE-ME-main-client'

    $existingUpdateHost = [string](Get-JsonValue $Pack.update 'host' '')
    $existingServerAddr = [string](Get-JsonValue $Pack.server 'address' '')
    $serverAddress = Get-FirstUseful @($existingServerAddr, $existingUpdateHost, $serverIp) 'CHANGE-ME-public-host'
    $updateHost = Get-FirstUseful @($existingUpdateHost, $serverAddress) 'CHANGE-ME-public-host'
    $updatePort = [int](Get-JsonValue $Pack.update 'port' 18088)
    if ($updatePort -le 0) { $updatePort = 18088 }

    $opsName = Get-FirstUseful @((Get-JsonValue $Ops 'serverName' ''), $packName) $packName
    $opsAddr = Get-FirstUseful @((Get-JsonValue $Ops 'serverAddress' ''), $serverAddress) $serverAddress
    $backupPrefix = Get-FirstUseful @((Get-JsonValue $Ops.backupSchedule 'backupPrefix' ''), $packId) $packId
    $discordEnabled = [bool](Get-JsonValue $Ops.discord 'enabled' $false)
    $webhook = [string](Get-JsonValue $Ops.discord 'webhookUrl' '')
    if (Test-UsefulValue $webhook) { $discordEnabled = $true }

    return [pscustomobject]@{
        PackName = $packName
        PackId = $packId
        MinecraftVersion = $minecraftVersion
        LoaderType = $loaderType
        LoaderVersion = $loaderVersion
        SourceClient = $sourceClient
        SourceCandidates = $sourceCandidates
        PublishDir = Get-FirstUseful @((Get-JsonValue $Pack 'publishDir' '')) '.\modpack-public\portable'
        DistDir = Get-FirstUseful @((Get-JsonValue $Pack 'distDir' '')) '.\dist'
        ServerAddress = $serverAddress
        ServerPort = $serverPort
        UpdateHost = $updateHost
        UpdatePort = $updatePort
        WorldName = (Get-FirstUseful @($levelName) 'world')
        OpsServerName = $opsName
        OpsServerAddress = $opsAddr
        BackupPrefix = $backupPrefix
        RconEnabled = ((Get-Prop $Props 'enable-rcon' '') -eq 'true')
        RconPort = (Get-Prop $Props 'rcon.port' '')
        HasRconPassword = (Test-UsefulValue (Get-Prop $Props 'rcon.password' ''))
        DiscordEnabled = $discordEnabled
        DiscordWebhook = $webhook
        Notes = @($loader.Notes)
    }
}

function Show-Summary($S) {
    Write-Host ''
    Write-Host '====== 便携工具包配置向导：待写入预览 ======' -ForegroundColor Cyan
    Write-Host "服务端根目录        : $Root"
    Write-Host "整合包显示名        : $($S.PackName)"
    Write-Host "整合包内部 ID       : $($S.PackId)"
    Write-Host "Minecraft 版本      : $($S.MinecraftVersion)"
    Write-Host "加载器              : $($S.LoaderType) $($S.LoaderVersion)"
    Write-Host "主分发客户端        : $($S.SourceClient)"
    if ($S.SourceClient -like '*CHANGE-ME*') {
        Write-Host '  ↳ 还没找到主分发客户端：客户端不必放在服务端目录内，菜单 2 里可直接输入任意路径；' -ForegroundColor Yellow
        Write-Host '    也可以先在服务端根目录新建「客户端」文件夹放入整合包客户端实例（从玩家包/规范导入包解压即可），再重跑本向导。' -ForegroundColor Yellow
    }
    Write-Host "玩家连接地址        : $($S.ServerAddress)"
    Write-Host "更新服务            : $($S.UpdateHost):$($S.UpdatePort)"
    if (-not $PlayerOnly) {
        Write-Host "世界目录            : $($S.WorldName)"
        Write-Host "备份前缀            : $($S.BackupPrefix)"
        Write-Host "Discord 显示名      : $($S.OpsServerName)"
        Write-Host "Discord 显示地址    : $($S.OpsServerAddress)"
        Write-Host "RCON                : $(if($S.RconEnabled){'已启用'}else{'未启用'}) / 端口 $($S.RconPort) / 密码$(if($S.HasRconPassword){'已设置'}else{'未设置'})"
        Write-Host "Discord             : $(if($S.DiscordEnabled){'启用'}else{'关闭'}) / webhook $(if(Test-UsefulValue $S.DiscordWebhook){'已填写'}else{'未填写'})"
    }
    if ($S.SourceCandidates.Count -gt 0) {
        Write-Host ''
        Write-Host '候选主分发客户端：'
        for ($i = 0; $i -lt $S.SourceCandidates.Count; $i++) {
            Write-Host ("  {0}. {1}  ({2})" -f ($i + 1), $S.SourceCandidates[$i].Display, $S.SourceCandidates[$i].Reason)
        }
    }
    if ($S.Notes.Count -gt 0) {
        Write-Host ''
        Write-Host '检测依据：'
        foreach ($note in $S.Notes) { Write-Host "  - $note" }
    }
    Write-Host '提示：以上只是待写入预览；只有选择“保存”才会写入 JSON 配置。' -ForegroundColor Yellow
    Write-Host '=============================================' -ForegroundColor Cyan
}
function Get-FieldsNeedingReview($S) {
    $required = [ordered]@{
        '整合包显示名' = $S.PackName
        '整合包内部 ID' = $S.PackId
        'Minecraft 版本' = $S.MinecraftVersion
        '加载器类型' = $S.LoaderType
        '加载器版本' = $S.LoaderVersion
        '主分发客户端' = $S.SourceClient
        '玩家连接地址' = $S.ServerAddress
        '更新服务公网 host' = $S.UpdateHost
    }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $required.GetEnumerator()) {
        if (-not (Test-UsefulValue $entry.Value)) { $missing.Add($entry.Key) | Out-Null }
    }
    return @($missing)
}
function Prompt-Value([string]$Label, [string]$Default, [switch]$AllowEmpty) {
    $hint = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
    $value = Read-Host "$Label$hint"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Prompt-Int([string]$Label, [int]$Default) {
    while ($true) {
        $raw = Prompt-Value $Label ([string]$Default)
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -gt 0) { return $n }
        Write-Host '请输入正整数。' -ForegroundColor Yellow
    }
}

function Prompt-YesNo([string]$Label, [bool]$Default) {
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $raw = Read-Host "$Label $suffix"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return ($raw.Trim().ToLowerInvariant() -in @('y','yes','1','true','是','好'))
}

function Prompt-SourceClient($S) {
    if ($S.SourceCandidates.Count -gt 0) {
        Write-Host ''
        Write-Host '请选择主分发客户端目录。也可以直接输入路径（可以是服务端目录外的任意文件夹，例如 D:\我的整合包客户端）。'
        for ($i = 0; $i -lt $S.SourceCandidates.Count; $i++) {
            Write-Host ("  {0}. {1}  ({2})" -f ($i + 1), $S.SourceCandidates[$i].Display, $S.SourceCandidates[$i].Reason)
        }
    }
    $raw = Prompt-Value '主分发客户端目录' $S.SourceClient
    $idx = 0
    if ([int]::TryParse($raw, [ref]$idx) -and $idx -ge 1 -and $idx -le $S.SourceCandidates.Count) {
        return $S.SourceCandidates[$idx - 1].Display
    }
    return $raw
}

function Edit-Suggestion($S) {
    Write-Host ''
    Write-Host '开始逐项确认。直接回车表示沿用括号里的值。' -ForegroundColor Cyan
    $S.PackName = Prompt-Value '整合包显示名 / Discord 默认显示名' $S.PackName
    $S.PackId = ConvertTo-PackId (Prompt-Value '整合包内部 ID（会自动转成安全 ID）' (ConvertTo-PackId $S.PackName))
    $S.MinecraftVersion = Prompt-Value 'Minecraft 版本' $S.MinecraftVersion
    $S.LoaderType = Prompt-Value '加载器类型（fabric/forge/neoforge/quilt/vanilla）' $S.LoaderType
    $S.LoaderVersion = Prompt-Value '加载器版本' $S.LoaderVersion
    $S.SourceClient = Prompt-SourceClient $S
    $S.ServerAddress = Prompt-Value '玩家连接地址' $S.ServerAddress
    $S.UpdateHost = Prompt-Value '更新服务公网 host' $S.UpdateHost
    $S.UpdatePort = Prompt-Int '更新服务端口' ([int]$S.UpdatePort)
    if (-not $PlayerOnly) {
        $S.WorldName = Prompt-Value '世界目录 level-name' $S.WorldName
        $S.OpsServerName = Prompt-Value 'Discord/监控显示的服务器名' $S.PackName
        $S.OpsServerAddress = Prompt-Value 'Discord/监控显示的服务器地址' $S.ServerAddress
        $S.BackupPrefix = ConvertTo-PackId (Prompt-Value '备份文件名前缀（会自动转成安全前缀）' (ConvertTo-PackId $S.PackId))
        $S.DiscordEnabled = Prompt-YesNo '是否启用 Discord 通知' $S.DiscordEnabled
        if ($S.DiscordEnabled -and -not (Test-UsefulValue $S.DiscordWebhook)) {
            $S.DiscordWebhook = Prompt-Value 'Discord webhookUrl（可回车暂不填）' '' -AllowEmpty
        }
    }
    return $S
}
function Ensure-ConfigFile([string]$Target, [string]$Template) {
    if (Test-Path -LiteralPath $Target -PathType Leaf) { return }
    if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) { throw "缺少模板：$Template" }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Target) | Out-Null
    Copy-Item -LiteralPath $Template -Destination $Target -Force
}

function Backup-CurrentConfigs([string[]]$Paths) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $Root "backups\portable-config-wizard-$stamp"
    New-Item -ItemType Directory -Force $backupRoot | Out-Null
    $copied = 0
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $full = [System.IO.Path]::GetFullPath($path)
            $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
            $rel = if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { $full.Substring($rootFull.Length).TrimStart('\','/') } else { Split-Path -Leaf $full }
            $dest = Join-Path $backupRoot $rel
            New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $path -Destination $dest -Force
            $copied++
        }
    }
    if ($copied -gt 0) { return $backupRoot }
    return ''
}

function Apply-Suggestion($Pack, $Ops, $S) {
    Set-JsonValue $Pack 'packId' $S.PackId
    Set-JsonValue $Pack 'packName' $S.PackName
    Set-JsonValue $Pack 'minecraftVersion' $S.MinecraftVersion
    Set-JsonValue $Pack 'sourceClient' $S.SourceClient
    Set-JsonValue $Pack 'publishDir' $S.PublishDir
    Set-JsonValue $Pack 'distDir' $S.DistDir
    Set-JsonValue $Pack.loader 'type' $S.LoaderType
    Set-JsonValue $Pack.loader 'version' $S.LoaderVersion
    Set-JsonValue $Pack.update 'host' $S.UpdateHost
    Set-JsonValue $Pack.update 'port' ([int]$S.UpdatePort)
    Set-JsonValue $Pack.server 'name' $S.PackName
    Set-JsonValue $Pack.server 'address' $S.ServerAddress
    Set-JsonValue $Pack.serverList 'name' $S.PackName
    Set-JsonValue $Pack.serverList 'address' $S.ServerAddress
    Set-JsonValue $Pack.mrpack 'summary' ("$($S.PackName) standard import pack. Server $($S.ServerAddress)")
    Set-JsonValue $Pack.mrpack 'instanceName' $S.PackName
    Set-JsonValue $Pack.pcl 'instanceName' $S.PackName

    if (-not $PlayerOnly) {
        Set-JsonValue $Ops 'serverName' $S.OpsServerName
        Set-JsonValue $Ops 'serverAddress' $S.OpsServerAddress
        Set-JsonValue $Ops.discord 'enabled' ([bool]$S.DiscordEnabled)
        if (Test-UsefulValue $S.DiscordWebhook) { Set-JsonValue $Ops.discord 'webhookUrl' $S.DiscordWebhook }
        Set-JsonValue $Ops.backupSchedule 'worldName' $S.WorldName
        Set-JsonValue $Ops.backupSchedule 'backupPrefix' $S.BackupPrefix
        if ($Ops.backupWatch) { Set-JsonValue $Ops.backupWatch 'directory' 'backups/world' }
        if ($Ops.logWatch) { Set-JsonValue $Ops.logWatch 'logPath' 'logs/latest.log' }
    }
}

function Test-OpsNeedsRcon($Ops) {
    $discordControl = $false
    if ($Ops.discord) {
        $events = Get-JsonValue $Ops.discord 'events' $null
        $commandEnabled = [bool](Get-JsonValue $events 'command' $false)
        $discordControl = $commandEnabled -and (Test-UsefulValue (Get-JsonValue $Ops.discord 'botToken' '')) -and (Test-UsefulValue (Get-JsonValue $Ops.discord 'channelId' ''))
    }
    $backupNeedsRcon = $false
    if ($Ops.backupSchedule) {
        $backupNeedsRcon = [bool](Get-JsonValue $Ops.backupSchedule 'enabled' $false)
    }
    return ($discordControl -or $backupNeedsRcon)
}

function Ensure-LocalRconForOps($Ops) {
    if (-not (Test-OpsNeedsRcon $Ops)) { return }
    $rconHelper = Join-Path $Root 'tools\enable-local-rcon.ps1'
    if (-not (Test-Path -LiteralPath $rconHelper -PathType Leaf)) {
        Write-Host '[portable] 提醒：当前配置需要 RCON，但缺少 tools\enable-local-rcon.ps1，无法自动修复。' -ForegroundColor Yellow
        return
    }
    Write-Host '[portable] 正在自动检查/启用本地 RCON，供 Discord 反控和备份保护使用...' -ForegroundColor Cyan
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rconHelper -NoPause
    } catch {
        Write-Host "[portable] RCON 自动配置失败：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '[portable] 可稍后手动运行：一键脚本\一键便携-启用RCON反控.bat（或控制面板「启用 RCON 反控」）' -ForegroundColor Yellow
    }
}
$packPath = Resolve-RootPath $PackConfigPath
$opsPath = Resolve-RootPath $OpsConfigPath
$packTemplate = Join-Path $Root 'tools\portable-pack.example.json'
$opsTemplate = Join-Path $Root 'tools\portable-ops-config.example.json'
Ensure-ConfigFile -Target $packPath -Template $packTemplate
$pack = Read-JsonFile $packPath
$packDefaults = Read-JsonFile $packTemplate
Merge-MissingJsonProperties -Target $pack -Template $packDefaults
if (-not $PlayerOnly) {
    Ensure-ConfigFile -Target $opsPath -Template $opsTemplate
    $ops = Read-JsonFile $opsPath
    $opsDefaults = Read-JsonFile $opsTemplate
    Merge-MissingJsonProperties -Target $ops -Template $opsDefaults
} else {
    # 玩家拉新公版不携带、也不生成运维配置；仅提供检测建议所需的中性占位结构。
    $ops = [pscustomobject]@{
        serverName = ''
        serverAddress = ''
        discord = [pscustomobject]@{ enabled = $false; webhookUrl = '' }
        backupSchedule = [pscustomobject]@{ backupPrefix = '' }
    }
}
$props = Read-ServerProperties (Join-Path $Root 'server.properties')
$suggestion = Get-ConfigSuggestion -Pack $pack -Ops $ops -Props $props

Show-Summary $suggestion
$mustEdit = @(Get-FieldsNeedingReview $suggestion)

$saveRequested = $Auto
if (-not $Auto) {
    while (-not $saveRequested) {
        Write-Host ''
        Write-Host '请选择操作：' -ForegroundColor Cyan
        Write-Host '  1. 保存当前显示结果到配置文件'
        Write-Host '  2. 中文菜单逐项确认/修改，然后询问是否保存（推荐）'
        Write-Host '  3. 仅重新显示检测结果（不会保存）'
        Write-Host '  4. 退出，不保存'
        $defaultChoice = if ($mustEdit.Count -gt 0) { '2' } else { '1' }
        $choice = Read-Host "输入 1-4 [$defaultChoice]"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = $defaultChoice }
        switch ($choice.Trim()) {
            '1' {
                $targetLabel = if ($PlayerOnly) { 'portable-pack.json' } else { 'portable-pack.json 和 ops-config.json' }
                Write-Host "正在保存当前显示结果到 $targetLabel..." -ForegroundColor Green
                $saveRequested = $true
            }
            '2' {
                $suggestion = Edit-Suggestion $suggestion
                $mustEdit = @(Get-FieldsNeedingReview $suggestion)
                Show-Summary $suggestion
                if (Prompt-YesNo '是否现在保存上面的配置' $true) {
                    $targetLabel = if ($PlayerOnly) { 'portable-pack.json' } else { 'portable-pack.json 和 ops-config.json' }
                    Write-Host "正在保存上面的配置到 $targetLabel..." -ForegroundColor Green
                    $saveRequested = $true
                } else {
                    Write-Host '未保存，返回主菜单。' -ForegroundColor Yellow
                }
            }
            '3' {
                Write-Host '仅重新显示检测结果；此操作不会写入任何配置。' -ForegroundColor Yellow
                Show-Summary $suggestion
            }
            '4' { Write-Host '已退出，未写入配置。'; exit 0 }
            default { Write-Host '请输入 1、2、3 或 4。' -ForegroundColor Yellow }
        }
    }
}

if ($Auto -and $mustEdit.Count -gt 0) {
    Write-Host '[portable] 自动模式下仍有 CHANGE-ME/不确定字段，已按当前建议写入；建议稍后运行交互菜单复核。' -ForegroundColor Yellow
}

Apply-Suggestion -Pack $pack -Ops $ops -S $suggestion

if ($DryRun) {
    Write-Host ''
    Write-Host '[portable] DryRun：未写入文件。' -ForegroundColor Yellow
    Write-Host '[portable] 将写入：'
    Write-Host "  $packPath"
    if (-not $PlayerOnly) { Write-Host "  $opsPath" }
    exit 0
}

$backupTargets = if ($PlayerOnly) { @($packPath) } else { @($packPath, $opsPath) }
$backup = Backup-CurrentConfigs $backupTargets
Write-JsonFile -Path $packPath -Object $pack
if (-not $PlayerOnly) { Write-JsonFile -Path $opsPath -Object $ops }

Write-Host ''
Write-Host '[portable] 配置已写入。' -ForegroundColor Green
if ($backup) { Write-Host "[portable] 写入前备份：$backup" }
Write-Host "[portable] 玩家包配置：$packPath"
if (-not $PlayerOnly) { Write-Host "[portable] 运维配置：$opsPath" }
if (-not $PlayerOnly) { Ensure-LocalRconForOps $ops }
if (-not $PlayerOnly -and $ops.discord -and $ops.discord.enabled -and (Test-UsefulValue $ops.discord.webhookUrl)) {
    $opsStarter = Join-Path $Root 'tools\\start-ops-monitor.ps1'
    if (Test-Path -LiteralPath $opsStarter -PathType Leaf) {
        Write-Host '[portable] 正在刷新 Discord/备份监控，使新配置立即生效...' -ForegroundColor Cyan
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $opsStarter -NoPause -Restart
        } catch {
            Write-Host "[portable] 监控刷新失败：$($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '[portable] 可稍后手动运行：tools\start-ops-monitor.ps1 -NoPause -Restart' -ForegroundColor Yellow
        }
    }
}

Write-Host '[portable] 下一步：控制面板点「仅发布更新」或「生成规范导入包」（命令行为 一键脚本\ 下对应 bat）。'
