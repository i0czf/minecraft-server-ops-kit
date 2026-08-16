param(
    [string]$ConfigPath = ".\tools\ops-config.json"
)

# Apply TPS-friendly gamerules after world load. Safe to re-run. Does not restart MC.

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$Rcon = Join-Path $Root 'tools\rcon-command.ps1'
$Log = Join-Path $Root 'logs\apply-tps-gamerules.log'

function Write-Log([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    try {
        $d = Split-Path $Log -Parent
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

function Invoke-Rcon([string]$cmd) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Rcon -Command $cmd 2>&1 | ForEach-Object { "$_" }
}

if (-not (Test-Path -LiteralPath $Rcon)) { throw "missing rcon-command.ps1" }

# Wait until RCON answers (post-boot)
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-Rcon 'list'
        if ($r -match 'There are') { $ok = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}
if (-not $ok) {
    Write-Log 'RCON not ready; skip gamerules'
    exit 1
}

$cmds = @(
    'gamerule maxEntityCramming 8',
    'gamerule doInsomnia false',
    'gamerule playersSleepingPercentage 50',
    'gamerule randomTickSpeed 3'
)
foreach ($c in $cmds) {
    $out = Invoke-Rcon $c
    Write-Log ("{0} => {1}" -f $c, (($out -join ' ').Trim()))
}
Write-Log 'done'
