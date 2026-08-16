param(
    [string]$Command,
    [string]$CommandFile,
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RemainingCommand
)

$ErrorActionPreference = "Stop"
# -- force UTF-8 stdout so Java(-Dfile.encoding=UTF-8) reads RCON reply correctly
try { [System.Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
if (-not [string]::IsNullOrWhiteSpace($CommandFile)) {
    if (Test-Path -LiteralPath $CommandFile) {
        $Command = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $CommandFile).Path, [System.Text.Encoding]::UTF8)
    } elseif ([string]::IsNullOrWhiteSpace($Command)) {
        $Command = $CommandFile
    } else {
        $RemainingCommand = @($CommandFile) + @($RemainingCommand)
    }
}
if ($RemainingCommand -and $RemainingCommand.Count -gt 0) {
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $Command = ($RemainingCommand -join " ")
    } else {
        $Command = ($Command, ($RemainingCommand -join " ") -join " ")
    }
}
if ([string]::IsNullOrWhiteSpace($Command)) {
    throw "RCON command is empty."
}
$Root = Split-Path -Parent $PSScriptRoot
$PropsPath = Join-Path $Root "server.properties"

$props = @{}
Get-Content -LiteralPath $PropsPath | ForEach-Object {
    if ($_ -match '^\s*([^#=]+)=(.*)$') {
        $props[$matches[1].Trim()] = $matches[2]
    }
}

if (($props["enable-rcon"] -as [string]) -ne "true") {
    throw "RCON is disabled in server.properties."
}

$hostName = "127.0.0.1"
$port = [int]$props["rcon.port"]
$password = [string]$props["rcon.password"]
if ([string]::IsNullOrWhiteSpace($password)) {
    throw "rcon.password is empty."
}

function New-RconPacket([int]$id, [int]$type, [string]$body) {
    # RCON 载荷必须 UTF-8：ASCII 会把中文全部替换成 ?（服务器收到 <say ????>）
    $payload = [System.Text.Encoding]::UTF8.GetBytes($body)
    $length = 4 + 4 + $payload.Length + 2
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]$length)
    $bw.Write([int]$id)
    $bw.Write([int]$type)
    $bw.Write($payload)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Flush()
    $ms.ToArray()
}

function Read-RconPacket($stream) {
    $lenBytes = New-Object byte[] 4
    $read = $stream.Read($lenBytes, 0, 4)
    if ($read -ne 4) { throw "No RCON response." }
    $length = [System.BitConverter]::ToInt32($lenBytes, 0)
    $data = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length) {
        $n = $stream.Read($data, $offset, $length - $offset)
        if ($n -le 0) { throw "Incomplete RCON response." }
        $offset += $n
    }
    [pscustomobject]@{
        Id = [System.BitConverter]::ToInt32($data, 0)
        Type = [System.BitConverter]::ToInt32($data, 4)
        Body = [System.Text.Encoding]::UTF8.GetString($data, 8, [Math]::Max(0, $length - 10))
    }
}

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($hostName, $port)
$client.ReceiveTimeout = 5000
$client.SendTimeout = 5000
$stream = $client.GetStream()

$auth = New-RconPacket 100 3 $password
$stream.Write($auth, 0, $auth.Length)
$authResponse = Read-RconPacket $stream
if ($authResponse.Id -eq -1) { throw "RCON auth failed." }

# 单个 RCON 响应包最多 4096 字符，超长返回会被服务端拆成多包发出。只读第一包会把
# 后面的静默丢掉——2026-08-04 实测本服 help 共 6666 字符，只拿到 4096，丢了 38%。
# 做法：短返回直接结束（不多一次往返）；正好顶到 4096 才补发一个 type=0 哨兵包，
# 服务端按序把剩余分段发完之后才回哨兵（原版回 "Unknown request 0"），读到它即收全。
$cmdId = 101
$sentinelId = 102
$cmdPacket = New-RconPacket $cmdId 2 $Command
$stream.Write($cmdPacket, 0, $cmdPacket.Length)
$cmdResponse = Read-RconPacket $stream
$body = [string]$cmdResponse.Body

if ($body.Length -ge 4096) {
    $sentinel = New-RconPacket $sentinelId 0 ''
    $stream.Write($sentinel, 0, $sentinel.Length)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($body)
    try {
        while ($true) {
            $pk = Read-RconPacket $stream
            if ($pk.Id -eq $sentinelId) { break }
            # 上限 512K：超大返回只停止累加，避免把内存吃穿
            if ($pk.Id -eq $cmdId -and $sb.Length -lt 524288) { [void]$sb.Append([string]$pk.Body) }
        }
    } catch {
        # 非原版 RCON 实现可能不回哨兵（读超时）：返回已收到的部分，不当失败
    }
    $body = $sb.ToString()
}

$client.Close()

$body
