# v0.1.0 · 首次公开版

面向需要长期维护 Minecraft Java 服务端的个人服主和小型团队。

## 主要更新

**服务端与 Web**：便携 Web 运维面板（状态、性能、日志、RCON；启停、备份、体检、复盘）；手机端窄屏布局；默认只听本机，任意 RCON 默认关。

**玩家分发**：规范导入包、PCL 包、完整客户端包、增量更新源；Windows / macOS / Linux 同步；局域网回退和客户端自助修复；尽量保留玩家个性化文件。

**QQ 与 AI**：QQ ↔ Minecraft 双向同步、权限分层、高危确认和审计；AI 连续回复增加一次受限恢复；工具独立超时。

**备份与诊断**：定时备份、校验、恢复冒烟、影子服、卡顿取证、错误指纹、事故复盘、运维时间线。DeepSeek 价格从官方页按北京高峰/非高峰读取。

## 实服截图

路径、端口、地址和凭据已脱敏。反控指令图保留示例角色标签，用来说明权限分层。

控制面板总览：

![服务器运维控制面板](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/control-panel-overview.png)

Web 面板手机端（性能、控制、日志 / RCON）：

![Web 面板性能](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/web-panel-mobile-performance.jpg)

![Web 面板控制](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/web-panel-mobile-control.jpg)

![Web 面板日志与 RCON](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/web-panel-mobile-logs-rcon.jpg)

QQ ↔ 游戏双向聊天：

![QQ 群消息桥接](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/qq-server-sync.png)

![Minecraft 游戏内消息桥接](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/minecraft-chat-sync.png)

反控、查询和 AI：

![QQ 反控指令集合](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/qq-command-catalog.png)

![QQ RCON 查询](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/qq-rcon-commands.png)

![QQ AI 运维助手](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/qq-ai-ops-assistant.png)

## 安全边界

公版不含真实配置、密码、Token、域名、玩家数据、世界、日志、QQ 登录数据或第三方客户端。高风险功能默认关闭。原创代码采用 PolyForm Noncommercial License 1.0.0。

## 快速开始

1. 下载本 Release 源码包，解压到服务端目录。
2. 运行 `一键脚本\一键便携-初始化配置.bat`。
3. 按 [README](https://github.com/i0czf/minecraft-server-ops-kit#readme) 继续启动或开 Web 面板。
4. 不要把运行中的服务端目录整体上传到 GitHub。
