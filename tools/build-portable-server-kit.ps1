param(
    [string]$Version = "",
    [switch]$Private,
    [switch]$Lite
)

if ($Lite -and $Private) { throw '精简版是公开包的变体（去 LLBot 本体），不能与 -Private 同时使用。' }

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = '生成便携工具包' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = Get-Date -Format 'yyyyMMdd-HHmmss' }

function Copy-KitFile([string]$Rel, [string]$KitRoot) {
    $src = Join-Path $Root $Rel
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "缺少工具包文件：$Rel" }
    $dest = Join-Path $KitRoot $Rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dest -Force
}

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Test-GenericPublicValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $v = $Value.Trim()
    if ($v -match 'CHANGE-ME|example\.com|^(true|false|server-pack|my-server-pack|minecraft-server|portable-pack)$') { return $true }
    if ($v -match '(?i)^(localhost|127\.0\.0\.1|0\.0\.0\.0|::1)(:\d+)?$') { return $true }
    if ($v -match '(?i)^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(/|$)') { return $true }
    return $false
}

function Add-PrivatePlayerName($Values, $Value) {
    if ($null -eq $Value) { return }
    $name = ([string]$Value).Trim()
    if ($name.Length -ge 4 -and $name.Length -le 16 -and
        $name -match '^[A-Za-z0-9_]+$' -and
        $name -notmatch '(?i)^(Steve|Alex|Notch|player|players|server|admin|owner|operator|CameraBot|MapCam|name|uuid|test|tester|sample|demo)$') {
        $Values.Add($name) | Out-Null
    }
}

function Add-PrivateComparisonValue($Values, $Value) {
    foreach ($entry in @($Value)) {
        if ($null -eq $entry) { continue }
        $text = ([string]$entry).Trim()
        if ($text.Length -ge 7 -and -not (Test-GenericPublicValue $text)) {
            $Values.Add($text) | Out-Null
        }
    }
}

function Test-PublicKitPrivacy([string]$KitRoot) {
    foreach ($forbidden in @(
        'tools\portable-pack.json', 'tools\ops-config.json',
        'tools\toolkit-update-source.txt', 'PRIVATE-WARNING.txt',
        'server.properties', 'ops.json', 'usercache.json', 'usernamecache.json',
        'whitelist.json', 'banned-ips.json', 'banned-players.json', '.update-server-token'
    )) {
        if (Test-Path -LiteralPath (Join-Path $KitRoot $forbidden)) {
            throw "公开包隐私门禁失败：禁止出现 $forbidden"
        }
    }
    foreach ($forbiddenDir in @('world', 'logs', 'backups', 'crash-reports', 'tmp')) {
        if (Test-Path -LiteralPath (Join-Path $KitRoot $forbiddenDir)) {
            throw "公开包隐私门禁失败：禁止携带运行目录 $forbiddenDir"
        }
    }

    $llbot = Join-Path $KitRoot 'tools\LLBot-CLI-win-x64'
    if (Test-Path -LiteralPath $llbot -PathType Container) {
        $llbotLeaks = @(Get-ChildItem -LiteralPath $llbot -Recurse -File | Where-Object {
            $_.Name -match '(?i)^(config_\d+\.json|webui_token\.txt|qrcode\.png|debug\.log)$' -or
            $_.Extension -match '(?i)^\.(log|db|sqlite|lock|pid)$' -or
            $_.FullName -match '(?i)\\bin\\llbot\\data\\'
        })
        if ($llbotLeaks.Count -gt 0) {
            throw ("公开包 LLBot 隐私门禁失败：" + (($llbotLeaks | Select-Object -First 5 -ExpandProperty FullName) -join '; '))
        }
        $publicPmhqPath = Join-Path $llbot 'bin\pmhq\pmhq_config.json'
        if (Test-Path -LiteralPath $publicPmhqPath -PathType Leaf) {
            $publicPmhq = Get-Content -LiteralPath $publicPmhqPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrEmpty([string]$publicPmhq.quick_login_qq) -or
                -not [string]::IsNullOrEmpty([string]$publicPmhq.qq_path)) {
                throw '公开包 LLBot 隐私门禁失败：pmhq_config.json 仍带登录账号或本机路径。'
            }
        }
    }

    # 用主目录真实配置做交叉比对，但只判断命中、不在输出中显示私有值。
    $privatePackPath = Join-Path $Root 'tools\portable-pack.json'
    $privateValues = New-Object System.Collections.Generic.List[string]
    $privatePlayerNames = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $privatePackPath -PathType Leaf) {
        $privatePack = Get-Content -LiteralPath $privatePackPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-PrivateComparisonValue $privateValues @(
            [string]$privatePack.packName,
            [string]$privatePack.packId,
            [string]$privatePack.server.address,
            [string]$privatePack.server.name,
            [string]$privatePack.update.host,
            [string]$privatePack.sourceClient,
            [string]$privatePack.serverList.address,
            [string]$privatePack.serverList.name,
            [string]$privatePack.mrpack.summary,
            [string]$privatePack.pcl.instanceName
        )
    }
    $privateOpsPath = Join-Path $Root 'tools\ops-config.json'
    if (Test-Path -LiteralPath $privateOpsPath -PathType Leaf) {
        $privateOps = Get-Content -LiteralPath $privateOpsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-PrivateComparisonValue $privateValues @(
            [string]$privateOps.serverName, [string]$privateOps.serverAddress,
            [string]$privateOps.discord.webhookUrl, [string]$privateOps.discord.botToken,
            [string]$privateOps.discord.channelId, [string]$privateOps.discord.proxyHost,
            [string]$privateOps.ddns.domain, [string]$privateOps.ddns.subDomain,
            [string]$privateOps.ddns.loginToken, [string]$privateOps.ai.playerView.cameraPlayer,
            [string]$privateOps.ai.bluemap.chromePath, [string]$privateOps.ai.webProxy,
            [string]$privateOps.modRelease.clientModsDirectory,
            [string]$privateOps.backupSchedule.backupPrefix
        )
        # 只有 ID 列表允许按逗号/空白拆分；路径、URL、令牌只按完整值比对，避免 C:\Program 等通用片段误报。
        foreach ($rawIds in @($privateOps.discord.adminIds, $privateOps.qq.groupId, $privateOps.qq.guestGroupIds, $privateOps.qq.adminIds)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$rawIds)) {
                Add-PrivateComparisonValue $privateValues ([string]$rawIds)
                foreach ($part in @(([string]$rawIds) -split '[,;\s]+')) {
                    Add-PrivateComparisonValue $privateValues $part
                }
            }
        }
        foreach ($id in @($privateOps.modRelease.sourceGroupIds) + @($privateOps.modRelease.publisherIds) + @($privateOps.modRelease.triggerIds) + @($privateOps.modRelease.notifyGroupIds)) {
            Add-PrivateComparisonValue $privateValues $id
        }
        if ($privateOps.qq -and $privateOps.qq.groupLabels) {
            foreach ($label in @($privateOps.qq.groupLabels.PSObject.Properties)) {
                Add-PrivateComparisonValue $privateValues $label.Name
                Add-PrivateComparisonValue $privateValues $label.Value
            }
        }
        if ($privateOps.ai -and $privateOps.ai.providers) {
            foreach ($provider in @($privateOps.ai.providers.PSObject.Properties)) {
                Add-PrivateComparisonValue $privateValues $provider.Value.apiKey
                Add-PrivateComparisonValue $privateValues $provider.Value.commandPath
            }
        }
    }
    $serverPropertiesPath = Join-Path $Root 'server.properties'
    if (Test-Path -LiteralPath $serverPropertiesPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $serverPropertiesPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match '^rcon\.password=(.+)$' -and -not [string]::IsNullOrWhiteSpace($matches[1])) {
                Add-PrivateComparisonValue $privateValues $matches[1]
            }
        }
    }
    $updateTokenPath = Join-Path $Root '.update-server-token'
    if (Test-Path -LiteralPath $updateTokenPath -PathType Leaf) {
        $tokenValue = (Get-Content -LiteralPath $updateTokenPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).Trim()
        Add-PrivateComparisonValue $privateValues $tokenValue
    }
    foreach ($identityFile in @('ops.json','whitelist.json','usercache.json','usernamecache.json','banned-players.json')) {
        $identityPath = Join-Path $Root $identityFile
        if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { continue }
        try {
            $identityJson = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in @($identityJson)) {
                if ($entry.PSObject.Properties['uuid']) { Add-PrivateComparisonValue $privateValues $entry.uuid }
                if ($entry.PSObject.Properties['name']) { Add-PrivatePlayerName $privatePlayerNames $entry.name }
            }
            # usernamecache.json 常见为对象映射，兼容 UUID -> 玩家名和反向映射。
            if ($identityFile -eq 'usernamecache.json' -and $identityJson -is [System.Management.Automation.PSCustomObject]) {
                foreach ($prop in @($identityJson.PSObject.Properties)) {
                    if ($prop.Name -match '(?i)^[0-9a-f]{8}-[0-9a-f-]{27}$') { Add-PrivateComparisonValue $privateValues $prop.Name }
                    else { Add-PrivatePlayerName $privatePlayerNames $prop.Name }
                    $mapped = ([string]$prop.Value).Trim()
                    if ($mapped -match '(?i)^[0-9a-f]{8}-[0-9a-f-]{27}$') { Add-PrivateComparisonValue $privateValues $mapped }
                    else { Add-PrivatePlayerName $privatePlayerNames $mapped }
                }
            }
        } catch { }
    }
    $bannedIpsPath = Join-Path $Root 'banned-ips.json'
    if (Test-Path -LiteralPath $bannedIpsPath -PathType Leaf) {
        try {
            foreach ($entry in @(Get-Content -LiteralPath $bannedIpsPath -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                if ($entry.PSObject.Properties['ip']) { Add-PrivateComparisonValue $privateValues $entry.ip }
            }
        } catch { }
    }
    $llbotDataPath = Join-Path $Root 'tools\LLBot-CLI-win-x64\bin\llbot\data'
    if (Test-Path -LiteralPath $llbotDataPath -PathType Container) {
        Get-ChildItem -LiteralPath $llbotDataPath -File -Filter 'config_*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.BaseName -match '^config_(\d+)$') { Add-PrivateComparisonValue $privateValues $matches[1] }
        }
    }
    $privateUpdateSource = Join-Path $Root 'tools\toolkit-update-source.txt'
    if (Test-Path -LiteralPath $privateUpdateSource -PathType Leaf) {
        Add-PrivateComparisonValue $privateValues (Get-Content -LiteralPath $privateUpdateSource -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    $pmhqPath = Join-Path $Root 'tools\LLBot-CLI-win-x64\bin\pmhq\pmhq_config.json'
    if (Test-Path -LiteralPath $pmhqPath -PathType Leaf) {
        try {
            $pmhq = Get-Content -LiteralPath $pmhqPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Add-PrivateComparisonValue $privateValues $pmhq.quick_login_qq
            Add-PrivateComparisonValue $privateValues $pmhq.qq_path
        } catch { }
    }
    $privateValues = @($privateValues | Where-Object {
        $_.Length -ge 7 -and -not (Test-GenericPublicValue $_)
    } | Select-Object -Unique)
    $privatePlayerNames = @($privatePlayerNames | Select-Object -Unique)
    # LLBot/node_modules 是第三方运行时，测试夹具里的通用数字/昵称会与玩家名产生假阳性；
    # 该目录由上面的专用门禁负责（账号 data、日志、数据库、二维码全禁，pmhq 登录字段强制为空）。
    foreach ($file in @(Get-ChildItem -LiteralPath $KitRoot -Recurse -File | Where-Object {
        $_.Length -le 2MB -and
        $_.Extension -match '(?i)^\.(ps1|py|java|js|json|md|txt|bat|command|properties|toml|ya?ml|xml|ini|cfg)$' -and
        $_.FullName -notmatch '(?i)\\tools\\LLBot-CLI-win-x64\\'
    })) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($text -match '(?i)\b[A-Z]:\\Users\\[^\\\r\n]+') {
            throw "公开包隐私门禁失败：$($file.FullName.Substring($KitRoot.Length + 1)) 含用户目录绝对路径。"
        }
        if ($text -match '(?i)https://(?:discord(?:app)?\.com)/api/webhooks/\d+/[A-Za-z0-9._-]{20,}' -or
            $text -match '(?<![A-Za-z0-9_])(?:sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})(?![A-Za-z0-9_])') {
            throw "公开包隐私门禁失败：$($file.FullName.Substring($KitRoot.Length + 1)) 含疑似真实密钥。"
        }
        foreach ($value in $privateValues) {
            if ($text.Contains($value)) {
                throw "公开包隐私门禁失败：$($file.FullName.Substring($KitRoot.Length + 1)) 命中本服私有身份值。"
            }
        }
        foreach ($playerName in $privatePlayerNames) {
            $pattern = '(?<![A-Za-z0-9_])' + [regex]::Escape($playerName) + '(?![A-Za-z0-9_])'
            if ([regex]::IsMatch($text, $pattern)) {
                throw "公开包隐私门禁失败：$($file.FullName.Substring($KitRoot.Length + 1)) 命中本服玩家身份。"
            }
        }
    }
}

function Test-NewConfigureMenu([string]$KitRoot) {
    $scriptPath = Join-Path $KitRoot 'tools\configure-portable-server.ps1'
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    foreach ($needle in @('待写入预览', '保存当前显示结果到配置文件', '仅重新显示检测结果（不会保存）', 'Discord 显示名', '$saveRequested = $Auto', 'portable-pack.json 和 ops-config.json', '正在自动检查/启用本地 RCON', 'Ensure-LocalRconForOps $ops', '正在刷新 Discord/备份监控，使新配置立即生效')) {
        if (-not $scriptText.Contains($needle)) {
            throw "configure-portable-server.ps1 不是最新菜单版本，缺少标记：$needle"
        }
    }
    if ($scriptText -like '*即将保存当前显示结果到 portable-pack.json 和 ops-config.json*') {
        throw 'configure-portable-server.ps1 仍是旧版不会保存的菜单循环。'
    }

    $starterPath = Join-Path $KitRoot 'tools\start-ops-monitor.ps1'
    $starterText = Get-Content -LiteralPath $starterPath -Raw -Encoding UTF8
    foreach ($needle in @('[switch]$Restart', 'function Stop-TrackedProcess', 'function Clear-MonitorLocks', '-EncodedCommand\s+', 'Stop-LegacyRelativeConsoleBridge', 'Start-Process -FilePath $java', '公开包不含 Discord 频道反控组件')) {
        if (-not $starterText.Contains($needle)) {
            throw "start-ops-monitor.ps1 不是可重启版，缺少标记：$needle"
        }
    }

    $stopperPath = Join-Path $KitRoot 'tools\stop-ops-monitor.ps1'
    $stopperText = Get-Content -LiteralPath $stopperPath -Raw -Encoding UTF8
    foreach ($needle in @('Minecraft 服务端进程不受影响', 'discord-watch.instance.lock', 'Stop-LegacyRelativeConsoleBridge')) {
        if (-not $stopperText.Contains($needle)) {
            throw "stop-ops-monitor.ps1 不是预期的监控停止脚本，缺少标记：$needle"
        }
    }

    # Discord 频道反控组件只随私用包分发；公开包（QQ 方案）没有该文件，跳过其标记校验
    $bridgePath = Join-Path $KitRoot 'tools\DiscordConsoleBridge.java'
    if (Test-Path -LiteralPath $bridgePath -PathType Leaf) {
        $bridgeText = Get-Content -LiteralPath $bridgePath -Raw -Encoding UTF8
        foreach ($needle in @('addAdminIds(c.adminIds, jsonString(discord, "adminIds"))', 'RCON 不可用，已从日志估算在线列表', 'Message Content Intent', 'command.equalsIgnoreCase("id")', 'command.equalsIgnoreCase("backup")', 'runAiAgent', '-SuppressWatchNotification')) {
            if (-not $bridgeText.Contains($needle)) {
                throw "DiscordConsoleBridge.java 不是已修复的频道反控桥，缺少标记：$needle"
            }
        }
    }
    foreach ($qqFile in @('tools\QQConsoleBridge.java', 'tools\setup-qq-bot.ps1', 'tools\start-qq-bot.ps1', 'tools\start-llonebot.ps1', 'tools\test-qq-bot.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $qqFile) -PathType Leaf)) {
            throw "工具包缺少 QQ 桥接文件：$qqFile"
        }
    }
    $qqBridgeText = Get-Content -LiteralPath (Join-Path $KitRoot 'tools\QQConsoleBridge.java') -Raw -Encoding UTF8
    # list/backup 现在按 firstWord/word 解析，保留带参数的 backup force；门禁按实际语义检查，避免仅因变量名变化误报。
    foreach ($needle in @('class QQConsoleBridge', 'send_group_msg', 'command.equalsIgnoreCase("list")', 'config.adminIds', 'isAuthorizedAdmin', 'msg.role.equalsIgnoreCase("owner")', 'word.equalsIgnoreCase("backup")', 'runAiAgent', '-SuppressWatchNotification')) {
        if (-not $qqBridgeText.Contains($needle)) {
            throw "QQConsoleBridge.java 不是预期的 QQ 桥接版本，缺少标记：$needle"
        }
    }
    foreach ($entry in @('一键便携-控制面板.bat', '一键脚本\一键便携-启动所有运维.bat', '一键脚本\一键便携-重启运维监控.bat', '一键脚本\一键便携-停止所有运维.bat', '一键脚本\一键便携-配置QQ机器人.bat', '一键脚本\一键便携-启动QQ机器人.bat', '一键脚本\一键便携-测试QQ机器人.bat', '一键脚本\一键便携-健康体检.bat', '一键脚本\一键便携-重建配方索引.bat', '一键脚本\一键客户端自助修复.bat', '一键脚本\一键便携-扫地僧清掉落物.bat', '一键脚本\一键便携-仅重载QQ桥.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $entry) -PathType Leaf)) {
            throw "工具包缺少一键入口：$entry"
        }
    }
    # 目录布局门禁：根目录只留控制面板一个 bat，其余必须在「一键脚本」且路径基于 %~dp0..
    $movedBat = Get-Content -LiteralPath (Join-Path $KitRoot '一键脚本\一键便携-启动服务端.bat') -Raw -Encoding UTF8
    foreach ($needle in @('cd /d "%~dp0.."', '%~dp0..\tools\')) {
        if (-not $movedBat.Contains($needle)) {
            throw "一键脚本\一键便携-启动服务端.bat 未适配子目录布局，缺少：$needle"
        }
    }

    $serverStarterPath = Join-Path $KitRoot '一键脚本\一键便携-启动服务端.bat'
    $serverStarterText = Get-Content -LiteralPath $serverStarterPath -Raw -Encoding UTF8
    foreach ($needle in @('-NoPause', '-RestartOnCleanExit')) {
        if (-not $serverStarterText.Contains($needle)) {
            throw "一键便携-启动服务端.bat 缺少 10 秒自动重启参数：$needle"
        }
    }

    $backupScriptPath = Join-Path $KitRoot 'tools\backup-world.ps1'
    $backupScriptText = Get-Content -LiteralPath $backupScriptPath -Raw -Encoding UTF8
    # 前两个 needle 守手动备份去重/静默输出；后两个守 2026-07-23 修的锁文件问题：
    # 必须以共享读写方式打开世界文件（否则服务端的写句柄会让 region 文件整片被跳过），
    # 且跳过任何文件时归档必须改名标记 INCOMPLETE，不能和完整备份混为一谈。
    foreach ($needle in @('SuppressWatchNotification', 'manual-backup-suppress.txt', '[System.IO.FileShare]::ReadWrite', '-INCOMPLETE.zip')) {
        if (-not $backupScriptText.Contains($needle)) {
            throw "backup-world.ps1 缺少必需标记：$needle"
        }
    }

    $watchScriptPath = Join-Path $KitRoot 'tools\discord-watch.ps1'
    $watchScriptText = Get-Content -LiteralPath $watchScriptPath -Raw -Encoding UTF8
    foreach ($needle in @('function Test-ManualBackupSuppressed', 'manual-backup-suppress.txt', 'Test-ManualBackupSuppressed -Path $_.FullName')) {
        if (-not $watchScriptText.Contains($needle)) {
            throw "discord-watch.ps1 缺少手动备份通知去重标记：$needle"
        }
    }
    $playerPs1Path = Join-Path $KitRoot 'tools\player-update-generic.ps1'
    $playerPs1Bytes = [System.IO.File]::ReadAllBytes($playerPs1Path)
    if ($playerPs1Bytes.Length -lt 3 -or $playerPs1Bytes[0] -ne 0xEF -or $playerPs1Bytes[1] -ne 0xBB -or $playerPs1Bytes[2] -ne 0xBF) {
        throw 'player-update-generic.ps1 必须保存为 UTF-8 BOM，避免 Windows PowerShell 5 按 ANSI 解析中文脚本。'
    }
    $playerPs1Text = Get-Content -LiteralPath $playerPs1Path -Raw -Encoding UTF8
    foreach ($needle in @('Get-MinecraftHomeForInstance', 'Write-PclGlobalConfig', 'LaunchFolderSelect:{0}', 'TrimStart([char]0xFEFF)', 'pcl-home/.minecraft/launcher_profiles.json')) {
        if (-not $playerPs1Text.Contains($needle)) {
            throw "player-update-generic.ps1 缺少 PCL 本地实例修复标记：$needle"
        }
    }

    $playerPyPath = Join-Path $KitRoot 'tools\player-update-generic.py'
    $playerPyText = Get-Content -LiteralPath $playerPyPath -Raw -Encoding UTF8
    foreach ($needle in @('minecraft_home_for_instance', 'write_pcl_global_config', 'manifest.get("pcl")', 'LaunchFolderSelect:{mc_dir_value}', 'profile_home = mc_home / ".minecraft" / "launcher_profiles.json"')) {
        if (-not $playerPyText.Contains($needle)) {
            throw "player-update-generic.py 缺少 PCL 本地实例修复标记：$needle"
        }
    }
    $selfRepairPath = Join-Path $KitRoot 'tools\player-self-repair.ps1'
    $selfRepairText = Get-Content -LiteralPath $selfRepairPath -Raw -Encoding UTF8
    foreach ($needle in @('Get-RequiredJavaMajor', '$manifest.minecraftVersion', 'requiredJavaMajor', 'return 25')) {
        if (-not $selfRepairText.Contains($needle)) {
            throw "player-self-repair.ps1 缺少按清单版本匹配 Java 的标记：$needle"
        }
    }
    if ($selfRepairText.Contains('Minecraft 1.21.1 / NeoForge 21.1 需要 Java 21')) {
        throw 'player-self-repair.ps1 仍把私服版本与 Java 21 写死在公版逻辑中。'
    }
    $postmortemPath = Join-Path $KitRoot 'tools\incident-postmortem.ps1'
    $postmortemText = Get-Content -LiteralPath $postmortemPath -Raw -Encoding UTF8
    foreach ($needle in @('事故自动复盘', 'report.md', 'summary-qq.txt', '不自动停服、回滚或修改配置')) {
        if (-not $postmortemText.Contains($needle)) {
            throw "incident-postmortem.ps1 缺少复盘输出/安全边界标记：$needle"
        }
    }
    foreach ($entry in @('tools\incident-postmortem.ps1', '一键脚本\一键便携-事故自动复盘.bat')) {
        if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $entry) -PathType Leaf)) {
            throw "工具包缺少事故复盘入口：$entry"
        }
    }
    $blueMapPath = Join-Path $KitRoot 'tools\bluemap-timemachine.ps1'
    $blueMapText = Get-Content -LiteralPath $blueMapPath -Raw -Encoding UTF8
    foreach ($needle in @('BlueMap 时光机 MVP', '不复制 tiles', 'summary-qq.txt', 'snapshot.json', 'bluemap\web', 'fingerprintVersion', 'fingerprint =', '仅目录刷新', 'refreshed')) {
        if (-not $blueMapText.Contains($needle)) {
            throw "bluemap-timemachine.ps1 缺少快照/安全边界标记：$needle"
        }
    }
    foreach ($entry in @('tools\bluemap-timemachine.ps1', '一键脚本\一键便携-BlueMap时光机.bat', 'docs\bluemap-timemachine-BlueMap时光机.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $entry) -PathType Leaf)) {
            throw "工具包缺少 BlueMap 时光机入口：$entry"
        }
    }
    $runServerPath = Join-Path $KitRoot 'tools\portable-run-server.ps1'
    $runServerText = Get-Content -LiteralPath $runServerPath -Raw -Encoding UTF8
    foreach ($needle in @('Resolve-JavaForServer', 'Get-RequiredJavaMajor', 'libraries\net\neoforged\neoforge', 'adoptium.net/zh-CN')) {
        if (-not $runServerText.Contains($needle)) {
            throw "portable-run-server.ps1 缺少 Java 自动匹配/NeoForge 支持标记：$needle"
        }
    }

    $updaterPath = Join-Path $KitRoot 'tools\update-toolkit.ps1'
    $updaterText = Get-Content -LiteralPath $updaterPath -Raw -Encoding UTF8
    foreach ($needle in @('KIT-VERSION.txt', 'toolkit-update-source.txt', "tools\portable-pack.json', 'tools\ops-config.json'", '本地私有配置已保护', '主发布目录')) {
        if (-not $updaterText.Contains($needle)) {
            throw "update-toolkit.ps1 缺少自更新/配置保护标记：$needle"
        }
    }

    $rconHelperPath = Join-Path $KitRoot 'tools\enable-local-rcon.ps1'
    $rconHelperText = Get-Content -LiteralPath $rconHelperPath -Raw -Encoding UTF8
    foreach ($needle in @('enable-rcon', 'rcon.password', 'broadcast-rcon-to-ops', 'RotatePassword', 'Minecraft 服务端必须重启')) {
        if (-not $rconHelperText.Contains($needle)) {
            throw "enable-local-rcon.ps1 不是预期的 RCON 自动配置脚本，缺少标记：$needle"
        }
    }

    foreach ($entry in @(
        'tools\item-sweeper.ps1',
        'tools\apply-tps-gamerules.ps1',
        'tools\advancement-translations.json',
        'tools\build-item-aspect-indexer.ps1',
        'tools\item-aspect-indexer\src\main\java\com\chesir\qqaspectindex\QQAspectIndexMod.java',
        'tools\item-aspect-indexer\src\main\resources\META-INF\neoforge.mods.toml',
        'docs\qq-item-aspect-index-要素物品反查.md',
        'tools\mod-release-manager.py',
        'tools\start-mod-release-manager.ps1',
        'tools\grok-qq-once.ps1',
        'tools\reload-qq-console.ps1',
        'tools\player-view-shot.ps1',
        'tools\bluemap-shot.js',
        'tools\setup-camera-account.md',
        'docs\mod-release-manager-模组发布事务.md',
        'docs\玩家指南-后台自动更新.md'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $entry) -PathType Leaf)) {
            throw "工具包缺少近期功能依赖：$entry"
        }
    }
    $opsExample = Get-Content -LiteralPath (Join-Path $KitRoot 'tools\portable-ops-config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $opsExample.itemSweeper -or [bool]$opsExample.itemSweeper.enabled) {
        throw '公开运维模板缺少默认关闭的 itemSweeper 配置。'
    }
    if (-not $opsExample.modRelease -or [bool]$opsExample.modRelease.enabled) {
        throw '公开运维模板缺少默认关闭的 modRelease 配置。'
    }
    if (-not $opsExample.ai.bluemap -or [bool]$opsExample.ai.bluemap.enabled -or [bool]$opsExample.ai.bluemap.memberAccess) {
        throw '公开运维模板缺少默认关闭且禁止普通成员调用的 BlueMap 截图配置。'
    }
    if (-not $opsExample.ai.playerView -or [bool]$opsExample.ai.playerView.enabled -or [bool]$opsExample.ai.playerView.memberAccess) {
        throw '公开运维模板缺少默认关闭且禁止普通成员调用的客户端视角配置。'
    }
    if ([bool]$opsExample.ai.codexActionsEnabled) {
        throw '公开运维模板必须默认关闭 Codex 服务器动作。'
    }
}

function Reset-KitStage([string]$Target, [string]$ExpectedName) {
    $tmpBase = [IO.Path]::GetFullPath((Join-Path $Root 'tmp')).TrimEnd('\','/')
    $targetFull = [IO.Path]::GetFullPath($Target).TrimEnd('\','/')
    $expected = [IO.Path]::GetFullPath((Join-Path $tmpBase $ExpectedName)).TrimEnd('\','/')
    if ($ExpectedName -notin @('portable-server-kit','portable-server-kit-lite','portable-server-kit-private') -or
        -not $targetFull.Equals($expected, [StringComparison]::OrdinalIgnoreCase) -or
        -not $targetFull.StartsWith($tmpBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理非预期工具包临时目录：$targetFull"
    }
    if (Test-Path -LiteralPath $tmpBase) {
        $tmpBaseItem = Get-Item -LiteralPath $tmpBase -Force -ErrorAction Stop
        if (-not $tmpBaseItem.PSIsContainer -or ($tmpBaseItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "拒绝在非普通目录或重解析点中清理工具包：$tmpBase"
        }
    }
    if (-not (Test-Path -LiteralPath $targetFull)) { return }
    $rootItem = Get-Item -LiteralPath $targetFull -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "拒绝清理非普通目录或重解析点：$targetFull"
    }
    $link = Get-ChildItem -LiteralPath $targetFull -Recurse -Force -ErrorAction Stop |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        Select-Object -First 1
    if ($link) { throw "拒绝跨越工具包临时目录中的重解析点：$($link.FullName)" }
    Remove-Item -LiteralPath $targetFull -Recurse -Force -ErrorAction Stop
}

$kitName = if ($Private) { 'portable-server-kit-private' } elseif ($Lite) { 'portable-server-kit-lite' } else { 'portable-server-kit' }
$tmp = Join-Path $Root "tmp\$kitName"
$kitRoot = Join-Path $tmp $kitName
$dist = Join-Path $Root 'dist'
Reset-KitStage -Target $tmp -ExpectedName $kitName
New-Item -ItemType Directory -Force $kitRoot | Out-Null
New-Item -ItemType Directory -Force $dist | Out-Null

$files = @(
    '一键便携-控制面板.bat',
    '一键脚本\一键便携-启动Web控制面板.bat',
    '一键脚本\一键便携-停止Web控制面板.bat',
    '一键脚本\一键便携-初始化配置.bat',
    '一键脚本\一键便携-仅发布更新.bat',
    '一键脚本\一键便携-生成玩家包.bat',
    '一键脚本\一键便携-生成规范导入包.bat',
    '一键脚本\一键便携-生成完整包.bat',
    '一键脚本\一键便携-开启更新服务.bat',
    '一键脚本\一键便携-启动服务端.bat',
    '一键脚本\一键便携-启动所有运维.bat',
    '一键脚本\一键便携-重启运维监控.bat',
    '一键脚本\一键便携-停止所有运维.bat',
    '一键脚本\一键便携-配置QQ机器人.bat',
    '一键脚本\一键便携-启动QQ机器人.bat',
    '一键脚本\一键便携-测试QQ机器人.bat',
    '一键脚本\一键便携-启用RCON反控.bat',
    '一键脚本\一键便携-同步DDNS解析.bat',
    '一键脚本\一键便携-切换AI.bat',
    '一键脚本\一键便携-扫地僧清掉落物.bat',
    '一键脚本\一键便携-仅重载QQ桥.bat',
    '一键脚本\一键便携-健康体检.bat',
    '一键脚本\一键便携-重建配方索引.bat',
    '一键脚本\一键客户端自助修复.bat',
    '一键脚本\一键便携-事故自动复盘.bat',
    '一键脚本\一键便携-BlueMap时光机.bat',
    'docs\web-panel-网页远程运维.md',
    'docs\portable-server-kit.md',
    'docs\qq-ai-provider-switch.md',
    'tools\portable-pack.example.json',
    'tools\portable-ops-config.example.json',
    'tools\configure-portable-server.ps1',
    'tools\portable-publish.ps1',
    'tools\send-update-notify.ps1',
    'tools\test-update-notify.bat',
    'tools\build-portable-player-pack.ps1',
    'tools\build-portable-import-packs.ps1',
    'tools\build-portable-full-pack.ps1',
    'tools\portable-pack-lib.ps1',
    'tools\build-portable-server-kit.ps1',
    'tools\player-update-generic.ps1',
    'tools\player-update-generic.py',
    'tools\portable-stage-daemon.ps1',
    'tools\portable-stage-daemon.py',
    'tools\portable-bootstrap-refresh.ps1',
    'tools\portable-windows-sync.bat',
    'tools\portable-macos-sync.command',
    'tools\portable-run-server.ps1',
    'tools\start-portable-update-server.ps1',
    'tools\start-update-server.ps1',
    'tools\secure-update-server.py',
    'tools\zip-with-unix-mode.py',
    'tools\start-ops-monitor.ps1',
    'tools\stop-ops-monitor.ps1',
    'tools\enable-local-rcon.ps1',
    'tools\ddns-update.ps1',
    'tools\discord-watch.ps1',
    'tools\advancement-translations.json',
    'tools\QQConsoleBridge.java',
    'tools\set-ai-provider.ps1',
    'tools\grok-qq-once.ps1',
    'tools\reload-qq-console.ps1',
    'tools\setup-qq-bot.ps1',
    'tools\start-qq-bot.ps1',
    'tools\start-llonebot.ps1',
    'tools\test-qq-bot.ps1',
    'tools\backup-scheduler.ps1',
    'tools\backup-world.ps1',
    'tools\item-sweeper.ps1',
    'tools\apply-tps-gamerules.ps1',
    'tools\health-check.ps1',
    'tools\log-fingerprint.ps1',
    'tools\ops-supervisor.ps1',
    'tools\perf-sampler.ps1',
    'tools\weekly-report.ps1',
    'tools\lag-forensics.ps1',
    'tools\verify-backup.ps1',
    'tools\ops-timeline.ps1',
    'tools\incident-postmortem.ps1',
    'tools\bluemap-timemachine.ps1',
    'tools\backup-restore-smoke.ps1',
    'tools\shadow-smoke.ps1',
    'tools\player-self-repair.ps1',
    'tools\build-recipe-index.ps1',
    'tools\build-item-aspect-indexer.ps1',
    'tools\item-aspect-indexer\src\main\java\com\chesir\qqaspectindex\QQAspectIndexMod.java',
    'tools\item-aspect-indexer\src\main\resources\META-INF\neoforge.mods.toml',
    'tools\recipe-lookup.ps1',
    'tools\rcon-command.ps1',
    'tools\update-toolkit.ps1',
    '一键脚本\一键更新工具包.bat',
    '一键脚本\一键便携-运行报告.bat',
    '一键脚本\一键便携-验证备份.bat',
    '一键脚本\一键便携-运维时间线.bat',
    '一键脚本\一键便携-备份恢复冒烟.bat',
    '一键脚本\一键便携-影子服试车间.bat',
    'docs\error-watch-指纹告警.md',
    'docs\risk-confirm-高危确认与审计.md',
    'docs\weekly-report-运行报告.md',
    'docs\lag-forensics-卡顿取证.md',
    'docs\verify-backup-可验证备份.md',
    'docs\ops-timeline-运维时间机.md',
    'docs\incident-postmortem-事故自动复盘.md',
    'docs\bluemap-timemachine-BlueMap时光机.md',
    'docs\backup-restore-smoke-恢复冒烟.md',
    'docs\shadow-smoke-影子服试车间.md',
    'docs\player-self-repair-客户端自助修复.md',
    'docs\recipe-index-本服配方助手.md',
    'tools\install-server.ps1',
    'tools\portable-control-panel.ps1',
    'tools\portable-web-panel.ps1',
    'tools\stop-portable-web-panel.ps1',
    'tools\portable-web-panel.example.json',
    'tools\mod-release-manager.py',
    'tools\start-mod-release-manager.ps1',
    'tools\player-view-shot.ps1',
    'tools\bluemap-shot.js',
    'tools\package.json',
    'tools\package-lock.json',
    'tools\setup-camera-account.md',
    'docs\mod-release-manager-模组发布事务.md',
    'docs\玩家指南-后台自动更新.md',
    'docs\qq-bot-minecraft-ai-architecture.md',
    'docs\qq-item-aspect-index-要素物品反查.md',
    'docs\玩家拉新公版.md'
)

# Discord 频道相关组件（反控桥/webhook 发送器/编译脚本）只随私用包分发：
# 国内场景公开包用 QQ 方案即可；discord-watch.ps1 是 Discord+QQ 共用的日志监控引擎，两包都带，缺 Discord 组件时自动降级。
# 四个「生成工具包」入口也只随私用包分发：拿到公开/精简包的人是使用者，不需要二次打包。
if ($Private) {
    $files += @(
        'tools\DiscordConsoleBridge.java',
        'tools\DiscordWebhookSender.java',
        'tools\compile-discord-sender.bat',
        '一键脚本\一键生成便携工具包.bat',
        '一键脚本\一键生成精简工具包.bat',
        '一键脚本\一键生成私用便携工具包.bat',
        '一键脚本\一键生成玩家拉新公版.bat',
        'tools\build-player-recruit-kit.ps1',
        'docs\ops-fix-missing-iss.md'
    )
}

if ($Private) {
    foreach ($privateFile in @(
        'tools\portable-pack.json',
        'tools\ops-config.json'
    )) {
        if (Test-Path -LiteralPath (Join-Path $Root $privateFile) -PathType Leaf) {
            $files += $privateFile
        } else {
            Write-Warning "[便携] 未找到私用配置文件，已跳过：$privateFile"
        }
    }
}

foreach ($file in $files) { Copy-KitFile $file $kitRoot }

# LLBot QQ 机器人程序本体随包分发（约 150MB），账号数据绝不入包：
# - bin\llbot\data\**：登录数据库、config_QQ号.json、webui_token、日志缓存
# - qrcode.png：登录二维码
# - pmhq_config.json：清空 quick_login_qq（QQ 号）和 qq_path（本机绝对路径）
# QQ NT 客户端本体（tools\napcat，约 2GB）不入包：体积过大且属腾讯客户端，新机自装 QQ 即可。
$llbotRel = 'tools\LLBot-CLI-win-x64'
$llbotSrc = Join-Path $Root $llbotRel
if ($Lite) {
    Write-Host "[便携] 精简版：不打包 LLBot 程序本体（zip 会小很多，便于传播）。QQ 机器人需另装 LLBot 到 tools\LLBot-CLI-win-x64，或改用完整版工具包。"
} elseif (Test-Path -LiteralPath $llbotSrc -PathType Container) {
    $llbotDest = Join-Path $kitRoot $llbotRel
    $llbotSrcFull = [System.IO.Path]::GetFullPath($llbotSrc)
    Get-ChildItem -LiteralPath $llbotSrc -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($llbotSrcFull.Length + 1)
        if ($rel -match '(?i)^bin\\llbot\\data(\\|$)') { return }
        if ($rel -match '(?i)(^|\\)(qrcode\.png|debug\.log)$') { return }
        if ($_.Extension -match '(?i)^\.(log|db|sqlite|lock|pid)$') { return }
        $dest = Join-Path $llbotDest $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
    $pmhqCfgKit = Join-Path $llbotDest 'bin\pmhq\pmhq_config.json'
    if (Test-Path -LiteralPath $pmhqCfgKit -PathType Leaf) {
        $pmhqCfg = Get-Content -LiteralPath $pmhqCfgKit -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pmhqCfg.PSObject.Properties['quick_login_qq']) { $pmhqCfg.quick_login_qq = '' }
        if ($pmhqCfg.PSObject.Properties['qq_path']) { $pmhqCfg.qq_path = '' }
        Write-Utf8NoBom -Path $pmhqCfgKit -Value (($pmhqCfg | ConvertTo-Json -Depth 10) + "`r`n")
    }
    if (-not (Test-Path -LiteralPath (Join-Path $llbotDest 'llbot.exe') -PathType Leaf)) {
        throw 'LLBot 打包失败：llbot.exe 未复制到工具包。'
    }
    # 隐私门禁：确认包内 LLBot 不带任何账号痕迹
    $llbotLeaks = @(Get-ChildItem -LiteralPath $llbotDest -Recurse -File | Where-Object {
        $_.Name -match '(?i)^(config_\d+\.json|webui_token\.txt|qrcode\.png|debug\.log)$' -or
        $_.Extension -match '(?i)^\.(log|db|sqlite|lock|pid)$' -or
        $_.FullName -match '(?i)\\bin\\llbot\\data\\'
    })
    if ($llbotLeaks.Count -gt 0) {
        throw ("LLBot 隐私门禁失败，包内仍有账号数据：" + (($llbotLeaks | Select-Object -First 5 -ExpandProperty FullName) -join '; '))
    }
    $pmhqCheck = Get-Content -LiteralPath $pmhqCfgKit -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::IsNullOrEmpty([string]$pmhqCheck.quick_login_qq) -or -not [string]::IsNullOrEmpty([string]$pmhqCheck.qq_path)) {
        throw 'LLBot 隐私门禁失败：pmhq_config.json 仍带 QQ 号或本机路径。'
    }
} else {
    Write-Warning "[便携] 未找到 $llbotRel，本次工具包不含 LLBot 程序本体（QQ 机器人需另行安装）。"
}

# 私包净化：私用包只保留可长期复用的入口信息（域名/端口/Discord/QQ 密钥），
# 旧服身份字段（整合包名称、版本、加载器、主客户端目录、PCL 实例名等）必须清空，
# 由新服的初始化配置向导重新识别并让腐竹自定义名称。2026-07-06 实锤过一次「旧服信息上任」。
function Write-NeutralJson([string]$Path, $Object) {
    $out = $Object | ConvertTo-Json -Depth 100
    # PS5.1 的 ConvertTo-Json 会把中文转成 \uXXXX，写回前还原（只还原非 ASCII，控制字符保持转义）
    $out = [regex]::Replace($out, '\\u([0-9a-fA-F]{4})', {
        param($m)
        $cp = [Convert]::ToInt32($m.Groups[1].Value, 16)
        if ($cp -ge 0x80) { [string][char]$cp } else { $m.Value }
    })
    Write-Utf8NoBom -Path $Path -Value ($out + "`r`n")
}

function Clear-PrivateKitIdentity([string]$KitRoot) {
    $packPath = Join-Path $KitRoot 'tools\portable-pack.json'
    if (Test-Path -LiteralPath $packPath -PathType Leaf) {
        $pack = Get-Content -LiteralPath $packPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @('packId', 'packName', 'version', 'minecraftVersion', 'sourceClient')) {
            if ($pack.PSObject.Properties[$k]) { $pack.$k = '' }
        }
        if ($pack.loader) {
            foreach ($k in @('type', 'version')) { if ($pack.loader.PSObject.Properties[$k]) { $pack.loader.$k = '' } }
        }
        if ($pack.server -and $pack.server.PSObject.Properties['name']) { $pack.server.name = '' }
        if ($pack.serverList -and $pack.serverList.PSObject.Properties['name']) { $pack.serverList.name = '' }
        if ($pack.mrpack -and $pack.mrpack.PSObject.Properties['summary']) { $pack.mrpack.summary = '' }
        if ($pack.pcl -and $pack.pcl.PSObject.Properties['instanceName']) { $pack.pcl.instanceName = '' }
        if ($pack.PSObject.Properties['includeFiles']) {
            # 剔除旧实例专属的版本 jar/json，保留 options.txt、servers.dat 这类通用文件
            $pack.includeFiles = @([string[]]@($pack.includeFiles | Where-Object { $_ -notmatch '\.(jar|json)$' }))
        }
        if ($pack.playerOptions -and $pack.playerOptions.defaults) {
            # options 格式号和汉化资源包名都是特定 MC 版本专属，带到新服反而是错的
            foreach ($k in @('version', 'resourcePacks', 'incompatibleResourcePacks')) {
                if ($pack.playerOptions.defaults.PSObject.Properties[$k]) { $pack.playerOptions.defaults.PSObject.Properties.Remove($k) }
            }
        }
        Write-NeutralJson -Path $packPath -Object $pack
    }
    $opsPath = Join-Path $KitRoot 'tools\ops-config.json'
    if (Test-Path -LiteralPath $opsPath -PathType Leaf) {
        $ops = Get-Content -LiteralPath $opsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ops.PSObject.Properties['serverName']) { $ops.serverName = '' }
        if ($ops.backupSchedule -and $ops.backupSchedule.PSObject.Properties['backupPrefix']) { $ops.backupSchedule.backupPrefix = '' }
        # AI 模型密钥绝不入包：私包也清空（旧版单模型字段 + 各厂商预设），改由目标机的环境变量提供
        if ($ops.ai) {
            if ($ops.ai.PSObject.Properties['apiKey']) { $ops.ai.apiKey = '' }
            if ($ops.ai.providers) {
                foreach ($prop in @($ops.ai.providers.PSObject.Properties)) {
                    if ($prop.Value -is [psobject] -and $prop.Value.PSObject.Properties['apiKey']) { $prop.Value.apiKey = '' }
                }
            }
        }
        Write-NeutralJson -Path $opsPath -Object $ops
    }
}

function Test-PrivateKitNeutral([string]$KitRoot) {
    $packPath = Join-Path $KitRoot 'tools\portable-pack.json'
    if (Test-Path -LiteralPath $packPath -PathType Leaf) {
        $pack = Get-Content -LiteralPath $packPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $identity = @(
            @{ N = 'packName';         V = [string]$pack.packName },
            @{ N = 'minecraftVersion'; V = [string]$pack.minecraftVersion },
            @{ N = 'loader.type';      V = $(if ($pack.loader) { [string]$pack.loader.type } else { '' }) },
            @{ N = 'loader.version';   V = $(if ($pack.loader) { [string]$pack.loader.version } else { '' }) },
            @{ N = 'sourceClient';     V = [string]$pack.sourceClient },
            @{ N = 'pcl.instanceName'; V = $(if ($pack.pcl) { [string]$pack.pcl.instanceName } else { '' }) }
        )
        foreach ($f in $identity) {
            if (-not [string]::IsNullOrWhiteSpace($f.V)) { throw "私包净化失败：portable-pack.json 的 $($f.N) 仍带着旧服身份「$($f.V)」。" }
        }
        foreach ($inc in @($pack.includeFiles)) {
            if ([string]$inc -match '\.(jar|json)$') { throw "私包净化失败：includeFiles 仍含旧实例文件「$inc」。" }
        }
    }
    $opsPath = Join-Path $KitRoot 'tools\ops-config.json'
    if (Test-Path -LiteralPath $opsPath -PathType Leaf) {
        $ops = Get-Content -LiteralPath $opsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$ops.serverName)) { throw "私包净化失败：ops-config.json 的 serverName 仍是「$($ops.serverName)」。" }
        if ($ops.ai -and -not [string]::IsNullOrWhiteSpace([string]$ops.ai.apiKey)) { throw "私包净化失败：ops-config.json 的 ai.apiKey 仍带着模型密钥，禁止入包。" }
        if ($ops.ai -and $ops.ai.providers) {
            foreach ($prop in @($ops.ai.providers.PSObject.Properties)) {
                if ($prop.Value -is [psobject] -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value.apiKey)) {
                    throw "私包净化失败：ops-config.json 的 ai.providers.$($prop.Name).apiKey 仍带着模型密钥，禁止入包。"
                }
            }
        }
    }
}

if ($Private) {
    Clear-PrivateKitIdentity -KitRoot $kitRoot
    Test-PrivateKitNeutral -KitRoot $kitRoot
    # 私包内置自更新源：指向本机主发布目录的 latest 私包，解压到新服即可零配置自更新。
    Write-Utf8NoBom -Path (Join-Path $kitRoot 'tools\toolkit-update-source.txt') -Value ((Join-Path $Root 'dist\portable-server-kit-private-latest.zip') + "`r`n")
} else {
    # 公版不继承作者自己的域名、端口或本机路径。需要公共自更新时，由发布者另行配置
    # 一个明确授权的渠道；空配置只会让「检查更新」给出中文说明，不影响运维或玩家拉新。
    $srcCheckPath = Join-Path $kitRoot 'tools\toolkit-update-source.txt'
    if (Test-Path -LiteralPath $srcCheckPath) { Remove-Item -LiteralPath $srcCheckPath -Force }
}

# 语法门禁：所有 PowerShell 脚本必须能被解析，防止“特征字符串在但文件本身是坏的”带病入包
# （例如 UTF-8 无 BOM 的中文 ps1 会被 Windows PowerShell 5 按 ANSI 解析成满屏语法错误，启动即退）。
Get-ChildItem -LiteralPath $kitRoot -Recurse -File -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '\\LLBot-CLI-win-x64\\' } | # 第三方程序目录（含 node_modules）不适用我们的脚本门禁
    ForEach-Object {
    $psBytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasUtf8Bom = $psBytes.Length -ge 3 -and $psBytes[0] -eq 0xEF -and $psBytes[1] -eq 0xBB -and $psBytes[2] -eq 0xBF
    $psText = [System.Text.Encoding]::UTF8.GetString($psBytes)
    if (-not $hasUtf8Bom -and [regex]::IsMatch($psText, '[^\x00-\x7F]')) {
        throw ("PowerShell 脚本含非 ASCII 字符但没有 UTF-8 BOM，Windows PowerShell 5 会解码错误，拒绝打包：{0}" -f $_.Name)
    }
    $parseErrors = $null
    $parseTokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $first = $parseErrors[0]
        throw ("工具包脚本存在语法错误，拒绝打包：{0}（行{1}：{2}）。如脚本含中文，请确认保存为 UTF-8 带 BOM。" -f $_.Name, $first.Extent.StartLineNumber, $first.Message)
    }
}
# bat 门禁：所有一键 bat 必须 CRLF + 无 BOM。
# LF 换行或带 BOM 的中文 bat 会被 cmd 按错误字节偏移解析，命令被切成 "owershell.exe" 这类碎片（2026-07-07 实锤）。
Get-ChildItem -LiteralPath $kitRoot -Recurse -File -Filter '*.bat' |
    Where-Object { $_.FullName -notmatch '\\LLBot-CLI-win-x64\\' } |
    ForEach-Object {
        $batBytes = [System.IO.File]::ReadAllBytes($_.FullName)
        if ($batBytes.Length -ge 3 -and $batBytes[0] -eq 0xEF -and $batBytes[1] -eq 0xBB -and $batBytes[2] -eq 0xBF) {
            throw ("bat 带 UTF-8 BOM，cmd 会解析异常，拒绝打包：{0}" -f $_.Name)
        }
        $batText = [System.Text.Encoding]::UTF8.GetString($batBytes)
        if ([regex]::IsMatch($batText, '(?<!\r)\n')) {
            throw ("bat 含 LF 换行（必须 CRLF，否则 cmd 字节错位切碎命令），拒绝打包：{0}" -f $_.Name)
        }
    }
Test-NewConfigureMenu -KitRoot $kitRoot
Copy-Item -LiteralPath (Join-Path $Root 'docs\portable-server-kit.md') -Destination (Join-Path $kitRoot 'README-portable-server-kit.md') -Force
# 更新日志随包分发，也是「检查更新」弹窗展示的内容
if (Test-Path -LiteralPath (Join-Path $Root 'docs\KIT-CHANGELOG.txt') -PathType Leaf) {
    Copy-Item -LiteralPath (Join-Path $Root 'docs\KIT-CHANGELOG.txt') -Destination (Join-Path $kitRoot 'KIT-CHANGELOG.txt') -Force
}

if (-not $Private) {
    Test-PublicKitPrivacy -KitRoot $kitRoot
}

if ($Private) {
    Write-Utf8NoBom -Path (Join-Path $kitRoot 'PRIVATE-WARNING.txt') -Value @"
This is a private portable server kit.

It may include personal Discord/RCON/update configuration files:
- tools\portable-pack.json
- tools\ops-config.json

Pack identity fields (pack name, Minecraft version, loader, source client dir,
PCL instance name) are blanked at build time on purpose: run the setup wizard
(一键脚本\一键便携-初始化配置.bat) on the new server to re-detect them and pick a new name.

Do not share this archive publicly.
"@
}

# 工具包版本号：自更新脚本（tools\update-toolkit.ps1）靠它比对新旧
Write-Utf8NoBom -Path (Join-Path $kitRoot 'KIT-VERSION.txt') -Value ($Version + "`r`n")

$manifestLines = @()
if ($Private) { $manifestLines += 'PRIVATE MODE: includes personal config files when present.' }
if ($Lite) { $manifestLines += 'LITE MODE: LLBot runtime not bundled (install LLBot to tools\LLBot-CLI-win-x64 for QQ bot, or use the full kit).' }
$manifestLines += $files
if (Test-Path -LiteralPath (Join-Path $kitRoot $llbotRel) -PathType Container) {
    $manifestLines += ($llbotRel + '\  (LLBot QQ bot runtime, account data stripped)')
}
Write-Utf8NoBom -Path (Join-Path $kitRoot 'KIT-MANIFEST.txt') -Value (($manifestLines -join "`r`n") + "`r`n")

$zip = Join-Path $dist ("$kitName-$Version.zip")
$zipTool = Join-Path $Root 'tools\zip-with-unix-mode.py'
& python $zipTool ([System.IO.Path]::GetFullPath($kitRoot)) ([System.IO.Path]::GetFullPath($zip))
if ($LASTEXITCODE -ne 0) { throw "压缩工具执行失败，退出码：$LASTEXITCODE" }
$latestZip = Join-Path $dist ("$kitName-latest.zip")
Copy-Item -LiteralPath $zip -Destination $latestZip -Force
Write-Host "[便携] 工具包已生成：$zip"
Write-Host "[便携] 最新副本：$latestZip"

if ($Lite) {
    # 精简包同时发布到工具包更新通道：更新服务运行时对外提供 /kit/ 无令牌下载，
    # 外发工具包的「检查更新」按钮即从这里获取新版本与更新日志。
    $kitChannel = Join-Path $Root 'modpack-public\kit-update'
    New-Item -ItemType Directory -Force $kitChannel | Out-Null
    Copy-Item -LiteralPath $latestZip -Destination (Join-Path $kitChannel 'portable-server-kit-lite-latest.zip') -Force
    Write-Utf8NoBom -Path (Join-Path $kitChannel 'KIT-VERSION.txt') -Value ($Version + "`r`n")
    if (Test-Path -LiteralPath (Join-Path $Root 'docs\KIT-CHANGELOG.txt') -PathType Leaf) {
        Copy-Item -LiteralPath (Join-Path $Root 'docs\KIT-CHANGELOG.txt') -Destination (Join-Path $kitChannel 'KIT-CHANGELOG.txt') -Force
    }
    Write-Host "[便携] 已发布到更新通道：$kitChannel（更新服务对外路径 /kit/portable-server-kit-lite-latest.zip）"
}




