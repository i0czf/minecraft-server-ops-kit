param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

function Resolve-Java17 {
    $adoptium = 'C:\Program Files\Eclipse Adoptium'
    if (Test-Path -LiteralPath $adoptium -PathType Container) {
        $hit = Get-ChildItem -LiteralPath $adoptium -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\java.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($hit) { return $hit }
    }
    if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        return (Join-Path $env:JAVA_HOME 'bin\java.exe')
    }
    return 'java.exe'
}

function Resolve-Javac17 {
    $java = Resolve-Java17
    if ($java -and $java.EndsWith('java.exe')) {
        $javac = $java.Substring(0, $java.Length - 'java.exe'.Length) + 'javac.exe'
        if (Test-Path -LiteralPath $javac) { return $javac }
    }
    return 'javac.exe'
}

$pidPath = Join-Path $Root 'tmp\qq-console.pid'
$lockPath = Join-Path $Root 'tmp\qq-console.lock'
$source = Join-Path $Root 'tools\QQConsoleBridge.java'
$classes = Join-Path $Root 'tmp\java-classes'
$config = Join-Path $Root 'tools\ops-config.json'

if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
    throw 'PID file not found; QQ bridge may not be running.'
}
$oldPid = 0
if (-not [int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref]$oldPid) -or $oldPid -le 0) {
    throw 'PID file does not contain a valid PID.'
}
$old = Get-Process -Id $oldPid -ErrorAction Stop
if ($old.ProcessName -ne 'java') {
    throw "Refusing to operate: PID=$oldPid is not a Java process."
}

Write-Host "Stopping QQ bridge PID=$oldPid (Minecraft is not touched)..."
Stop-Process -Id $oldPid -Force -ErrorAction Stop
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Process -Id $oldPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
}
if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
    throw "Old QQ bridge PID=$oldPid did not exit."
}
Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Path $classes,(Join-Path $Root 'logs') -Force | Out-Null
$classFile = Join-Path $classes 'QQConsoleBridge.class'
$sourceNewer = $true
if (Test-Path -LiteralPath $classFile -PathType Leaf) {
    $sourceNewer = (Get-Item -LiteralPath $source).LastWriteTimeUtc -gt
        (Get-Item -LiteralPath $classFile).LastWriteTimeUtc
}
if ($sourceNewer) {
    $javac = Resolve-Javac17
    & $javac -encoding UTF-8 -Xlint:all -d $classes $source
    if ($LASTEXITCODE -ne 0) { throw 'QQ bridge compilation failed.' }
}

$java = Resolve-Java17
$new = Start-Process -FilePath $java -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
    -ArgumentList @('-Dfile.encoding=UTF-8','-Dqq.quietStart=true','-cp',("`"$classes`""),'QQConsoleBridge',("`"$config`"")) `
    -RedirectStandardOutput (Join-Path $Root 'logs\qq-console-start.out') `
    -RedirectStandardError (Join-Path $Root 'logs\qq-console-start.err')
Set-Content -LiteralPath $pidPath -Value $new.Id -Encoding ASCII
Start-Sleep -Seconds 3
if (-not (Get-Process -Id $new.Id -ErrorAction SilentlyContinue)) {
    throw "New QQ bridge exited after starting, PID=$($new.Id). Check logs\qq-console-start.err."
}
Write-Host "QQ bridge reloaded: old PID=$oldPid, new PID=$($new.Id)"
if (-not $NoPause) { Read-Host 'Press Enter to close' }
