# v0.2.0 · QQ 图片/表情包图床转发与 ChatImage 预览

## 新增

- QQ 普通图片、GIF 和表情包自动下载、校验并转存图床。
- Minecraft 聊天使用可被所有玩家访问的公链地址；上传仍通过服务端本机回环地址完成。
- 普通图片显示为“图片”，动画/商城表情及表情子类型图片显示为“表情包”。
- 增加 `link`、`chatimage`、`imagepreviewer` 三种 Minecraft 渲染模式。
- `chatimage` 模式发送 ChatImage `CICode`，安装对应客户端模组的玩家可直接在聊天栏预览远程图片。
- 图片同源/同内容缓存、失败回退和有界队列，避免媒体处理阻塞 QQ WebSocket。

## 实际效果

- 已补入 NeoForge 1.21.1 / 21.1.235 实服的普通图片与表情包预览截图，见 [真实界面演示](live-ui-demo.md) 和 [PF-GUGUBot 功能核查](PF-GUGUBot功能核查与跟进方案.md)。
- 截图素材位于 `docs/assets/qq-chatimage-image-preview.png` 与 `docs/assets/qq-chatimage-sticker-preview.png`，用于说明 `CICode` 预览和`[图片]`/`[表情包]`语义区分。

## 配置要点

```json
{
  "autoRelay": true,
  "uploadUrl": "http://127.0.0.1:38080/upload",
  "publicBaseUrl": "http://image-host.example.com:38080",
  "minecraftBaseUrl": "http://image-host.example.com:38080",
  "minecraftImageMode": "chatimage"
}
```

`minecraftBaseUrl` 必须是所有 Minecraft 客户端都能访问的地址，不能使用服务器本机 `127.0.0.1` 或仅局域网地址。令牌和实际域名只放在本机私有配置中。

## 验证

- NeoForge 1.21.1 / 21.1.235 实服热重载通过。
- ChatImage `CICode` 图片/表情包渲染冒烟通过。
- 图床上传、公开地址读取、删除清理冒烟通过。
- Java、Python、PowerShell 检查及公版构建通过。
