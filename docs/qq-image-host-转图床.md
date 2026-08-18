# QQ 图片自动转存与 Minecraft 预览 / 大图

本说明描述 QQ 图片、GIF 和表情图片如何经过本机图床转存，再以链接或 ChatImage 预览的方式进入 Minecraft。文中的域名、路径和令牌均为示例；真实地址只放在目标服务器的私有配置中。

## 先看结论

- 自动转发：打开 `imageHost.enabled` 和 `imageHost.autoRelay` 后，QQ 普通图片、GIF 和表情图片会自动下载、校验并上传到图床。
- 手动转存：引用图片或表情包后发送 `!转图床` 或 `!上传图床`；也可以把图片和命令放在同一条消息里。
- Minecraft 预览：`minecraftImageMode=chatimage` 时，桥会发送 ChatImage `CICode`；安装匹配客户端 Mod 的玩家可以悬停预览。
- 降级路径：没有 ChatImage 时仍显示可点击链接；图床上传失败时回退为 QQ 原图链接，不阻塞文字消息。

## 自动转发流程

1. QQ 群里发送普通图片、GIF 或表情图片，不需要额外命令。
2. QQ 桥下载原图，并通过本机回环地址上传到图床，例如 `http://127.0.0.1:38080/upload`。
3. 图床按内容哈希保存图片；同一来源或同一内容在缓存有效期内不会重复上传。
4. 自动转发生成的 Minecraft 图片地址按 `minecraftBaseUrl`、`publicBaseUrl`、`lanBaseUrl` 的顺序选择。远端玩家场景必须让 `minecraftBaseUrl`（或回退使用的 `publicBaseUrl`）对每个玩家可访问，不能使用服务器本机的 `127.0.0.1` 或仅局域网地址。
5. 普通图片显示为`[图片]`，动画/商城表情及表情子类型图片显示为`[表情包]`。下载失败、格式不支持或超过大小限制时，会保留原图链接并继续转发整条消息。

## 群里手动转图床

1. 长按要转的图片、表情包或动图，选择引用。
2. 发送 `!转图床` 或 `!上传图床`；全角前缀也可以使用。
3. 一次最多处理 5 张图片；引用原文、消息数组和回复预览中重复出现的同一图片会按 QQ 文件标识或内容哈希去重。

成功后会返回类似下面的直链：

```text
http://image-host.example.com:38080/i/<文件名>.gif
```

`memberAccess=true` 时普通群成员也可以使用手动转存；设为 `false` 时仅群主/管理员可用。无论哪种模式，高危服务器运维命令仍由独立权限边界控制。

## 配置

在私有的 `tools/ops-config.json` 根级 `imageHost` 中配置。公版只提供模板，不要把真实域名、令牌或服务器路径写回仓库：

```json
{
  "enabled": true,
  "memberAccess": true,
  "autoRelay": true,
  "uploadUrl": "http://127.0.0.1:38080/upload",
  "publicBaseUrl": "http://image-host.example.com:38080",
  "lanBaseUrl": "",
  "bindHost": "0.0.0.0",
  "minecraftBaseUrl": "http://image-host.example.com:38080",
  "minecraftImageMode": "chatimage",
  "tokensFile": "tools/image-host-tokens.json",
  "tokenLabel": "qq-chat-relay",
  "maxBytes": 20971520,
  "relayCacheMinutes": 1440,
  "root": "tmp/image-host",
  "port": 38080
}
```

地址分工很重要：

- `uploadUrl` 只给服务器本机使用，默认监听回环地址即可。
- `publicBaseUrl` 用于手动转存返回的公开直链。
- `minecraftBaseUrl` 用于自动转发到 Minecraft 的图片地址；远端玩家必须能访问它。若留空，桥会回退到 `publicBaseUrl`，不要把 `lanBaseUrl` 误当成公网地址。
- 需要远端玩家访问时才考虑 `bindHost=0.0.0.0`，并在防火墙/路由器只放行图床所需端口。
- `tools/image-host-tokens.json` 和 `tools/ops-config.json` 属于私有配置，不能提交到公版仓库或发送到群里。

图床启动器会检查 `/status`，如果兼容的图床已经在端口上运行就跳过重复启动：

```powershell
.\tools\start-image-host.ps1 -NoPause
```

修改 QQ 桥配置后，按现有部署方式热重载 QQ 桥：

```powershell
.\tools\reload-qq-console.ps1 -NoPause
```

## 服务器内悬停预览和点击查看大图

将模式设置为：

```json
"minecraftImageMode": "chatimage"
```

桥会把 ChatImage `CICode` 放进可见图片文本的悬停内容，并把 `open_url` 点击事件绑定到同一个文本组件：

1. 将鼠标悬停在聊天里的`[图片]`或`[表情包]`上，查看 ChatImage 预览。
2. 点击同一个预览项，客户端会按 Minecraft 的浏览器打开确认流程访问图床大图。
3. 如果只看到文字链接，说明客户端没有安装或没有加载与当前 Minecraft/NeoForge 版本匹配的 ChatImage；直接点击链接仍可在浏览器查看。

模式选择：

| `minecraftImageMode` | 依赖 | 效果 |
| --- | --- | --- |
| `link` | 不需要额外 Mod/插件 | 显示链接，悬停查看地址，点击浏览器打开 |
| `chatimage` | 每个要预览的玩家安装匹配版本的 [ChatImage](https://modrinth.com/mod/chatimage) 客户端 Mod | Minecraft 聊天内悬停预览图片 |
| `imagepreviewer` | Paper/Spigot 服务端安装 [ImagePreviewer](https://www.spigotmc.org/resources/image-previewer%E2%80%8B-preview-images-in-chat-bar-with-ease-1-20-1-21-3.120888/) 和 PacketEvents | 执行插件预览命令；不适用于纯 NeoForge 服务端 |

本项目的 NeoForge 1.21.1 / 21.1.235 实测采用 ChatImage 路径；客户端 Mod 构建必须以实际 Minecraft/NeoForge 版本为准，不能直接套用其他版本的 JAR。

## 常见失败

- 没有自动转存：确认 `imageHost.enabled=true`、`autoRelay=true`，令牌文件存在且标签匹配。
- 手动命令提示无权限：检查 `memberAccess`；管理员仍需通过项目的管理员识别逻辑。
- 图床无响应：访问本机 `http://127.0.0.1:38080/status`，检查图床进程、端口和日志。
- 玩家打不开图片：检查 `minecraftBaseUrl` 是否为玩家可达地址、防火墙是否放行，以及图床是否只监听了 `127.0.0.1`。
- 图片转发失败：QQ 原图可能已过期、下载需要鉴权、超过默认 20MB，或格式不是 PNG/JPG/GIF/WEBP/BMP。
- 只有文字没有预览：检查客户端是否安装并加载了与当前版本匹配的 ChatImage。

令牌、实际域名、私服目录、群号和运行日志不要写进公开文档。
