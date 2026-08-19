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

function ConvertTo-DateTimeOffsetOrNull {
    param([object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        return [System.DateTimeOffset]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
    } catch {
        return $null
    }
}

function Format-StateDateTime {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    try { return ([System.DateTimeOffset]$Value).UtcDateTime.ToString('o') } catch { return $null }
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
        [string]$Detail = "",
        [int]$OnlinePlayers = -1,
        [string]$ActivityMode = "",
        [string]$NextAction = "",
        [object]$EmptySinceUtc = $null,
        [object]$NextBackupUtc = $null
    )
    $stateDir = Split-Path -Parent $script:StatePath
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $tempPath = $script:StatePath + ".tmp-" + $PID
    $payload = [ordered]@{
        schema = 2
        nextRunUtc = $NextRun.UtcDateTime.ToString("o")
        updatedUtc = [System.DateTime]::UtcNow.ToString("o")
        lastOutcome = $Outcome
        lastDetail = $Detail
        onlinePlayers = $OnlinePlayers
        activityMode = $ActivityMode
        nextAction = $NextAction
        emptySinceUtc = (Format-StateDateTime $EmptySinceUtc)
        nextBackupUtc = (Format-StateDateTime $NextBackupUtc)
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($tempPath, $payload, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $script:StatePath -Force
}

function Read-SchedulerState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $next = ConvertTo-DateTimeOffsetOrNull $state.nextRunUtc
        $nextBackup = ConvertTo-DateTimeOffsetOrNull $state.nextBackupUtc
        $emptySince = ConvertTo-DateTimeOffsetOrNull $state.emptySinceUtc
        $lastPlayers = -1
        if ($state.PSObject.Properties.Name -contains 'onlinePlayers') {
            try { $lastPlayers = [int]$state.onlinePlayers } catch { $lastPlayers = -1 }
        }
        return [pscustomobject]@{
            NextRun = $next
            LastOutcome = [string]$state.lastOutcome
            LastPlayerCount = $lastPlayers
            ActivityMode = if ($state.PSObject.Properties.Name -contains 'activityMode') { [string]$state.activityMode } else { '' }
            NextAction = if ($state.PSObject.Properties.Name -contains 'nextAction') { [string]$state.nextAction } else { '' }
            EmptySince = $emptySince
            NextBackup = $nextBackup
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

function Get-PlayerSnapshot {
    $rconScript = Join-Path $Root "tools\rcon-command.ps1"
    try {
        $listReply = ((& $rconScript -Command "list") | Out-String).Trim()
    } catch {
        return [pscustomobject]@{
            Success = $false
            Players = -1
            Detail = "RCON list failed: $($_.Exception.Message)"
        }
    }

    if ($listReply -notmatch '(?i)there\s+are\s+(\d+)\s+of\s+a\s+max') {
        return [pscustomobject]@{
            Success = $false
            Players = -1
            Detail = "cannot parse online count: $listReply"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Players = [int]$matches[1]
        Detail = "players=$([int]$matches[1])"
    }
}

function Get-BackupLoadGate {
    param(
        [int]$KnownPlayers = -1
    )
    $rconScript = Join-Path $Root "tools\rcon-command.ps1"
    $players = $KnownPlayers
    if ($players -lt 0) {
        $snapshot = Get-PlayerSnapshot
        if (-not $snapshot.Success) {
            return [pscustomobject]@{ Allowed = $false; Players = -1; Detail = $snapshot.Detail }
        }
        $players = $snapshot.Players
    }
    if ($script:DeferWhenPlayersOnline -and $players -gt 0) {
        return [pscustomobject]@{ Allowed = $false; Players = $players; Detail = "players online=$players" }
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
                        Players = $players
                        Detail = "MSPT=$([math]::Round([double]$sample.mspt, 2)) exceeds $($script:MaxMsptForBackup)"
                    }
                }
            } catch {
                Write-SchedulerLog "load sample unreadable; player gate still applies: $($_.Exception.Message)"
            }
        }
    }

    return [pscustomobject]@{ Allowed = $true; Players = $players; Detail = "players=$players load-ok" }
}

function Write-ActivityStateSnapshot {
    param(
        [Parameter(Mandatory = $true)][System.DateTimeOffset]$NextPlayerPoll,
        [object]$NextBackup = $null,
        [Parameter(Mandatory = $true)][string]$Mode,
        [int]$OnlinePlayers = -1,
        [object]$EmptySince = $null,
        [string]$Outcome = "observed",
        [string]$Detail = ""
    )

    $nextRun = $NextPlayerPoll
    $nextAction = "player-poll"
    if ($null -ne $NextBackup) {
        $backupAt = [System.DateTimeOffset]$NextBackup
        # nextRunUtc describes the next backup action for an active/pending
        # state; player polling remains an internal wake-up and is represented
        # by nextAction=player-poll only in idle mode.
        $nextRun = $backupAt
        if ($Mode -eq 'offline-final-pending') {
            $nextAction = 'offline-final-backup'
        } else {
            $nextAction = 'active-backup'
        }
    }

    Write-SchedulerState `
        -NextRun $nextRun `
        -Outcome $Outcome `
        -Detail $Detail `
        -OnlinePlayers $OnlinePlayers `
        -ActivityMode $Mode `
        -NextAction $nextAction `
        -EmptySinceUtc $EmptySince `
        -NextBackupUtc $NextBackup
}

function Get-NextActiveBackupDue {
    param(
        [Parameter(Mandatory = $true)][System.DateTimeOffset]$Now,
        [Parameter(Mandatory = $true)][int]$IntervalMinutes,
        [Parameter(Mandatory = $true)][int]$StartupDelayMinutes,
        [object]$ExistingDue = $null
    )

    if ($null -ne $ExistingDue) {
        $existing = [System.DateTimeOffset]$ExistingDue
        if ($existing -gt $Now) { return $existing }
    }

    $latest = Get-LatestCompleteBackup
    if ($latest) {
        $latestAt = [System.DateTimeOffset]$latest.LastWriteTimeUtc
        $candidate = $latestAt.AddMinutes($IntervalMinutes)
        if ($candidate -gt $Now) { return $candidate }

        # A player has just resumed after a long idle period. Give the server a
        # short settling window, then create a fresh point instead of waiting
        # another full active interval.
        $leadMinutes = [Math]::Min(5, [Math]::Max(1, $StartupDelayMinutes))
        return $Now.AddMinutes($leadMinutes)
    }

    return $Now.AddMinutes([Math]::Max(1, $StartupDelayMinutes))
}

function Start-ActivityAwareScheduler {
    param(
        [Parameter(Mandatory = $true)][int]$ActiveIntervalMinutes,
        [Parameter(Mandatory = $true)][int]$StartupDelayMinutes,
        [Parameter(Mandatory = $true)][int]$RetryMinutes,
        [Parameter(Mandatory = $true)][int]$PlayerPollMinutes,
        [Parameter(Mandatory = $true)][int]$OfflineFinalDelayMinutes,
        [Parameter(Mandatory = $true)][int]$OfflineFinalMinAgeMinutes,
        [Parameter(Mandatory = $true)][int]$KeepRolling,
        [Parameter(Mandatory = $true)][int]$KeepDaily,
        [Parameter(Mandatory = $true)][int]$KeepWeekly,
        [Parameter(Mandatory = $true)][double]$MaxTotalSizeGB,
        [Parameter(Mandatory = $true)][string]$WorldName,
        [Parameter(Mandatory = $true)][string]$BackupPrefix,
        [Parameter(Mandatory = $true)][string]$BackupScript
    )

    $state = Read-SchedulerState
    $now = [System.DateTimeOffset]::Now
    $stateMode = if ($state) { [string]$state.ActivityMode } else { '' }
    $statePlayers = if ($state) { [int]$state.LastPlayerCount } else { -1 }
    $emptySince = if ($state) { $state.EmptySince } else { $null }
    $onlinePlayers = -1
    $mode = 'unknown'
    $nextBackup = $null
    $nextPlayerPoll = $now
    $lastPlayerError = ''

    Write-SchedulerLog "activity-aware scheduler started: active=${ActiveIntervalMinutes}m finalDelay=${OfflineFinalDelayMinutes}m finalMinAge=${OfflineFinalMinAgeMinutes}m playerPoll=${PlayerPollMinutes}m startupDelay=${StartupDelayMinutes}m retry=${RetryMinutes}m retention=${KeepRolling}x/${MaxTotalSizeGB}GB"

    $initialSnapshot = Get-PlayerSnapshot
    if ($initialSnapshot.Success) {
        $onlinePlayers = $initialSnapshot.Players
        if ($onlinePlayers -gt 0) {
            $mode = 'active'
            if ($state -and $state.ActivityMode -eq 'active' -and $state.NextBackup -and $state.NextBackup -gt $now) {
                $nextBackup = $state.NextBackup
            } elseif ($state -and [string]::IsNullOrWhiteSpace($state.ActivityMode) -and $state.NextRun -and $state.NextRun -gt $now) {
                # Migrate the previous interval-only state without creating an
                # extra backup merely because the scheduler was restarted.
                $nextBackup = $state.NextRun
            } else {
                $nextBackup = Get-NextActiveBackupDue -Now $now -IntervalMinutes $ActiveIntervalMinutes -StartupDelayMinutes $StartupDelayMinutes
            }
        } else {
            $wasActive = ($statePlayers -gt 0) -or ($stateMode -in @('active', 'offline-final-pending'))
            if ($wasActive) {
                $mode = 'offline-final-pending'
                if ($null -eq $emptySince) { $emptySince = $now }
                $nextBackup = $emptySince.AddMinutes($OfflineFinalDelayMinutes)
                if ($nextBackup -lt $now) { $nextBackup = $now }
            } else {
                $latest = Get-LatestCompleteBackup
                if (-not $latest) {
                    # A completely new server still needs its first recovery
                    # point, even if nobody is online yet.
                    $mode = 'offline-final-pending'
                    $emptySince = $now
                    $nextBackup = $now.AddMinutes([Math]::Max(1, $StartupDelayMinutes))
                } else {
                    $mode = 'idle'
                    $nextBackup = $null
                }
            }
        }
        $nextPlayerPoll = $now.AddMinutes($PlayerPollMinutes)
        Write-SchedulerLog "activity state initialized: players=$onlinePlayers mode=$mode"
        Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'initialized' -Detail "activity-aware state initialized"
    } else {
        $onlinePlayers = $statePlayers
        $mode = if ([string]::IsNullOrWhiteSpace($stateMode)) { 'unknown' } else { $stateMode }
        if ($state -and $state.NextBackup) {
            $nextBackup = $state.NextBackup
        } elseif ($state -and $state.NextRun -and $mode -ne 'idle') {
            $nextBackup = $state.NextRun
        } elseif ($mode -ne 'idle') {
            $nextBackup = $now.AddMinutes($RetryMinutes)
        }
        $nextPlayerPoll = $now.AddMinutes($PlayerPollMinutes)
        $lastPlayerError = $initialSnapshot.Detail
        Write-SchedulerLog "activity state pending: $($initialSnapshot.Detail); player count will retry"
        Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'deferred' -Detail $initialSnapshot.Detail
    }

    while ($true) {
        $now = [System.DateTimeOffset]::Now
        $wakeAt = $nextPlayerPoll
        if ($null -ne $nextBackup -and ([System.DateTimeOffset]$nextBackup) -lt $wakeAt) {
            $wakeAt = [System.DateTimeOffset]$nextBackup
        }
        if ($now -lt $wakeAt) {
            $sleepSeconds = [int][Math]::Ceiling(($wakeAt - $now).TotalSeconds)
            $sleepSeconds = [Math]::Max(1, [Math]::Min(60, $sleepSeconds))
            Start-Sleep -Seconds $sleepSeconds
            continue
        }

        $snapshot = $null
        $backupDue = ($null -ne $nextBackup -and $now -ge ([System.DateTimeOffset]$nextBackup))
        if ($now -ge $nextPlayerPoll -or $backupDue) {
            $snapshot = Get-PlayerSnapshot
            $nextPlayerPoll = $now.AddMinutes($PlayerPollMinutes)
            if (-not $snapshot.Success) {
                if ($snapshot.Detail -ne $lastPlayerError) {
                    Write-SchedulerLog "player poll unavailable: $($snapshot.Detail)"
                    $lastPlayerError = $snapshot.Detail
                }
                if ($backupDue) {
                    $nextBackup = $now.AddMinutes($RetryMinutes)
                    Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'deferred' -Detail $snapshot.Detail
                }
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($lastPlayerError)) {
                Write-SchedulerLog "player poll recovered"
                $lastPlayerError = ''
            }
        }

        if ($snapshot -and $snapshot.Success) {
            $oldPlayers = $onlinePlayers
            $onlinePlayers = $snapshot.Players
            if ($onlinePlayers -gt 0) {
                if ($mode -ne 'active' -or $oldPlayers -le 0) {
                    if ($oldPlayers -eq 0 -or $mode -in @('idle', 'offline-final-pending')) {
                        Write-SchedulerLog "player activity resumed: players=$onlinePlayers"
                    }
                    $mode = 'active'
                    $emptySince = $null
                    $nextBackup = Get-NextActiveBackupDue -Now $now -IntervalMinutes $ActiveIntervalMinutes -StartupDelayMinutes $StartupDelayMinutes
                }
            } elseif ($mode -eq 'active' -or $oldPlayers -gt 0) {
                $mode = 'offline-final-pending'
                if ($null -eq $emptySince) { $emptySince = $now }
                $nextBackup = $emptySince.AddMinutes($OfflineFinalDelayMinutes)
                if ($nextBackup -lt $now) { $nextBackup = $now }
                Write-SchedulerLog "last player left: final offline backup due $($nextBackup.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))"
            } elseif ($mode -eq 'unknown') {
                $latest = Get-LatestCompleteBackup
                if (-not $latest) {
                    $mode = 'offline-final-pending'
                    $emptySince = $now
                    if ($null -eq $nextBackup -or $nextBackup -lt $now) {
                        $nextBackup = $now.AddMinutes([Math]::Max(1, $StartupDelayMinutes))
                    }
                } else {
                    $mode = 'idle'
                    $nextBackup = $null
                }
            } elseif ($mode -eq 'idle') {
                $nextBackup = $null
            }

            Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'observed' -Detail "players=$onlinePlayers mode=$mode"
        }

        $now = [System.DateTimeOffset]::Now
        $backupDue = ($null -ne $nextBackup -and $now -ge ([System.DateTimeOffset]$nextBackup))
        if (-not $backupDue) { continue }

        if ($onlinePlayers -gt 0 -and $mode -eq 'active') {
            $gate = Get-BackupLoadGate -KnownPlayers $onlinePlayers
            if (-not $gate.Allowed) {
                $nextBackup = $now.AddMinutes($RetryMinutes)
                Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'deferred' -Detail $gate.Detail
                Write-SchedulerLog "active backup deferred: $($gate.Detail); retry at $($nextBackup.ToLocalTime().ToString('HH:mm:ss'))"
                continue
            }

            $nextBackup = $now.AddMinutes($RetryMinutes)
            Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'running' -Detail $gate.Detail
            try {
                & $BackupScript -WorldName $WorldName -KeepRolling $KeepRolling -KeepDaily $KeepDaily -KeepWeekly $KeepWeekly -MaxTotalSizeGB $MaxTotalSizeGB -BackupPrefix $BackupPrefix
                $nextBackup = [System.DateTimeOffset]::Now.AddMinutes($ActiveIntervalMinutes)
                Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'success' -Detail 'active backup completed'
                Write-SchedulerLog "active backup completed; next active backup $($nextBackup.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))"
            } catch {
                $nextBackup = [System.DateTimeOffset]::Now.AddMinutes($RetryMinutes)
                Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'failed' -Detail $_.Exception.Message
                Write-SchedulerLog "active backup failed: $($_.Exception.Message); retry at $($nextBackup.ToLocalTime().ToString('HH:mm:ss'))"
            }
            continue
        }

        if ($onlinePlayers -eq 0 -and $mode -eq 'offline-final-pending') {
            $latest = Get-LatestCompleteBackup
            $skipFinal = $false
            if ($latest -and $OfflineFinalMinAgeMinutes -gt 0) {
                $ageMinutes = ((Get-Date) - $latest.LastWriteTime).TotalMinutes
                if ($ageMinutes -ge 0 -and $ageMinutes -lt $OfflineFinalMinAgeMinutes) {
                    $skipFinal = $true
                    Write-SchedulerLog "offline final backup skipped: latest complete backup is $([Math]::Round($ageMinutes, 1)) minute(s) old; entering idle"
                }
            }
            if ($skipFinal) {
                $mode = 'idle'
                $nextBackup = $null
                Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'success' -Detail 'offline final backup not needed; recent complete backup exists'
                continue
            }

            $gate = Get-BackupLoadGate -KnownPlayers 0
            if (-not $gate.Allowed) {
                $nextBackup = $now.AddMinutes($RetryMinutes)
                Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'deferred' -Detail $gate.Detail
                Write-SchedulerLog "offline final backup deferred: $($gate.Detail); retry at $($nextBackup.ToLocalTime().ToString('HH:mm:ss'))"
                continue
            }

            $nextBackup = $now.AddMinutes($RetryMinutes)
            Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'running' -Detail $gate.Detail
            try {
                & $BackupScript -WorldName $WorldName -KeepRolling $KeepRolling -KeepDaily $KeepDaily -KeepWeekly $KeepWeekly -MaxTotalSizeGB $MaxTotalSizeGB -BackupPrefix $BackupPrefix
                $mode = 'idle'
                $nextBackup = $null
                Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'success' -Detail 'offline final backup completed; entering idle'
                Write-SchedulerLog "offline final backup completed; idle mode entered"
            } catch {
                if ($_.Exception.Message -like 'Recent complete backup is only*') {
                    $mode = 'idle'
                    $nextBackup = $null
                    Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'success' -Detail 'offline final backup skipped by recent-backup guard; entering idle'
                    Write-SchedulerLog "offline final backup skipped by recent-backup guard; idle mode entered"
                } else {
                    $nextBackup = [System.DateTimeOffset]::Now.AddMinutes($RetryMinutes)
                    Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'failed' -Detail $_.Exception.Message
                    Write-SchedulerLog "offline final backup failed: $($_.Exception.Message); retry at $($nextBackup.ToLocalTime().ToString('HH:mm:ss'))"
                }
            }
            continue
        }

        # A stale due time can only remain when the state was migrated from the
        # old interval-only scheduler. Do not run it without a known activity
        # state; re-enter the idle poll loop instead.
        $nextBackup = $null
        Write-ActivityStateSnapshot -NextPlayerPoll $nextPlayerPoll -NextBackup $nextBackup -Mode $mode -OnlinePlayers $onlinePlayers -EmptySince $emptySince -Outcome 'observed' -Detail 'no backup action for current activity state'
    }
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

$script:ActivityAware = $false
if ($config.backupSchedule.PSObject.Properties['activityAware']) {
    $script:ActivityAware = [bool]$config.backupSchedule.activityAware
}
$activeIntervalMinutes = $intervalMinutes
if ($config.backupSchedule.PSObject.Properties['activeIntervalMinutes']) {
    $activeIntervalMinutes = [int]$config.backupSchedule.activeIntervalMinutes
}
if ($activeIntervalMinutes -lt 30) { $activeIntervalMinutes = 30 }

$playerPollMinutes = 1
if ($config.backupSchedule.PSObject.Properties['playerPollMinutes']) {
    $playerPollMinutes = [int]$config.backupSchedule.playerPollMinutes
}
if ($playerPollMinutes -lt 1) { $playerPollMinutes = 1 }

$offlineFinalDelayMinutes = 2
if ($config.backupSchedule.PSObject.Properties['offlineFinalDelayMinutes']) {
    $offlineFinalDelayMinutes = [int]$config.backupSchedule.offlineFinalDelayMinutes
}
if ($offlineFinalDelayMinutes -lt 1) { $offlineFinalDelayMinutes = 1 }

$offlineFinalMinAgeMinutes = 20
if ($config.backupSchedule.PSObject.Properties['offlineFinalMinAgeMinutes']) {
    $offlineFinalMinAgeMinutes = [int]$config.backupSchedule.offlineFinalMinAgeMinutes
}
if ($offlineFinalMinAgeMinutes -lt 0) { $offlineFinalMinAgeMinutes = 0 }

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

if ($script:ActivityAware) {
    Start-ActivityAwareScheduler `
        -ActiveIntervalMinutes $activeIntervalMinutes `
        -StartupDelayMinutes $startupDelayMinutes `
        -RetryMinutes $retryMinutes `
        -PlayerPollMinutes $playerPollMinutes `
        -OfflineFinalDelayMinutes $offlineFinalDelayMinutes `
        -OfflineFinalMinAgeMinutes $offlineFinalMinAgeMinutes `
        -KeepRolling $keepRolling `
        -KeepDaily $keepDaily `
        -KeepWeekly $keepWeekly `
        -MaxTotalSizeGB $maxTotalSizeGB `
        -WorldName $script:WorldName `
        -BackupPrefix $backupPrefix `
        -BackupScript $backupScript
    return
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
