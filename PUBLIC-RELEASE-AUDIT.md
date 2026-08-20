# 公版发布边界

本仓库是从运行中的 Minecraft 服务端目录按公版白名单整理出的源码仓库。原服务端目录不属于本仓库，也不会被 Git 跟踪。

## 已纳入

- 通用运维脚本、桌面/Web 控制面板、QQ 桥接源码和玩家同步工具
- Web 面板远程运维说明
- 公版配置模板（`tools/*.example.json`）
- 公版构建器、验证脚本和通用使用文档
- 经脱敏的实服截图原件（`docs/assets/`），按版本嵌在发行说明里；`docs/live-ui-demo.md` 只作索引
- 近期功能：备份验证、卡顿取证、事故复盘、BlueMap 时光机、模组发布事务、配方/要素索引、客户端自助修复、QQ 图片/表情包图床转发、QQ 与游戏 ID 绑定，以及绑定提醒、游戏 `@ID` 点 QQ、`!转发` 开关等
- v0.4.0 媒体流水线：QQ 原视频 → Qwen3.7 Flash 完整时间轴画面；可选 Qwen Audio ASR 并行音轨；默认 DeepSeek 最终汇总；媒体提示注入隔离和明确降级
- 根目录 Web 面板快捷入口，以及独立实机目录隐私交叉比对 / 无更新通道审计构建参数

## 明确排除

- `tools/portable-pack.json`、`tools/ops-config.json`、`tools/portable-web-panel.json`、更新源 token、Web 面板令牌、RCON 密码
- 世界、日志、备份、崩溃报告、玩家缓存、OP/白名单/封禁名单
- 运行时绑定与开关：`logs/qq-player-binds.json`、`logs/qq-chat-relay.json`、`logs/qq-bind-remind.json`
- 私服客户端、模组、地图、存档和服务端运行时目录
- QQ/LLBot 登录数据、二维码、第三方 QQ 客户端、启动器和本机依赖
- 私服域名、群号、频道号、机器人 token、DDNS/API 密钥和本机绝对路径
- 原始未脱敏截图；`docs/assets/` 只允许放经过裁剪或遮挡的公开展示副本
- QQ 下载的视频、抽帧、ASR 文本、模型请求/回答、临时媒体目录和任何真实群聊内容

## 公版构建

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\build-portable-server-kit.ps1 `
  -Version 20260820-170600 -Lite -NoUpdateChannel `
  -PrivacyReferenceRoot C:\path\to\private-server-root
```

构建器会执行隐私、脚本编码、PowerShell 语法和关键功能门禁，并将生成物放到 `dist/`（该目录已被 `.gitignore` 排除）。首次使用时复制模板或运行初始化向导，不要把真实配置文件改名后提交。

本仓库不携带 QQ/LLBot 本体；需要 QQ 机器人时，请在目标机器按文档自行安装，并在本机生成配置。第三方组件请遵守各自许可证。

## v0.4.0 验收（2026-08-20）

- 精简公版：140 个文件，826,280 字节；SHA-256 `2B94C669A9A3BE3120A90047563F64366EFDFEF3E396CF860C09069167F3AF3F`；ZIP CRC 全通过。
- 可复现构建：压缩条目使用固定 ZIP 标准时间戳；同一源码树、同一版本连续独立构建两次的字节数与 SHA-256 完全一致，且 `-NoUpdateChannel` 未改动实机更新通道。
- 脱敏：167 个待推文件完成通用密钥模式与实机私有值交叉扫描；真实域名、群号、玩家身份、绝对路径、Webhook/Token/API Key 均为 0 命中；模板非空 API Key 为 0。
- Java：包内 `QQConsoleBridge.java` 独立编译通过，`--media-selftest` 通过；`--ai-status` 核对为 DeepSeek 最终模型 + Qwen3.7 Flash 视频预处理 + ASR 公版默认关闭。
- 脚本：57 个 PowerShell 解析通过，7 个 JSON 解析通过，36 个 BAT 均为 CRLF/无 BOM，1 个 macOS `.command` 为 LF/无 BOM，Python 全量编译通过。
- 回归：玩家混源更新器 15 项测试通过；实机 QQ/OneBot 只读回归 6/6，通过期间未发送群测试消息，原机器人进程保持运行。
- 端到端：真实短视频验证过“Qwen 完整时间轴画面 + Qwen Audio ASR + DeepSeek 汇总”，三阶段均有独立耗时和费用记录；测试媒体、转写和日志未进入仓库或 ZIP。
