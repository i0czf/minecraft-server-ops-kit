# v0.2.0 · QQ 图片/表情包图床转发与 ChatImage 预览

## 新增

- QQ 普通图片、GIF 和表情包自动下载、校验并转存图床。
- Minecraft 聊天使用实际玩家可访问的图床地址；上传仍通过服务端本机回环地址完成。
- 普通图片显示为“图片”，动画/商城表情及表情子类型图片显示为“表情包”。
- 增加 `link`、`chatimage`、`imagepreviewer` 三种 Minecraft 渲染模式。
- `chatimage` 模式把 ChatImage `CICode` 放进可见消息的悬停内容，安装对应客户端模组的玩家可在聊天栏预览远程图片，并点击同一个预览项打开大图；若配置了 `publicBaseUrl`，本地/局域网图床对象会映射到公链同名对象。
- 图片同源/同内容缓存、失败回退和有界队列，避免媒体处理阻塞 QQ WebSocket。

## 实际效果

- 已补入 NeoForge 1.21.1 / 21.1.235 实服的普通图片与表情包预览截图，见 [真实界面演示](https://github.com/i0czf/minecraft-server-ops-kit/blob/main/docs/live-ui-demo.md)、[PF-GUGUBot 功能核查](https://github.com/i0czf/minecraft-server-ops-kit/blob/main/docs/PF-GUGUBot%E5%8A%9F%E8%83%BD%E6%A0%B8%E6%9F%A5%E4%B8%8E%E8%B7%9F%E8%BF%9B%E6%96%B9%E6%A1%88.md) 和 [QQ 图片转图床说明](https://github.com/i0czf/minecraft-server-ops-kit/blob/main/docs/qq-image-host-%E8%BD%AC%E5%9B%BE%E5%BA%8A.md)。发布正文使用完整 URL，避免 GitHub Release 页面按错误的相对路径解析。
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

`minecraftBaseUrl` 必须是实际目标 Minecraft 客户端能访问的地址，可以按部署范围使用公网或局域网地址，但不能使用玩家不可达的服务器本机 `127.0.0.1`。配置 `publicBaseUrl` 后，`chatimage` 的同项点击会把 `minecraftBaseUrl`/`lanBaseUrl` 下的图床对象映射为公链大图。令牌和实际域名只放在本机私有配置中。

## 验证

- NeoForge 1.21.1 / 21.1.235 实服热重载通过。
- ChatImage `CICode` 图片/表情包渲染冒烟通过。
- 图床上传、公开地址读取、删除清理冒烟通过。
- Java、Python、PowerShell 检查及公版构建通过。
