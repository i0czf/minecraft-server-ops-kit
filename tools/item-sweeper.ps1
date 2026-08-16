param(
    [string]$ConfigPath = ".\tools\ops-config.json",
    [switch]$Once,
    [switch]$Force,
    [int]$IntervalSeconds = 0,
    [int]$MinAgeTicks = -1,
    [int]$PlayerSafeRadius = -1
)

# Entity janitor (item + lag entities + far hostiles). RCON only. Never restarts MC.

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'entity-janitor / item-sweeper' } catch { }

$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
$ToolsDir = $PSScriptRoot
$PidPath = Join-Path $Root 'tmp\item-sweeper.pid'
$LogPath = Join-Path $Root 'logs\item-sweeper.log'
$RconScript = Join-Path $ToolsDir 'rcon-command.ps1'

function Write-SweepLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
    try { Write-Host $line } catch { }
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-SweepLog ('config parse failed: ' + $_.Exception.Message); return $null }
}

function Get-CfgValue($Obj, [string]$Name, $Default) {
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

$script:RconClient = $null
$script:RconStream = $null
$script:RconNextId = 200

function Close-RconSession {
    try { if ($script:RconStream) { $script:RconStream.Dispose() } } catch {}
    try { if ($script:RconClient) { $script:RconClient.Close() } } catch {}
    $script:RconStream = $null
    $script:RconClient = $null
}

function New-RconPacket([int]$Id, [int]$Type, [string]$Body) {
    $payload = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $length = 4 + 4 + $payload.Length + 2
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]$length)
    $bw.Write([int]$Id)
    $bw.Write([int]$Type)
    $bw.Write($payload)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Flush()
    return $ms.ToArray()
}

function Read-RconPacket($Stream) {
    $lenBytes = New-Object byte[] 4
    $read = $Stream.Read($lenBytes, 0, 4)
    if ($read -ne 4) { throw 'No RCON response.' }
    $length = [System.BitConverter]::ToInt32($lenBytes, 0)
    $data = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length) {
        $n = $Stream.Read($data, $offset, $length - $offset)
        if ($n -le 0) { throw 'Incomplete RCON response.' }
        $offset += $n
    }
    return [pscustomobject]@{
        Id = [System.BitConverter]::ToInt32($data, 0)
        Type = [System.BitConverter]::ToInt32($data, 4)
        Body = [System.Text.Encoding]::UTF8.GetString($data, 8, [Math]::Max(0, $length - 10))
    }
}

function Open-RconSession {
    if ($script:RconClient -and $script:RconClient.Connected -and $script:RconStream) { return }
    Close-RconSession
    $props = @{}
    $propsPath = Join-Path $Root 'server.properties'
    Get-Content -LiteralPath $propsPath | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)=(.*)$') { $props[$matches[1].Trim()] = $matches[2] }
    }
    if (($props['enable-rcon'] -as [string]) -ne 'true') { throw 'RCON is disabled in server.properties.' }
    $port = [int]$props['rcon.port']
    $password = [string]$props['rcon.password']
    if ([string]::IsNullOrWhiteSpace($password)) { throw 'rcon.password is empty.' }
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect('127.0.0.1', $port)
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    $stream = $client.GetStream()
    $auth = New-RconPacket 100 3 $password
    $stream.Write($auth, 0, $auth.Length)
    $authResponse = Read-RconPacket $stream
    if ($authResponse.Id -eq -1) { throw 'RCON auth failed.' }
    $script:RconClient = $client
    $script:RconStream = $stream
    $script:RconNextId = 200
}

function Invoke-Rcon([string]$Command) {
    $attempts = 0
    while ($attempts -lt 2) {
        $attempts++
        try {
            Open-RconSession
            $cmdId = $script:RconNextId
            $script:RconNextId++
            if ($script:RconNextId -gt 1000000) { $script:RconNextId = 200 }
            $bytes = New-RconPacket $cmdId 2 $Command
            $script:RconStream.Write($bytes, 0, $bytes.Length)
            $resp = Read-RconPacket $script:RconStream
            $body = [string]$resp.Body
            if ($body.Length -ge 4096) {
                $sentinelId = $script:RconNextId
                $script:RconNextId++
                $sentinel = New-RconPacket $sentinelId 0 ''
                $script:RconStream.Write($sentinel, 0, $sentinel.Length)
                $sb = New-Object System.Text.StringBuilder
                [void]$sb.Append($body)
                try {
                    while ($true) {
                        $pk = Read-RconPacket $script:RconStream
                        if ($pk.Id -eq $sentinelId) { break }
                        if ($pk.Id -eq $cmdId -and $sb.Length -lt 524288) { [void]$sb.Append([string]$pk.Body) }
                    }
                } catch { }
                $body = $sb.ToString()
            }
            return $body
        } catch {
            Close-RconSession
            if ($attempts -ge 2) {
                if (-not (Test-Path -LiteralPath $RconScript -PathType Leaf)) { throw }
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RconScript -Command $Command 2>&1
                return (($out | ForEach-Object { "$_" }) -join "`n")
            }
        }
    }
}


function Get-OnlinePlayerCount {
    $raw = Invoke-Rcon 'list'
    if ($raw -match 'There are (\d+) of a max') { return [int]$Matches[1] }
    if ($raw -match 'There are (\d+)/') { return [int]$Matches[1] }
    return 0
}
function Ensure-Scoreboards {
    [void](Invoke-Rcon 'scoreboard objectives add _sw_cnt dummy')
    [void](Invoke-Rcon 'scoreboard objectives add _sw_age dummy')
}

function Get-EntityCount([string]$FakePlayer, [string]$Selector) {
    # Fast path: prefer not to spam when selector empty - still 2-3 rcon calls
    [void](Invoke-Rcon ('scoreboard players set {0} _sw_cnt 0' -f $FakePlayer))
    # Use execute store with score from count - MC has no direct count; keep add loop but only when needed
    [void](Invoke-Rcon ('execute as {0} run scoreboard players add {1} _sw_cnt 1' -f $Selector, $FakePlayer))
    $raw = Invoke-Rcon ('scoreboard players get {0} _sw_cnt' -f $FakePlayer)
    if ($raw -match 'has (-?\d+)') { return [int]$Matches[1] }
    if ($raw -match "Can't get value") { return 0 }
    return -1
}

function Get-NearEntityCount([string]$Selector, [int]$Radius) {
    if ($Radius -le 0) { return 0 }
    [void](Invoke-Rcon 'scoreboard players set #sw_n _sw_cnt 0')
    [void](Invoke-Rcon ('execute as {0} at @s if entity @a[distance=..{1}] run scoreboard players add #sw_n _sw_cnt 1' -f $Selector, $Radius))
    $raw = Invoke-Rcon 'scoreboard players get #sw_n _sw_cnt'
    if ($raw -match 'has (-?\d+)') { return [int]$Matches[1] }
    if ($raw -match "Can't get value") { return 0 }
    return -1
}

function Send-Broadcast([string]$Message, [string]$Color = 'gold') {
    $esc = $Message.Replace('\', '\\').Replace('"', '\"')
    [void](Invoke-Rcon ('tellraw @a {"text":"' + $esc + '","color":"' + $Color + '"}'))
}

function Invoke-SweepPass {
    param(
        [int]$MinAge,
        [int]$SafeRadius,
        [bool]$ClearXp,
        [bool]$ClearFalling,
        [int]$FallingMin,
        [bool]$ClearProjectiles,
        [bool]$CullHostiles,
        [int]$HostileSafeRadius,
        [object]$HostileTypes,
        [bool]$Broadcast,
        [int]$WarnSeconds,
        [int]$WarnMinCount,
        [bool]$IgnoreItemAge,
        [string]$Reason,
        [int]$CooldownSeconds = 180,
        [int]$BroadcastMinItems = 8
    )

    Ensure-Scoreboards

    $itemBefore = Get-EntityCount '#sw_i' '@e[type=item]'
    $itemNearBefore = if ($itemBefore -gt 0) { Get-NearEntityCount '@e[type=item]' $SafeRadius } else { 0 }
    $xpBefore = if ($ClearXp) { Get-EntityCount '#sw_x' '@e[type=experience_orb]' } else { 0 }
    $fbBefore = if ($ClearFalling) { Get-EntityCount '#sw_f' '@e[type=falling_block]' } else { 0 }
    $arrowBefore = if ($ClearProjectiles) { Get-EntityCount '#sw_a' '@e[type=arrow]' } else { 0 }

    $hostileBefore = 0
    $hostileBreakdown = @()
    if ($CullHostiles -and $HostileTypes) {
        foreach ($t in @($HostileTypes)) {
            $tt = [string]$t
            if ([string]::IsNullOrWhiteSpace($tt)) { continue }
            $n = Get-EntityCount '#sw_h' ("@e[type={0}]" -f $tt)
            if ($n -gt 0) {
                $hostileBefore += $n
                $hostileBreakdown += ('{0}={1}' -f $tt, $n)
            }
        }
    }

    Write-SweepLog ('scan reason={0} items={1} near={2} xp={3} falling={4} arrows={5} hostiles={6} minAge={7} itemSafeR={8} hostileSafeR={9} ignoreAge={10}' -f `
            $Reason, $itemBefore, $itemNearBefore, $xpBefore, $fbBefore, $arrowBefore, $hostileBefore, $MinAge, $SafeRadius, $HostileSafeRadius, $IgnoreItemAge)
    if ($hostileBreakdown.Count -gt 0) {
        Write-SweepLog ('hostiles detail: ' + ($hostileBreakdown -join ', '))
    }

    if ($itemBefore -lt 0) { Write-SweepLog 'RCON count failed; skip pass'; return }

    $needItem = $itemBefore -gt 0
    $needXp = $ClearXp -and $xpBefore -gt 0
    $needFb = $ClearFalling -and $fbBefore -ge [Math]::Max(1, $FallingMin)
    $needArrow = $ClearProjectiles -and $arrowBefore -gt 0
    $needHostile = $CullHostiles -and $hostileBefore -gt 0
    if (-not $needItem -and -not $needXp -and -not $needFb -and -not $needArrow -and -not $needHostile) {
        Write-SweepLog 'nothing to clean'
        return
    }

    # 公屏只为「玩家可能还要捡的掉落物」说话。远处清怪是后台卫生，不预告、不报数。
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cooled = ($CooldownSeconds -le 0) -or (($nowMs - $script:LastBroadcastMs) -ge ($CooldownSeconds * 1000L))
    $warnBecauseItems = $itemBefore -ge $WarnMinCount
    $warnBecauseHardWipe = $IgnoreItemAge -and ($itemBefore -gt $itemNearBefore)
    $didWarn = $false
    if ($Broadcast -and $WarnSeconds -gt 0 -and $cooled -and ($warnBecauseItems -or $warnBecauseHardWipe)) {
        Send-Broadcast ('[扫地僧] ' + $WarnSeconds + '秒后清理远离玩家的掉落物，身边的不扫') 'gold'
        $script:LastBroadcastMs = $nowMs
        $didWarn = $true
        Start-Sleep -Seconds $WarnSeconds
    }

    # --- far hostiles FIRST (loot drops items; items cleaned after) ---
    $hostileKilledApprox = 0
    if ($needHostile) {
        $hr = [Math]::Max(24, $HostileSafeRadius)
        foreach ($t in @($HostileTypes)) {
            $tt = [string]$t
            if ([string]::IsNullOrWhiteSpace($tt)) { continue }
            $cmd = 'execute as @e[type=' + $tt + '] at @s unless entity @a[distance=..' + $hr + '] unless data entity @s CustomName run kill @s'
            [void](Invoke-Rcon $cmd)
        }
        $afterH = 0
        foreach ($t in @($HostileTypes)) {
            $tt = [string]$t
            if ([string]::IsNullOrWhiteSpace($tt)) { continue }
            $n = Get-EntityCount '#sw_h' ("@e[type={0}]" -f $tt)
            if ($n -gt 0) { $afterH += $n }
        }
        $hostileKilledApprox = [Math]::Max(0, $hostileBefore - $afterH)
        # brief settle so death drops exist as item entities
        if ($hostileKilledApprox -gt 0) { Start-Sleep -Milliseconds 800 }
    }

    # --- items AFTER hostiles (include cull loot) ---
    # hard: far items skip age so cull-loot is wiped; player bubble is never ignored.
    # Tag from the player side: execute-as-item + unless @a is unreliable on this stack
    # (hard passes were still zeroing near-player items).
    $itemAgeFloor = if ($IgnoreItemAge) { 0 } else { $MinAge }
    if ($needItem -or $hostileKilledApprox -gt 0) {
        [void](Invoke-Rcon 'tag @e[type=item] remove _sw_keep')
        if ($SafeRadius -gt 0) {
            [void](Invoke-Rcon ('execute as @a at @s run tag @e[type=item,distance=..{0}] add _sw_keep' -f $SafeRadius))
        }
        [void](Invoke-Rcon 'execute as @e[type=item] store result score @s _sw_age run data get entity @s Age')
        if ($SafeRadius -le 0) {
            [void](Invoke-Rcon ('kill @e[type=item,scores={_sw_age=' + $itemAgeFloor + '..}]'))
        } else {
            [void](Invoke-Rcon ('kill @e[type=item,tag=!_sw_keep,scores={_sw_age=' + $itemAgeFloor + '..}]'))
        }
    }
    if ($needXp -or $hostileKilledApprox -gt 0) {
        if ($SafeRadius -le 0) {
            [void](Invoke-Rcon 'kill @e[type=experience_orb]')
        } else {
            [void](Invoke-Rcon 'tag @e[type=experience_orb] remove _sw_keep')
            [void](Invoke-Rcon ('execute as @a at @s run tag @e[type=experience_orb,distance=..{0}] add _sw_keep' -f $SafeRadius))
            [void](Invoke-Rcon 'kill @e[type=experience_orb,tag=!_sw_keep]')
        }
    }
    if ($needFb) { [void](Invoke-Rcon 'kill @e[type=falling_block]') }
    if ($needArrow) {
        [void](Invoke-Rcon ('execute as @e[type=arrow] at @s unless entity @a[distance=..' + [Math]::Max(8, $SafeRadius) + '] run kill @s'))
        [void](Invoke-Rcon ('execute as @e[type=spectral_arrow] at @s unless entity @a[distance=..' + [Math]::Max(8, $SafeRadius) + '] run kill @s'))
    }

    $itemAfter = Get-EntityCount '#sw_i' '@e[type=item]'
    $itemNearAfter = if ($itemAfter -gt 0) { Get-NearEntityCount '@e[type=item]' $SafeRadius } else { 0 }
    $xpAfter = if ($ClearXp) { Get-EntityCount '#sw_x' '@e[type=experience_orb]' } else { 0 }
    $fbAfter = if ($ClearFalling) { Get-EntityCount '#sw_f' '@e[type=falling_block]' } else { 0 }
    $arrowAfter = if ($ClearProjectiles) { Get-EntityCount '#sw_a' '@e[type=arrow]' } else { 0 }

    $removedItems = [Math]::Max(0, $itemBefore - [Math]::Max(0, $itemAfter))
    $removedXp = [Math]::Max(0, $xpBefore - [Math]::Max(0, $xpAfter))
    $removedFb = [Math]::Max(0, $fbBefore - [Math]::Max(0, $fbAfter))
    $removedArrows = [Math]::Max(0, $arrowBefore - [Math]::Max(0, $arrowAfter))

    Write-SweepLog ('done items-{0}->left{1} near{2}->{3} xp-{4} falling-{5} arrows-{6} hostiles~-{7}' -f $removedItems, $itemAfter, $itemNearBefore, $itemNearAfter, $removedXp, $removedFb, $removedArrows, $hostileKilledApprox)

    $showDone = $Broadcast -and $removedItems -gt 0 -and ($didWarn -or ($removedItems -ge $BroadcastMinItems -and $cooled))
    if ($showDone) {
        Send-Broadcast ('[扫地僧] 已清理掉落物 ' + $removedItems) 'green'
        if (-not $didWarn) { $script:LastBroadcastMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    }
}

$cfgPath = $ConfigPath
if (-not [System.IO.Path]::IsPathRooted($cfgPath)) {
    $cfgPath = Join-Path $Root ($ConfigPath.TrimStart('.', '\', '/'))
}
$ops = Read-JsonFile $cfgPath
$sw = if ($ops) { $ops.itemSweeper } else { $null }

$enabled = [bool](Get-CfgValue $sw 'enabled' $true)
if (-not $enabled -and -not $Once -and -not $Force) {
    Write-SweepLog 'itemSweeper.enabled=false; exit'
    exit 0
}

$interval = if ($IntervalSeconds -gt 0) { $IntervalSeconds } else { [int](Get-CfgValue $sw 'intervalSeconds' 120) }
if ($interval -lt 30) { $interval = 30 }

$minAge = if ($MinAgeTicks -ge 0) { $MinAgeTicks } else { [int](Get-CfgValue $sw 'minAgeTicks' 600) }
if ($minAge -lt 0) { $minAge = 0 }

$safeR = if ($PlayerSafeRadius -ge 0) { $PlayerSafeRadius } else { [int](Get-CfgValue $sw 'playerSafeRadius' 16) }
$warnSec = [int](Get-CfgValue $sw 'warnSeconds' 10)
$warnMin = [int](Get-CfgValue $sw 'warnMinCount' 30)
$clearXp = [bool](Get-CfgValue $sw 'clearXpOrbs' $true)
$clearFb = [bool](Get-CfgValue $sw 'clearFallingBlocks' $true)
$fbMin = [int](Get-CfgValue $sw 'fallingBlockMinCount' 8)
$clearProj = [bool](Get-CfgValue $sw 'clearProjectiles' $true)
$cullHostiles = [bool](Get-CfgValue $sw 'cullFarHostiles' $true)
$hostileSafeR = [int](Get-CfgValue $sw 'hostileSafeRadius' 40)
$broadcast = [bool](Get-CfgValue $sw 'broadcast' $true)
$broadcastCooldownSec = [int](Get-CfgValue $sw 'broadcastCooldownSeconds' 180)
if ($broadcastCooldownSec -lt 0) { $broadcastCooldownSec = 0 }
$broadcastMinItems = [int](Get-CfgValue $sw 'broadcastMinItems' 8)
if ($broadcastMinItems -lt 1) { $broadcastMinItems = 1 }
$script:LastBroadcastMs = 0
$hardEvery = [int](Get-CfgValue $sw 'hardClearEveryPasses' 3)
if ($hardEvery -lt 0) { $hardEvery = 0 }
$startupDelay = [int](Get-CfgValue $sw 'startupDelaySeconds' 8)
if ($Force) { $startupDelay = 0 }

$peakThreshold = [int](Get-CfgValue $sw 'peakPlayerThreshold' 5)
$peakInterval = [int](Get-CfgValue $sw 'peakIntervalSeconds' 50)
if ($peakInterval -lt 30) { $peakInterval = 30 }
$peakHostileR = [int](Get-CfgValue $sw 'peakHostileSafeRadius' 28)
$peakMinAge = [int](Get-CfgValue $sw 'peakMinAgeTicks' 400)
$peakItemSafeR = [int](Get-CfgValue $sw 'peakPlayerSafeRadius' 12)
$baseInterval = $interval
$baseHostileR = $hostileSafeR
$baseMinAge = $minAge
$baseItemSafeR = $safeR

$defaultHostiles = @(
    'minecraft:creeper', 'minecraft:zombie', 'minecraft:skeleton', 'minecraft:spider',
    'minecraft:cave_spider', 'minecraft:drowned', 'minecraft:husk', 'minecraft:stray',
    'minecraft:witch', 'minecraft:phantom', 'minecraft:slime', 'minecraft:magma_cube',
    'minecraft:enderman', 'minecraft:pillager', 'minecraft:vindicator', 'minecraft:bat',
    'minecraft:zombified_piglin', 'minecraft:hoglin', 'minecraft:zoglin',
    'thaumcraft:brainy_zombie', 'thaumcraft:giant_brainy_zombie', 'thaumcraft:firebat',
    'thaumcraft:wisp', 'thaumcraft:taintacle', 'thaumcraft:taint_seed', 'thaumcraft:taint_swarm',
    'cataclysm:urchinkin', 'cataclysm:symbiocto', 'cataclysm:drowned_host', 'cataclysm:cindaria',
    'cataclysm:hippocamtus', 'cataclysm:wave', 'cataclysm:cm_falling_block',
    'goety:haunted_armor', 'goety:wraith', 'goety:reprobate', 'goety:maverick', 'goety:web_spider',
    'touhou_little_maid:fairy'
)
$hostileTypes = @()
try {
    $cfgList = Get-CfgValue $sw 'hostileTypes' $null
    if ($cfgList) { $hostileTypes = @($cfgList) }
} catch { }
if ($hostileTypes.Count -eq 0) { $hostileTypes = $defaultHostiles }

if (-not $Once) {
    $tmp = Join-Path $Root 'tmp'
    if (-not (Test-Path -LiteralPath $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
    if (Test-Path -LiteralPath $PidPath) {
        $old = 0
        try { [void][int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$old) } catch { }
        if ($old -gt 0 -and $old -ne $PID) {
            $op = Get-Process -Id $old -ErrorAction SilentlyContinue
            if ($op) { Write-SweepLog ('already running pid=' + $old + '; exit'); exit 0 }
        }
    }
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
}

Write-SweepLog ('start once={0} force={1} interval={2}s minAge={3} itemSafeR={4} cullHostiles={5} hostileSafeR={6} policy=keep-near-player' -f [bool]$Once, [bool]$Force, $interval, $minAge, $safeR, $cullHostiles, $hostileSafeR)

if (-not $Once -and $startupDelay -gt 0) {
    Write-SweepLog ('startup delay ' + $startupDelay + 's')
    Start-Sleep -Seconds $startupDelay
}

$pass = 0
try {
    while ($true) {
        $pass++
        $online = 0
        try { $online = Get-OnlinePlayerCount } catch { $online = 0 }
        try {
            $live = Read-JsonFile $cfgPath
            $liveSw = if ($live) { $live.itemSweeper } else { $null }
            if ($null -ne $liveSw) {
                $broadcast = [bool](Get-CfgValue $liveSw 'broadcast' $false)
                if ($IntervalSeconds -le 0) {
                    $baseInterval = [int](Get-CfgValue $liveSw 'intervalSeconds' $baseInterval)
                    if ($baseInterval -lt 30) { $baseInterval = 30 }
                }
                if ($MinAgeTicks -lt 0) {
                    $baseMinAge = [int](Get-CfgValue $liveSw 'minAgeTicks' $baseMinAge)
                    if ($baseMinAge -lt 0) { $baseMinAge = 0 }
                }
                if ($PlayerSafeRadius -lt 0) {
                    $baseItemSafeR = [int](Get-CfgValue $liveSw 'playerSafeRadius' $baseItemSafeR)
                }
                $baseHostileR = [int](Get-CfgValue $liveSw 'hostileSafeRadius' $baseHostileR)
                $peakThreshold = [int](Get-CfgValue $liveSw 'peakPlayerThreshold' $peakThreshold)
                $peakInterval = [int](Get-CfgValue $liveSw 'peakIntervalSeconds' $peakInterval)
                if ($peakInterval -lt 30) { $peakInterval = 30 }
                $peakHostileR = [int](Get-CfgValue $liveSw 'peakHostileSafeRadius' $peakHostileR)
                $peakMinAge = [int](Get-CfgValue $liveSw 'peakMinAgeTicks' $peakMinAge)
                $peakItemSafeR = [int](Get-CfgValue $liveSw 'peakPlayerSafeRadius' $peakItemSafeR)
                $hardEvery = [int](Get-CfgValue $liveSw 'hardClearEveryPasses' $hardEvery)
                if ($hardEvery -lt 0) { $hardEvery = 0 }
            }
        } catch { }
        $peak = ($online -ge $peakThreshold)
        $useInterval = if ($peak) { $peakInterval } else { $baseInterval }
        $useHostileR = if ($peak) { $peakHostileR } else { $baseHostileR }
        $useMinAge = if ($peak) { $peakMinAge } else { $baseMinAge }
        $useItemSafeR = if ($peak) { $peakItemSafeR } else { $baseItemSafeR }
        $hard = $Force -or ($hardEvery -gt 0 -and ($pass % $hardEvery) -eq 0)
        # peak: hard a bit more often (far items only; player bubble still kept)
        if ($peak -and ($pass % 2) -eq 0) { $hard = $true }
        try {
            $wsec = if ($Force) { [Math]::Max(8, $warnSec) } else { $warnSec }
            $wmin = if ($Force) { 1 } else { $warnMin }
            $ignoreAge = $hard -and -not $Force
            $reason = $(if ($hard) { 'hard' } else { 'soft' }) + $(if ($peak) { '+peak' } else { '' }) + (' online=' + $online)
            Write-SweepLog ('mode peak={0} online={1} interval={2} hostileR={3} minAge={4} itemSafeR={5} ignoreAge={6}' -f $peak, $online, $useInterval, $useHostileR, $useMinAge, $useItemSafeR, $ignoreAge)
            $talk = $broadcast -and $online -gt 0
            Invoke-SweepPass -MinAge $useMinAge -SafeRadius $useItemSafeR `
                -ClearXp $clearXp -ClearFalling $clearFb -FallingMin $fbMin `
                -ClearProjectiles $clearProj -CullHostiles $cullHostiles -HostileSafeRadius $useHostileR `
                -HostileTypes $hostileTypes `
                -Broadcast $talk -WarnSeconds $wsec -WarnMinCount $wmin `
                -IgnoreItemAge $ignoreAge -Reason $reason `
                -CooldownSeconds $broadcastCooldownSec -BroadcastMinItems $broadcastMinItems
        } catch {
            Write-SweepLog ('pass failed: ' + $_.Exception.Message)
        }
        if ($Once) { break }
        $Force = $false
        Start-Sleep -Seconds $useInterval
    }
} finally {
    Close-RconSession
    if (-not $Once) {
        try {
            if (Test-Path -LiteralPath $PidPath) {
                $cur = 0
                if ([int]::TryParse((Get-Content -LiteralPath $PidPath -Raw).Trim(), [ref]$cur) -and $cur -eq $PID) {
                    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }
}
Write-SweepLog 'exit'