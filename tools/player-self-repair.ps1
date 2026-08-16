param(
    [string]$InstanceDir = '.',
    [string]$ManifestUrl = '',
    [switch]$Fix,
    [switch]$Deep,
    [switch]$QqSummary,
    [switch]$Quiet,
    [switch]$NoPause
)

# 玩家客户端自助修复：对照清单检查 Java / 更新源 / 模组哈希，可选自动修补。
# 在玩家实例目录运行；可 -Fix 只重下异常文件。中文输出 + 诊断编号。

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

function Normalize-Rel([string]$Rel) { return ([string]$Rel).Replace('\', '/').TrimStart('/') }
function Normalize-RelKey([string]$Rel) { return (Normalize-Rel $Rel).ToLowerInvariant() }
function Get-Sha1([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant()
}
function Test-RelativePathSafe([string]$Rel) {
    $n = Normalize-Rel $Rel
    if ([string]::IsNullOrWhiteSpace($n)) { return $false }
    if ($n.StartsWith('/') -or $n -match '^[A-Za-z]:') { return $false }
    foreach ($p in $n.Split('/')) { if ($p -eq '..') { return $false } }
    return $true
}
function Join-Safe([string]$Root, [string]$Rel) {
    if (-not (Test-RelativePathSafe $Rel)) { throw "不安全路径: $Rel" }
    return Join-Path $Root ((Normalize-Rel $Rel).Replace('/', [IO.Path]::DirectorySeparatorChar))
}
function New-DirectHttpRequest([string]$Url, [int]$TimeoutSec = 30, [switch]$AllowProxy) {
    # 家宽和官方源都直连。系统代理下 Timeout 经常不生效，会卡数分钟。
    $request = [System.Net.HttpWebRequest]::Create($Url)
    if (-not $AllowProxy) { $request.Proxy = $null }
    $request.Timeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.ReadWriteTimeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $request.KeepAlive = $false
    try { $request.ServicePoint.Expect100Continue = $false } catch {}
    $request.UserAgent = 'portable-server-kit-repair/1.0'
    return $request
}
function Test-OfficialHttpsUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try { $uri = [Uri]$Url } catch { return $false }
    if (-not $uri.IsAbsoluteUri) { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    $h = [string]$uri.Host
    if ([string]::IsNullOrWhiteSpace($h)) { return $false }
    if ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -eq '::1') { return $false }
    return $true
}
function Get-OfficialFileUrls($File) {
    $out = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($File -and $File.PSObject.Properties['url'] -and -not [string]::IsNullOrWhiteSpace([string]$File.url)) {
        [void]$candidates.Add(([string]$File.url).Trim())
    }
    if ($File -and $File.PSObject.Properties['downloads']) {
        foreach ($u in @($File.downloads)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$u)) { [void]$candidates.Add(([string]$u).Trim()) }
        }
    }
    foreach ($u in $candidates) {
        if ((Test-OfficialHttpsUrl $u) -and $seen.Add($u)) { [void]$out.Add($u) }
    }
    return @($out)
}
function Read-UrlText([string]$Url, [int]$TimeoutSec = 30) {
    $request = New-DirectHttpRequest -Url $Url -TimeoutSec $TimeoutSec
    $response = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        return ($reader.ReadToEnd()).TrimStart([char]0xFEFF)
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
    }
}
function Save-UrlToFile([string]$Url, [string]$Path, [int]$TimeoutSec = 90, [switch]$AllowProxy) {
    $request = New-DirectHttpRequest -Url $Url -TimeoutSec $TimeoutSec -AllowProxy:$AllowProxy
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
function Download-FileChecked([string]$Url, [string]$Dest, [string]$ExpectedSha1, [switch]$AllowProxy, [int]$TimeoutSec = 90) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Dest) | Out-Null
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('repair-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Save-UrlToFile -Url $Url -Path $tmp -TimeoutSec $TimeoutSec -AllowProxy:$AllowProxy
        $actual = Get-Sha1 $tmp
        if ($actual -ne $ExpectedSha1.ToLowerInvariant()) {
            throw "SHA1 不匹配 expected=$ExpectedSha1 actual=$actual"
        }
        Move-Item -LiteralPath $tmp -Destination $Dest -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item $tmp -Force -EA SilentlyContinue }
    }
}
function Download-RepairEntry($File, [string]$FileBaseUrl, [string]$Dest, [string]$ExpectedSha1, [string]$Rel) {
    foreach ($url in @(Get-OfficialFileUrls $File)) {
        try {
            Download-FileChecked -Url $url -Dest $Dest -ExpectedSha1 $ExpectedSha1 -TimeoutSec 8
            return
        } catch {}
    }
    $parts = ($Rel -replace '\\', '/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
    Download-FileChecked -Url ($FileBaseUrl + ($parts -join '/')) -Dest $Dest -ExpectedSha1 $ExpectedSha1
}
function Strip-JsonComments([string]$Text) {
    # 去掉可能出现的 // 行注释（部分本地 manifest 带说明字段导致解析失败）
    $lines = $Text -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $t = $line
        # 不处理字符串内 // 的复杂情况；清单里注释多在键说明行
        if ($t -match '^\s*//') { continue }
        $out.Add($t) | Out-Null
    }
    return ($out -join "`n")
}
function Get-RequiredJavaMajor([string]$MinecraftVersion) {
    if ([string]::IsNullOrWhiteSpace($MinecraftVersion) -or
        $MinecraftVersion -notmatch '^(?<major>\d+)\.(?<minor>\d+)(?:\.(?<patch>\d+))?') {
        return 0
    }
    $major = [int]$matches.major
    $minor = [int]$matches.minor
    $patch = if ($matches.patch) { [int]$matches.patch } else { 0 }
    if ($major -ne 1) {
        if ($major -ge 26) { return 25 }
        return 0
    }
    if ($minor -le 16) { return 8 }
    if ($minor -le 19) { return 17 }
    if ($minor -eq 20 -and $patch -le 4) { return 17 }
    return 21
}
function Find-JavaInfo([int]$RequiredMajor = 0) {
    $info = [ordered]@{ found = $false; path = ''; version = ''; major = 0; requiredMajor = $RequiredMajor; compatible = $false }
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME 'bin\java.exe') }
    $cmd = Get-Command java -EA SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    # 启动器托管 Java 和常见 JDK 安装目录。不能找到 PATH 里的第一份就停：
    # 很多电脑 PATH 仍是另一代 Java，但 HMCL/PCL 可能已经为目标 MC 版本准备了正确运行时。
    foreach ($javaRoot in @(
        (Join-Path $env:APPDATA '.hmcl\java'),
        (Join-Path $env:APPDATA '.minecraft\runtime'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Eclipse Adoptium'),
        (Join-Path $env:ProgramFiles 'Eclipse Adoptium'),
        (Join-Path $env:ProgramFiles 'Java'),
        (Join-Path $env:ProgramFiles 'Microsoft')
    )) {
        if (Test-Path -LiteralPath $javaRoot -PathType Container) {
            Get-ChildItem -LiteralPath $javaRoot -Recurse -File -Filter 'java.exe' -EA SilentlyContinue |
                Select-Object -First 20 | ForEach-Object { $candidates += $_.FullName }
        }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $candidates) {
        if (-not $c -or -not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        $candidateFull = [IO.Path]::GetFullPath([string]$c)
        if (-not $seen.Add($candidateFull)) { continue }
        try {
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $candidateFull
            $psi.Arguments = '-version'
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $p = [Diagnostics.Process]::Start($psi)
            $err = $p.StandardError.ReadToEnd()
            $out = $p.StandardOutput.ReadToEnd()
            [void]$p.WaitForExit(5000)
            $text = $err + $out
            if ($text -match 'version "([^"]+)"') {
                $found = [ordered]@{ found = $true; path = $candidateFull; version = $matches[1]; major = 0; requiredMajor = $RequiredMajor; compatible = $false }
                if ($found.version -match '^1\.(\d+)') { $found.major = [int]$matches[1] }
                elseif ($found.version -match '^(\d+)') { $found.major = [int]$matches[1] }
                $found.compatible = ($RequiredMajor -le 0 -or $found.major -eq $RequiredMajor)
                if ($found.compatible) { return $found }
                if (-not $info.found) { $info = $found }
            }
        } catch { }
    }
    return $info
}

$instanceRoot = if ([IO.Path]::IsPathRooted($InstanceDir)) {
    [IO.Path]::GetFullPath($InstanceDir)
} else {
    [IO.Path]::GetFullPath((Join-Path (Get-Location) $InstanceDir))
}
if (-not (Test-Path -LiteralPath $instanceRoot -PathType Container)) {
    throw "实例目录不存在: $instanceRoot"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$diagId = 'RPR-' + $stamp + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6).ToUpperInvariant())
$outDir = Join-Path $instanceRoot ('_repair\' + $stamp)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$missing = New-Object System.Collections.Generic.List[object]
$mismatch = New-Object System.Collections.Generic.List[object]
$okCount = 0
$checked = 0
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$fixed = New-Object System.Collections.Generic.List[string]
$manifestUrl = $ManifestUrl
$packVersion = ''
$serverReachable = $false

# UPDATE-URL
if ([string]::IsNullOrWhiteSpace($manifestUrl)) {
    foreach ($rel in @('UPDATE-URL.txt', 'PORTABLE-UPDATE-URL.txt', 'TFCR-update-url.txt', '_updater\UPDATE-URL.txt')) {
        $p = Join-Path $instanceRoot $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $v = (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim()
            if ($v) { $manifestUrl = $v; break }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($manifestUrl)) {
    # 本地清单兜底
    $localMan = Join-Path $instanceRoot 'server-manifest.json'
    if (Test-Path $localMan) {
        $warnings.Add('未找到 UPDATE-URL.txt，改用本地 server-manifest.json（可能不是最新）') | Out-Null
        $manifestUrl = 'file:///' + ($localMan -replace '\\', '/')
    } else {
        $errors.Add('找不到 UPDATE-URL.txt 与本地清单。请确认玩家包完整，或用 -ManifestUrl 指定。') | Out-Null
    }
}

$manifest = $null
$fileBaseUrl = ''
if ($manifestUrl -and $errors.Count -eq 0) {
    try {
        if ($manifestUrl -like 'file:///*') {
            $path = $manifestUrl -replace '^file:///', '' -replace '/', [IO.Path]::DirectorySeparatorChar
            $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            $fileBaseUrl = ''
        } else {
            $raw = Read-UrlText $manifestUrl
            $slash = $manifestUrl.LastIndexOf('/')
            $fileBaseUrl = if ($slash -gt 0) { $manifestUrl.Substring(0, $slash + 1) } else { '' }
            $serverReachable = $true
        }
        $raw = Strip-JsonComments $raw
        $manifest = $raw | ConvertFrom-Json
        if ($manifest.version) { $packVersion = [string]$manifest.version }
        if ($manifest.PSObject.Properties['updateUrl'] -and $manifest.updateUrl -and -not $fileBaseUrl) {
            $u = [string]$manifest.updateUrl
            $slash = $u.LastIndexOf('/')
            if ($slash -gt 0) { $fileBaseUrl = $u.Substring(0, $slash + 1) }
        }
    } catch {
        $errors.Add('拉取/解析清单失败: ' + $_.Exception.Message) | Out-Null
    }
}

# Java：需求随清单里的 Minecraft 版本变化，不把某个私服版本写死在公版逻辑里。
$minecraftVersion = if ($manifest -and $manifest.PSObject.Properties['minecraftVersion']) { [string]$manifest.minecraftVersion } else { '' }
$requiredJavaMajor = Get-RequiredJavaMajor $minecraftVersion
$java = Find-JavaInfo $requiredJavaMajor
if (-not $java.found) {
    if ($requiredJavaMajor -gt 0) {
        $warnings.Add(("未检测到 Java。Minecraft {0} 需要 Java {1}；请优先使用启动器自动下载的 Java。" -f $minecraftVersion, $requiredJavaMajor)) | Out-Null
    } else {
        $warnings.Add('未检测到 Java，且清单未提供可识别的 Minecraft 版本，无法自动判断所需主版本。') | Out-Null
    }
} elseif (-not $java.compatible) {
    $warnings.Add(("Java 版本不匹配：{0}（Minecraft {1} 需要 Java {2}）" -f $java.version, $minecraftVersion, $requiredJavaMajor)) | Out-Null
}

# 对照清单（默认只查 mods/** 与 _updater/**；Deep 查全部非保留类）
if ($manifest -and $manifest.files) {
    $files = @($manifest.files)
    foreach ($f in $files) {
        if (-not $f.path -or -not $f.sha1) { continue }
        $rel = [string]$f.path
        $key = Normalize-Rel $rel
        $isMod = $key -like 'mods/*'
        $isUpdater = $key -like '_updater/*'
        if (-not $Deep -and -not $isMod -and -not $isUpdater) { continue }
        # 跳过玩家个人向
        if ($key -match '^(options\.txt|servers\.dat|saves/|screenshots/)') { continue }

        $checked++
        $full = Join-Safe $instanceRoot $rel
        $expected = ([string]$f.sha1).ToLowerInvariant()
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $missing.Add([pscustomobject]@{ path = $rel; sha1 = $expected; size = $f.size }) | Out-Null
            continue
        }
        $actual = Get-Sha1 $full
        if ($actual -ne $expected) {
            $mismatch.Add([pscustomobject]@{ path = $rel; expected = $expected; actual = $actual }) | Out-Null
        } else {
            $okCount++
        }
    }
}

# 本地 mods 多余（相对清单）
$extraMods = @()
$modsDir = Join-Path $instanceRoot 'mods'
if ((Test-Path $modsDir) -and $manifest -and $manifest.files) {
    $manifestMods = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($manifest.files)) {
        $r = Normalize-Rel ([string]$f.path)
        if ($r -like 'mods/*') { [void]$manifestMods.Add($r) }
    }
    Get-ChildItem $modsDir -File -Filter '*.jar' -EA SilentlyContinue | ForEach-Object {
        $rel = 'mods/' + $_.Name
        # 允许中文名前缀 jar：用相对路径
        $rel2 = Normalize-Rel (('mods/' + $_.Name))
        $found = $false
        foreach ($m in $manifestMods) {
            if ([IO.Path]::GetFileName($m) -eq $_.Name) { $found = $true; break }
        }
        if (-not $found) { $extraMods += $_.Name }
    }
}

# Fix
if ($Fix -and $fileBaseUrl -and ($missing.Count -gt 0 -or $mismatch.Count -gt 0)) {
    $fileByPath = @{}
    if ($manifest -and $manifest.files) {
        foreach ($f in @($manifest.files)) {
            if ($f.path) { $fileByPath[(Normalize-Rel ([string]$f.path))] = $f }
        }
    }
    $toFix = @()
    foreach ($m in $missing) { $toFix += [pscustomobject]@{ path = $m.path; sha1 = $m.sha1 } }
    foreach ($m in $mismatch) { $toFix += [pscustomobject]@{ path = $m.path; sha1 = $m.expected } }
    foreach ($item in $toFix) {
        try {
            $rel = [string]$item.path
            $dest = Join-Safe $instanceRoot $rel
            if (Test-Path $dest) {
                $bak = Join-Path $outDir ('backup\' + ($rel -replace '/', '_'))
                New-Item -ItemType Directory -Force (Split-Path $bak) | Out-Null
                Copy-Item $dest $bak -Force
            }
            $src = $fileByPath[(Normalize-Rel $rel)]
            Download-RepairEntry -File $src -FileBaseUrl $fileBaseUrl -Dest $dest -ExpectedSha1 $item.sha1 -Rel $rel
            $fixed.Add($rel) | Out-Null
        } catch {
            $errors.Add(("修补失败 {0}: {1}" -f $item.path, $_.Exception.Message)) | Out-Null
        }
    }
}

# 评分
$issueN = $missing.Count + $mismatch.Count + $errors.Count
$level = '绿'
if ($issueN -gt 0 -or $warnings.Count -gt 0) { $level = '黄' }
if ($missing.Count -gt 5 -or $mismatch.Count -gt 5 -or $errors.Count -gt 0) { $level = '红' }
if (-not $serverReachable -and $manifestUrl -notlike 'file:*') { if ($level -eq '绿') { $level = '黄' } }

$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('【客户端自助修复】')
[void]$sb.AppendLine(('诊断编号：{0}' -f $diagId))
[void]$sb.AppendLine(('实例：{0}' -f $instanceRoot))
if ($packVersion) { [void]$sb.AppendLine(('清单版本：{0}' -f $packVersion)) }
[void]$sb.AppendLine(('更新源：{0}' -f $(if ($serverReachable) { '可达' } elseif ($manifestUrl -like 'file:*') { '本地清单' } else { '不可达/未知' })))
if ($java.found) {
    $javaStatus = if ($requiredJavaMajor -le 0) { '清单版本未知，未判定' } elseif ($java.compatible) { 'OK' } else { "需 Java $requiredJavaMajor" }
    [void]$sb.AppendLine(('Java：{0}（主版本 {1}）{2}' -f $java.version, $java.major, $javaStatus))
} else {
    [void]$sb.AppendLine('Java：未检测到')
}
[void]$sb.AppendLine(('检查文件：{0} · 正常 {1} · 缺失 {2} · 哈希不符 {3}' -f $checked, $okCount, $missing.Count, $mismatch.Count))
if ($extraMods.Count -gt 0) {
    [void]$sb.AppendLine(('本地多余模组 jar：{0} 个（未强制删除）' -f $extraMods.Count))
    $show = $extraMods | Select-Object -First 8
    foreach ($e in $show) { [void]$sb.AppendLine(('  · {0}' -f $e)) }
}
if ($missing.Count -gt 0) {
    [void]$sb.AppendLine('缺失（最多列 12）：')
    foreach ($m in ($missing | Select-Object -First 12)) { [void]$sb.AppendLine(('  · {0}' -f $m.path)) }
}
if ($mismatch.Count -gt 0) {
    [void]$sb.AppendLine('损坏/版本不对（最多列 12）：')
    foreach ($m in ($mismatch | Select-Object -First 12)) { [void]$sb.AppendLine(('  · {0}' -f $m.path)) }
}
if ($fixed.Count -gt 0) {
    [void]$sb.AppendLine(('已自动修补：{0} 个文件' -f $fixed.Count))
}
foreach ($e in $errors) { [void]$sb.AppendLine(('错误：' + $e)) }
foreach ($w in $warnings) { [void]$sb.AppendLine(('提示：' + $w)) }
[void]$sb.AppendLine(('风险灯：{0}' -f $level))
if (-not $Fix -and ($missing.Count -gt 0 -or $mismatch.Count -gt 0)) {
    [void]$sb.AppendLine('建议：再运行一次并加 -Fix 自动重下异常文件；或双击「更新mod-Windows端.bat」完整同步。')
}
[void]$sb.AppendLine(('报告目录：_repair\{0}' -f $stamp))
[void]$sb.AppendLine('把诊断编号发给管理员可加快协助。')
$qqText = $sb.ToString().TrimEnd()

$meta = [ordered]@{
    diagId = $diagId
    instanceRoot = $instanceRoot
    packVersion = $packVersion
    minecraftVersion = $minecraftVersion
    requiredJavaMajor = $requiredJavaMajor
    manifestUrl = $manifestUrl
    serverReachable = $serverReachable
    java = $java
    checked = $checked
    okCount = $okCount
    missing = @($missing | ForEach-Object { $_.path })
    mismatch = @($mismatch | ForEach-Object { $_.path })
    extraMods = @($extraMods)
    fixed = @($fixed)
    level = $level
    fixMode = [bool]$Fix
    generatedAt = (Get-Date).ToString('o')
}
$enc = New-Object Text.UTF8Encoding $true
[IO.File]::WriteAllText((Join-Path $outDir 'report.txt'), $qqText, $enc)
[IO.File]::WriteAllText((Join-Path $outDir 'report-qq.txt'), $qqText, $enc)
[IO.File]::WriteAllText((Join-Path $outDir 'meta.json'), ($meta | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
# latest shortcut
$latest = Join-Path $instanceRoot '_repair\latest'
New-Item -ItemType Directory -Path $latest -Force | Out-Null
Copy-Item (Join-Path $outDir 'report.txt') (Join-Path $latest 'report.txt') -Force
Copy-Item (Join-Path $outDir 'meta.json') (Join-Path $latest 'meta.json') -Force

if ($QqSummary) { Write-Output $qqText }
elseif (-not $Quiet) {
    Write-Host $qqText
    Write-Host ''
    Write-Host ("完整报告: " + (Join-Path $outDir 'report.txt')) -ForegroundColor Cyan
}

if (-not $NoPause -and -not $QqSummary -and -not $Quiet) {
    try { Write-Host '按 Enter 关闭...'; [void][Console]::ReadLine() } catch { }
}

if ($level -eq '红' -or $errors.Count -gt 0) { exit 2 }
if ($level -eq '黄') { exit 1 }
exit 0
