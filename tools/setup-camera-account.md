# 旁观摄像机账号（player_view）

目标：让 QQ 机器人能像**客户端**那样看到玩家正在做什么（挖矿、打架、看向哪里），而不是只有 BlueMap 地图标点。

## 原理

1. 本机常驻一个**专用摄像机账号**的 Minecraft 客户端（同模组包）
2. 机器人通过 RCON 执行：`gamemode spectator <摄像机>` → `execute as <摄像机> run spectate <目标>`
3. 摄像机客户端进入该玩家的**第一人称旁观视角**（能看到挥手、挖方块、手持物等）
4. 截取客户端窗口画面（可选再录 3～5 秒短视频）发到 QQ 群

> BlueMap **做不到**动作画面；这是唯一稳妥且适配重度 NeoForge 模组服的方案。

## 一次性配置

### 1. 建号

1. 用启动器打开本服配套客户端（`客户端\` 或 `modpack-public\hmcl-serverpack`）
2. 离线名示例：`CameraBot`（须与 `ops-config.json` 里 `ai.playerView.cameraPlayer` 一致）
3. 连上你在 `ops-config.json` 中配置的服务器地址，或本机测试用 `localhost`
4. 完成 AuthShield 注册/登录（与正常玩家相同）
5. **保持客户端窗口开着**（可最小化；截图前脚本会尝试还原窗口）

### 2. 开 OP（推荐）

控制台或已有 OP 执行：

```text
op CameraBot
```

旁观指令一般不需要 OP，但 OP 可减少部分模组限制。

### 3. 配置文件

`tools/ops-config.json` → `ai.playerView`：

```json
"playerView": {
  "enabled": true,
  "cameraPlayer": "CameraBot",
  "memberAccess": true,
  "clipSeconds": 4,
  "settleMs": 1500,
  "titleMatch": "Minecraft NeoForge"
}
```

| 字段 | 含义 |
|------|------|
| `enabled` | 总开关 |
| `cameraPlayer` | 摄像机游戏名 |
| `memberAccess` | 普通群友能否让 AI 用（第一人称较隐私，可改 `false` 仅管理员） |
| `clipSeconds` | 短视频秒数，`0` 只发静图 |
| `settleMs` | 旁观切换后等待渲染的毫秒 |
| `titleMatch` | 匹配客户端窗口标题的正则/关键字 |

### 4. 重启 QQ 运维桥

控制面板重新「启动运维监控」，或停掉旧 `QQConsoleBridge` 再启，使新 class 生效。

## 群里怎么用

对机器人说例如：

- 「@机器人 sl 在干嘛，给我看客户端画面」
- 「看看 Sample_Player 在干什么」

AI 会优先走 **`player_view`**（客户端视角）；问「在地图哪」仍可用 BlueMap。

## 故障排查

| 现象 | 处理 |
|------|------|
| 提示摄像机不在线 | 用专用摄像机账号登录客户端并保持在线 |
| 提示未找到 Minecraft 窗口 | 客户端是否在本机；标题是否含 `Minecraft NeoForge`；改 `titleMatch` |
| 截到主菜单/选服界面 | 摄像机未进服或掉线，重新进服 |
| 画面是史蒂夫视角但不是目标 | RCON 旁观失败：看 `logs/qq-console.log`；确认目标在线 |
| 短视频没有 | 安装 ffmpeg 并加入 PATH；或把 `clipSeconds` 设为 0 只用静图 |
| AuthShield 踢摄像机 | 登录一次后不要关客户端；超时设置见 `config/authshield` |

## 隐私说明

旁观视角≈看对方屏幕内容（手持、准心方向、部分 HUD）。公开群建议 `memberAccess: false`，或仅在信任群开启。
