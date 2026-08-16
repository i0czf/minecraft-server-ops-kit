param(
    [switch]$Deploy,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $PSScriptRoot 'item-aspect-indexer'
$Build = Join-Path $Root 'tmp\item-aspect-indexer-build'
$Classes = Join-Path $Build 'classes'
$Output = Join-Path $Build 'qq-aspect-indexer-1.0.0.jar'
$Deployed = Join-Path $Root 'mods\qq-aspect-indexer-1.0.0.jar'

$JdkRoot = @(
    'C:\Program Files\Eclipse Adoptium\jdk-25.0.2.10-hotspot',
    'C:\Program Files\Eclipse Adoptium\jdk-21.0.8.9-hotspot',
    $env:JAVA_HOME
) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'bin\javac.exe')) } |
    Select-Object -First 1
if (-not $JdkRoot) { throw 'JDK 21+ with javac was not found' }

$Thaumcraft = Get-ChildItem -LiteralPath (Join-Path $Root 'mods') -File -Filter '*.jar' |
    Where-Object { $_.Name -match '(?i)thaumcraft-0\.2\.2' } |
    Sort-Object LastWriteTimeUtc, Name -Descending |
    Select-Object -First 1
if (-not $Thaumcraft) { throw 'Thaumcraft JAR was not found under mods' }

$Dependencies = @(
    (Join-Path $Root 'libraries\net\neoforged\neoforge\21.1.235\neoforge-21.1.235-universal.jar'),
    (Join-Path $Root 'libraries\net\neoforged\neoforge\21.1.235\neoforge-21.1.235-server.jar'),
    (Join-Path $Root 'libraries\net\minecraft\server\1.21.1-20240808.144430\server-1.21.1-20240808.144430-srg.jar'),
    (Join-Path $Root 'libraries\net\neoforged\fancymodloader\loader\4.0.42\loader-4.0.42.jar'),
    (Join-Path $Root 'libraries\net\neoforged\bus\8.0.5\bus-8.0.5.jar'),
    (Join-Path $Root 'libraries\net\neoforged\mergetool\2.0.0\mergetool-2.0.0-api.jar'),
    (Join-Path $Root 'libraries\com\mojang\brigadier\1.3.10\brigadier-1.3.10.jar'),
    (Join-Path $Root 'libraries\com\mojang\datafixerupper\8.0.16\datafixerupper-8.0.16.jar'),
    (Join-Path $Root 'libraries\com\google\code\gson\gson\2.10.1\gson-2.10.1.jar'),
    (Join-Path $Root 'libraries\org\apache\maven\maven-artifact\3.8.5\maven-artifact-3.8.5.jar'),
    (Join-Path $Root 'libraries\cpw\mods\securejarhandler\3.0.8\securejarhandler-3.0.8.jar'),
    $Thaumcraft.FullName
)
foreach ($dependency in $Dependencies) {
    if (-not (Test-Path -LiteralPath $dependency)) { throw "Missing compile dependency: $dependency" }
}

if (Test-Path -LiteralPath $Classes) {
    $resolvedBuild = [IO.Path]::GetFullPath($Build)
    $resolvedClasses = [IO.Path]::GetFullPath($Classes)
    if (-not $resolvedClasses.StartsWith($resolvedBuild + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected path: $resolvedClasses"
    }
    $classRootItem = Get-Item -LiteralPath $resolvedClasses -Force -ErrorAction Stop
    if (($classRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to clean reparse-point build directory: $resolvedClasses"
    }
    $nestedReparse = Get-ChildItem -LiteralPath $resolvedClasses -Force -Recurse -ErrorAction Stop |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($nestedReparse) {
        throw "Refusing to traverse reparse point under build directory: $($nestedReparse.FullName)"
    }
    Remove-Item -LiteralPath $Classes -Recurse -Force
}
New-Item -ItemType Directory -Path $Classes -Force | Out-Null

$Source = Join-Path $Project 'src\main\java\com\chesir\qqaspectindex\QQAspectIndexMod.java'
$ClassPath = $Dependencies -join ';'
& (Join-Path $JdkRoot 'bin\javac.exe') --release 21 -encoding UTF-8 `
    -classpath $ClassPath -d $Classes $Source
if ($LASTEXITCODE -ne 0) { throw "Indexer compilation failed; javac exit=$LASTEXITCODE" }

if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
& (Join-Path $JdkRoot 'bin\jar.exe') --create --file $Output `
    -C $Classes . -C (Join-Path $Project 'src\main\resources') .
if ($LASTEXITCODE -ne 0) { throw "Indexer packaging failed; jar exit=$LASTEXITCODE" }

if ($Deploy) {
    Copy-Item -LiteralPath $Output -Destination $Deployed -Force
}

if (-not $Quiet) {
    Write-Host "Runtime item-aspect indexer built: $Output"
    if ($Deploy) {
        Write-Host "Deployed: $Deployed (takes effect on the next normal server start)"
    }
}

$DeployedResult = ''
if ($Deploy) { $DeployedResult = $Deployed }
[pscustomobject]@{
    output = $Output
    deployed = $DeployedResult
    thaumcraft = $Thaumcraft.Name
}
