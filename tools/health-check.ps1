param(
    [switch]$Pack,
    [switch]$Quiet,
    [switch]$Json,
    [switch]$QqSummary,
    [int]$LogTailLines = 8000,
    [string]$OutDir = ''
)

# 一键健康体检中心：只读取证 + 风险评分 + 可选脱敏诊断包。
# 设计原则：
# 1) 单一引擎，多入口（bat / 控制面板 / QQ !体检）共享同一套检查与评分。
# 2) 输出必须可行动：每条发现都有 原因 / 影响 / 建议动作。
# 3) 诊断包默认脱敏：密钥、Token、RCON 密码、玩家 IP、本机用户路径一律过滤。
# 4) 绝不修改服务端配置、世界或运维进程状态。

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = '服务端健康体检' } catch { }

$Root = Split-Path -Parent $PSScriptRoot
$ToolsDir = $PSScriptRoot
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $Root ('tmp\health-check\' + $Stamp)
}
$ReportDir = $OutDir
$Findings = New-Object System.Collections.Generic.List[object]
$Meta = [ordered]@{
    startedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    root        = $Root
    kitVersion  = ''
    overall     = 'green'
    score       = 100
    errorCount  = 0
    warnCount   = 0
    okCount     = 0
}

function Add-Finding {
    param(
        [ValidateSet('ok', 'warn', 'error', 'info')][string]$Severity,
        [string]$Category,
        [string]$Title,
        [string]$Detail = '',
        [string]$Impact = '',
        [string]$Action = ''
    )
    $Findings.Add([pscustomobject]@{
            Severity = $Severity
            Category = $Category
            Title    = $Title
            Detail   = $Detail
            Impact   = $Impact
            Action   = $Action
        }) | Out-Null
}

function Write-CheckHost([string]$Message, [string]$Color = 'Gray') {
    if ($Quiet -or $QqSummary) { return }
    Write-Host $Message -ForegroundColor $Color
}

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KiB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Test-PortListening([int]$Port) {
    if ($Port -le 0) { return $false }
    try {
        foreach ($ep in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            if ($ep.Port -eq $Port) { return $true }
        }
    } catch { }
    return $false
}

function Get-PidFileAlive([string]$RelPath) {
    $path = Join-Path $Root $RelPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
    $raw = ''
    try { $raw = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) } catch { return 0 }
    $procId = 0
    if (-not [int]::TryParse(($raw.Trim()), [ref]$procId)) { return 0 }
    if ($procId -le 0) { return 0 }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) { return 0 }
    try { $started = $proc.StartTime } catch { return 0 }
    try {
        $stamp = (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTime
        if ($started -gt $stamp.AddSeconds(60)) { return 0 }
    } catch { }
    return $procId
}

function Read-ServerProperties {
    $props = @{}
    $path = Join-Path $Root 'server.properties'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $props }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line -match '^\s*([^#=]+)=(.*)$') {
            $props[$matches[1].Trim()] = $matches[2]
        }
    }
    return $props
}

function Get-LoaderDetection {
    $forgeRoot = Join-Path $Root 'libraries\net\minecraftforge\forge'
    if (Test-Path -LiteralPath $forgeRoot -PathType Container) {
        $d = Get-ChildItem -LiteralPath $forgeRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d -and $d.Name -match '^(?<mc>[0-9]+(\.[0-9]+){1,2})-(?<v>.+)$') {
            return @{ Loader = 'forge'; LoaderVersion = $matches.v; Mc = $matches.mc }
        }
    }
    $neoRoot = Join-Path $Root 'libraries\net\neoforged\neoforge'
    if (Test-Path -LiteralPath $neoRoot -PathType Container) {
        $d = Get-ChildItem -LiteralPath $neoRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d) {
            $mc = ''
            if ($d.Name -match '^(?<a>\d+)\.(?<b>\d+)\.(?<c>\d+)') {
                $a = [int]$matches.a; $b = [int]$matches.b; $c = [int]$matches.c
                if ($a -ge 26) {
                    $mc = if ($c -eq 0) { ('{0}.{1}' -f $a, $b) } else { ('{0}.{1}.{2}' -f $a, $b, $c) }
                } else {
                    $mc = if ($b -eq 0) { '1.' + $a } else { ('1.{0}.{1}' -f $a, $b) }
                }
            }
            return @{ Loader = 'neoforge'; LoaderVersion = $d.Name; Mc = $mc }
        }
    }
    $fabRoot = Join-Path $Root 'libraries\net\fabricmc\fabric-loader'
    if (Test-Path -LiteralPath $fabRoot -PathType Container) {
        $d = Get-ChildItem -LiteralPath $fabRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($d) { return @{ Loader = 'fabric'; LoaderVersion = $d.Name; Mc = '' } }
    }
    return $null
}

function Resolve-JavaCandidate {
    $adoptium = 'C:\Program Files\Eclipse Adoptium'
    $found = @()
    if (Test-Path -LiteralPath $adoptium -PathType Container) {
        $found += Get-ChildItem -LiteralPath $adoptium -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'bin\java.exe' } |
            Where-Object { Test-Path -LiteralPath $_ }
    }
    if ($env:JAVA_HOME) {
        $jh = Join-Path $env:JAVA_HOME 'bin\java.exe'
        if (Test-Path -LiteralPath $jh) { $found += $jh }
    }
    $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $found += $cmd.Source }
    return ($found | Select-Object -Unique)
}

function Get-JavaVersionInfo([string]$JavaExe) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $JavaExe
        $psi.Arguments = '-version'
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEnd()
        $out = $p.StandardOutput.ReadToEnd()
        [void]$p.WaitForExit(8000)
        $text = ($err + "`n" + $out)
        $ver = ''
        if ($text -match 'version\s+"([^"]+)"') { $ver = $matches[1] }
        $major = 0
        if ($ver -match '^1\.(\d+)') { $major = [int]$matches[1] }
        elseif ($ver -match '^(\d+)') { $major = [int]$matches[1] }
        # 必须用 pscustomobject：裸 hashtable 在管道里会被拆成 DictionaryEntry，版本列表只剩碎片
        return [pscustomobject]@{ Path = $JavaExe; Version = $ver; Major = $major }
    } catch {
        return $null
    }
}

function Required-JavaMajor([string]$McVersion) {
    # 粗映射：足够做体检，不追求覆盖每一个 snapshot。
    if ([string]::IsNullOrWhiteSpace($McVersion)) { return 21 }
    if ($McVersion -match '^1\.(\d+)') {
        $minor = [int]$matches[1]
        if ($minor -ge 21) { return 21 }
        if ($minor -ge 18) { return 17 }
        if ($minor -ge 17) { return 16 }
        return 8
    }
    return 21
}

function Read-TextSmart([string]$Path, [int]$MaxLines = 0) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    # latest.log 常被 MC 进程独占写入：必须 FileShare.ReadWrite，否则 ReadAllBytes 直接炸
    $bytes = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $ms = New-Object System.IO.MemoryStream
            $fs.CopyTo($ms)
            $bytes = $ms.ToArray()
            $ms.Dispose()
        } finally { $fs.Dispose() }
    } catch {
        return @("# health-check: cannot read log: $($_.Exception.Message)")
    }
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return @() }
    $text = $null
    # BOM / 启发式：先 UTF-8，失败再 GBK（Windows 中文环境常见）
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false, $true
        $text = $utf8.GetString($bytes)
    } catch {
        try {
            $gbk = [System.Text.Encoding]::GetEncoding(936)
            $text = $gbk.GetString($bytes)
        } catch {
            $text = [System.Text.Encoding]::Default.GetString($bytes)
        }
    }
    $lines = $text -split "`r?`n", -1
    if ($MaxLines -gt 0 -and $lines.Count -gt $MaxLines) {
        return $lines[($lines.Count - $MaxLines)..($lines.Count - 1)]
    }
    return $lines
}

# 与 discord-watch 共用 tools/log-fingerprint.ps1，避免两套规则漂移
. (Join-Path $PSScriptRoot 'log-fingerprint.ps1')
function Get-LogFingerprint([string]$Line) { return (Get-McLogFingerprint -Line $Line) }

function Test-JsonFile([string]$Path) {
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-TomlOrConfBasics([string]$Path) {
    # 轻量语法嗅探：不成对引号、明显截断。不引入完整 TOML 解析器。
    try {
        $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        $i = 0
        foreach ($line in $lines) {
            $i++
            $t = $line.Trim()
            if ($t.StartsWith('#') -or $t.Length -eq 0) { continue }
            $dq = ([regex]::Matches($t, '(?<!\\)"')).Count
            if (($dq % 2) -ne 0) { return "line ${i}: unmatched double quote" }
        }
        return $null
    } catch {
        return $_.Exception.Message
    }
}

function Get-BackupZips {
    $dir = Join-Path $Root 'backups\world'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.zip' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
}

function Test-BackupZipReadable([string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    try {
        $z = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $names = $z.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }
            $hasLevel = $false
            foreach ($n in $names) {
                if ($n -match '(^|/)level\.dat$') { $hasLevel = $true; break }
            }
            return @{ Ok = $true; HasLevelDat = $hasLevel; EntryCount = $z.Entries.Count }
        } finally { $z.Dispose() }
    } catch {
        return @{ Ok = $false; HasLevelDat = $false; EntryCount = 0; Error = $_.Exception.Message }
    }
}

function Protect-SecretText([string]$Text) {
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    # key=value / "key": "value" 形态
    $secretKeys = @(
        'password', 'rcon\.password', 'apiKey', 'api_key', 'token', 'botToken', 'webhookUrl',
        'loginToken', 'secret', 'authorization', 'access_token', 'client_secret', 'private_key'
    )
    foreach ($k in $secretKeys) {
        $s = [regex]::Replace($s, "(?im)($k\s*[=:]\s*)([`"']?)([^`"'`r`n,}]+)\2", '${1}${2}***REDACTED***${2}')
        $s = [regex]::Replace($s, "(?im)(`"$k`"\s*:\s*)`"[^`"]*`"", '${1}"***REDACTED***"')
    }
    # Bearer / raw long tokens
    $s = [regex]::Replace($s, '(?i)(Bearer\s+)[A-Za-z0-9\-._~+/]+=*', '${1}***REDACTED***')
    # IPv4（含可选端口）——诊断包不应带玩家 IP
    $s = [regex]::Replace($s, '\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)(?::\d{1,5})?\b', '<ip>')
    # Windows 用户路径
    $s = [regex]::Replace($s, '(?i)([A-Z]:\\Users\\)[^\\\/\s"]+', '${1}<user>')
    $s = [regex]::Replace($s, '(?i)(/home/)[^/\s"]+', '${1}<user>')
    $s = [regex]::Replace($s, '(?i)(C:\\Users\\)[^\\\/\s"]+', '${1}<user>')
    return $s
}

function Write-RedactedCopy([string]$Src, [string]$Dest) {
    $parent = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) { return }
    $ext = [System.IO.Path]::GetExtension($Src).ToLowerInvariant()
    $name = [System.IO.Path]::GetFileName($Src).ToLowerInvariant()
    $texty = $ext -in @('.log', '.txt', '.properties', '.json', '.toml', '.conf', '.cfg', '.yml', '.yaml', '.md', '.ps1', '.java', '.bat')
    if (-not $texty) {
        # 二进制不入包（避免 hprof / zip 撑爆）
        Set-Content -LiteralPath ($Dest + '.skipped.txt') -Value ('skipped binary: ' + $name) -Encoding UTF8
        return
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Src)
        $safe = Protect-SecretText $raw
        [System.IO.File]::WriteAllText($Dest, $safe, (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Set-Content -LiteralPath ($Dest + '.error.txt') -Value $_.Exception.Message -Encoding UTF8
    }
}

function Invoke-OptionalRcon([string]$Command) {
    $script = Join-Path $ToolsDir 'rcon-command.ps1'
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        return @{ Ok = $false; Output = 'missing rcon-command.ps1' }
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Command `"$Command`""
        $psi.WorkingDirectory = $Root
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(12000)) {
            try { $p.Kill() } catch { }
            return @{ Ok = $false; Output = 'RCON timeout' }
        }
        if ($p.ExitCode -ne 0) {
            $msg = if ($err) { $err.Trim() } else { $out.Trim() }
            return @{ Ok = $false; Output = $msg }
        }
        return @{ Ok = $true; Output = $out.Trim() }
    } catch {
        return @{ Ok = $false; Output = $_.Exception.Message }
    }
}

# ---------------- 检查实现 ----------------

Write-CheckHost '========================================' 'Cyan'
Write-CheckHost '  服务端一键健康体检' 'Cyan'
Write-CheckHost '========================================' 'Cyan'
Write-CheckHost ("根目录：{0}" -f $Root) 'DarkGray'
Write-CheckHost ''

# Kit version
$kitVerPath = Join-Path $Root 'KIT-VERSION.txt'
if (Test-Path -LiteralPath $kitVerPath) {
    $Meta.kitVersion = (Get-Content -LiteralPath $kitVerPath -Raw -ErrorAction SilentlyContinue).Trim()
}

# 1) 版本与 Java
Write-CheckHost '[1/8] 版本与 Java…' 'White'
$loader = Get-LoaderDetection
if ($null -eq $loader) {
    Add-Finding -Severity error -Category '版本' -Title '未识别到加载器' `
        -Detail 'libraries 下找不到 forge / neoforge / fabric-loader' `
        -Impact '服务端可能未正确安装，或目录不是完整服务端根' `
        -Action '用面板「服务端下载与安装」或核对 libraries 目录'
} else {
    $mcText = if ($loader.Mc) { $loader.Mc } else { '未知' }
    Add-Finding -Severity ok -Category '版本' -Title ("加载器 {0} {1}" -f $loader.Loader, $loader.LoaderVersion) `
        -Detail ("Minecraft {0}" -f $mcText)
    $needJava = Required-JavaMajor $loader.Mc
    $javas = @(Resolve-JavaCandidate | ForEach-Object { Get-JavaVersionInfo $_ } | Where-Object { $_ -and $_.Major -gt 0 })
    if ($javas.Count -eq 0) {
        Add-Finding -Severity error -Category 'Java' -Title '未找到可用 Java' `
            -Detail 'Adoptium / JAVA_HOME / PATH 均未探测到 java.exe' `
            -Impact '无法启动服务端' `
            -Action ("安装 Java {0}（Eclipse Temurin 推荐）" -f $needJava)
    } else {
        $best = $javas | Sort-Object Major -Descending | Select-Object -First 1
        # ≥ 推荐大版本即合格（已装 25 对需要 21 的 1.21 服是 OK 的）
        $match = @($javas | Where-Object { $_.Major -ge $needJava } | Sort-Object Major | Select-Object -First 1)
        if ($match.Count -gt 0) {
            Add-Finding -Severity ok -Category 'Java' -Title ("Java {0} 可用（需要 ≥{1}）" -f $match[0].Major, $needJava) `
                -Detail ("{0} ({1})" -f $match[0].Version, $match[0].Path)
        } else {
            Add-Finding -Severity warn -Category 'Java' -Title ("未找到推荐的 Java ≥{0}" -f $needJava) `
                -Detail ("当前探测到：{0}" -f (($javas | ForEach-Object { "Java $($_.Major) $($_.Version)" }) -join '；')) `
                -Impact '版本不匹配可能导致启动失败或模组异常' `
                -Action ("安装 Java {0}+，或确认 portable-run-server 能自动匹配到正确运行时" -f $needJava)
        }
    }
}

# 2) 模组
Write-CheckHost '[2/8] 模组清单…' 'White'
$modsDir = Join-Path $Root 'mods'
if (-not (Test-Path -LiteralPath $modsDir -PathType Container)) {
    Add-Finding -Severity warn -Category '模组' -Title 'mods 目录不存在' `
        -Detail $modsDir -Impact '无模组可加载' -Action '确认是否应有模组目录'
} else {
    $jars = @(Get-ChildItem -LiteralPath $modsDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.jar$' -or $_.Name -like '*.jar.disable' -or $_.Name -like '*.disabled' })
    $active = @($jars | Where-Object { $_.Extension -eq '.jar' })
    $disabled = @($jars | Where-Object { $_.Name -match '\.(jar\.disable|disabled|jar\.disabled)$' -or $_.Name -like '*.disable' })
    # 也扫 .disable 后缀（本服历史：xxx.jar.disable）
    $disabledExtra = @(Get-ChildItem -LiteralPath $modsDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*.disable' })
    $disabled = @($disabled + $disabledExtra | Select-Object -Unique FullName)

    Add-Finding -Severity ok -Category '模组' -Title ("活跃模组 {0} 个" -f $active.Count) `
        -Detail ("禁用 {0} 个" -f $disabled.Count)

    # 重复：去掉中文括号装饰与版本数字后的基名粗聚类
    $groups = @{}
    foreach ($j in $active) {
        $base = $j.BaseName
        $base = [regex]::Replace($base, '^\[[^\]]+\]\s*', '')
        $base = [regex]::Replace($base, '[-_]?\d+(\.\d+)+(?:[-+][A-Za-z0-9._]+)?$', '')
        $base = $base.Trim().ToLowerInvariant()
        if (-not $groups.ContainsKey($base)) { $groups[$base] = New-Object System.Collections.Generic.List[string] }
        $groups[$base].Add($j.Name) | Out-Null
    }
    $dups = @($groups.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
    if ($dups.Count -gt 0) {
        $sample = ($dups | Select-Object -First 5 | ForEach-Object {
                '{0} => {1}' -f $_.Key, ($_.Value -join ' | ')
            }) -join '; '
        Add-Finding -Severity warn -Category '模组' -Title ("疑似重复模组 {0} 组" -f $dups.Count) `
            -Detail $sample `
            -Impact '同一模组多版本并存可能导致冲突/启动失败' `
            -Action '保留正确版本，其余改名 .disable 或移出 mods'
    } else {
        Add-Finding -Severity ok -Category '模组' -Title '未发现明显重复模组'
    }

    if ($disabled.Count -gt 0) {
        $dn = ($disabled | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', '
        Add-Finding -Severity info -Category '模组' -Title ("已禁用模组 {0} 个" -f $disabled.Count) `
            -Detail $dn
    }
}

# 3) 配置语法
Write-CheckHost '[3/8] 配置与语法…' 'White'
$props = Read-ServerProperties
$propsPath = Join-Path $Root 'server.properties'
if (-not (Test-Path -LiteralPath $propsPath)) {
    Add-Finding -Severity error -Category '配置' -Title '缺少 server.properties' `
        -Impact '服务端无法正常启动' -Action '从干净安装复制或重新运行安装向导'
} else {
    $needKeys = @('server-port', 'level-name', 'max-players', 'online-mode', 'enable-rcon')
    $missing = @($needKeys | Where-Object { -not $props.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        Add-Finding -Severity warn -Category '配置' -Title 'server.properties 缺关键键' `
            -Detail ($missing -join ', ') -Action '补全缺失字段'
    } else {
        Add-Finding -Severity ok -Category '配置' -Title 'server.properties 可解析' `
            -Detail ("port={0} rcon={1} online-mode={2}" -f $props['server-port'], $props['enable-rcon'], $props['online-mode'])
    }
    if (($props['enable-rcon'] -as [string]) -ne 'true') {
        Add-Finding -Severity warn -Category '配置' -Title 'RCON 未启用' `
            -Detail 'enable-rcon 不是 true' `
            -Impact 'QQ/面板远程控制、安全备份存盘不可用' `
            -Action '面板点「启用 RCON 反控」或运行 enable-local-rcon.ps1'
    } elseif ([string]::IsNullOrWhiteSpace([string]$props['rcon.password'])) {
        Add-Finding -Severity error -Category '配置' -Title 'RCON 密码为空' `
            -Impact 'RCON 无法认证' -Action '设置 rcon.password 并重启服务端'
    } else {
        Add-Finding -Severity ok -Category '配置' -Title 'RCON 已配置' `
            -Detail ("端口 {0}" -f $props['rcon.port'])
    }
}

$opsPath = Join-Path $ToolsDir 'ops-config.json'
if (Test-Path -LiteralPath $opsPath) {
    if (Test-JsonFile $opsPath) {
        Add-Finding -Severity ok -Category '配置' -Title 'ops-config.json 语法正确'
    } else {
        Add-Finding -Severity error -Category '配置' -Title 'ops-config.json JSON 语法错误' `
            -Impact '运维监控/QQ 桥可能无法启动' -Action '用编辑器校验 JSON 逗号与引号'
    }
} else {
    Add-Finding -Severity warn -Category '配置' -Title '缺少 ops-config.json' `
        -Action '运行初始化配置向导'
}

$packPath = Join-Path $ToolsDir 'portable-pack.json'
if (Test-Path -LiteralPath $packPath) {
    if (Test-JsonFile $packPath) {
        Add-Finding -Severity ok -Category '配置' -Title 'portable-pack.json 语法正确'
    } else {
        Add-Finding -Severity error -Category '配置' -Title 'portable-pack.json JSON 语法错误' `
            -Action '修复 JSON 后重新发布'
    }
}

# 抽样检查 config 下 JSON（严格）。
# 注意：PS5.1 里 -LiteralPath + -Include 经常不过滤扩展名，会把 .toml 全塞进来；
# 必须用 Where-Object 按扩展名筛。TOML 多行字符串不宜做引号计数，只统计数量。
$configDir = Join-Path $Root 'config'
$badConfigs = New-Object System.Collections.Generic.List[string]
$tomlCount = 0
$jsonChecked = 0
if (Test-Path -LiteralPath $configDir -PathType Container) {
    $jsonFiles = @(Get-ChildItem -LiteralPath $configDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.json' } |
            Select-Object -First 120)
    $jsonChecked = $jsonFiles.Count
    foreach ($f in $jsonFiles) {
        if (-not (Test-JsonFile $f.FullName)) {
            $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
            $badConfigs.Add($rel) | Out-Null
            if ($badConfigs.Count -ge 8) { break }
        }
    }
    $tomlCount = @(Get-ChildItem -LiteralPath $configDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.toml', '.conf') }).Count
}
if ($badConfigs.Count -gt 0) {
    Add-Finding -Severity warn -Category '配置' -Title ("JSON 配置语法错误 {0}+" -f $badConfigs.Count) `
        -Detail ($badConfigs -join '; ') `
        -Impact '对应模组可能回退默认配置或启动报错' `
        -Action '按路径打开文件修复 JSON 语法'
} else {
    Add-Finding -Severity ok -Category '配置' -Title '抽样 JSON 配置语法正常' `
        -Detail ("检查 {0} 个 JSON；TOML/CONF 约 {1} 个（未做严格解析）" -f $jsonChecked, $tomlCount)
}

# 4) 可达性 / 进程
Write-CheckHost '[4/8] 端口与运维进程…' 'White'
$serverPort = 25565
if ($props.ContainsKey('server-port')) {
    $tmp = 0
    if ([int]::TryParse(([string]$props['server-port']).Trim(), [ref]$tmp) -and $tmp -gt 0) { $serverPort = $tmp }
}
$rconPort = 25575
if ($props.ContainsKey('rcon.port')) {
    $tmp = 0
    if ([int]::TryParse(([string]$props['rcon.port']).Trim(), [ref]$tmp) -and $tmp -gt 0) { $rconPort = $tmp }
}

$serverUp = Test-PortListening $serverPort
if ($serverUp) {
    Add-Finding -Severity ok -Category '运行' -Title ("服务端端口 {0} 在监听" -f $serverPort)
} else {
    Add-Finding -Severity warn -Category '运行' -Title ("服务端端口 {0} 未监听" -f $serverPort) `
        -Impact '玩家无法连接（若本应开服）' -Action '面板点「启动服务端」或检查崩溃日志'
}

if (($props['enable-rcon'] -as [string]) -eq 'true') {
    $rconListen = Test-PortListening $rconPort
    if ($rconListen) {
        $probe = Invoke-OptionalRcon 'list'
        if ($probe.Ok) {
            Add-Finding -Severity ok -Category '运行' -Title 'RCON 可连接' `
                -Detail (Protect-SecretText ($probe.Output.Substring(0, [Math]::Min(120, $probe.Output.Length))))
        } else {
            Add-Finding -Severity warn -Category '运行' -Title 'RCON 端口在听但命令失败' `
                -Detail (Protect-SecretText $probe.Output) `
                -Impact '远程运维命令可能失败' -Action '核对 rcon.password 是否与运行中进程一致（改密需重启）'
        }
    } elseif ($serverUp) {
        Add-Finding -Severity warn -Category '运行' -Title ("RCON 端口 {0} 未监听" -f $rconPort) `
            -Impact '尽管 enable-rcon=true，当前进程未开 RCON' -Action '确认已重启服务端使配置生效'
    } else {
        Add-Finding -Severity info -Category '运行' -Title '服务端未运行，跳过 RCON 实测'
    }
}

$opsPids = @{
    '日志监控'   = Get-PidFileAlive 'tmp\discord-watch.pid'
    'QQ控制台'  = Get-PidFileAlive 'tmp\qq-console.pid'
    '备份调度'   = Get-PidFileAlive 'tmp\backup-scheduler.pid'
    '性能采样'   = Get-PidFileAlive 'tmp\perf-sampler.pid'
}
foreach ($kv in $opsPids.GetEnumerator()) {
    if ($kv.Value -gt 0) {
        Add-Finding -Severity ok -Category '运维' -Title ("{0} 运行中" -f $kv.Key) -Detail ("PID {0}" -f $kv.Value)
    } else {
        Add-Finding -Severity warn -Category '运维' -Title ("{0} 未运行" -f $kv.Key) `
            -Impact '对应通知/调度/采样能力不可用' -Action '面板「启动所有运维」或「重启运维监控」'
    }
}

# 更新服务
$updPort = 0
if (Test-Path -LiteralPath $packPath) {
    try {
        $packObj = Get-Content -LiteralPath $packPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($packObj.update -and $packObj.update.port) { $updPort = [int]$packObj.update.port }
    } catch { }
}
if ($updPort -gt 0) {
    if (Test-PortListening $updPort) {
        Add-Finding -Severity ok -Category '运维' -Title ("更新服务端口 {0} 在监听" -f $updPort)
    } else {
        Add-Finding -Severity warn -Category '运维' -Title ("更新服务端口 {0} 未监听" -f $updPort) `
            -Impact '玩家增量同步/预下载不可用' -Action '面板「开启更新服务」'
    }
}

# BlueMap
$bmUrl = 'http://127.0.0.1:8100'
if (Test-Path -LiteralPath $opsPath) {
    try {
        $opsObj = Get-Content -LiteralPath $opsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($opsObj.ai -and $opsObj.ai.bluemap -and $opsObj.ai.bluemap.webUrl) {
            $bmUrl = [string]$opsObj.ai.bluemap.webUrl
        }
    } catch { }
}
try {
    $uri = [Uri]$bmUrl
    $bmPort = $uri.Port
    if ($bmPort -le 0) { $bmPort = if ($uri.Scheme -eq 'https') { 443 } else { 80 } }
    if (Test-PortListening $bmPort) {
        Add-Finding -Severity ok -Category '运维' -Title ("BlueMap 端口 {0} 在监听" -f $bmPort) -Detail $bmUrl
    } else {
        Add-Finding -Severity info -Category '运维' -Title ("BlueMap 端口 {0} 未监听" -f $bmPort) `
            -Detail $bmUrl -Impact '地图网页/截图不可用（若未启用可忽略）' -Action '确认 bluemap 模组已加载且 webserver 开启'
    }
} catch {
    Add-Finding -Severity info -Category '运维' -Title 'BlueMap URL 无法解析' -Detail $bmUrl
}

# 5) 世界与磁盘
Write-CheckHost '[5/8] 世界与磁盘…' 'White'
$worldName = 'world'
if ($props.ContainsKey('level-name') -and -not [string]::IsNullOrWhiteSpace([string]$props['level-name'])) {
    $worldName = [string]$props['level-name']
}
$worldDir = Join-Path $Root $worldName
$levelDat = Join-Path $worldDir 'level.dat'
if (Test-Path -LiteralPath $levelDat) {
    Add-Finding -Severity ok -Category '世界' -Title 'level.dat 存在' -Detail $worldName
} else {
    Add-Finding -Severity error -Category '世界' -Title '缺少 level.dat' `
        -Detail $levelDat -Impact '世界不可用或路径错误' -Action '核对 level-name 与 world 目录'
}

$lockPath = Join-Path $worldDir 'session.lock'
if (Test-Path -LiteralPath $lockPath) {
    # 粗探：若服务端未运行却仍有锁文件，可能是残留（MC 的 session.lock 在 Windows 上是空文件+独占句柄）
    if (-not $serverUp) {
        try {
            $fs = [System.IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None')
            $fs.Close()
            Add-Finding -Severity ok -Category '世界' -Title 'session.lock 未被占用' `
                -Detail '服务端未运行，锁可打开'
        } catch {
            Add-Finding -Severity error -Category '世界' -Title 'session.lock 仍被占用' `
                -Detail $_.Exception.Message `
                -Impact '启动会因抢锁失败而崩溃循环' `
                -Action '结束残留 java.exe 后再启动；勿强删锁后双开'
        }
    } else {
        Add-Finding -Severity ok -Category '世界' -Title '服务端运行中（世界锁正常占用）'
    }
} else {
    Add-Finding -Severity info -Category '世界' -Title '尚无 session.lock' -Detail '世界可能尚未被服务端打开过'
}

try {
    $drive = (Get-Item -LiteralPath $Root).PSDrive
    if (-not $drive) {
        $rootPath = [System.IO.Path]::GetPathRoot($Root)
        $driveInfo = New-Object System.IO.DriveInfo($rootPath)
        $free = [double]$driveInfo.AvailableFreeSpace
        $total = [double]$driveInfo.TotalSize
    } else {
        $free = [double]$drive.Free
        $total = [double]($drive.Used + $drive.Free)
    }
    $pct = if ($total -gt 0) { [math]::Round(100.0 * $free / $total, 1) } else { 0 }
    $detail = ("剩余 {0} / 共 {1}（{2}% 空闲）" -f (Format-Bytes $free), (Format-Bytes $total), $pct)
    if ($free -lt 5GB) {
        Add-Finding -Severity error -Category '磁盘' -Title '磁盘剩余不足 5 GiB' `
            -Detail $detail -Impact '备份/崩溃转储/日志可能写失败' -Action '清理旧备份、日志、hprof'
    } elseif ($free -lt 15GB) {
        Add-Finding -Severity warn -Category '磁盘' -Title '磁盘剩余偏低' `
            -Detail $detail -Impact '大世界备份可能失败' -Action '检查 backups 分层保留策略'
    } else {
        Add-Finding -Severity ok -Category '磁盘' -Title '磁盘空间充足' -Detail $detail
    }
} catch {
    Add-Finding -Severity warn -Category '磁盘' -Title '无法读取磁盘空间' -Detail $_.Exception.Message
}

# 6) 备份
Write-CheckHost '[6/8] 备份可读性…' 'White'
$zips = Get-BackupZips
if ($zips.Count -eq 0) {
    Add-Finding -Severity warn -Category '备份' -Title '未找到世界备份 zip' `
        -Detail 'backups\world' -Impact '无法回档' -Action '启动备份调度或手动「立即备份」'
} else {
    $latest = $zips[0]
    $ageH = [math]::Round(((Get-Date) - $latest.LastWriteTime).TotalHours, 1)
    $ageSev = 'ok'
    if ($ageH -gt 48) { $ageSev = 'error' }
    elseif ($ageH -gt 12) { $ageSev = 'warn' }
    Add-Finding -Severity $ageSev -Category '备份' -Title ("最近备份 {0} 小时前" -f $ageH) `
        -Detail ("{0} · {1}" -f $latest.Name, (Format-Bytes $latest.Length)) `
        -Impact $(if ($ageSev -ne 'ok') { '备份过旧，故障时 RPO 变差' } else { '' }) `
        -Action $(if ($ageSev -ne 'ok') { '检查备份调度是否在跑；必要时手动备份' } else { '' })

    $checkCount = [Math]::Min(3, $zips.Count)
    $badZip = 0
    $noLevel = 0
    for ($i = 0; $i -lt $checkCount; $i++) {
        $r = Test-BackupZipReadable $zips[$i].FullName
        if (-not $r.Ok) { $badZip++ }
        elseif (-not $r.HasLevelDat) { $noLevel++ }
    }
    if ($badZip -gt 0) {
        Add-Finding -Severity error -Category '备份' -Title ("最近 {0} 份中有 {1} 份无法打开" -f $checkCount, $badZip) `
            -Impact '损坏的备份无法恢复' -Action '立即做一次新备份并检查磁盘'
    } elseif ($noLevel -gt 0) {
        Add-Finding -Severity warn -Category '备份' -Title ("最近备份可能缺 level.dat（{0}/{1}）" -f $noLevel, $checkCount) `
            -Impact '恢复后世界可能不完整' -Action '打开 zip 核对内容；必要时重新备份'
    } else {
        Add-Finding -Severity ok -Category '备份' -Title ("最近 {0} 份备份可读且含 level.dat" -f $checkCount) `
            -Detail ("共 {0} 份历史备份" -f $zips.Count)
    }
}

# 7) 日志指纹与崩溃
Write-CheckHost '[7/8] 日志错误指纹…' 'White'
$logPath = Join-Path $Root 'logs\latest.log'
$errorMap = @{}
$warnMap = @{}
$keepUp = 0
$oom = 0
$mixinHard = 0
$mixinSoft = 0
if (Test-Path -LiteralPath $logPath) {
    $lines = Read-TextSmart $logPath $LogTailLines
    foreach ($line in $lines) {
        $trim = $line.TrimStart()
        # 栈帧 / Caused by 不算独立事故，否则 DataResult 一条 ERROR 会变成几十条指纹
        if ($trim -match '^(at |More \d+ |\.\.\. \d+ more|Caused by:|Suppressed:)') { continue }
        if ($line -match 'Can''t keep up' -or $line -match 'is too far behind') { $keepUp++ }
        if ($line -match 'OutOfMemoryError|Java heap space') { $oom++ }
        # soft：可选依赖探测 ClassNotFound（Alex's Mobs / Controllable 等未装时的正常 mixin 嗅探）
        if ($line -match '\[mixin/\].*ClassNotFoundException|Error loading class:.*ClassNotFoundException') {
            $mixinSoft++
            continue
        }
        if ($line -match 'MixinApplyError|MixinTransformerError|@Mixin.*failed|critical mixin') {
            $mixinHard++
        }
        $isErr = $line -match '\]\s*\[ERROR\]|\bERROR\b.+:|/ERROR\]|/FATAL\]|\]\s*\[FATAL\]'
        # 必须像日志头，排除纯异常类名行
        if ($isErr -and $line -notmatch '^\s+at ') {
            $fp = Get-LogFingerprint $line
            if ([string]::IsNullOrWhiteSpace($fp) -or $fp -match '^at ') { continue }
            if (-not $errorMap.ContainsKey($fp)) { $errorMap[$fp] = 0 }
            $errorMap[$fp]++
        } elseif ($line -match '\]\s*\[WARN\]|/WARN\]') {
            $fp = Get-LogFingerprint $line
            if ([string]::IsNullOrWhiteSpace($fp)) { continue }
            if (-not $warnMap.ContainsKey($fp)) { $warnMap[$fp] = 0 }
            $warnMap[$fp]++
        }
    }
    $errTotal = ($errorMap.Values | Measure-Object -Sum).Sum
    if (-not $errTotal) { $errTotal = 0 }
    $warnTotal = ($warnMap.Values | Measure-Object -Sum).Sum
    if (-not $warnTotal) { $warnTotal = 0 }
    $topErr = @($errorMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)
    $topWarn = @($warnMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3)

    if ($errTotal -eq 0) {
        Add-Finding -Severity ok -Category '日志' -Title '近期日志无有效 ERROR 头' `
            -Detail ("扫描约 {0} 行（已忽略栈帧）；WARN {1} 条 / {2} 类" -f $lines.Count, $warnTotal, $warnMap.Count)
    } else {
        # 按「独立 ERROR 头」计分，不再被栈帧放大。
        # 大量「各 1 次」的缺物品配方/标签噪音更适合黄灯；红灯留给高频重复事故。
        $topCount = if ($topErr.Count -ge 1) { [int]$topErr[0].Value } else { 0 }
        $sev = if ($topCount -ge 10 -or $errTotal -ge 80) { 'error' }
            elseif ($errTotal -ge 1) { 'warn' }
            else { 'ok' }
        $detail = ("ERROR 头 {0} 条 / {1} 类；WARN {2} 条 / {3} 类" -f $errTotal, $errorMap.Count, $warnTotal, $warnMap.Count)
        if ($topErr.Count -gt 0) {
            $detail += ' | Top: ' + (($topErr | ForEach-Object { '{0}× {1}' -f $_.Value, $_.Key }) -join ' || ')
        }
        Add-Finding -Severity $sev -Category '日志' -Title '日志错误指纹聚类' `
            -Detail $detail `
            -Impact '重复错误往往指向同一根因，未处理会持续恶化' `
            -Action '优先处理 Top 指纹对应模组/配置；需要时生成诊断包交给 AI'
    }

    if ($keepUp -gt 0) {
        $sev = if ($keepUp -ge 10) { 'error' } else { 'warn' }
        Add-Finding -Severity $sev -Category '性能' -Title ("Can't keep up × {0}" -f $keepUp) `
            -Detail '主线程刻延迟告警' `
            -Impact '卡顿、回档感、玩家掉线风险' `
            -Action '查性能黑匣子/Spark；减少区块加载与实体；核对最近更新'
    } else {
        Add-Finding -Severity ok -Category '性能' -Title '近期无 Can''t keep up'
    }
    if ($oom -gt 0) {
        Add-Finding -Severity error -Category '性能' -Title ("检测到堆内存不足迹象 × {0}" -f $oom) `
            -Impact '可能崩溃或严重 GC 停顿' -Action '核对 Xmx、查 hprof、限制高速探索生成'
    }
    if ($mixinHard -gt 0) {
        Add-Finding -Severity warn -Category '日志' -Title ("Mixin 硬失败 × {0}" -f $mixinHard) `
            -Impact '模组冲突可能导致功能缺失' -Action '对照崩溃报告与模组版本'
    } elseif ($mixinSoft -gt 0) {
        Add-Finding -Severity info -Category '日志' -Title ("Mixin 可选依赖探测 × {0}" -f $mixinSoft) `
            -Detail 'ClassNotFoundException：对应模组未安装时的 soft mixin，一般可忽略' `
            -Action '无需处理；若要用该功能再装对应模组'
    }
} else {
    Add-Finding -Severity warn -Category '日志' -Title '没有 logs/latest.log' `
        -Action '先启动一次服务端再体检'
}

$crashDir = Join-Path $Root 'crash-reports'
if (Test-Path -LiteralPath $crashDir -PathType Container) {
    $crashes = @(Get-ChildItem -LiteralPath $crashDir -File -Filter 'crash-*.txt' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
    if ($crashes.Count -eq 0) {
        Add-Finding -Severity ok -Category '崩溃' -Title '无 crash-*.txt 报告'
    } else {
        $latestCrash = $crashes[0]
        $ageD = [math]::Round(((Get-Date) - $latestCrash.LastWriteTime).TotalDays, 1)
        $head = (Read-TextSmart $latestCrash.FullName 80) -join "`n"
        $kind = '未知类型'
        if ($head -match 'OutOfMemoryError|Java heap space') { $kind = '堆内存不足 OOM' }
        elseif ($head -match 'Watchdog|A single server tick') { $kind = 'Watchdog 卡死' }
        elseif ($head -match 'Mixin|mixin') { $kind = 'Mixin/模组冲突' }
        elseif ($head -match 'AccessControlException|dll|UnsatisfiedLinkError') { $kind = '原生库/权限' }
        elseif ($head -match 'ModLoading|Missing.*dependenc') { $kind = '模组依赖/加载失败' }
        elseif ($head -match 'JsonSyntaxException|Gson|Toml|Config') { $kind = '配置格式错误' }
        $sev = if ($ageD -le 2) { 'warn' } else { 'info' }
        if ($ageD -le 0.5) { $sev = 'error' }
        Add-Finding -Severity $sev -Category '崩溃' -Title ("最近崩溃：{0}" -f $kind) `
            -Detail ("{0} · {1} 天前 · 历史共 {2} 份" -f $latestCrash.Name, $ageD, $crashes.Count) `
            -Impact $(if ($sev -eq 'error') { '近期刚崩，需优先复盘' } else { '' }) `
            -Action '打开该报告或 !问 AI 分析；生成诊断包便于对照'
    }
} else {
    Add-Finding -Severity info -Category '崩溃' -Title '无 crash-reports 目录'
}

# 8) 实时性能快照（若 RCON 可用）
Write-CheckHost '[8/8] 实时性能快照…' 'White'
if ($serverUp -and ($props['enable-rcon'] -as [string]) -eq 'true' -and (Test-PortListening $rconPort)) {
    $tpsCmd = 'tps'
    if ($loader -and $loader.Loader -eq 'neoforge') { $tpsCmd = 'neoforge tps' }
    elseif ($loader -and $loader.Loader -eq 'forge') { $tpsCmd = 'forge tps' }
    $tps = Invoke-OptionalRcon $tpsCmd
    if ($tps.Ok) {
        $t = $tps.Output
        $mspt = $null
        $tpsVal = $null
        if ($t -match '([\d.]+)\s*TPS\s*\(([\d.]+)\s*ms/tick\)') {
            $tpsVal = [double]$matches[1]; $mspt = [double]$matches[2]
        } elseif ($t -match 'Mean tick time:\s*([\d.]+)\s*ms.*?Mean TPS:\s*([\d.]+)') {
            $mspt = [double]$matches[1]; $tpsVal = [double]$matches[2]
        }
        if ($null -ne $mspt) {
            $sev = 'ok'
            if ($mspt -ge 50 -or ($null -ne $tpsVal -and $tpsVal -lt 15)) { $sev = 'error' }
            elseif ($mspt -ge 40 -or ($null -ne $tpsVal -and $tpsVal -lt 18)) { $sev = 'warn' }
            Add-Finding -Severity $sev -Category '性能' -Title ("实时 TPS/MSPT") `
                -Detail ("TPS={0} MSPT={1}" -f $(if ($null -ne $tpsVal) { $tpsVal } else { '?' }), $mspt) `
                -Impact $(if ($sev -ne 'ok') { '当前存在卡顿' } else { '' }) `
                -Action $(if ($sev -ne 'ok') { '结合性能黑匣子与在线玩家活动定位' } else { '' })
        } else {
            Add-Finding -Severity info -Category '性能' -Title 'TPS 已查询' -Detail (Protect-SecretText ($t.Substring(0, [Math]::Min(200, $t.Length))))
        }
    } else {
        Add-Finding -Severity info -Category '性能' -Title '无法查询 TPS' -Detail (Protect-SecretText $tps.Output)
    }
} else {
    Add-Finding -Severity info -Category '性能' -Title '跳过实时 TPS（服务端或 RCON 不可用）'
}

# 性能黑匣子样本是否存在
$perfDir = Join-Path $Root 'logs\perf'
$sampleFile = Join-Path $perfDir 'samples.jsonl'
if (Test-Path -LiteralPath $sampleFile) {
    $sampleCount = 0
    try {
        $sampleCount = @(Get-Content -LiteralPath $sampleFile -ErrorAction SilentlyContinue).Count
    } catch { }
    $age = ((Get-Date) - (Get-Item -LiteralPath $sampleFile).LastWriteTime).TotalMinutes
    if ($age -gt 30) {
        Add-Finding -Severity warn -Category '性能' -Title '性能黑匣子样本过旧' `
            -Detail ("{0} 条 · 最后写入 {1:N0} 分钟前" -f $sampleCount, $age) `
            -Action '确认 perf-sampler 在跑（重启运维监控）'
    } else {
        Add-Finding -Severity ok -Category '性能' -Title '性能黑匣子有近期样本' `
            -Detail ("{0} 条 · {1:N0} 分钟前更新" -f $sampleCount, $age)
    }
} else {
    Add-Finding -Severity info -Category '性能' -Title '尚无性能黑匣子数据' `
        -Detail 'logs/perf/samples.jsonl 不存在' `
        -Action '启动运维后由 perf-sampler 自动采集；也可用 !性能 看实时 TPS'
}

# ---------------- 汇总评分 ----------------
$errN = @($Findings | Where-Object { $_.Severity -eq 'error' }).Count
$warnN = @($Findings | Where-Object { $_.Severity -eq 'warn' }).Count
$okN = @($Findings | Where-Object { $_.Severity -eq 'ok' }).Count
$Meta.errorCount = $errN
$Meta.warnCount = $warnN
$Meta.okCount = $okN
# 100 起评：error -15，warn -5，下限 0
$score = 100 - (15 * $errN) - (5 * $warnN)
if ($score -lt 0) { $score = 0 }
$Meta.score = $score
if ($errN -gt 0 -or $score -lt 60) { $Meta.overall = 'red' }
elseif ($warnN -gt 0 -or $score -lt 85) { $Meta.overall = 'yellow' }
else { $Meta.overall = 'green' }
$Meta.finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$levelLabel = @{ green = '🟢 健康'; yellow = '🟡 需关注'; red = '🔴 高风险' }[$Meta.overall]

function Format-ReportText {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('========================================')
    [void]$sb.AppendLine(' 服务端健康体检报告')
    [void]$sb.AppendLine('========================================')
    [void]$sb.AppendLine(("时间：{0}" -f $Meta.startedAt))
    if ($Meta.kitVersion) { [void]$sb.AppendLine(("工具包：{0}" -f $Meta.kitVersion)) }
    [void]$sb.AppendLine(("总评：{0}  评分 {1}/100  （红{2} 黄{3} 绿{4}）" -f $levelLabel, $Meta.score, $errN, $warnN, $okN))
    [void]$sb.AppendLine('')

    $order = @('error', 'warn', 'info', 'ok')
    foreach ($sev in $order) {
        $items = @($Findings | Where-Object { $_.Severity -eq $sev })
        if ($items.Count -eq 0) { continue }
        $tag = switch ($sev) {
            'error' { '【红】' }
            'warn' { '【黄】' }
            'info' { '【信息】' }
            default { '【绿】' }
        }
        [void]$sb.AppendLine(("---- {0} {1} 条 ----" -f $tag, $items.Count))
        foreach ($it in $items) {
            [void]$sb.AppendLine(("· [{0}] {1}" -f $it.Category, $it.Title))
            if ($it.Detail) { [void]$sb.AppendLine(("  详情：{0}" -f $it.Detail)) }
            if ($it.Impact) { [void]$sb.AppendLine(("  影响：{0}" -f $it.Impact)) }
            if ($it.Action) { [void]$sb.AppendLine(("  建议：{0}" -f $it.Action)) }
        }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('提示：加 -Pack 可生成脱敏诊断包（tmp\health-check\…\diagnostic-pack.zip）')
    return $sb.ToString()
}

function Format-QqSummary {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(("[体检] {0}  评分 {1}/100" -f $levelLabel, $Meta.score))
    [void]$sb.AppendLine(("红 {0} · 黄 {1} · 绿 {2}" -f $errN, $warnN, $okN))
    $focus = @($Findings | Where-Object { $_.Severity -in @('error', 'warn') } | Select-Object -First 8)
    if ($focus.Count -eq 0) {
        [void]$sb.AppendLine('未发现需要处理的问题。')
    } else {
        [void]$sb.AppendLine('优先处理：')
        $i = 1
        foreach ($it in $focus) {
            $mark = if ($it.Severity -eq 'error') { '🔴' } else { '🟡' }
            $line = '{0}{1}. [{2}] {3}' -f $mark, $i, $it.Category, $it.Title
            [void]$sb.AppendLine($line)
            if ($it.Action) {
                [void]$sb.AppendLine(('   → {0}' -f $it.Action))
            }
            $i++
        }
    }
    if ($Pack) {
        [void]$sb.AppendLine('已请求生成脱敏诊断包，见 tmp\health-check\')
    } else {
        [void]$sb.AppendLine('需要完整证据时：面板「健康体检」或脚本加 -Pack')
    }
    return $sb.ToString().TrimEnd()
}

$reportText = Format-ReportText
$qqText = Format-QqSummary

# 落盘
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$reportPath = Join-Path $ReportDir 'health-report.txt'
$qqPath = Join-Path $ReportDir 'health-qq.txt'
$jsonPath = Join-Path $ReportDir 'health-report.json'
[System.IO.File]::WriteAllText($reportPath, $reportText, (New-Object System.Text.UTF8Encoding $true))
[System.IO.File]::WriteAllText($qqPath, $qqText, (New-Object System.Text.UTF8Encoding $true))

$jsonObj = [ordered]@{
    meta     = $Meta
    findings = $Findings
}
$jsonRaw = ($jsonObj | ConvertTo-Json -Depth 6)
[System.IO.File]::WriteAllText($jsonPath, $jsonRaw, (New-Object System.Text.UTF8Encoding $false))

# 诊断包
$packZip = $null
if ($Pack) {
    Write-CheckHost '正在打包脱敏诊断包…' 'Cyan'
    $packRoot = Join-Path $ReportDir 'diagnostic-src'
    New-Item -ItemType Directory -Path $packRoot -Force | Out-Null
    Copy-Item -LiteralPath $reportPath -Destination (Join-Path $packRoot 'health-report.txt') -Force
    Copy-Item -LiteralPath $jsonPath -Destination (Join-Path $packRoot 'health-report.json') -Force
    Copy-Item -LiteralPath $qqPath -Destination (Join-Path $packRoot 'health-qq.txt') -Force

    # 脱敏配置与日志
    Write-RedactedCopy (Join-Path $Root 'server.properties') (Join-Path $packRoot 'server.properties')
    Write-RedactedCopy (Join-Path $ToolsDir 'ops-config.json') (Join-Path $packRoot 'ops-config.redacted.json')
    Write-RedactedCopy (Join-Path $ToolsDir 'portable-pack.json') (Join-Path $packRoot 'portable-pack.redacted.json')
    Write-RedactedCopy (Join-Path $Root 'user_jvm_args.txt') (Join-Path $packRoot 'user_jvm_args.txt')
    Write-RedactedCopy (Join-Path $Root 'KIT-VERSION.txt') (Join-Path $packRoot 'KIT-VERSION.txt')

    if (Test-Path -LiteralPath $logPath) {
        $tail = Read-TextSmart $logPath 3000
        $safeLog = Protect-SecretText ($tail -join "`r`n")
        [System.IO.File]::WriteAllText((Join-Path $packRoot 'latest.log.tail.txt'), $safeLog, (New-Object System.Text.UTF8Encoding $false))
    }

    $crashDir2 = Join-Path $Root 'crash-reports'
    if (Test-Path -LiteralPath $crashDir2) {
        $recentCrashes = @(Get-ChildItem -LiteralPath $crashDir2 -File -Filter 'crash-*.txt' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 3)
        $cdir = Join-Path $packRoot 'crash-reports'
        New-Item -ItemType Directory -Path $cdir -Force | Out-Null
        foreach ($c in $recentCrashes) {
            Write-RedactedCopy $c.FullName (Join-Path $cdir $c.Name)
        }
    }

    # 模组列表（仅文件名）
    $modsListPath = Join-Path $packRoot 'mods-list.txt'
    if (Test-Path -LiteralPath $modsDir) {
        $names = @(Get-ChildItem -LiteralPath $modsDir -File -ErrorAction SilentlyContinue |
                Sort-Object Name | ForEach-Object { $_.Name })
        [System.IO.File]::WriteAllLines($modsListPath, $names, (New-Object System.Text.UTF8Encoding $false))
    }

    # 指纹 Top
    $fpPath = Join-Path $packRoot 'error-fingerprints.txt'
    $fpLines = @('=== ERROR fingerprints ===')
    foreach ($e in ($errorMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 30)) {
        $fpLines += ('{0,5}  {1}' -f $e.Value, $e.Key)
    }
    $fpLines += '=== WARN fingerprints ==='
    foreach ($e in ($warnMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20)) {
        $fpLines += ('{0,5}  {1}' -f $e.Value, $e.Key)
    }
    [System.IO.File]::WriteAllLines($fpPath, $fpLines, (New-Object System.Text.UTF8Encoding $false))

    $readme = @"
脱敏诊断包
生成时间：$($Meta.startedAt)
总评：$levelLabel  评分 $($Meta.score)/100

已过滤：密钥/Token/RCON 密码、玩家 IP、本机用户目录名。
未包含：世界存档、完整备份 zip、hprof 堆转储、未脱敏原始 ops-config。

请将本 zip 发给管理员或 AI 助手做进一步分析。
"@
    [System.IO.File]::WriteAllText((Join-Path $packRoot 'README.txt'), $readme, (New-Object System.Text.UTF8Encoding $true))

    $packZip = Join-Path $ReportDir 'diagnostic-pack.zip'
    if (Test-Path -LiteralPath $packZip) { Remove-Item -LiteralPath $packZip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($packRoot, $packZip, 'Optimal', $false)
    Write-CheckHost ("诊断包：{0}" -f $packZip) 'Green'
}

# 控制台输出
if ($QqSummary) {
    Write-Output $qqText
} else {
    if (-not $Quiet) {
        Write-Host ''
        Write-Host $reportText
        Write-Host ("报告目录：{0}" -f $ReportDir) -ForegroundColor Cyan
        if ($packZip) { Write-Host ("诊断包：{0}" -f $packZip) -ForegroundColor Green }
    } else {
        Write-Output $reportText
    }
}

# 退出码：红=2，黄=1，绿=0（便于脚本/监控）
if ($Meta.overall -eq 'red') { exit 2 }
if ($Meta.overall -eq 'yellow') { exit 1 }
exit 0
