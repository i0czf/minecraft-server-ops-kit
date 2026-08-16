# 玩家客户端自助修复

> 2026-08-06 完成功能，2026-08-07 补齐在线发布源和全部玩家包交付链。玩家在**自己电脑的整合包实例**上自检；不碰服务端存档。

## 做什么

对照更新清单（`server-manifest.json` / UPDATE-URL）检查：

1. 更新源是否可达  
2. Java 是否符合清单中的 Minecraft 版本（≤1.16 使用 Java 8、1.17–1.20.4 使用 Java 17、1.20.5–1.21.x 使用 Java 21、新纪年 26.x 使用 Java 25）  
3. `mods/**` 与 `_updater/**` 是否缺失、SHA1 是否一致  
4. 本地是否有清单外多余 jar（只提示不删）  
5. 可选 **`-Fix`**：只重下异常文件  

输出**中文报告** + 诊断编号 `RPR-时间-随机`，方便发给管理员。

## 玩家怎么用

在整合包实例根目录（有 `mods`、`UPDATE-URL.txt` 的那层）：

1. 双击 **`一键客户端自助修复.bat`**  
2. 看风险灯：绿 / 黄 / 红，记下 **诊断编号**  
3. 有缺失或哈希不符时：  
   ```text
   powershell -File _updater\player-self-repair.ps1 -Fix
   ```  
   或直接用平时的 **`更新mod-Windows端.bat`** 做完整同步  

## 管理员

- 源脚本：`tools/player-self-repair.ps1`  
- 发布时打进玩家包：`_updater/player-self-repair.ps1` + 根目录 `一键客户端自助修复.bat`  
- QQ 全员可发：`!自助修复` / `!客户端修复` 获取指引  

构建脚本现会强制检查这两个文件；同步包、Modrinth `.mrpack`、PCL 客户端包、完整客户端包以及公开/精简/私用腐竹工具包均已纳入，缺件会直接拒绝出包。

## 参数

| 参数 | 说明 |
|------|------|
| `-InstanceDir` | 实例目录，默认当前目录 |
| `-ManifestUrl` | 覆盖 UPDATE-URL |
| `-Fix` | 自动重下缺失/不符文件 |
| `-Deep` | 检查清单内更多路径（不仅 mods/_updater） |
| `-QqSummary` | 只打印摘要 |

## 报告位置

`实例\_repair\<时间戳>\report.txt` 与 `meta.json`；另有 `_repair\latest\`。

## 验收标准

按批处理实际行为传入**绝对实例路径**，确认远程更新源可达、清单文件全部通过 SHA1 校验、无意外多余模组且风险灯为绿。公版按清单中的 Minecraft 版本选择对应 Java 主版本，不记录作者服务器的文件数、版本号或玩家环境。
