# 便携服务端工具包

这套工具把“玩家拉新/同步分发”和“QQ/Discord/备份/崩溃监控”拆开做，适合复制到任意新的 Minecraft 服务端目录。

## 新手三步上手

不挑 Minecraft 版本，不挑加载器（Forge / NeoForge / Fabric / Quilt / 原版都可以），全程中文：

1. 把工具包 zip 解压到你的服务端根目录（和 `server.properties` 同级；新服还没有该文件也没关系，先解压）。
2. 双击根目录唯一的入口 `一键便携-控制面板.bat`，打开「服务器运维控制面板」。
3. 跟着面板顶部「🚀 上手路线」亮起的 ▶ 一步步点：初始化配置向导 → 选主客户端 → 启动服务端 → 发布更新 → 开更新服务。日常开服、重启运维、看日志、发 RCON 命令也都在面板里完成。Java 不用管：启动时按本服 Minecraft 版本自动挑选本机合适的 Java（≤1.16→8，1.17–1.20.4→17，1.20.5–1.21.x→21，新纪年 26.x→25）；本机没有对应版本会给出中文下载指引，不会陷入反复重启。

不知道先点啥？面板右上第一张卡就是「🚀 上手路线」：核心五步按真实状态实时点亮（✓ 已完成 / ▶ 当前该做 / 灰色待办），跟着 ▶ 点下去即可，每步可直接点击执行，旁边还有一句话说明。第六步「QQ 机器人」是可选项，不拦进度，想要 QQ 群通知/反控再点它。

只想用命令行也可以：全部一键 bat 收纳在 `一键脚本\` 子目录，每个都能单独双击使用（内部路径已按子目录适配），面板只是把它们组织到了一个窗口里。

## 三类运维包与独立拉新公版

- 公开工具包：运行 `一键脚本\一键生成便携工具包.bat`，只打包模板，不携带真实密钥/更新配置，适合留档或分享给别人。**公开包不含 Discord 频道相关组件**（反控桥、webhook 发送器）——国内场景 QQ 群方案已完整覆盖通知与反控；运维启动脚本和面板会自动识别并跳过/隐藏 Discord 相关项。
- 精简工具包：运行 `一键脚本\一键生成精简工具包.bat`（或面板「生成精简工具包」），公开包的精简变体——再去掉 LLBot 程序本体，zip 从约 77MB 缩到几百 KB，最适合网络传播。拿到包的人如需 QQ 机器人，自行下载 LLBot 放到 `tools\LLBot-CLI-win-x64`（启动脚本会给中文指引），或向你要完整版。
- 私用工具包：运行 `一键脚本\一键生成私用便携工具包.bat`，会额外带上 `tools/portable-pack.json` 和 `tools/ops-config.json`。它保留你长期复用的域名、端口、Discord/QQ 密钥等私用配置；打包时会自动清空旧服身份字段（整合包名称/ID、Minecraft 版本、加载器类型和版本、主客户端目录、PCL 实例名、旧实例专属 jar、旧版本 options 默认项等），并由打包门禁校验，净化不干净直接拒绝出包。解压到新服后跑初始化配置向导重新识别并自定义名称即可。
- 玩家拉新公版：运行 `一键脚本\一键生成玩家拉新公版.bat`，只带主客户端发布、规范导入包/PCL/完整包、增量更新服务和玩家自助修复；不带 QQ/Discord、RCON 运维、备份、世界或作者更新源，适合单独给其他服务器使用。
- 在已配置好的老服务器上更新工具包时，注意私用包会把这两份 json 覆盖成「密钥在、身份空白」的净化版——先备份或解压时跳过它们，或者重跑一次向导恢复身份字段。
- 配置文件里的 `_说明`、`_字段说明` 是合法 JSON 字段，用来代替 JSON 注释；脚本只读取需要的字段，会忽略这些说明字段。
- 公开包和私用包内置 LLBot QQ 机器人程序本体（`tools/LLBot-CLI-win-x64`，约 150MB，zip 因此变大属正常；精简包不含）。打包时自动剔除全部账号数据（登录数据库、`config_QQ号.json`、WebUI token、登录二维码），并清空 `pmhq_config.json` 里的 QQ 号和本机路径，由隐私门禁校验。新机首次启动 QQ 机器人时扫码登录即可。QQ NT 客户端本体（约 2GB 的 `tools/napcat`）**不入包**：新机需自行安装 QQ，或把 `pmhq_config.json` 的 `qq_path` 指向本机 `QQ.exe`（留空则自动探测已安装的 QQ）。**精简包用户补齐 LLBot**：找作者要完整版解压覆盖，或到 LLOneBot 官方发布页（github.com/LLOneBot/LLOneBot/releases）下载 LLBot CLI（Windows x64）解压到 `tools/LLBot-CLI-win-x64/`（确保有 `llbot.exe`）；「配置/启动 QQ 机器人」在缺 LLBot 时也会给出同样的中文指引。

## 自动配置向导

解压工具包到任意服务端根目录后，优先双击下面入口。注意：这一步只负责生成/更新配置，不会直接启动 Minecraft 服务端；启动仍然用 `一键脚本\一键便携-启动服务端.bat`。

- `一键脚本\一键便携-初始化配置.bat`

向导会自动读取这些信息：

- `server.properties`：MOTD、`server-port`、`level-name`、RCON 是否启用、RCON 端口和密码是否存在。
- `SOURCE-CLIENT.txt`：作为兼容旧服的候选来源；如果它指向服务端根目录外，只显示为外部候选，不会压过根目录内客户端。
- 服务端根目录内客户端目录：优先自动寻找含 `mods` 的主分发客户端候选，作为以后加 mod、修 config 的唯一工作路径。支持 PCL/HMCL 常见结构，例如 `客户端\.minecraft\versions\1.20.1-Forge_47.4.20`，会自动识别为 Minecraft `1.20.1`、Forge `47.4.20`。
- `libraries`、`versions`、客户端 JSON：识别 Minecraft 版本、Fabric/Forge/NeoForge/Quilt 类型和加载器版本。**版本和加载器始终以本机实测优先**：即使配置文件里带着旧服的版本（比如私包迁移），也会被自动纠正成当前服务端的实际版本。
- 已有 `tools/portable-pack.json` 和 `tools/ops-config.json`：保留你已经填过的域名、端口、Discord webhook/bot token/channelId 等长期配置。配置里的主客户端目录只有在本机真实存在时才沿用，旧服带来的失效路径会被忽略。
- 主客户端不必放在服务端目录内：菜单 2 里可以直接输入任意路径（例如 `D:\我的整合包客户端`），控制面板里也有「选择主客户端…」按钮用文件夹选择器指定。如果还没有客户端，推荐在服务端根目录新建「客户端」文件夹放入整合包客户端实例（从玩家包/规范导入包解压即可），向导会自动识别。

向导会显示中文检测结果，并提供菜单：

- `1` 保存当前显示结果到配置文件。
- `2` 中文菜单逐项确认/修改，然后询问是否保存，推荐第一次迁移时使用。
- `3` 仅重新显示检测结果，不会保存。
- `4` 退出，不保存。

写入前会自动备份当前 `tools/portable-pack.json` 和 `tools/ops-config.json` 到 `backups/portable-config-wizard-*`。

如果 Discord 频道反控或定时备份处于启用状态，向导保存后会自动运行 `tools/enable-local-rcon.ps1`：备份 `server.properties`，设置 `enable-rcon=true`、`rcon.port=25575`、生成/保留强 `rcon.password`，并设置 `broadcast-rcon-to-ops=false`。这些改动需要重启 Minecraft 服务端后生效。

## 已内置的成熟策略

玩家同步/拉新：

- 不强制覆盖玩家个性化文件：`options.txt`、`servers.dat`、资源包、光影、存档、截图、小地图点位、schematics 等默认保留玩家修改。
- 不强制恢复玩家删除的个性化文件：同一批路径默认也保留玩家删除记录。
- `options.txt` 只写安全默认项，例如跳过多人游戏提示；不会批量覆盖按键、鼠标灵敏度等个人设置。
- 首次同步可自动写 `servers.dat`，但默认只在玩家没有服务器列表时写入。
- 玩家双击同步入口会先从更新源刷新同步器脚本，再执行同步，方便以后修复玩家端脚本 bug。
- 会接管本地已有同 hash 文件，减少重复下载和重复文件。
- 日常增量与后台预下载走混源：公开发行的模组/资源包/光影按 sha1 走 Modrinth CDN，汉化包和私有文件仍走自建更新服务；官方源失败或哈希不符自动回落，不依赖 Gitee 之类的代码托管。
- 会清理 `mods/.connector` 运行时缓存，避免 Connector 跨机器/跨系统残留。
- 会禁用导入器 `modrinth.index.json` 修包入口，避免启动器按旧索引把文件“修回去”。
- 会把重复 mod 归档到 `_disabled_mod_duplicates`，优先保留服务端清单里的 jar。
- 如果玩家包采用 `客户端\.minecraft\versions\实例名` 结构，会自动把 PCL 放到玩家包根目录，并写入 `PCL.ini`、`PCL\Setup.ini` 和 `.minecraft\launcher_profiles.json`，让 PCL 直接显示本地实例。
- 所有被覆盖、删除或强制清理的文件会先放入 `.portable-sync-backups`。

Discord/QQ 运维（Discord 频道组件仅私用包携带，公开包为纯 QQ 方案）：

- 转发启动、上线、停服、聊天、进退服、死亡、成就、命令、崩溃、备份、公网 IP 变化与 DDNS 同步结果（支持 DNSPod 自动改解析，见「动态公网 IP 与 DDNS」）。
- 日志编码自动识别：`logWatch.charset` 留空或填 `auto` 时，按文件字节自动判断 UTF-8/GBK（MC 日志编码取决于服务端 Java：1.20.4 及以下常见 GBK，1.20.5+/Java 18+ 是 UTF-8），换版本换服不再出现中文聊天乱码；也可显式填 `GBK`/`UTF-8` 强制指定。
- 发布更新通知的变更列表按类型标符号：新增 `+`、更新 `~`、删除 `-`。
- 玩家登录 IP 可附带归属地，配置项是 `showJoinIp`、`showJoinIpLocation`、`joinIpLocationEndpoint`。
- 支持 Discord webhook 发送，也支持 bot token + channelId 做频道反控；`adminIds` 可填单个 Discord 用户 ID、逗号分隔字符串或数组。QQ 群反控分两级权限：`!help`/`!list`/`!day`/`!rules`/`!version`/`!uptime`/`!ip`/`!roll`/`!运势`/`!id` 全体群友可用；`!tps`/`!backup`/`!save`/`!seed`/`!weather`/`!stop`/`!restart`/`!cmd`/`!ai`（查当前 AI 模型与可切换预设）仅群主、群管理员（QQ 群身份自动识别）或 `qq.adminIds` 白名单可用。
- AI 运维助手（OpenAI 兼容智能体，可接 DeepSeek / 阿里云百炼 Qwen 等）：群主/管理员在 QQ 群 `@机器人 <问题>` 或用 `!问 <问题>`（Discord 同样 `@机器人` 或 `!问`）即可让机器人像智能体一样答疑并**多轮自主查证**。它用 function calling 真实调用 11 个工具：`run_rcon`（执行任意命令，含 `data get entity/block` 读实体/方块 NBT）、`read_server_log`、`read_crash_report`、`list_mods`、`list_dir`、`read_file`（读模组配置/语言/脚本等文本）、`search_files`（按关键词搜文件）、`read_nbt`（读 `.dat` 二进制存档并转 SNBT，如清洁女仆回收站内容在 `world/data/SweeperMaid-SavedData.dat`）、`web_fetch`（联网查外部知识，Fandom/GitHub/mcmod 等）、`read_recent_chat`（读群聊记录：默认最近内存记录，也可带 date=YYYY-MM-DD/今天/昨天、player=昵称、keyword=关键词回查历史——群聊会按日落盘到 `logs/chat/qq|discord-日期.log`，跨天引用某玩家的发言就靠它；图片/表情记为 [图片]/[表情] 标记，AI 是纯文本模型看不到图片内容）、`set_server_property`（读/改 `server.properties` 单个配置项如 allow-flight/pvp/view-distance，改前自动备份为 `server.properties.ai-bak`，rcon/密码类键禁止读写）、`replace_in_config`（修改模组配置：在 `config/`、`world/serverconfig/`、`defaultconfigs/` 下的文本配置里精确查找替换，如把 curios 的 `slots = []` 改成 `slots = ["charm"]`；改前自动备份 `.ai-bak`，出现次数过多会要求补上下文防误伤）——两个写工具改完都会提醒发 `!restart` 生效。**权限分层**：`ai.memberAccess=true` 时普通群友也能 @AI 闲聊和只读查询（在线/TPS/时间/难度/模组列表/群聊话题），但受服务端硬围栏：RCON 仅白名单查询命令、文件/日志/存档/联网/配置工具一律拒绝、`memberCooldownSeconds` 冷却防刷、群友与管理员的对话历史相互隔离（防管理员会话里的配置内容泄给群友）；`!help` 对群友只展示他们能用的命令。消息理解：图片/表情包（含商城表情，本质是图可喂视觉）/语音/文件/合并转发/卡片分享都会转成可读标记。带多轮对话记忆（保留最近 6 轮，空闲 30 分钟清空）支持追问，另有独立的群聊滚动缓冲让它能了解群友之间聊了啥；**引用（回复）某条消息再 @机器人 提问**时会自动取回被引用的原文当上下文（QQ 走 OneBot `/get_msg`，Discord 走 `referenced_message`），用机器人自身 QQ 号 @ 它也能触发。**视觉看图**：模型支持视觉时（如 qwen3.7-plus），QQ 里 @机器人 带图、或引用带图消息提问，图片会以多模态直接发给模型分析（截图报错、物品属性图都能看）；聊天记录里的历史图片仍只有 [图片] 标记。配置见 `ops-config.json` 的 `ai` 段。**换模型只改一处**：`ai.providers` 是多厂商预设表（内置 deepseek / deepseek-pro / qwen / kimi / zhipu / siliconflow / openai / openrouter / ollama，每个预设含 `apiUrl`+`model`+`apiKey`/`apiKeyEnv`+`vision`），把 `ai.provider` 改成其中一个键名，接口地址、模型、密钥就整套切过去；`ai.visionProvider` 指定「当前模型不支持看图时，带图提问临时改用的那家」（默认 deepseek 干活、带图自动转 qwen 看图，没配则忽略图片并如实告知）。要接新厂商就在 `providers` 里加一个键，任何 OpenAI 兼容的 chat/completions 接口都行，但**必须支持 function calling**，否则智能体查不了服务器；回环地址（Ollama/LM Studio）免密钥。改完重跑一次运维监控即自动重编译重启，群里发 `!ai` 可查当前用哪家、密钥来源、还能切到哪些（也可 `java -cp tmp/java-classes QQConsoleBridge --ai-status tools/ops-config.json` 离线自查）。密钥**建议留空、改用 `apiKeyEnv` 指定的环境变量**（如 `DEEPSEEK_API_KEY`），私包打包会强制清空 `ai.apiKey` 与所有 `providers.*.apiKey`，密钥不入包。其余：`timeoutSeconds`、`logTailLines`、`maxSteps`（最多工具轮数，默认 8）、`rconDeny`（禁止 AI 自动执行的命令首词，默认 `stop,restart`）、`webFetch`（联网开关）、`webProxy`（联网走的 HTTP 代理，外网 wiki 需填本机 Clash 如 `127.0.0.1:7890`，国内直连留空）。**用量与花费**：每条 AI 回答末尾附一行本次消耗，如「用量 12,431 tok（入 11,905，缓存命中 8,192＝69%；出 526）｜3 次请求｜约 ¥0.0032」——token 数取自模型接口自己返回的 `usage` 字段（厂商的计费口径，不做本地估算，按字数估的 token 与实际扣费必然对不上），且按 agent 每一步累加：一次提问常要请求模型 3~8 次，每步工具调用都把全部上下文重发一遍，只算最后一次会严重低估；输入里命中缓存的部分单独按 `priceCacheIn` 计价（DeepSeek 命中价只有未命中的 2%，不分开算金额会离谱）。命中率按整次提问加权计算（第一步几乎全未命中、后续步骤复用同一段前缀），直接对应省下多少钱；厂商报了缓存字段就一定显示（哪怕 0%，那说明输入全按全价扣），不报的则整段省略而不是拿 0 冒充。单价填在各预设的 `priceIn`/`priceCacheIn`/`priceOut`（每百万 token）与 `currency`（`CNY`/`USD`，美元按 `ai.usdToCny` 折人民币），已按官方计费页预填 deepseek / deepseek-pro / grok / qwen；**没填价就只报 token 不报钱**，绝不按估价编一个金额，本机 ollama 填 0 则显示「¥0（本机模型，不计费）」。`ai.showUsage=false` 可关掉这行；本机 Codex / Grok CLI 后端走登录态、接口不返回 token 数，那两种模式不带此行（`!ai` 里会写明）。**安全**：仅群主/管理员可用；单飞执行防成本失控；文件工具锁死在服务器目录内且拒读含密钥/密码的敏感文件（`ops-config.json`/`server.properties` 等）；联网工具严格挡内网/本机地址（防 SSRF 借道打本机服务）。
- 定时世界备份会尽量走 RCON `save-off/save-all flush/save-on`，失败时仍会 zip 当前世界；手动 `!backup`/`!备份` 只发一条简洁完成回执，并会抑制 backupWatch 的重复通知。
- 外置监控独立于 Minecraft 进程，服务端崩掉后仍能发崩溃/退出通知。
- 最近新增的高风险功能全部“配置存在但默认关闭”：扫地僧实体清理、QQ 模组发布事务、BlueMap 截图、专用摄像机视角与 Codex 服务器动作都需腐竹主动启用；公版模板不会因缺字段自行开启。
- QQ 要素物品反查随包提供运行时索引器源码和构建脚本；它依赖 NeoForge/Thaumcraft，其他类型服务器不启用即可，不会自动把本服专用模组塞进对方的 `mods`。

## 目录角色

- `tools/configure-portable-server.ps1`: 自动配置向导；读取当前服务端信息并生成/更新配置。
- `tools/portable-pack.example.json`: 公开中性模板，新服可复制成 `tools/portable-pack.json` 后填写，也可由向导自动生成。
- `tools/portable-pack.json`: 玩家拉新和更新源配置；向导会自动填 `packId`、`packName`、`sourceClient`、`minecraftVersion`、`loader`、服务器地址等；`standardPackageName` / `fullPackageName` 可分别指定规范导入包、完整懒人包的输出文件名前缀，留空则沿用旧版命名。
- `tools/portable-publish.ps1`: 从主分发客户端生成更新源和 `server-manifest.json`。
- `tools/build-portable-player-pack.ps1`: 生成玩家首次同步小包，并顺手生成 `.mrpack`/PCL 包。
- `tools/build-portable-import-packs.ps1`: 只生成 `.mrpack` 和 PCL 压缩包。
- `tools/player-update-generic.ps1`: Windows 玩家同步器。
- `tools/player-update-generic.py`: macOS/Linux 玩家同步器。
- `tools/portable-ops-config.example.json`: Discord/备份/崩溃/IP 监控公开模板，不含密钥。
- `tools/ops-config.json`: 运维配置；向导会自动填服务端名、地址、世界名、备份前缀，并保留私用 Discord 配置。
- `tools/portable-run-server.ps1`: 可选通用启动 wrapper，会拉起 ops monitor 并写 `logs/server-wrapper.log`。一键入口会传 `-RestartOnCleanExit`，所以 `!stop`/`!restart` 或控制台 `stop` 会触发 10 秒倒计时自动拉起；手动调用该脚本时，不传此参数则正常退出不重启。
- `tools/stop-ops-monitor.ps1`: 停止 Discord 监控、备份调度、Discord 频道反控；不会停止 Minecraft 服务端进程。
- `tools/enable-local-rcon.ps1`: 自动启用/修复本地 RCON，供 Discord 频道反控和备份前 `save-off/save-all` 使用；会先备份 `server.properties`，不会在控制台显示 RCON 密码。
- `tools/portable-control-panel.ps1`: 图形控制面板（WPF）。只做状态展示、调度既有一键入口和 RCON 快捷控制台，不重写任何发布/同步/监控逻辑；含中文，必须保存为 UTF-8 带 BOM。
- `tools/install-server.ps1`: 服务端下载安装向导（控制台）。选目录、自选 Minecraft 版本与加载器（原版/Forge/NeoForge/Fabric）一键下载部署；下载源可选官方或 BMCLAPI 国内镜像（镜像覆盖原版+Forge），Forge/NeoForge 自动匹配本机 Java 运行官方安装器，EULA 在向导里确认后写入。通常从面板「⬇ 服务端下载与安装」调度。

## 目录布局与一键脚本

为了让新手一眼找到入口，服务端根目录只保留 `一键便携-控制面板.bat` 和本说明文件；其余一键 bat 全部收纳在 `一键脚本\` 子目录，面板按钮会自动调度它们，直接双击使用也完全等价。从旧版工具包升级时，根目录残留的旧 bat 可以直接删除（面板兼容两种布局）。

工具包提供这些双击入口：

- `一键脚本\一键便携-初始化配置.bat`: 启动中文自动配置向导，生成/更新 `portable-pack.json` 和 `ops-config.json`。
- `一键脚本\一键便携-仅发布更新.bat`: 只刷新 `modpack-public` 更新源和 `server-manifest.json`，适合服务端改完主分发客户端后发布增量。发布时会按 sha1 反查 Modrinth，命中的文件写入官方下载地址，玩家同步器和后台预下载优先走 CDN。
- QQ `!升级模组` 当前采用手动服务端生命周期：事务只校验、替换双端模组并执行「仅发布更新」，不自动 `save-all`、停服或起服；运行中的 NeoForge 要加载新模组，需群主/管理员手动停服后再启动。
- `一键脚本\一键便携-生成规范导入包.bat`: 拉新首选。先自动发布更新源，再生成规范 `.mrpack` 和 PCL 客户端压缩包，PCL/HMCL/Prism 可直接导入。`.mrpack` 按规范工作：模组/资源包/光影进 `modrinth.index.json` 清单（下载 URL + sha1/sha512 + 体积），启动器导入时自行下载，包本体只含配置等小杂项（约 20MB 而非数百 MB）。下载源为混合模式：构建时按 sha1 反查 Modrinth，公开发行的文件直接用官方 CDN（大部分流量不经过你的服务器），汉化包等私有文件走自建更新服务——**有文件走自建源时，导入期间更新服务需在线**；Modrinth API 不可达自动全回退自建源，未配置公网地址再回退全内嵌。PCL 客户端压缩包则是完整离线客户端（含启动器与全部文件），适合网络不便的玩家。控制面板「④ 发布与拉新」只暴露这一个拉新入口。
- `一键脚本\一键便携-生成玩家包.bat`: 规范导入包的超集，额外多产一个传统「玩家同步包 zip」（散文件+同步器结构）。与规范导入包高度重叠，面板已不再展示，仅保留命令行入口给需要传统 zip 的场合。
- `一键脚本\一键便携-开启更新服务.bat`: 按 `tools\portable-pack.json` 里的 `publishDir`、`update.host`、`update.port` 开启更新服务。
- `一键脚本\一键便携-启动服务端.bat`: 用通用 wrapper 启动服务端，并尝试拉起 Discord/QQ/备份监控。Forge 服务端会自动识别 `libraries\net\minecraftforge\forge\...\win_args.txt`，不需要也不建议直接双击 Forge 自带 `run.bat`。
- `一键脚本\一键便携-启动所有运维.bat`: 一键启动/刷新 Discord 通知、QQ 通知与反控、备份调度；不会启动或重启 Minecraft 服务端。`一键脚本\一键便携-重启运维监控.bat` 作为兼容入口会自动转入它。
- `一键脚本\一键便携-停止所有运维.bat`: 手动停止 Discord/QQ 日志监控、频道/群反控桥、备份调度；不会停止 Minecraft 服务端。
- `一键脚本\一键便携-启用RCON反控.bat`: 单独修复 `server.properties` 里的本地 RCON；初始化向导通常会自动运行它，手动排查时再双击即可。
- `一键便携-控制面板.bat`: 打开「服务器运维控制面板」：实时显示服务端/更新服务/Discord/QQ/备份监控/RCON 状态，按运维流程分组调度上面所有一键入口，并内置 RCON 快捷控制台（TPS 命令按加载器自适应 Forge/NeoForge/其他）。顶部「🚀 上手路线」五步导航按真实状态点亮、可点击直达。「② 服务端运行」提供重启（RCON 安全 stop + 看门狗自动拉起）与停止（写 `maintenance.stop` 标记，不自动重启；下次启动自动清除）。左栏「常用设置」可一键切换正版验证/白名单/PVP/难度并写入 `server.properties`（写入前自动备份，改完提示需重启生效）。整合包信息里有「本服检测」行，直接扫 `libraries` 实测版本和加载器，配置与本服不符时黄牌提醒去跑向导。可一键直达服务端 mods、主客户端 mods、主客户端根目录等常用目录，设置主分发客户端有三个等价入口：整合包信息里的「主客户端」行直接点击、①配置里的「选择分发客户端目录」按钮、日志与目录里的「选择主客户端…」按钮，都会弹出文件夹选择器，任意目录（含服务端外）皆可（写入前自动备份到 `backups/panel-config`）。右下角提供暗夜/白昼/深海/翡翠/樱花五套主题，选择记忆在 `tmp/panel-theme.txt`。左栏「📊 性能监控」用四个环形占比仪表实时展示服务端 CPU、整机 GPU、系统内存、磁盘占用（每 5 秒刷新，负载按绿/黄/红三档变色；服务端主刻循环是 CPU 密集型、TPS 掉即 CPU 顶不住，服务端本身不碰 GPU，GPU 环监控的是整机最忙引擎、口径同任务管理器），配最近 5 分钟负载趋势曲线，下方列出服务端内存、世界/备份占用（GPU 与目录扫描都在后台采样，不卡界面）。右栏「💾 备份管理」显示备份轮次/总占用/最新时间，列表按日期筛选、Ctrl/Shift 多选、弹窗确认后删除，双击定位文件，也可「立即备份」手动触发一轮；「⬇ 服务端下载与安装」弹文件夹选择器后调度 `tools/install-server.ps1`，任选版本与加载器一键部署全新服务端（或重装当前目录核心，会先弹窗确认）。除「选择主客户端」只改 `sourceClient` 一个字段外，面板只负责调度与查看，关闭面板不影响任何已启动的进程。
- `一键脚本\一键生成便携工具包.bat`: 生成公开工具包，不携带真实私密配置。
- `一键脚本\一键生成精简工具包.bat`: 生成精简工具包（公开包去 LLBot 本体，体积小便于传播）。
- `一键脚本\一键生成私用便携工具包.bat`: 生成私用工具包，会携带当前 `portable-pack.json` 和 `ops-config.json`。

## 工具包自更新与检查更新

工具包像常规软件一样自带更新能力，面板⑤点「检查更新」：比对版本号 → 弹窗展示新版本号与更新日志 → 确认后一键更新并自动重启面板。**本服 `portable-pack.json`、`ops-config.json`、更新源配置永不覆盖**，其余被改动的文件先备份到 `backups\toolkit-update-*`；QQ 机器人运行中被占用的 LLBot 程序文件会逐个跳过（登录数据不受影响）。

更新源写在 `tools\toolkit-update-source.txt`（一行本地 zip 路径或 HTTPS URL）：

- **公开/精简包**：为避免泄露作者自己的域名和端口，出厂不带该文件；面板会提示“未配置更新源”。发布者如要提供公版自更新，应自行写入明确授权的 HTTPS 下载 URL。生成精简包仍会发布到本机 `modpack-public\kit-update`，但不会把本机地址反向写进公版。
- **私用包**：内置主发布目录 `dist\portable-server-kit-private-latest.zip` 的本机路径，自己的多台服务端零配置跟进；在主发布目录本身点检查更新会被识别并拦下（防止旧包覆盖开发中的新改动）。
- 命令行等价入口：`一键脚本\一键更新工具包.bat`。生成工具包的三个 bat 仅私用包携带（公开/精简包用户是使用者，不需要再分发）。

版本号在根目录 `KIT-VERSION.txt`，更新日志在 `KIT-CHANGELOG.txt`（作者每次发布前在主目录 `docs\KIT-CHANGELOG.txt` 顶部补一段，随包分发并在检查更新弹窗中展示）。

## 下个服怎么用

如果是你自己迁移，优先用私用工具包：

1. 在已经更新过工具包的当前目录双击 `一键脚本\一键生成私用便携工具包.bat`。如果当前目录本身还是旧工具包，生成出来也会是旧包。
2. 优先把 `dist\portable-server-kit-private-latest.zip` 解压到下个服务端根目录；时间戳 zip 只是留档。
3. 双击 `一键脚本\一键便携-初始化配置.bat`，看中文检测结果，第一次建议选 `2` 逐项确认。
4. 重点确认：整合包名、`packId`、主分发客户端、Minecraft 版本、加载器类型/版本、玩家连接地址、更新服务 host/port、Discord 显示名、世界名和备份前缀。主分发客户端建议固定为服务端根目录内目录，例如 `.\主分发客户端`、`.\main-client`，或 `.\客户端\.minecraft\versions\1.20.1-Forge_47.4.20` 这种启动器版本目录；以后加 mod、修 config 都只改这个目录。
5. 双击 `一键脚本\一键便携-生成规范导入包.bat`（或面板「生成规范导入包」），生成规范导入包和 PCL 包；需要传统玩家同步包 zip 时再用 `一键脚本\一键便携-生成玩家包.bat`。
6. 双击 `一键脚本\一键便携-开启更新服务.bat`，让玩家同步器能访问更新源。
7. 开服时双击 `一键脚本\一键便携-启动服务端.bat`，让 Discord、QQ、备份、崩溃监控一起工作。直接双击 Forge 自带 `run.bat` 只会开服，不会启动 Discord 监控。

如果是要给别人一个干净工具包，用公开工具包：

1. 双击 `一键脚本\一键生成便携工具包.bat`。
2. 把 `dist\portable-server-kit-*.zip` 给对方。
3. 对方解压后直接双击 `一键脚本\一键便携-初始化配置.bat`，不需要手动复制模板。

如果对方只需要玩家拉新与更新，不需要整套运维机器人，则生成并分享 `dist\minecraft-player-recruit-kit-latest.zip`；对方运行 `一键脚本\一键拉新-初始化配置.bat` 后，只会维护 `portable-pack.json`，不会生成 `ops-config.json` 或启用 RCON。

## 开启更新服务

先保持 `tools/portable-pack.json` 的 `update.host` 和 `update.port` 与公网入口一致，然后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\start-portable-update-server.ps1 -ConfigPath .\tools\portable-pack.json
```

`portable-publish.ps1` 会生成或复用 `.update-server-token`。不要把这个 token 当公开链接发到群里，只发玩家包即可。

## 运维监控进程规则

- `一键脚本\一键便携-初始化配置.bat` 保存配置后会自动用 `start-ops-monitor.ps1 -Restart` 刷新 Discord/QQ/备份监控，让新服务器名、地址、webhook 等立即生效。
- `一键脚本\一键便携-启动服务端.bat` 只会调用普通启动；如果监控已经是当前配置，它会复用现有进程，不会再开第二份。
- Discord 频道反控直接记录 Java 进程 PID；初始化刷新或停止监控时也会清理旧版相对路径残留进程，避免多个 bot 轮询导致 Discord 429 限流。
- 一键入口启动服务端时已启用 `-RestartOnCleanExit`：手动控制台 `stop`、QQ群/Discord `!stop` 或 `!restart` 都会让 wrapper 在 10 秒后自动拉起。若你手动运行 `portable-run-server.ps1` 且不传此参数，则正常退出不重启。
- 停服后默认保留运维监控，这样仍可发停服/崩溃/备份/IP 变化通知，也能避免停服瞬间漏消息。监控是单例，不会因为下次开服重复堆进程。
- 如果你确定今天不再需要 Discord/备份/频道反控，双击 `一键脚本\一键便携-停止所有运维.bat` 清理监控进程和锁文件。
- 进阶：如果确实想让 wrapper 结束时顺便关闭监控，可手动运行 `tools\portable-run-server.ps1 -StopOpsMonitorOnExit`；默认入口不这样做。
- **不要用「以管理员身份运行」跑任何一键入口**：工具全程不需要管理员权限。一旦运维进程被管理员身份启动，之后普通双击就无法停止/重启它们（Windows 不允许普通进程结束提权进程），会报「权限不足，请用管理员权限运行一键入口」——补救办法是用管理员身份跑一次 `一键脚本\一键便携-停止所有运维.bat` 清干净，之后一律普通双击。

## RCON 自动化

RCON 是 Minecraft 服务端的本地远程控制台，Discord/QQ 反控里的 `!cmd`、`!day`、`!tps`、`!stop`/`!restart`，以及定时/手动备份前的 `save-off/save-all/save-on` 都会用到它。

- `enable-rcon=true`：开启 RCON；不是写 `enable`，值必须是 `true` 或 `false`。
- `rcon.port=25575`：RCON 端口，工具默认用本机 `127.0.0.1:25575` 连接。
- `rcon.password=...`：RCON 密码，脚本会自动生成或保留强密码；这是本机 `server.properties` 的密码，不是 Discord token/webhook，也不需要填进 `tools/ops-config.json`。
- `broadcast-rcon-to-ops=false`：RCON 命令结果不刷给在线 OP，减少频道反控时的游戏内噪音。
- `enable-query`：旧式查询协议，主要给外部查询工具用；Discord 反控不依赖它，默认不需要打开。

每台服务端的 RCON 各自独立：开关和密码都只写在自己目录的 `server.properties` 里，A 服开着 RCON 不会影响 B 服。唯一要注意的是**同一台电脑同时跑两个服务端**时，两边不能都用 25575——后启动的那个 RCON 会绑定端口失败（Minecraft 本体照常运行，但反控/备份用不了 RCON）。给其中一个服把 `rcon.port` 手动改成别的端口（如 25576）即可；不同电脑或不同时运行则完全不用管。面板「① 配置」里有一对开关按钮：「启用 RCON 反控」与「关闭 RCON」（后者执行 `tools/enable-local-rcon.ps1 -Disable`，只把 `enable-rcon` 设为 `false`，端口和密码保留，下次一键重开），两者都需重启 Minecraft 服务端后生效。
- `enable-status`：允许客户端服务器列表/MOTD 状态 ping，通常保持 `true`。

修改 `enable-rcon`、`rcon.port` 或 `rcon.password` 后，必须重启 Minecraft 服务端才会生效；只重启 Discord 监控不够。
## 动态公网 IP 与 DDNS

家宽/动态 IP 场景，重拨后公网 IP 一变，域名解析没跟上，玩家就会「服务器列表刷不出来」。工具包提供两层保障：

- **变化监控（默认开启）**：运维监控每 `ipWatch.pollMinutes` 分钟直连探测公网 IPv4 与 IPv6 前缀（**绕过系统代理**，避免拿到 Clash 等代理出口 IP 造成误报），变化即推送 Discord/QQ；状态落盘 `tmp/ipwatch-state.json`，监控停机期间发生的变化重启后也能补报。未启用自动同步时，还会定期比对域名解析与本机公网 IP（`ipWatch.dnsMismatchAlert`），连续两次不一致就告警「解析未同步」。
- **DDNS 自动同步（域名托管在 DNSPod/腾讯云解析时强烈建议开启）**：在 `ops-config.json` 的 `ddns` 段填好 DNSPod API 密钥（console.dnspod.cn -> 账号中心 -> API 密钥，格式「ID,Token」）、主域名 `domain` 和记录前缀 `subDomain`，`enabled` 改 `true`。之后公网 IP 一变，运维监控**立刻**把 A/AAAA 记录改过来并推送「解析已自动更新」通知；平时每 `checkMinutes` 分钟还会核对一次解析防漏（记录不存在会自动创建）。改完配置先双击「一键脚本\一键便携-同步DDNS解析.bat」手动跑一次验证最省心。

细节与注意事项：

- AAAA（IPv6）记录取的是本机「稳定」全局地址而非出站临时地址，避免 Windows 临时地址每日轮换导致解析天天变；本机暂时没有公网 IPv6 时自动跳过 AAAA，不算失败。
- 解析记录 TTL 默认 600 秒：IP 变化被自动纠正后，老玩家客户端最多约 10 分钟内随 DNS 缓存过期自动恢复，这段时间刷新不出来属正常收敛。
- 如果路由器/光猫里还开着别的 DDNS 客户端，建议关掉，避免两个更新源打架。
- `loginToken` 是密钥，只存在私用配置 `tools/ops-config.json` 里，不会进公开工具包；同步日志在 `logs/ddns-update.log`。

## Discord/QQ/备份监控

公开包流程：运行自动配置向导后，再按需要填写 `discord.webhookUrl`、`discord.botToken`、`discord.channelId`、`discord.adminIds`。频道里可先发 `!id` 查看自己的用户 ID；如果 bot 看到空消息，按日志提示在 Discord Developer Portal 开启 Message Content Intent。

私用包流程：`tools/ops-config.json` 可以带你的长期 Discord/QQ/RCON/备份配置。换服时必须检查服务端名字、地址、RCON 端口/密码、备份保留数量、Discord 频道、QQ 群号和 `qq.adminIds` 是否仍然正确。`!list` 会优先走 RCON；RCON 未启用时会从 `logs/latest.log` 估算在线列表并在 Discord/QQ 里说明原因。

不要把私用包、真实 `tools/ops-config.json`、`.update-server-token`、RCON 密码发给玩家或公开仓库。

## 旧服专用配置

历史服务器专用的整合包名称、主客户端目录、版本号、加载器版本只应该留在对应服务器目录里单独使用，不进入便携工具包。便携工具包只承担“迁移方法和成熟策略”的复用。




