# v0.3.2 · Windows 玩家更新器闪退与 9009

这是玩家 Windows 更新入口的修复，不另开大版本。不改 QQ 桥，也不需要重启 Minecraft。

## 修复

- **双击闪退**：`portable-windows-sync.bat` 混用 LF 时，CMD 在 UTF-8 代码页下会把内嵌 PowerShell 拆碎。发布和打包现在拒绝这类批处理。
- **退出码 9009**：`where python` 会把微软商店假入口当成真解释器。现改为先试跑一行，假的或 9009 回落 PowerShell。

## 新增

- `tools/portable-windows-repair.ps1`、`tools/portable-windows-repair.bat`：给已经闪退、热更新进不去的老包换入口。
- `tools/build-windows-repair-kit.ps1`：打一份几 KB 的独立修复小包，不必重下完整客户端。

新打的完整包根目录不带「修复」入口，只保留正常的「更新mod-Windows端.bat」。

## 使用要点

| 玩家现状 | 怎么做 |
|---|---|
| 旧入口还能跑 | 再跑一次，热刷新脚本 |
| 双击立刻闪退 | 用独立修复小包，放到整合包根目录再双击 |
| 新完整包 | 直接跑「更新mod-Windows端.bat」 |

说明：[Windows 玩家更新器 CMD 闪退与 9009](https://github.com/i0czf/minecraft-server-ops-kit/blob/main/docs/player-updater-windows-cmd.md)

## 验证

- 混用 LF 的入口按玩家路径复现：CMD 拆行报错，磁盘脚本不会被热更新换掉。
- 修好的入口能进自刷新和同步器。
- 假 Python / 9009 会回落 PowerShell。
- 公版文件不含真实域名、IP、群号或令牌。
