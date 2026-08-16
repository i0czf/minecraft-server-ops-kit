param(
    [string]$ConfigPath = ".\tools\ops-config.json"
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = 'World backup scheduler' } catch { }
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

function Resolve-RootPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Write-SchedulerLog {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath (Join-Path $Root "backups\backup-scheduler.log") -Value $line -Encoding UTF8
    Write-Host $line
}

function Read-Config {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing config: $Path"
    }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-SchedulerState {
    param(
        [Parameter(Mandatory = $true)][System.DateTimeOffset]$NextRun,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [string]$Detail = ""
    )
    $stateDir = Split-Path -Parent $script:StatePath
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $tempPath = $script:StatePath + ".tmp-" + $PID
    $payload = [ordered]@{
        schema = 1
        nextRunUtc = $NextRun.UtcDateTime.ToString("o")
        updatedUtc = [System.DateTime]::UtcNow.ToString("o")
        lastOutcome = $Outcome
        lastDetail = $Detail
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($tempPath, $payload, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $script:StatePath -Force
}

function Read-SchedulerState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $next = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$state.nextRunUtc)) {
            $next = [System.DateTimeOffset]::Parse(
                [string]$state.nextRunUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
        }
        return [pscustomobject]@{
            NextRun = $next
            LastOutcome = [string]$state.lastOutcome
        }
    } catch {
        Write-SchedulerLog "state unreadable; rebuilding schedule: $($_.Exception.Message)"
        return $null
    }
}

function Get-BackupRunTimes {
    param($Schedule)
    $parsed = New-Object System.Collections.Generic.List[TimeSpan]
    if (-not $Schedule -or -not $Schedule.PSObject.Properties['runTimes'] -or -not $Schedule.runTimes) {
        return @()
    }
    foreach ($item in @($Schedule.runTimes)) {
        $ts = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse([string]$item, [ref]$ts)) {
            [void]$parsed.Add($ts)
        } else {
            Write-SchedulerLog "ignored invalid runTimes entry: $item"
        }
    }
    return @($parsed | Sort-Object | Select-Object -Unique)
}

function Get-NextBackupSlot {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$After,
        [TimeSpan[]]$RunTimes,
        [int]$FallbackMinutes
    )
    if (-not $RunTimes -or $RunTimes.Count -lt 1) {
        return $After.AddMinutes($FallbackMinutes)
    }
    $local = $After.LocalDateTime
    for ($day = 0; $day -le 2; $day++) {
        $dayDate = $local.Date.AddDays($day)
        foreach ($t in $RunTimes) {
            $candidate = [DateTimeOffset]($dayDate + $t)
            if ($candidate -gt $After) { return $candidate }
        }
    }
    return $After.AddMinutes($FallbackMinutes)
}

function Get-LatestCompleteBackup {
    $backupRoot = Join-Path $Root "backups\world"
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { return $null }
    $namePattern = '^.+-' + [regex]::Escape($script:WorldName) + '-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.zip$'
    return Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $namePattern } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Get-BackupLoadGate {
    $rconScript = Join-Path $Root "tools\rcon-command.ps1"
    try {
        $listReply = ((& $rconScript -Command "list") | Out-String).Trim()
    } catch {
        return [pscustomobject]@{ Allowed = $false; Detail = "RCON list failed: $($_.Exception.Message)" }
    }

    if ($listReply -notmatch '(?i)there\s+are\s+(\d+)\s+of\s+a\s+max') {
        return [pscustomobject]@{ Allowed = $false; Detail = "cannot parse online count: $listReply" }
    }
    $players = [int]$matches[1]
    if ($script:DeferWhenPlayersOnline -and $players -gt 0) {
        return [pscustomobject]@{ Allowed = $false; Detail = "players online=$players" }
    }

    if ($script:MaxMsptForBackup -gt 0) {
        $samplePath = Join-Path $Root "logs\perf\samples.jsonl"
        if (Test-Path -LiteralPath $samplePath -PathType Leaf) {
            try {
                $lastLine = Get-Content -LiteralPath $samplePath -Tail 1 -Encoding UTF8
                $sample = $lastLine | ConvertFrom-Json
                $sampleAt = [System.DateTimeOffset]::Parse([string]$sample.ts)
                $ageSeconds = ([System.DateTimeOffset]::Now - $sampleAt).TotalSeconds
                if ($ageSeconds -ge 0 -and $ageSeconds -le $script:LoadSampleMaxAgeSeconds -and
                    [bool]$sample.serverUp -and [double]$sample.mspt -gt $script:MaxMsptForBackup) {
                    return [pscustomobject]@{
                        Allowed = $false
                        Detail = "MSPT=$([math]::Round([double]$sample.mspt, 2)) exceeds $($script:MaxMsptForBackup)"
                    }
                }
            } catch {
                Write-SchedulerLog "load sample unreadable; player gate still applies: $($_.Exception.Message)"
            }
        }
    }

    return [pscustomobject]@{ Allowed = $true; Detail = "players=$players load-ok" }
}

New-Item -ItemType Directory -Force (Join-Path $Root "backups") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Root "tmp") | Out-Null

$config = Read-Config -Path (Resolve-RootPath $ConfigPath)
if (-not $config.backupSchedule -or -not $config.backupSchedule.enabled) {
    Write-SchedulerLog "backup scheduler disabled"
    return
}

$intervalMinutes = [int]$config.backupSchedule.intervalMinutes
if ($intervalMinutes -lt 30) { $intervalMinutes = 360 }

$startupDelayMinutes = [int]$config.backupSchedule.startupDelayMinutes
if ($startupDelayMinutes -lt 0) { $startupDelayMinutes = 15 }

$retryMinutes = [int]$config.backupSchedule.deferRetryMinutes
if ($retryMinutes -lt 5) { $retryMinutes = 15 }

$keepRolling = [int]$config.backupSchedule.keepRolling
if ($keepRolling -lt 1) { $keepRolling = 4 }

$keepDaily = [int]$config.backupSchedule.keepDaily
if ($keepDaily -lt 0) { $keepDaily = 0 }

$keepWeekly = [int]$config.backupSchedule.keepWeekly
if ($keepWeekly -lt 0) { $keepWeekly = 0 }

$maxTotalSizeGB = 50
if ($config.backupSchedule.PSObject.Properties['maxTotalSizeGB']) {
    $maxTotalSizeGB = [double]$config.backupSchedule.maxTotalSizeGB
}
if ($maxTotalSizeGB -lt 0) { $maxTotalSizeGB = 0 }

$script:RunTimes = @(Get-BackupRunTimes -Schedule $config.backupSchedule)

$script:WorldName = [string]$config.backupSchedule.worldName
if ([string]::IsNullOrWhiteSpace($script:WorldName)) { $script:WorldName = "world" }

$backupPrefix = [string]$config.backupSchedule.backupPrefix
if ([string]::IsNullOrWhiteSpace($backupPrefix)) { $backupPrefix = "server" }

$script:DeferWhenPlayersOnline = [bool]$config.backupSchedule.deferWhenPlayersOnline
$script:MaxMsptForBackup = [double]$config.backupSchedule.maxMsptForBackup
if ($script:MaxMsptForBackup -lt 0) { $script:MaxMsptForBackup = 0 }
$script:LoadSampleMaxAgeSeconds = [int]$config.backupSchedule.loadSampleMaxAgeSeconds
if ($script:LoadSampleMaxAgeSeconds -lt 30) { $script:LoadSampleMaxAgeSeconds = 180 }

$stateRelative = [string]$config.backupSchedule.statePath
if ([string]::IsNullOrWhiteSpace($stateRelative)) { $stateRelative = "tmp\backup-scheduler-state.json" }
$script:StatePath = Resolve-RootPath $stateRelative

$backupScript = Join-Path $Root "tools\backup-world.ps1"
if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) {
    throw "Missing backup script: $backupScript"
}

$slotLabel = if ($script:RunTimes.Count -gt 0) {
    'slots=' + (($script:RunTimes | ForEach-Object { $_.ToString('hh\:mm') }) -join ',')
} else {
    "interval=${intervalMinutes}m"
}
Write-SchedulerLog "backup scheduler started: $slotLabel startupDelay=${startupDelayMinutes}m retry=${retryMinutes}m playerDefer=$($script:DeferWhenPlayersOnline) maxMSPT=$($script:MaxMsptForBackup) retention=${keepRolling}x/${maxTotalSizeGB}GB"

$now = [System.DateTimeOffset]::Now
$state = Read-SchedulerState
$nextRun = $null
if ($script:RunTimes.Count -gt 0) {
    $slot = Get-NextBackupSlot -After $now -RunTimes $script:RunTimes -FallbackMinutes $intervalMinutes
    $keepPending = $false
    if ($state -and $state.NextRun -and $state.LastOutcome -in @('deferred', 'failed', 'running')) {
        if ($state.NextRun -gt $now -and $state.NextRun -lt $slot) {
            $keepPending = $true
            $nextRun = $state.NextRun
        }
    }
    if (-not $keepPending) {
        $latest = Get-LatestCompleteBackup
        if (-not $latest) {
            $nextRun = $now.AddMinutes($startupDelayMinutes)
            if ($slot -lt $nextRun) { $nextRun = $slot }
        } else {
            $nextRun = $slot
        }
        Write-SchedulerState -NextRun $nextRun -Outcome "initialized" -Detail "next clock slot"
    }
} elseif ($state -and $state.NextRun) {
    $nextRun = $state.NextRun
} else {
    $latest = Get-LatestCompleteBackup
    if ($latest) {
        $candidate = [System.DateTimeOffset]$latest.LastWriteTime
        $candidate = $candidate.AddMinutes($intervalMinutes)
        if ($candidate -gt $now) {
            $nextRun = $candidate
        } else {
            $nextRun = $now.AddMinutes($startupDelayMinutes)
        }
    } else {
        $nextRun = $now.AddMinutes($startupDelayMinutes)
    }
    Write-SchedulerState -NextRun $nextRun -Outcome "initialized" -Detail "derived from latest complete backup"
}
Write-SchedulerLog "next backup due: $($nextRun.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))"

while ($true) {
    $now = [System.DateTimeOffset]::Now
    if ($now -lt $nextRun) {
        $sleepSeconds = [int][math]::Ceiling(($nextRun - $now).TotalSeconds)
        $sleepSeconds = [math]::Max(1, [math]::Min(60, $sleepSeconds))
        Start-Sleep -Seconds $sleepSeconds
        continue
    }

    $gate = Get-BackupLoadGate
    if (-not $gate.Allowed) {
        $nextRun = [System.DateTimeOffset]::Now.AddMinutes($retryMinutes)
        Write-SchedulerState -NextRun $nextRun -Outcome "deferred" -Detail $gate.Detail
        Write-SchedulerLog "backup deferred: $($gate.Detail); retry at $($nextRun.ToLocalTime().ToString('HH:mm:ss'))"
        continue
    }

    # Pre-commit a short retry. If the scheduler itself dies mid-backup, a restart
    # will not immediately launch a duplicate archive job.
    $nextRun = [System.DateTimeOffset]::Now.AddMinutes($retryMinutes)
    Write-SchedulerState -NextRun $nextRun -Outcome "running" -Detail $gate.Detail
    try {
        & $backupScript -WorldName $script:WorldName -KeepRolling $keepRolling -KeepDaily $keepDaily -KeepWeekly $keepWeekly -MaxTotalSizeGB $maxTotalSizeGB -BackupPrefix $backupPrefix
        if ($script:RunTimes.Count -gt 0) {
            $nextRun = Get-NextBackupSlot -After ([System.DateTimeOffset]::Now) -RunTimes $script:RunTimes -FallbackMinutes $intervalMinutes
        } else {
            $nextRun = [System.DateTimeOffset]::Now.AddMinutes($intervalMinutes)
        }
        Write-SchedulerState -NextRun $nextRun -Outcome "success" -Detail "backup completed"
        Write-SchedulerLog "backup completed; next run $($nextRun.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    } catch {
        $nextRun = [System.DateTimeOffset]::Now.AddMinutes($retryMinutes)
        Write-SchedulerState -NextRun $nextRun -Outcome "failed" -Detail $_.Exception.Message
        Write-SchedulerLog "backup failed: $($_.Exception.Message); retry at $($nextRun.ToLocalTime().ToString('HH:mm:ss'))"
    }
}
