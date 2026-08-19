param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $Root 'dist' }

$stamp = Get-Date -Format 'yyyyMMdd'
$kitName = "修复Windows更新脚本-$stamp"
$tmp = Join-Path $env:TEMP ('portable-repair-kit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Value, $encoding)
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'portable-windows-repair.bat') -Destination (Join-Path $tmp '修复更新脚本-Windows端.bat') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'portable-windows-repair.ps1') -Destination (Join-Path $tmp 'portable-windows-repair.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'portable-windows-sync.bat') -Destination (Join-Path $tmp 'Windows-sync.bat') -Force

$readme = @(
    '修复 Windows 更新脚本（不用重下 800MB 整合包）',
    '',
    '适用：双击「更新mod-Windows端.bat」窗口一闪就没。',
    '',
    '用法：',
    '1. 解压本文件夹。',
    '2. 把整个文件夹放到整合包解压根目录（和「更新mod-Windows端.bat」放一起）。',
    '   放在旁边当邻居文件夹也可以。',
    '3. 双击「修复更新脚本-Windows端.bat」。',
    '4. 修好后会自动启动正常更新。',
    '',
    '不要只发其中一个文件；三个文件要在一起。',
    '不要在压缩软件里直接双击运行。'
) -join "`r`n"
Write-Utf8NoBom (Join-Path $tmp 'README-修复.txt') ($readme + "`r`n")

$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile((Join-Path $tmp 'portable-windows-repair.ps1'), [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { throw ("repair.ps1 parse failed: " + $errors[0].Message) }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$zip = Join-Path $OutDir ($kitName + '.zip')
$py = Join-Path $PSScriptRoot 'zip-with-unix-mode.py'
& python $py $tmp $zip
if ($LASTEXITCODE -ne 0) { throw "zip-with-unix-mode.py failed: $LASTEXITCODE" }
Remove-Item -LiteralPath $tmp -Recurse -Force
$item = Get-Item -LiteralPath $zip
Write-Host ("[修复包] " + $item.FullName + "  " + $item.Length + " bytes")
return $item.FullName
