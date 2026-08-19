@echo off
setlocal EnableExtensions
chcp 65001 >nul
rem ============================================================
rem Portable player sync launcher (maintenance notes)
rem 1) Keep CRLF line endings + UTF-8 without BOM. LF endings make
rem    cmd desync its byte reader on multibyte content and crash.
rem 2) All Chinese user-facing text must go through powershell
rem    Write-Host; cmd echo garbles CJK under chcp 65001.
rem 3) Keep every cmd-parsed line, rem included, ASCII-only:
rem    Chinese in rem lines also desyncs cmd under chcp 65001 and
rem    part of the comment gets executed as a command.
rem 4) Bootstrap: copy self to TEMP first, because sync may
rem    overwrite this running script and corrupt parsing.
rem 5) Inline powershell uses direct HttpWebRequest and must set
rem    ProgressPreference=SilentlyContinue: the PS5.1 progress bar
rem    redraw overlaps CJK glyphs under chcp 65001.
rem ============================================================
if defined PORTABLE_SYNC_BOOTSTRAPPED goto :Main
rem Wrapper uses delayed expansion to return the child exit code on one
rem line; everything after cmd /c must stay on that same line because
rem this file may get overwritten by the sync right afterwards.
setlocal EnableDelayedExpansion
set "PORTABLE_SYNC_HOME=%~dp0"
set "PORTABLE_SYNC_BOOTSTRAPPED=1"
set "_PSYNC_TMP=%TEMP%\portable-sync-run-%RANDOM%%RANDOM%.bat"
copy /y "%~f0" "%_PSYNC_TMP%" >nul 2>nul
if not exist "%_PSYNC_TMP%" goto :Main
cmd /c ""%_PSYNC_TMP%"" & set "_PSYNC_CODE=!ERRORLEVEL!" & del "%_PSYNC_TMP%" >nul 2>nul & exit /b !_PSYNC_CODE!

:Main
if defined PORTABLE_SYNC_HOME (cd /d "%PORTABLE_SYNC_HOME%") else (cd /d "%~dp0")
set "PORTABLE_SCRIPT_DIR=%CD%"
set "PORTABLE_INSTANCE_DIR=%CD%"
for %%I in ("%PORTABLE_SCRIPT_DIR%") do if /I "%%~nxI"=="_updater" set "PORTABLE_INSTANCE_DIR=%%~dpI"
for %%I in ("%PORTABLE_INSTANCE_DIR%") do set "PORTABLE_INSTANCE_DIR=%%~fI"
rem Strip trailing backslash: %%~dp keeps it, and a trailing backslash before
rem the closing quote in -InstanceDir "..." escapes the quote inside powershell
rem argument parsing, injecting a literal quote into the path (Illegal characters).
if "%PORTABLE_INSTANCE_DIR:~-1%"=="\" set "PORTABLE_INSTANCE_DIR=%PORTABLE_INSTANCE_DIR:~0,-1%"

if exist "%PORTABLE_INSTANCE_DIR%\player-update-generic.ps1" if /I not "%PORTABLE_SCRIPT_DIR%"=="%PORTABLE_INSTANCE_DIR%" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=Join-Path $env:PORTABLE_SCRIPT_DIR 'player-update-generic.ps1';$r=Join-Path $env:PORTABLE_INSTANCE_DIR 'player-update-generic.ps1';$t=$null;$e=$null;if((Test-Path -LiteralPath $s -PathType Leaf) -and (Test-Path -LiteralPath $r -PathType Leaf)){[System.Management.Automation.Language.Parser]::ParseFile($s,[ref]$t,[ref]$e)|Out-Null;if($e.Count -gt 0){$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($r,[ref]$t,[ref]$e)|Out-Null;if($e.Count -eq 0){$tmp=$s+'.repair';Copy-Item -LiteralPath $r -Destination $tmp -Force;Move-Item -LiteralPath $tmp -Destination $s -Force;Write-Host '[repair] restored invalid updater from package root.'}}}"

cls
set "PORTABLE_BOOTSTRAP_REFRESH=%PORTABLE_INSTANCE_DIR%\_updater\portable-bootstrap-refresh.ps1"
if not exist "%PORTABLE_BOOTSTRAP_REFRESH%" set "PORTABLE_BOOTSTRAP_REFRESH=%PORTABLE_SCRIPT_DIR%\portable-bootstrap-refresh.ps1"
if exist "%PORTABLE_BOOTSTRAP_REFRESH%" goto :PortableBootstrapRefresh
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Continue'; $ProgressPreference='SilentlyContinue'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}; function Save-DirectFile { param([string]$Url, [string]$Path, [int]$TimeoutSec = 25); $target=$Url; $hostHeader=$null; try { $uri=[Uri]$Url; if($uri.HostNameType -eq [UriHostNameType]::Dns){ $ipv4=[Net.Dns]::GetHostAddresses($uri.Host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1; if($ipv4){ $b=New-Object UriBuilder $uri; $b.Host=$ipv4.IPAddressToString; $target=$b.Uri.AbsoluteUri; $hostHeader=$uri.Host } } } catch {}; $req=[System.Net.HttpWebRequest]::Create($target); if($hostHeader){ $req.Host=$hostHeader }; $req.Proxy=$null; $req.Timeout=[Math]::Max(1000,$TimeoutSec*1000); $req.ReadWriteTimeout=[Math]::Max(1000,$TimeoutSec*1000); $req.UserAgent='portable-server-kit-bootstrap/1.0'; } $resp=$null; $inputStream=$null; $outputStream=$null; try { $resp=$req.GetResponse(); $inputStream=$resp.GetResponseStream(); $outputStream=[System.IO.File]::Open($Path,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None); $inputStream.CopyTo($outputStream) } finally { if($outputStream){$outputStream.Dispose()}; if($inputStream){$inputStream.Dispose()}; if($resp){$resp.Dispose()} } }; Write-Host '============================================================'; Write-Host '  便携 Minecraft 玩家同步'; Write-Host '============================================================'; Write-Host ('实例目录: ' + $env:PORTABLE_INSTANCE_DIR); Write-Host ''; Write-Host '[更新器] 正在从更新源刷新同步脚本（直连模式）...'; $scriptDir=$env:PORTABLE_SCRIPT_DIR; $instanceDir=[System.IO.Path]::GetFullPath($env:PORTABLE_INSTANCE_DIR); $u=$env:PORTABLE_MANIFEST_URL; foreach($p in @((Join-Path $instanceDir 'UPDATE-URL.txt'),(Join-Path $instanceDir 'PORTABLE-UPDATE-URL.txt'),(Join-Path $instanceDir 'TFCR-update-url.txt'),(Join-Path $scriptDir 'UPDATE-URL.txt'),(Join-Path $scriptDir 'PORTABLE-UPDATE-URL.txt'),(Join-Path $scriptDir 'TFCR-update-url.txt'))){ if([string]::IsNullOrWhiteSpace($u) -and (Test-Path -LiteralPath $p -PathType Leaf)){ $u=(Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim() } }; if(-not [string]::IsNullOrWhiteSpace($u)){ $base=$u.Substring(0,$u.LastIndexOf('/')); foreach($name in @('player-update-generic.ps1','player-update-generic.py','portable-stage-daemon.ps1','macOS-sync.command','Windows-sync.bat')){ $url=$base + '/_updater/' + [Uri]::EscapeDataString($name) + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); $out=Join-Path $scriptDir $name; $tmp=Join-Path ([System.IO.Path]::GetTempPath()) ('portable-refresh-' + [System.Guid]::NewGuid().ToString('N') + '.tmp'); try { $done=$false; for($attempt=1;$attempt -le 3 -and -not $done;$attempt++){ try { Save-DirectFile -Url $url -Path $tmp -TimeoutSec 25; $done=$true } catch { if($attempt -lt 3){ Start-Sleep -Seconds 2 } else { throw } } }; $newHash=(Get-FileHash -LiteralPath $tmp -Algorithm SHA1).Hash; $oldHash=''; if(Test-Path -LiteralPath $out -PathType Leaf){ $oldHash=(Get-FileHash -LiteralPath $out -Algorithm SHA1).Hash }; if($newHash -ne $oldHash){ Move-Item -LiteralPath $tmp -Destination $out -Force; Write-Host ('[更新器] 已刷新 ' + $name) } else { Write-Host ('[更新器] 已是最新 ' + $name) } } catch { Write-Host ('[更新器] 跳过自刷新 ' + $name + ': ' + $_.Exception.Message) } finally { if(Test-Path -LiteralPath $tmp -PathType Leaf){ Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } } } else { Write-Host '[更新器] 未找到 UPDATE-URL.txt，将使用包内同步脚本。' }"
goto :PortableBootstrapRefreshDone
:PortableBootstrapRefresh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PORTABLE_BOOTSTRAP_REFRESH%" -InstanceDir "%PORTABLE_INSTANCE_DIR%" -ScriptDir "%PORTABLE_SCRIPT_DIR%" -ManifestUrl "%PORTABLE_MANIFEST_URL%"
:PortableBootstrapRefreshDone

rem Promote any files the background daemon pre-downloaded during the last session,
rem before the sync runs. Best-effort: jars are unlocked now (game not started yet).
if exist "%PORTABLE_SCRIPT_DIR%\portable-stage-daemon.ps1" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PORTABLE_SCRIPT_DIR%\portable-stage-daemon.ps1" -InstanceDir "%PORTABLE_INSTANCE_DIR%" -Mode Promote

set "PORTABLE_PY="
where py >nul 2>nul && set "PORTABLE_PY=py -3"
if not defined PORTABLE_PY where python >nul 2>nul && set "PORTABLE_PY=python"
if defined PORTABLE_PY if exist "%PORTABLE_SCRIPT_DIR%\player-update-generic.py" goto :SyncWithPython
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PORTABLE_SCRIPT_DIR%\player-update-generic.ps1" -InstanceDir "%PORTABLE_INSTANCE_DIR%" -NoPause
set "code=%ERRORLEVEL%"
goto :AfterSync
:SyncWithPython
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host '[同步] 使用 Python 同步器'"
%PORTABLE_PY% "%PORTABLE_SCRIPT_DIR%\player-update-generic.py" --instance-dir "%PORTABLE_INSTANCE_DIR%"
set "code=%ERRORLEVEL%"
:AfterSync
if not "%code%"=="0" goto :SyncFailed

rem Launch the background staging daemon as an independent process (survives this
rem window closing). It pre-downloads future updates into .portable-staging while
rem the player is online, and self-exits when the game closes or after a max runtime.
rem NOTE: do NOT pass -WindowStyle Hidden here. "start powershell -WindowStyle Hidden
rem -ExecutionPolicy Bypass -File" trips Huorong heuristic PS.NetLoader and the bat
rem gets deleted on double-click. Start minimized (/min) and let the daemon minimize
rem its own console at runtime instead.
rem First stop any daemon left over from a previous session so this launch always runs
rem the current daemon version and is never blocked by a stale single-instance lock.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$lk=Join-Path $env:PORTABLE_INSTANCE_DIR '.portable-staging\daemon.lock'; if(Test-Path -LiteralPath $lk){ try{ $op=[int]((Get-Content -LiteralPath $lk -Raw -EA SilentlyContinue).Trim()); $cp=Get-CimInstance Win32_Process -Filter ('ProcessId='+$op) -EA SilentlyContinue; if($cp -and $cp.CommandLine -like '*portable-stage-daemon*'){ Stop-Process -Id $op -Force -EA SilentlyContinue } }catch{}; Remove-Item -LiteralPath $lk -Force -EA SilentlyContinue }"
if defined PORTABLE_PY if exist "%PORTABLE_SCRIPT_DIR%\portable-stage-daemon.py" (
  start "portable-stage-daemon" /min %PORTABLE_PY% "%PORTABLE_SCRIPT_DIR%\portable-stage-daemon.py" --instance-dir "%PORTABLE_INSTANCE_DIR%" --mode watch
) else if exist "%PORTABLE_SCRIPT_DIR%\portable-stage-daemon.ps1" start "portable-stage-daemon" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PORTABLE_SCRIPT_DIR%\portable-stage-daemon.ps1" -InstanceDir "%PORTABLE_INSTANCE_DIR%" -Mode Watch -Toast

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $root=[System.IO.Path]::GetFullPath($env:PORTABLE_INSTANCE_DIR); $launcherDir=Join-Path $root '_launchers'; $mcHome=''; $p=Split-Path -Parent $root; $gp=''; if($p){ $gp=Split-Path -Parent $p }; if($gp -and ((Split-Path -Leaf $p) -ieq 'versions') -and ((Split-Path -Leaf $gp) -ieq '.minecraft')){ $mcHome=Split-Path -Parent $gp }; Write-Host ''; $started=$false; $pclHome=$root; if($mcHome){ $pclHome=$mcHome }; $pcl=$null; foreach($n in @('PCL.exe','Plain Craft Launcher.exe')){ $c=Join-Path $pclHome $n; if(Test-Path -LiteralPath $c -PathType Leaf){ $pcl=$c; break } }; if(-not $pcl -and $mcHome){ foreach($src in @((Join-Path $root 'PCL.exe'),(Join-Path $launcherDir 'PCL.exe'))){ if(Test-Path -LiteralPath $src -PathType Leaf){ $dest=Join-Path $mcHome 'PCL.exe'; try { Copy-Item -LiteralPath $src -Destination $dest -Force; $pcl=$dest; Write-Host ('[启动器] 已把 PCL 放到 ' + $mcHome + '（PCL 只识别自己所在目录下的 .minecraft 实例）') } catch { $pcl=$null }; break } } }; if($pcl){ Write-Host ('[启动器] 正在启动 PCL：' + $pcl); try { Start-Process -FilePath $pcl -WorkingDirectory (Split-Path -Parent $pcl); $started=$true; Write-Host '[启动器] PCL 已启动。' } catch { Write-Host ('[启动器] PCL 启动失败：' + $_.Exception.Message) } }; if(-not $started){ $jar=$null; foreach($c in @((Join-Path $root 'HMCL.jar'),(Join-Path $launcherDir 'HMCL.jar'))){ if(Test-Path -LiteralPath $c -PathType Leaf){ $jar=$c; break } }; if($jar){ $wd=$root; if($mcHome){ $wd=$mcHome; Write-Host ('[启动器] 将从 ' + $wd + ' 启动 HMCL 以识别实例。') }; Write-Host '[启动器] 正在启动 HMCL...'; $java=Get-Command javaw.exe -ErrorAction SilentlyContinue; try { if($java){ Start-Process -FilePath $java.Source -ArgumentList @('-jar',$jar) -WorkingDirectory $wd } else { Start-Process -FilePath $jar -WorkingDirectory $wd }; $started=$true; Write-Host '[启动器] HMCL 已启动。' } catch { Write-Host ('[启动器] HMCL 启动失败：' + $_.Exception.Message) } } }; if(-not $started){ $sakura=Join-Path $root 'SakuraLauncher.exe'; if(Test-Path -LiteralPath $sakura -PathType Leaf){ Write-Host '[启动器] 正在启动 SakuraLauncher...'; try { Start-Process -FilePath $sakura -WorkingDirectory $root; $started=$true; Write-Host '[启动器] SakuraLauncher 已启动。' } catch {} } }; if(-not $started){ Write-Host ('[启动器] 未找到可自动启动的启动器，请检查：' + $root + ' 或 ' + $launcherDir) }; Write-Host ''; Write-Host '按回车键关闭窗口...'"
pause >nul
exit /b %code%

:SyncFailed
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host ('[同步] 失败，退出码 ' + $env:code + '。请把本窗口截图发给管理员。'); Write-Host ''; Write-Host '按回车键关闭窗口...'"
pause >nul
exit /b %code%
