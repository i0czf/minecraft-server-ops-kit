# QQ bridge helper: run local grok headless once (tools none).
# Java ProcessBuilder of grok.exe often hangs; PS Start-Process is reliable.
param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,
    [Parameter(Mandatory = $true)]
    [string]$OutFile,
    [Parameter(Mandatory = $true)]
    [string]$WorkDir,
    [string]$GrokExe = '',
    [string]$Model = 'grok-4.6',
    [string]$SchemaFile = '',
    [string]$Effort = '',
    [string]$ProxyUrl = '',
    [int]$TimeoutSec = 75
)

$ErrorActionPreference = 'Stop'
try {
    if ([string]::IsNullOrWhiteSpace($GrokExe)) {
        $GrokExe = Join-Path $env:USERPROFILE '.grok\bin\grok.exe'
    }
    if (-not (Test-Path -LiteralPath $GrokExe -PathType Leaf)) {
        ('GROK_NOT_FOUND: ' + $GrokExe) | Set-Content -LiteralPath ($OutFile + '.err') -Encoding utf8
        exit 127
    }
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
        ('PROMPT_NOT_FOUND: ' + $PromptFile) | Set-Content -LiteralPath ($OutFile + '.err') -Encoding utf8
        exit 2
    }
    if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    }

    $env:NO_COLOR = '1'
    $env:TERM = 'dumb'
    $env:CI = '1'
    # 服务进程通常早于代理程序/当前终端启动，不能指望它继承临时的 HTTP_PROXY。
    # ai.webProxy 由 Java 显式传入，这样 QQ 桥与手工终端测试走的是同一条网络路径。
    if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
        $normalizedProxy = $ProxyUrl.Trim()
        if ($normalizedProxy -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') {
            $normalizedProxy = 'http://' + $normalizedProxy
        }
        $proxyUri = $null
        if (-not [Uri]::TryCreate($normalizedProxy, [UriKind]::Absolute, [ref]$proxyUri) -or
            [string]::IsNullOrWhiteSpace($proxyUri.Host) -or $proxyUri.Port -le 0 -or
            $proxyUri.Scheme -notin @('http', 'https', 'socks5', 'socks5h')) {
            ('INVALID_PROXY: expected host:port or http(s)/socks5 URL') | Set-Content -LiteralPath ($OutFile + '.err') -Encoding utf8
            exit 4
        }
        $env:HTTP_PROXY = $normalizedProxy
        $env:HTTPS_PROXY = $normalizedProxy
        $env:ALL_PROXY = $normalizedProxy
        $env:NO_PROXY = 'localhost,127.0.0.1,.local,::1'
    }
    # 官方建议自动化调用禁用后台自更新；升级留给人工维护窗口，避免机器人请求撞上换版。
    $env:GROK_CONNECT_UI_TIMEOUT_SECS = '45'
    # 强制本后端使用 grok login 的 SuperGrok OAuth；不能因系统环境残留 XAI_API_KEY 而回退到 API team。
    Remove-Item Env:XAI_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:GROK_CODE_XAI_API_KEY -ErrorAction SilentlyContinue

    $errFile = $OutFile + '.err'
    Remove-Item -LiteralPath $OutFile, $errFile -Force -ErrorAction SilentlyContinue

    if (-not [string]::IsNullOrWhiteSpace($SchemaFile) -and -not (Test-Path -LiteralPath $SchemaFile -PathType Leaf)) {
        ('SCHEMA_NOT_FOUND: ' + $SchemaFile) | Set-Content -LiteralPath ($OutFile + '.err') -Encoding utf8
        exit 3
    }

    # PS 5.1: ArgumentList must be a single string (array form drops args).
    # PromptFile 是 ACP JSON content blocks；输出保留完整 JSON，供 Java 解析结构化结果、usage 和耗时。
    # 显式 deny 版本兼容 Grok CLI 1.0.2：--tools none 会被误解析为未知工具名，
    # 所以用一个允许项加完整 deny 清单，最终 init.tools 应为空。
    $deny = 'run_terminal_command,read_file,search_replace,list_dir,grep,kill_command_or_subagent,get_command_or_subagent_output,spawn_subagent,scheduler_create,scheduler_delete,scheduler_list,monitor,search_tool,use_tool,todo_write,workflow,enter_plan_mode,exit_plan_mode,ask_user_question,web_search,web_fetch,image_gen,image_edit,image_to_video,reference_to_video,write,Agent'
    $arg = '--no-auto-update --prompt-file "' + $PromptFile + '" --cwd "' + $WorkDir + '" --output-format json --permission-mode plan --tools todo_write --disallowed-tools ' + $deny + ' --no-subagents --no-memory --max-turns 1 -m ' + $Model
    if (-not [string]::IsNullOrWhiteSpace($Effort)) {
        $arg += ' --effort ' + $Effort.Trim()
    }
    # 从文件读取 schema 后通过单行参数传入；当前 schema 只有 ASCII，避免中文/换行破坏 Windows 参数解析。
    if (-not [string]::IsNullOrWhiteSpace($SchemaFile)) {
        $schemaText = (Get-Content -LiteralPath $SchemaFile -Raw).Trim()
        $schemaText = $schemaText -replace '[\r\n]+', ''
        $arg += ' --json-schema "' + ($schemaText -replace '"', '\"') + '"'
    }

    $p = Start-Process -FilePath $GrokExe -ArgumentList $arg -WorkingDirectory $WorkDir -NoNewWindow -PassThru -RedirectStandardOutput $OutFile -RedirectStandardError $errFile

    $ms = [Math]::Max(5, $TimeoutSec) * 1000
    $ok = $p.WaitForExit($ms)
    if (-not $ok) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        try { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null } catch {}
        ('TIMEOUT after ' + $TimeoutSec + 's') | Set-Content -LiteralPath $errFile -Encoding utf8
        exit 124
    }

    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        New-Item -ItemType File -Path $OutFile -Force | Out-Null
    }
    exit $p.ExitCode
}
catch {
    $msg = 'WRAPPER_ERROR: ' + $_.Exception.Message
    try { $msg | Set-Content -LiteralPath ($OutFile + '.err') -Encoding utf8 } catch {}
    Write-Error $msg
    exit 1
}
