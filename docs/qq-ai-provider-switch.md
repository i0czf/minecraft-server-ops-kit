# QQ 群 AI 后端切换

QQ 桥的最终回答入口仍然是 `tools/ops-config.json` 的 `ai.provider`，公版默认 `deepseek`。图片/视频预处理由 `ai.visionProvider` 单独选择，视频音轨则由可选的 `ai.audioTranscription` 处理；Grok Build 保留为可切换后端，不再是默认汇总模型。

- `grok-local`：**本机 Grok CLI**（推荐不调 API 时用）。走 `grok --prompt-file` 单轮 headless，使用本机 `grok login` 登录态，配置里不写 API Key。默认 `--permission-mode plan` 只读。
- `codex-local`：本机 Codex CLI，使用本机 Codex 登录，默认只读；当前固定 `gpt-5.6-luna` + `max` 推理强度，通过 `codex exec --json` 读取 `turn.completed.usage`，保留用量/计费尾巴和耗时尾巴。
- `grok`：xAI 官方 OpenAI 兼容 **HTTP 接口**，密钥从环境变量 `XAI_API_KEY` 读取（会调远程 API）。
- 其它：`deepseek`（默认 `deepseek-v4-flash`，关思考，适合群聊）/ `deepseek-pro`（开思考，适合排查）/ `qwen` / `ollama` 等 HTTP 预设。

## 一键切换

双击 `一键脚本\一键便携-切换AI.bat`，输入 `grok-local`、`codex-local`、`grok`、`deepseek` 等预设名。也可以在 PowerShell 中直接执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\set-ai-provider.ps1 -Provider grok-local
powershell -ExecutionPolicy Bypass -File .\tools\set-ai-provider.ps1 -Provider codex-local
powershell -ExecutionPolicy Bypass -File .\tools\set-ai-provider.ps1 -Provider grok
powershell -ExecutionPolicy Bypass -File .\tools\set-ai-provider.ps1 -List -NoPause
```

切换脚本会先把当前配置备份到 `backups\qq-ai-switch-时间戳\ops-config.json`，然后刷新 QQ/Discord 运维桥；不会重启 Minecraft 服务端。若只想改配置、不立即刷新，加 `-NoRestart`。

## 首次使用本机 Grok CLI（不调 API）

1. 本机已安装 Grok CLI，且当前 Windows 用户能在终端运行 `grok`。
2. 完成登录（只需一次）：

```powershell
grok login
```

3. 切到本机后端并刷新运维桥：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\set-ai-provider.ps1 -Provider grok-local
```

4. 群里发 `!ai`，应显示「本机 Grok CLI」且密钥为「使用本机 Grok 登录」。

`commandPath` 留空时自动探测 `%USERPROFILE%\.grok\bin\grok.exe`，再回退 PATH 中的 `grok`。模型默认 `grok-4.6`，可按本机 `grok models` 调整 `ai.providers.grok-local.model`；`ai.webProxy` 会显式传给子进程，避免常驻桥没有继承后来启动的代理环境。

## 首次使用 Grok HTTP（调 xAI API）

仅在你明确要用 HTTP 预设 `grok` 时才需要。在启动 QQ 桥的同一 Windows 用户环境中设置密钥，不要把密钥写入 JSON：

```powershell
[Environment]::SetEnvironmentVariable('XAI_API_KEY', '你的 xAI API Key', 'User')
powershell -ExecutionPolicy Bypass -File .\tools\set-ai-provider.ps1 -Provider grok
```

## 本机 CLI 的边界（grok-local / codex-local）

本机 CLI 是命令行代理，不是 `apiUrl` 上的本地 Chat Completions 服务：

| 后端 | 实际调用 | 登录 | 默认安全 |
|------|----------|------|----------|
| `grok-local` | `grok --prompt-file ... --tools none --max-turns 1`（空 cwd） | `grok login` | 无工具单轮；服情由 Java 预取快照写入 prompt，避免扫整个服目录超时 |
| `codex-local` | `codex exec --json --sandbox read-only` | 本机 Codex 登录 | 只读沙箱 |

两者都**不使用** QQ 桥的 RCON / function-calling 工具；`codex-local` 会解析 Codex JSONL 的模型用量，`grok-local` 仍不显示 token 用量。需要完整运维（改配置、RCON、BlueMap 截图等）时，切回 `deepseek`、`grok` 等 HTTP 预设。

### grok-local 为何曾超时

若把 cwd 设为服务端根目录并允许多轮工具，Grok agent 会扫 `bluemap/`、`world/` 等巨量目录，plain 输出又只在结束时打印，表现就是「处理中」卡满 120–180 秒后超时。当前实现改为：

1. cwd = `tmp/grok-qq-workspace`（空目录）
2. 禁用 CLI 工具、子代理和后台自更新，限制为单轮结构化输出
3. 崩溃列表 / 日志末尾等由 `QQConsoleBridge` 读入 prompt
4. 图片先在本机压缩后通过 ACP content block 传入；视频仍走 Qwen 画面报告与可选 ASR，再交给 Grok 汇总

## 用量与花费（回答末尾的小尾巴）

`ai.showUsage=true`（默认）时，每条 AI 回答后面附一行：

```
———
用量 12,431 tok（入 11,905，缓存命中 8,192＝69%；出 526）｜3 次请求｜约 ¥0.0032
```

- **数字从哪来**：模型接口自己返回的 `usage` 字段，即厂商的计费口径。不做本地估算——按字数估的 token 与实际扣费必然对不上。DeepSeek 的 `prompt_cache_hit_tokens` 与 OpenAI 兼容的 `prompt_tokens_details.cached_tokens` 都能识别。
- **为什么显示「N 次请求」**：一次提问在 agent 循环里会请求模型多次（每步工具调用都要把全部上下文重发一遍），token 是逐次累加的。只看最后一次会严重低估。
- **缓存命中率**：命中率是整次提问的加权值（第一步几乎全未命中，后续步骤复用同一段前缀），它直接对应省下多少钱：命中部分按 `priceCacheIn` 计价。DeepSeek V4 的官方缓存价与未命中价都以官方页面为准，不能把旧的固定比例写死。厂商报了缓存字段就一定显示，哪怕是 0%——那说明每个输入 token 都在按全价扣，是该看见的信号；压根不报缓存的厂商则整段省略，不拿 0 冒充「没命中」。
- **DeepSeek 官方价自动同步**：`ai.officialPricing.enabled=true` 后，QQ 桥启动时及每 `refreshMinutes` 分钟读取官方价目页，校验模型、价格和北京时间峰值时段后更新 V4 Flash/Pro；校验失败保留当前回退价，不影响 AI 请求。每次模型响应按响应时刻的北京时间选择峰/谷价；`!ai` 可查看当前价与同步状态。
- **单价填在哪**：普通预设使用 `ai.providers.<预设>` 下的 `priceIn` / `priceCacheIn` / `priceOut`（每百万 token）与 `currency`（`CNY` 或 `USD`）。DeepSeek V4 还支持 `pricePeakIn` / `pricePeakCacheIn` / `pricePeakOut` 作为峰值回退价；官方同步成功后会覆盖直连 V4 预设的运行时价格。美元按 `ai.usdToCny` 折人民币，`priceCacheIn` 不填就按 `priceIn` 算。
- **没填价**：只报 token，金额位置写明去哪填，不会按估价编一个数字。本机 ollama 填 0 则显示「¥0（本机模型，不计费）」。
- **本机 CLI**：`codex-local` 从 `turn.completed.usage` 读取输入、缓存输入和输出 token；`grok-local` 的主回答使用 SuperGrok 订阅额度，不伪装成按 token 账单。若同时用了 Qwen 视频/ASR，页脚会单列这些 API 费用。两者耗时都由 QQ 桥本地计时器统计。
- `codex-local` 当前锁定 `gpt-5.6-luna` + `max`，价格为输入 `$1`、缓存输入 `$0.1`、输出 `$6`（每百万 token）；页脚显示的是按 API 价格折算的“约”值，ChatGPT 登录态的实际账户扣费/额度以账号计划为准。
- 单价随时会变，以各家官方计费页为准；填错只影响显示的金额，不影响真实扣费。发 `!ai` 可看当前预设的单价。

## 排查

```powershell
java -cp .\tmp\java-classes QQConsoleBridge --ai-status .\tools\ops-config.json
Get-Content .\logs\qq-console.log -Tail 80
grok models
```

- `grok-local`：本机已 `grok login`，`grok -p "ping"` 能出字。
- `grok` HTTP：需要可用的 `XAI_API_KEY`。
- `codex-local`：需要先在本机完成 Codex 登录。

`!ai` / `--ai-status` 只显示密钥来源与状态，不显示密钥内容。
