param(
    [string]$WorldName = "world",
    [int]$KeepRolling = 4,
    # Tiered retention. Daily/weekly default to 0, which keeps a flat rolling window.
    [int]$KeepDaily = 0,
    [int]$KeepWeekly = 0,
    [double]$MaxTotalSizeGB = 50,
    [string]$BackupPrefix = "server",
    [switch]$NoRcon,
    [switch]$IgnoreLoadGate,
    # Explicit manual override for the player-count gate. MSPT and recent-backup
    # guards still apply, so an online snapshot cannot bypass all safety checks.
    [switch]$AllowPlayersOnline,
    # Explicit manual override for the current-load gate. The recent-backup guard
    # is intentionally kept even for a forced live snapshot.
    [switch]$IgnoreMsptGate,
    [switch]$SuppressWatchNotification
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root

# Manual callers may pass only -KeepRolling; all omitted retention values use the same
# ops-config.json source as the scheduler. A broken config must never take the backup
# itself down, so the safe defaults above remain in force on parse errors.
$opsConfigPath = Join-Path $Root "tools\ops-config.json"
if (Test-Path -LiteralPath $opsConfigPath) {
    try {
        $schedule = (Get-Content -LiteralPath $opsConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json).backupSchedule
        if ($schedule) {
            $names = @($schedule.PSObject.Properties.Name)
            if (-not $PSBoundParameters.ContainsKey('KeepRolling')    -and $names -contains 'keepRolling')    { $KeepRolling    = [int]$schedule.keepRolling }
            if (-not $PSBoundParameters.ContainsKey('KeepDaily')      -and $names -contains 'keepDaily')      { $KeepDaily      = [int]$schedule.keepDaily }
            if (-not $PSBoundParameters.ContainsKey('KeepWeekly')     -and $names -contains 'keepWeekly')     { $KeepWeekly     = [int]$schedule.keepWeekly }
            if (-not $PSBoundParameters.ContainsKey('MaxTotalSizeGB') -and $names -contains 'maxTotalSizeGB') { $MaxTotalSizeGB = [double]$schedule.maxTotalSizeGB }
        }
    } catch {
        # A broken ops-config.json must never take the backup itself down.
    }
}
if ($KeepRolling -lt 0) { $KeepRolling = 0 }
if ($KeepDaily -lt 0) { $KeepDaily = 0 }
if ($KeepWeekly -lt 0) { $KeepWeekly = 0 }
if ($MaxTotalSizeGB -lt 0) { $MaxTotalSizeGB = 0 }

$worldPath = Join-Path $Root $WorldName
if (-not (Test-Path -LiteralPath $worldPath)) {
    throw "World directory does not exist yet: $worldPath"
}

$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$dayDir = Join-Path $Root ("backups\world\{0:yyyy\\M\\d}" -f (Get-Date))
$safePrefix = $BackupPrefix.Trim()
foreach ($bad in [System.IO.Path]::GetInvalidFileNameChars()) { $safePrefix = $safePrefix.Replace($bad, '-') }
if ([string]::IsNullOrWhiteSpace($safePrefix)) { $safePrefix = "server" }
$zipPath = Join-Path $dayDir ("{0}-{1}-{2}.zip" -f $safePrefix, $WorldName, $stamp)
$partialZipPath = $zipPath + ".partial"
$logPath = Join-Path $Root "backups\backup.log"
New-Item -ItemType Directory -Force $dayDir | Out-Null

function Format-BackupSize {
    param([long]$Bytes)
    if ($Bytes -lt 1MB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    return ("{0:N2} GB" -f ($Bytes / 1GB))
}

function Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-WorldEntryCompression {
    param([System.IO.FileInfo]$File)
    # Fat region files are already zlib-compressed per chunk. Deflate Fastest
    # on them is ~30 MB/s and saves ~2%. Sparse / tiny files still compress.
    $ext = $File.Extension
    if (($ext -eq '.mca' -or $ext -eq '.slvlr') -and $File.Length -ge 1MB) {
        return [System.IO.Compression.CompressionLevel]::NoCompression
    }
    return [System.IO.Compression.CompressionLevel]::Fastest
}

function Invoke-RconRequired {
    param([string]$Command)
    if ($NoRcon) {
        Log "RCON skipped (-NoRcon): $Command"
        return
    }
    & (Join-Path $Root "tools\rcon-command.ps1") -Command $Command | Out-Null
    Log "RCON ok: $Command"
}

function Assert-LiveBackupAllowed {
    if ($NoRcon -or $IgnoreLoadGate) { return }

    $deferWhenPlayersOnline = $true
    $maxMspt = 35.0
    $sampleMaxAgeSeconds = 180
    $recentGuardMinutes = 45
    $opsConfigPath = Join-Path $Root "tools\ops-config.json"
    if (Test-Path -LiteralPath $opsConfigPath -PathType Leaf) {
        try {
            $schedule = (Get-Content -LiteralPath $opsConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json).backupSchedule
            if ($schedule) {
                if ($null -ne $schedule.deferWhenPlayersOnline) { $deferWhenPlayersOnline = [bool]$schedule.deferWhenPlayersOnline }
                if ($null -ne $schedule.maxMsptForBackup) { $maxMspt = [double]$schedule.maxMsptForBackup }
                if ($null -ne $schedule.loadSampleMaxAgeSeconds) { $sampleMaxAgeSeconds = [int]$schedule.loadSampleMaxAgeSeconds }
                if ($null -ne $schedule.recentBackupGuardMinutes) { $recentGuardMinutes = [int]$schedule.recentBackupGuardMinutes }
            }
        } catch {
            throw "Cannot read live-backup safety settings: $($_.Exception.Message)"
        }
    }

    if ($recentGuardMinutes -gt 0) {
        $backupRoot = Join-Path $Root "backups\world"
        $namePattern = '^.+-' + [regex]::Escape($WorldName) + '-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.zip$'
        $latest = Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $namePattern } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            $ageMinutes = ((Get-Date) - $latest.LastWriteTime).TotalMinutes
            if ($ageMinutes -ge 0 -and $ageMinutes -lt $recentGuardMinutes) {
                throw "Recent complete backup is only $([math]::Round($ageMinutes, 1)) minute(s) old; guard=$recentGuardMinutes minute(s)."
            }
        }
    }

    $listReply = ((& (Join-Path $Root "tools\rcon-command.ps1") -Command "list") | Out-String).Trim()
    if ($listReply -notmatch '(?i)there\s+are\s+(\d+)\s+of\s+a\s+max') {
        throw "Cannot parse online count from RCON: $listReply"
    }
    $players = [int]$matches[1]
    if ($deferWhenPlayersOnline -and $players -gt 0 -and -not $AllowPlayersOnline) {
        throw "Live backup deferred because $players player(s) are online."
    }

    if ($maxMspt -gt 0 -and -not $IgnoreMsptGate) {
        $samplePath = Join-Path $Root "logs\perf\samples.jsonl"
        if (Test-Path -LiteralPath $samplePath -PathType Leaf) {
            try {
                $sample = (Get-Content -LiteralPath $samplePath -Tail 1 -Encoding UTF8) | ConvertFrom-Json
                $sampleAt = [System.DateTimeOffset]::Parse([string]$sample.ts)
                $ageSeconds = ([System.DateTimeOffset]::Now - $sampleAt).TotalSeconds
                if ($ageSeconds -ge 0 -and $ageSeconds -le $sampleMaxAgeSeconds -and
                    [bool]$sample.serverUp -and [double]$sample.mspt -gt $maxMspt) {
                    throw "Live backup deferred because MSPT=$([math]::Round([double]$sample.mspt, 2)) exceeds $maxMspt."
                }
            } catch {
                if ($_.Exception.Message -like 'Live backup deferred because MSPT=*') { throw }
                Log "load sample unreadable; player gate still passed: $($_.Exception.Message)"
            }
        }
    }
    Log "live backup gate ok: players=$players allowPlayersOnline=$AllowPlayersOnline ignoreMsptGate=$IgnoreMsptGate"
}

# FileShare.None makes this a process-lifetime mutex without stale-lock problems:
# the marker file may remain, but the OS releases the handle if a process dies.
$lockDir = Join-Path $Root "tmp"
$lockPath = Join-Path $lockDir "backup-world.lock"
New-Item -ItemType Directory -Force $lockDir | Out-Null
$lockStream = $null
try {
    $lockStream = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
} catch [System.IO.IOException] {
    Log "backup skipped: another backup process owns $lockPath"
    throw "Another world backup is already running."
}

try {
    Log "=== backup start ==="
    Log "retention: rolling=$KeepRolling daily=$KeepDaily weekly=$KeepWeekly maxTotal=$MaxTotalSizeGB GB"
    Assert-LiveBackupAllowed

    $saveDisabled = $false
    try {
        if (-not $NoRcon) {
            Invoke-RconRequired "save-off"
            $saveDisabled = $true
            # A failed flush means the on-disk snapshot is not trustworthy. Abort
            # instead of silently producing a green-looking archive.
            Invoke-RconRequired "save-all flush"
        }

    # Build zip file-by-file. CreateEntryFromFile is deliberately NOT used: it
    # opens the source with FileShare.Read, which collides with the write
    # handles the running server keeps cached on region files, so every live
    # .mca raised a sharing violation and silently dropped out of the archive.
    # Opening with FileShare.ReadWrite+Delete coexists with those handles.
    # save-off + save-all flush above guarantee the on-disk bytes are settled.
    $skipCount = 0
    $skipped = @()
    $storedCount = 0
    $fastestCount = 0
    # session.lock is held exclusively and is worthless in a restore.
    # Zero-byte region placeholders are not restore-relevant; Minecraft recreates them.
    $listedFiles = @(
        Get-ChildItem -LiteralPath $worldPath -Recurse -File |
            Where-Object { $_.Name -ne "session.lock" }
    )
    $emptySkipCount = @($listedFiles | Where-Object { $_.Length -le 0 }).Count
    $worldFiles = @($listedFiles | Where-Object { $_.Length -gt 0 })
    if ($worldFiles.Count -lt 1) {
        throw "World contains no backup-eligible files: $worldPath"
    }
    $zipArchive = [System.IO.Compression.ZipFile]::Open(
        $partialZipPath,
        [System.IO.Compression.ZipArchiveMode]::Create
    )
    try {
        foreach ($file in $worldFiles) {
            $relativePath = $file.FullName.Substring($worldPath.Length + 1) -replace '\\', '/'
            $source = $null
            try {
                $source = [System.IO.File]::Open(
                    $file.FullName,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                )
                $level = Get-WorldEntryCompression -File $file
                if ($level -eq [System.IO.Compression.CompressionLevel]::NoCompression) {
                    $storedCount++
                } else {
                    $fastestCount++
                }
                $entry = $zipArchive.CreateEntry($relativePath, $level)
                $entry.LastWriteTime = $file.LastWriteTime
                $target = $entry.Open()
                try {
                    $source.CopyTo($target)
                } finally {
                    $target.Dispose()
                }
            } catch [System.IO.IOException] {
                $skipCount++
                $skipped += $relativePath
                Log "skipped locked file: $relativePath"
            } finally {
                if ($source) { $source.Dispose() }
            }
        }
    } finally {
        $zipArchive.Dispose()
    }
    Log "archive write: stored=$storedCount fastest=$fastestCount skippedEmpty=$emptySkipCount"

    # Re-open the completed temporary archive before publishing it. A .partial file
    # is intentionally invisible to backup watchers and restore tooling.
    $verifyArchive = [System.IO.Compression.ZipFile]::OpenRead($partialZipPath)
    try {
        if ($verifyArchive.Entries.Count -lt 1) {
            throw "Temporary archive contains no entries."
        }
        $expectedEntries = $worldFiles.Count - $skipCount
        if ($verifyArchive.Entries.Count -ne $expectedEntries) {
            throw "Archive entry mismatch: expected=$expectedEntries actual=$($verifyArchive.Entries.Count)."
        }
        Log "archive verification ok: $($verifyArchive.Entries.Count) entries"
    } finally {
        $verifyArchive.Dispose()
    }

    # A backup missing region files restores as a hole in the world, so make an
    # incomplete archive impossible to mistake for a good one.
    if ($skipCount -gt 0) {
        $incompletePath = [System.IO.Path]::ChangeExtension($zipPath, $null).TrimEnd('.') + "-INCOMPLETE.zip"
        if (Test-Path -LiteralPath $incompletePath) { throw "Archive target already exists: $incompletePath" }
        Move-Item -LiteralPath $partialZipPath -Destination $incompletePath
        $zipPath = $incompletePath
        Log "WARNING: $skipCount file(s) could not be read; archive marked INCOMPLETE"
    } else {
        if (Test-Path -LiteralPath $zipPath) { throw "Archive target already exists: $zipPath" }
        Move-Item -LiteralPath $partialZipPath -Destination $zipPath
    }

    $size = (Get-Item -LiteralPath $zipPath).Length
    $displaySize = Format-BackupSize -Bytes $size
    Log "backup created: $zipPath ($displaySize, $skipCount locked file(s) skipped)"
    if ($skipCount -gt 0) {
        throw "Backup is incomplete because $skipCount file(s) could not be read."
    }
    if ($SuppressWatchNotification) {
        New-Item -ItemType Directory -Force (Join-Path $Root "tmp") | Out-Null
        $markerPath = Join-Path $Root "tmp\manual-backup-suppress.txt"
        Add-Content -LiteralPath $markerPath -Value $zipPath -Encoding UTF8
    }
    } finally {
        if ($saveDisabled) {
            # Never leave the server in save-off mode, even when compression fails.
            Invoke-RconRequired "save-on"
        }
    }

if ($KeepRolling -gt 0 -or $MaxTotalSizeGB -gt 0) {
    # Retention counts every archive this tool made for THIS world, not just ones
    # carrying the current prefix. Renaming the prefix (e.g. dropping an old season
    # name) otherwise strands every older archive outside the rolling window, where
    # it is never pruned and silently eats disk forever. The generated name is always
    # <prefix>-<world>-<timestamp>.zip, so matching that shape scopes the sweep to our
    # own files and leaves anything a human dropped in the folder untouched.
    $namePattern = '^.+-' + [regex]::Escape($WorldName) + '-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(-INCOMPLETE)?\.zip$'
    $all = @(Get-ChildItem -LiteralPath (Join-Path $Root "backups\world") -Recurse -File -Filter '*.zip' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $namePattern } | Sort-Object LastWriteTime)
    # Retention is counted over complete archives only. If incomplete ones were
    # included, a bad streak could evict every good backup off the shelf.
    $complete = @($all | Where-Object { $_.Name -notlike "*-INCOMPLETE.zip" })
    $incomplete = @($all | Where-Object { $_.Name -like "*-INCOMPLETE.zip" })

    # Tiered ("grandfather-father-son") retention. A flat window spends the whole
    # disk budget on the newest archives, so damage noticed later may have no restore
    # point left. Keeping everything inside a short recent window, then one per day,
    # then one per week, extends restore reach without exposing deployment-specific
    # world sizes or retention measurements in the public toolkit.
    $newestFirst = @($complete | Sort-Object LastWriteTime -Descending)
    $keep = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in @($newestFirst | Select-Object -First $KeepRolling)) {
        [void]$keep.Add($f.FullName)
    }
    # Bucket by local calendar day / ISO week, keeping the newest archive in each of
    # the most recent N buckets. System.Globalization.ISOWeek is .NET Core only, so
    # the week bucket is the date of that week's Monday (DayOfWeek: Sunday=0).
    $tiers = @(
        @{ Count = $KeepDaily;  Key = { $_.LastWriteTime.ToString('yyyy-MM-dd') } },
        @{ Count = $KeepWeekly; Key = { $_.LastWriteTime.Date.AddDays(-((([int]$_.LastWriteTime.DayOfWeek) + 6) % 7)).ToString('yyyy-MM-dd') } }
    )
    foreach ($tier in $tiers) {
        if ($tier.Count -le 0) { continue }
        $newestFirst |
            Group-Object -Property $tier.Key |
            Sort-Object Name -Descending |
            Select-Object -First $tier.Count |
            ForEach-Object {
                $newestInBucket = @($_.Group | Sort-Object LastWriteTime -Descending)[0]
                [void]$keep.Add($newestInBucket.FullName)
            }
    }

    $remove = @()
    $removePaths = New-Object 'System.Collections.Generic.HashSet[string]'
    $capRemovalPaths = New-Object 'System.Collections.Generic.HashSet[string]'
    # A retention pass that keeps nothing is a bug, not an instruction to wipe the
    # shelf, so refuse to prune rather than destroy every backup.
    if ($keep.Count -lt 1 -and $complete.Count -gt 0) {
        Log "WARNING: retention keep-set came out empty; skipping prune of $($complete.Count) archive(s)"
    } else {
        foreach ($f in @($complete | Where-Object { -not $keep.Contains($_.FullName) })) {
            if ($removePaths.Add($f.FullName)) { $remove += $f }
        }
    }
    if ($incomplete.Count -gt 3) {
        foreach ($f in @($incomplete | Select-Object -First ($incomplete.Count - 3))) {
            if ($removePaths.Add($f.FullName)) { $remove += $f }
        }
    }

    # Apply the hard shelf-size cap after count/tier selection. Failed archives are
    # discarded before good archives; the newest complete backup is always protected
    # so a single archive larger than the cap does not erase the last restore point.
    if ($MaxTotalSizeGB -gt 0) {
        $maxTotalBytes = [long][math]::Floor($MaxTotalSizeGB * 1GB)
        $remaining = @($all | Where-Object { -not $removePaths.Contains($_.FullName) })
        $remainingComplete = @($remaining | Where-Object { $_.Name -notlike "*-INCOMPLETE.zip" })
        $remainingIncomplete = @($remaining | Where-Object { $_.Name -like "*-INCOMPLETE.zip" })
        $newestComplete = $remainingComplete | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        [long]$totalBytes = 0
        foreach ($f in $remaining) { $totalBytes += [long]$f.Length }

        if ($totalBytes -gt $maxTotalBytes) {
            Log "retention size before cap: $(Format-BackupSize -Bytes $totalBytes) / $(Format-BackupSize -Bytes $maxTotalBytes)"
            $capCandidates = @($remainingIncomplete | Sort-Object LastWriteTime) + @($remainingComplete | Sort-Object LastWriteTime)
            foreach ($f in $capCandidates) {
                if ($totalBytes -le $maxTotalBytes) { break }
                if ($newestComplete -and $f.FullName -eq $newestComplete.FullName) {
                    Log "WARNING: newest complete backup exceeds remaining size cap; preserving it: $($f.FullName)"
                    continue
                }
                if ($removePaths.Add($f.FullName)) {
                    [void]$capRemovalPaths.Add($f.FullName)
                    $remove += $f
                    $totalBytes -= [long]$f.Length
                }
            }
            if ($totalBytes -gt $maxTotalBytes) {
                Log "WARNING: backup shelf remains above cap because the newest complete backup is larger than the configured limit"
            }
        }
    }
    foreach ($f in $remove) {
        Remove-Item -LiteralPath $f.FullName -Force
        if ($capRemovalPaths.Contains($f.FullName)) {
            Log "pruned for total-size cap: $($f.FullName)"
        } else {
            Log "pruned old backup: $($f.FullName)"
        }
    }
}

Log "=== backup done ==="
} finally {
    if ($lockStream) { $lockStream.Dispose() }
}
