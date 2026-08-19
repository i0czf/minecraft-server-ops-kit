# 公版发布边界

本仓库是从运行中的 Minecraft 服务端目录按公版白名单整理出的源码仓库。原服务端目录不属于本仓库，也不会被 Git 跟踪。

## 已纳入

- 通用运维脚本、桌面/Web 控制面板、QQ 桥接源码和玩家同步工具
- Web 面板远程运维说明，以及经过元数据清理的真实手机端界面截图
- 公版配置模板（`tools/*.example.json`）
- 公版构建器、验证脚本和通用使用文档
- 经脱敏的真实运行界面截
- 近期功能：备份验证、卡顿取证、事故复盘、BlueMap 时光机、模组发布事务、配方/要素索引、客户端自助修复、QQ 图片/表情包图床转发、QQ 与游戏 ID 绑定，以及绑定提醒、游戏 `@ID` 点 QQ、`!转发` 开关、Windows 更新入口换行门禁与 9009 回落等

## 明确排除

- `tools/portable-pack.json`、`tools/ops-config.json`、`tools/portable-web-panel.json`、更新源 token、Web 面板令牌、RCON 密码
- 世界、日志、备份、崩溃报告、玩家缓存、OP/白名单/封禁名单
- 运行时绑定与开关：`logs/qq-player-binds.json`、`logs/qq-chat-relay.json`、`logs/qq-bind-remind.json`
- 私服客户端、模组、地图、存档和服务端运行时目录
- QQ/LLBot 登录数据、二维码、第三方 QQ 客户端、启动器和本机依赖
- 私服域名、群号、频道号、机器人 token、DDNS/API 密钥和本机绝对路径
- 原始未脱敏截图；`docs/assets/` 只允许放经过裁剪或遮挡的公开展示副本

## 公版构建

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-portable-server-kit.ps1 -Version 20260816-public
```

构建器会执行隐私、脚本编码、PowerShell 语法和关键功能门禁，并将生成物放到 `dist/`（该目录已被 `.gitignore` 排除）。首次使用时复制模板或运行初始化向导，不要把真实配置文件改名后提交。

本仓库不携带 QQ/LLBot 本体；需要 QQ 机器人时，请在目标机器按文档自行安装，并在本机生成配置。第三方组件请遵守各自许可证。
