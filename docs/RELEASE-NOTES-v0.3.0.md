# v0.3.0 · QQ 号与游戏 ID 绑定

## 新增

- QQ 群可以把 QQ 号和本服游戏 ID 一对一绑定，接到现有 QQ 桥上，不引入 MCDR 或新的机器人。
- 普通群友：`!绑定 游戏ID`、`!绑定查询`、`!解绑`、`!id`。
- 管理员：`!绑定 @某人 游戏ID`、`!解绑 @某人`、`!绑定列表`。
- 绑定后，主群消息进入 Minecraft 公屏会同时显示群名片和游戏 ID；群里的 `@QQ` 在对方已绑定时显示为 `@游戏ID`。
- 可选皮肤头像：安装 ChatImage 后，悬停名字前的 `●` 预览该角色头像，复用现有皮肤同步和图床链路。图床或客户端没有 ChatImage 时，文字 ID 仍正常显示。
- 默认一人一号、再绑即改绑；`requireSeenOnServer=true` 时必须先进过服。绑定数据写在 `logs/qq-player-binds.json`，属于运行时数据，不要提交到仓库。

## 实服截图

NeoForge 1.21.1 / 21.1.235。QQ 侧头像和群名已打码。命令与配置见 [QQ 号与游戏 ID 绑定](https://github.com/i0czf/minecraft-server-ops-kit/blob/main/docs/qq-player-bind-%E6%B8%B8%E6%88%8FID%E7%BB%91%E5%AE%9A.md)。后续提醒、游戏 `@` 和 `!转发` 见 [v0.3.1](https://github.com/i0czf/minecraft-server-ops-kit/releases/tag/v0.3.1)。

![QQ 群里绑定游戏 ID](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/qq-player-bind-qq-command.jpg)

![游戏公屏显示绑定 ID 并悬停预览皮肤头像](https://github.com/i0czf/minecraft-server-ops-kit/raw/main/docs/assets/qq-player-bind-minecraft-preview.png)

## 配置要点

公版模板默认关闭。复制到本机 `tools/ops-config.json` 后按需打开：

```json
{
  "playerBind": {
    "enabled": false,
    "memberAccess": true,
    "requireSeenOnServer": true,
    "showSkinHead": true,
    "maxPerQq": 1,
    "namePattern": "^[A-Za-z0-9_]{1,16}$",
    "store": "logs/qq-player-binds.json"
  }
}
```

改完只热重载 QQ 桥，不要把真实群号、令牌、绑定 JSON 或 `ops-config.json` 提交到仓库。

## 同期也包含

相对 `v0.2.0`，这次发布还带上玩家更新器与活动感知备份的优化（不再探测家里的局域网地址、无更新时少做整包哈希、官方源按持续速率回落、有人在线才按周期备份）。

## 验证

- NeoForge 1.21.1 / 21.1.235 实服已完成绑定，并在游戏公屏看到 ID 和头像预览。
- `QQConsoleBridge --bind-selftest` 通过。
- 公版文件隐私扫描通过：无真实域名、IP、群号、令牌或绑定仓库。
