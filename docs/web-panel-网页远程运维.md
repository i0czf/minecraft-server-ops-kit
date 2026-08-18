# Web 网页远程运维面板

## 目标

在保留原有 WPF 桌面控制面板的同时，增加一套浏览器访问方式：服务端本机启动一个轻量 HTTP 面板，管理员可以通过 SSH/VPN 或路由器端口转发，从外部浏览器运维服务器。

## 访问链路

```text
浏览器 → SSH/VPN/路由器端口转发 → Web 面板端口 → 白名单脚本 / 本地 RCON → Minecraft 服务端
```

Web 面板不直接拼接执行浏览器传来的 PowerShell 命令。开服、重启、停服、运维、备份和诊断都映射到已有脚本；RCON 快捷命令是固定命令，任意 RCON 控制台需要在服务器本机配置文件中显式开启。

## 文件

- `一键脚本\一键便携-启动Web控制面板.bat`：启动入口。
- `一键脚本\一键便携-停止Web控制面板.bat`：按 PID 文件安全停止 Web 进程。
- `tools\portable-web-panel.ps1`：HTTP 服务和网页本体。
- `tools\stop-portable-web-panel.ps1`：停止脚本。
- `tools\portable-web-panel.example.json`：配置模板。
- `tools\portable-web-panel.json`：首次启动自动生成的实际配置，不应公开。
- `tmp\portable-web-panel.token`：首次启动自动生成的登录令牌，不应公开。

## 默认启动

```text
双击 一键脚本\一键便携-启动Web控制面板.bat
浏览器打开 http://127.0.0.1:58080/
```

默认只绑定 `127.0.0.1`，因此只有服务器本机能连接。默认不需要管理员权限、IIS、Node、Python 或 Windows URL ACL。

## 推荐远程方式：SSH 本地端口转发

服务器 Web 面板保持默认绑定：

```json
{
  "bindAddress": "127.0.0.1",
  "port": 58080
}
```

外部电脑建立隧道：

```bash
ssh -N -L 58080:127.0.0.1:58080 user@server
```

外部浏览器打开 `http://127.0.0.1:58080/`。这种方式不需要开放服务器 Web 端口，链路由 SSH 加密。

## 路由器端口映射方式

如果没有 SSH/VPN，只能用端口映射：

1. 把 `bindAddress` 改为 `0.0.0.0`；
2. 选择未占用的高位端口，例如 `58080`；
3. Windows 防火墙只放行该端口，最好限定固定管理 IP；
4. 路由器把外部端口转到服务器内网 IP 与 `58080`；
5. 重启 Web 面板，用 `http://公网地址:外部端口/` 访问。

注意：这是 HTTP，不是 HTTPS。公网直连会暴露令牌和操作内容，推荐改用 SSH/VPN 或 HTTPS 反向代理。端口映射不会自动处理 CGNAT、动态公网 IP、IPv6 防火墙或运营商入站封锁；这些是网络层问题。

## 令牌

第一次启动会生成随机令牌，并在启动窗口显示。查询令牌：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\portable-web-panel.ps1 -ShowToken -NoPause
```

轮换令牌：先停止 Web 面板，再运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\portable-web-panel.ps1 -ResetToken -ShowToken -NoPause
```

然后正常双击启动入口。旧会话和旧令牌不再可用。不要把令牌写入 URL、截图、聊天群或公开压缩包。

## 功能和限制

- 状态：Minecraft 端口、RCON、更新服务、主要运维 PID、备份数量和占用。
- 性能：每 5 秒刷新服务端 CPU、整机 GPU、系统内存、磁盘占用，并绘制最近 5 分钟趋势曲线；同时显示服务端内存和磁盘可用空间。
- 控制：开服、通过 RCON 安全重启、通过 `maintenance.stop` 安全停服、仅发布更新、启动/重启/停止运维。
- 诊断：立即备份、健康体检、运行报告、事故复盘、验证备份。
- 观察：读取允许的日志末尾，不提供任意文件浏览或下载。
- RCON：固定快捷命令默认可用；任意控制台默认关闭。
- UAC：某些现有运维 bat 会请求管理员权限；远程浏览器不能点击服务器本机 UAC。
- 终止 Web 面板不会停止 Minecraft、RCON 或其他运维进程。

## 手机端 UI 布局

Web 面板已加入移动端响应式适配，重点覆盖手机浏览器的 360px–390px 窄屏场景：

- 服务端控制、运维监控和 RCON 快捷按钮采用两列布局，并保留适合触控的按钮高度；
- 通过收缩网格最小宽度，避免控制卡片把整页撑出横向滚动；
- 备份表格固定为屏宽布局，长文件名自动换行，不再依赖整页横向滚动；
- 日志、RCON 输入、控制台提示及访问信息支持长文本换行；
- 性能监控在手机端保持 CPU/GPU/内存/磁盘两列仪表和趋势图。

移动端布局由 tools\portable-web-panel.ps1 内嵌网页样式提供，不需要额外安装前端依赖。更新脚本后重启 Web 面板，手机端刷新页面即可加载新样式。

## 高风险开关

`tools\portable-web-panel.json` 的 `allowConsoleCommands` 默认是 `false`。改成 `true` 后，网页登录用户可以发送任意 RCON 命令，权限等同服务器管理员。只有在访问链路已经由 SSH/VPN/HTTPS 保护，并且令牌、来源 IP、Windows 账户都已妥善控制时，才应该开启。

## 排障

- 页面打不开：确认启动窗口没有报端口占用，检查 `tmp\portable-web-panel.pid` 和 `logs\portable-web-panel.log`。
- 本机能打开、外部打不开：按顺序检查 bindAddress、Windows 防火墙、路由器映射、运营商 CGNAT 和公网 IP。
- 登录失败：在服务器本机用 `-ShowToken` 查询；若怀疑泄露，用 `-ResetToken` 轮换。
- 重启/停服按钮提示 RCON：先用现有「启用 RCON 反控」入口配置并重启 Minecraft，使 `enable-rcon` 和密码真正生效。
- 运维按钮没有立即生效：查看服务器本机是否出现 UAC 窗口，以及对应脚本新开的控制台窗口和 `logs`。
