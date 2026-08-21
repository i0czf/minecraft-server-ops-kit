# Minecraft 腐竹运维工具包

面向 Minecraft Java 服务端服主的便携式运维工具包：开服、玩家分发、增量更新、QQ 群运维、备份恢复和性能诊断收在一个可迁移目录里。

项目源自 1.21.1 NeoForge 的长期实战，脚本会优先读取目标服务端的实际版本和加载器，不把某一台服的身份写死在公版里。

实服截图按引入版本放在 [Releases](https://github.com/i0czf/minecraft-server-ops-kit/releases)，首页只保留说明和入口。

## 版本

- [最新稳定版](https://github.com/i0czf/minecraft-server-ops-kit/releases/latest)
- [全部发行说明](https://github.com/i0czf/minecraft-server-ops-kit/releases)
- [版本对比](https://github.com/i0czf/minecraft-server-ops-kit/compare)

发布页只记经过验证、对使用者有意义的批次。

## 适合谁

- 自己维护 Minecraft Java 服务端的个人服主
- 需要把整合包、更新源和运维流程标准化的人
- 想把临时手工排查变成可复用脚本和报告的人
- 需要中文一键入口，但不想被某个启动器或加载器锁定的人

## 主要能力

**服务端**：中文控制面板（启停、RCON、发布、状态）；可选 Web 面板，默认只听 127.0.0.1、令牌登录、任意 RCON 默认关；初始化向导识别版本 / Forge / NeoForge / Fabric / Quilt；按版本匹配 Java；本机 RCON 自动配置。详见 [Web 面板](docs/web-panel-网页远程运维.md)。

**玩家分发**：规范导入包、PCL 包、完整客户端包和增量更新源；Windows / macOS / Linux 同步；尽量保留玩家按键、服务器列表和资源包；哈希校验、混源回落、客户端自助修复。

**QQ 群**：开服 / 聊天 / 进退服 / 成就 / 崩溃 / 备份通知；群友查询、管理执行；高危确认码和审计；可选 AI 助手。QQ 与游戏 ID 绑定后，公屏显示游戏名，游戏里 @游戏ID 会点到对应 QQ；管理员可用 !转发 立刻停双向聊天，用 !绑定提醒 控制未绑定轻提醒。可选图床 + ChatImage 预览、模组发布事务、DDNS。QQ / LLBot 本体不随仓库分发。详见 [绑定说明](docs/qq-player-bind-游戏ID绑定.md)、[图床说明](docs/qq-image-host-转图床.md)。

**AI 多媒体**：QQ 当前消息、引用消息和合并转发里的原视频可由 Qwen3.7 Flash 覆盖完整时间轴；Qwen Audio ASR 负责视频音轨和 QQ 语音文字，Qwen3.5-Omni 可选判断说话、唱歌、纯音乐和环境声，再由默认 DeepSeek 汇总。引用语音发送 `!转写` 只做 ASR，发送 `!听语音` 或带语音 `!问`/`@机器人` 才并行理解声音。Silk 按真实文件头识别：OneBot 转码优先，失败时用内置 `silk-wasm` 解 WAV；长 WAV 超过 Omni 的 Base64 限制时只在本机压成 MP3，ffmpeg 不可用则按 PCM 帧分片，不会为了绕过限制上传公网。机器人不会自动上传全群语音。取不到原视频才退回少量关键帧，任何媒体内容都不能授权服务器操作。详见 [视频、语音识别与 DeepSeek 汇总](docs/qq-video-audio-ai.md)。

**跨群共享 AI 知识库**：主群管理员明确纠正或用 `!知识库记住 主题 => 结论` 写入一次后，所有客群 `@机器人` 都会先按文本与音频 SHA-256 指纹检索相似结论，再交给 DeepSeek 汇总。默认只保存通用短文本，不保存服务器日志/配置、密钥、群号、QQ 号或原始媒体；普通群友只读。可用 `!知识库查询 关键词`、`!知识库删除 关键词` 管理，文件默认 `logs/ai-shared-knowledge.jsonl`。

**备份与诊断**：定时 / 手动备份、ZIP 校验、恢复冒烟、影子服试车、卡顿取证、错误指纹、事故复盘、运维时间线、BlueMap 时光机。扫地僧、配方和要素查询等可选。高风险能力在公版模板里默认关闭。

## 快速开始

1. 把仓库放到服务端根目录，或用构建器生成 `dist/` 下的公版包再解压。新服可以还没有 `server.properties`。
2. 运行 `一键脚本\一键便携-初始化配置.bat`。第一次建议逐项确认。结果写入本机私有文件 `tools\portable-pack.json` 和 `tools\ops-config.json`，不要提交或外发。
3. 需要浏览器运维时运行根目录 `一键便携-Web控制面板.bat`，或 `一键脚本\一键便携-启动Web控制面板.bat`。首次会生成 `tmp\portable-web-panel.token`，默认地址 `http://127.0.0.1:58080/`。远程优先走 SSH / VPN。
4. 启动服务端：`一键脚本\一键便携-启动服务端.bat`。日常启停、运维监控和 RCON 也可走根目录控制面板。
5. 发布玩家更新：确认主客户端和更新源后，运行 `一键脚本\一键便携-生成规范导入包.bat` 和 `一键脚本\一键便携-开启更新服务.bat`。公网更新必须用你自己授权的域名、端口和访问策略。

完整手册：[docs/portable-server-kit.md](docs/portable-server-kit.md)。

## 目录

```text
.
├─ 一键便携-控制面板.bat     根目录唯一的控制面板入口
├─ 一键便携-Web控制面板.bat  根目录 Web 面板快捷入口
├─ 一键脚本/                 可单独双击的一键入口
├─ tools/                    脚本与公版模板（*.example.json）
├─ docs/                     功能说明；截图原件在 docs/assets/
├─ PUBLIC-RELEASE-AUDIT.md   公版纳入 / 排除边界
└─ .gitignore                私有配置和运行目录保护
```

## 构建公版

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\build-portable-server-kit.ps1 `
  -Version 20260820-170600 -Lite -NoUpdateChannel
```

构建器会做白名单、私有文件门禁、路径 / 密钥扫描、脚本编码和语法检查。产物在 `dist/`，默认不进 Git。发布者还可传 `-PrivacyReferenceRoot <实机根目录>`，只读收集实机身份值与公版交叉比对，命中时只报文件、不回显私密值；`-NoUpdateChannel` 用于审计构建，避免提前覆盖本地更新通道。

```powershell
python -m compileall -q .\tools
New-Item -ItemType Directory -Force .\tmp\javac-check | Out-Null
javac --add-modules jdk.httpserver -encoding UTF-8 `
  -d .\tmp\javac-check .\tools\QQConsoleBridge.java
```

## 隐私与安全

仓库只收通用源码、模板和文档，不含：

- 真实 Token、Webhook、密码、群号、域名
- 本机 ops-config.json / portable-pack.json、RCON 密码、更新令牌
- 世界、日志、备份、崩溃报告、玩家缓存、白名单
- 私服客户端、模组、地图、QQ 登录数据和第三方运行时

报 Issue 前先删配置和日志里的域名、IP、玩家名、UUID、群号和密钥。不要整包上传运行中的服务端。

日常建议：密钥放环境变量或本机私有配置；RCON 只听本机并用随机强密码；生产操作先备份，恢复前先验证或影子服试车；不要用管理员身份跑一键入口，除非你清楚在做什么。

## 贡献

欢迎 Issue、文档改进和 Pull Request。提交前请确认：

1. 不含服务器身份、玩家信息或凭据。
2. 新功能在公版模板里默认安全关闭，或写明风险。
3. PowerShell 用 UTF-8；Windows .bat 保持 CRLF、不带 BOM。
4. 跑过公版构建器和相关语法检查。
5. 写明测试环境、Minecraft 版本和加载器。

## 许可证

原创代码采用 [PolyForm Noncommercial License 1.0.0](LICENSE)，© 2026 i0czf。允许非商业使用、修改和再分发；商业使用需事先书面许可。第三方依赖、QQ / LLBot、Minecraft 模组和启动器遵守各自许可证。
