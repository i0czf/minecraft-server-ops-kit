# 真实界面演示

这里的图片来自实际运行中的服务器运维控制面板、QQ 桥接和 Minecraft 游戏内消息，不是概念图。它们用于说明工具包的真实交互边界，不代表安装后会自带 QQ/LLBot 客户端、模组、地图或服务器运行数据。

为适合公开展示，图片只保留能力验证所需内容；本机路径、端口/PID、真实服务地址、凭据和运行数据已脱敏。此前界面截图中的昵称、头像和玩家名已遮挡；反控指令集合图保留了示例角色标签、昵称和头像，用于说明权限分层，不包含凭据或服务地址。原始未脱敏截图不随仓库发布。

## 控制面板总览

实际 WPF 控制面板集中展示运行状态、性能监控、发布/拉新、工具包更新和 RCON 快捷控制台。

![服务器运维控制面板总览](assets/control-panel-overview.png)

## QQ 群与游戏内消息双向同步

QQ 侧可以收到服务端事件或转发的聊天消息：

![QQ 群消息桥接](assets/qq-server-sync.png)

游戏内聊天窗口也能看到桥接回传的消息：

![Minecraft 游戏内消息桥接](assets/minecraft-chat-sync.png)

两张图分别展示桥接链路的 QQ 端和游戏端，不依赖公开仓库携带任何登录资料。

## QQ 图片与表情包的 ChatImage 预览

安装 ChatImage 客户端 Mod 后，QQ 普通图片与表情包会经过图床转存，以 `CICode` 形式进入 Minecraft 聊天；玩家可以直接触发图片预览，普通图片和表情包仍保留不同标签。以下为 NeoForge 1.21.1 / 21.1.235 实服截图：

![QQ 普通图片的 ChatImage 游戏内预览实测](assets/qq-chatimage-image-preview.png)

![QQ 表情包的 ChatImage 游戏内预览实测](assets/qq-chatimage-sticker-preview.png)

## QQ 号与游戏 ID 绑定

群友可以在 QQ 里把账号绑到本服游戏 ID。绑定后的主群消息进入 Minecraft 时，公屏会显示群名片和游戏 ID；安装 ChatImage 后，悬停名字前的 `●` 能看到该角色头像。下面是实服截图：QQ 侧头像和群名已打码，仅保留命令、回执和公屏效果。

![QQ 群里绑定游戏 ID](assets/qq-player-bind-qq-command.jpg)

![游戏公屏显示绑定 ID 并悬停预览皮肤头像](assets/qq-player-bind-minecraft-preview.png)

命令、权限和配置见 [QQ 号与游戏 ID 绑定](qq-player-bind-游戏ID绑定.md)。

## 反控指令集合

`!help` 汇总了普通查询、信息检索、管理操作和需要确认码的高危操作，可以直观看到权限边界。

![QQ 反控指令集合](assets/qq-command-catalog.png)

## QQ 反控查询

`!list`、`!tps` 等无破坏查询可以从 QQ 发起，并由机器人返回在线玩家和性能信息；高危操作仍受权限和确认流程约束。

![QQ RCON 查询](assets/qq-rcon-commands.png)

## @QQ 机器人的 AI 运维辅助

在群内 @ 机器人并描述服务器异常后，AI 助手可以结合看门狗/崩溃报告给出故障类型、卡顿位置、关联模组和排查建议。截图中的分析内容来自实际运行示例，具体结果取决于目标服务器日志和配置。

![QQ AI 运维助手](assets/qq-ai-ops-assistant.png)
