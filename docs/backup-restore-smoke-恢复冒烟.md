# 备份完整恢复冒烟

> 2026-08-06 落地。**独立目录**解压 + 影子服起服到 Done；**不碰线上 world**。

## 做什么

1. 从 `backups/world` 取最新 zip（或指定路径）  
2. 解压到 `tmp/backup-restore-smoke/<时间戳>/world`  
3. 检查 `level.dat` + `region/*.mca`  
4. 可选 `-Boot`：用 junction 挂 `libraries`/`mods`，独立端口起服，等到 **Done** 后停掉  

## 用法

```powershell
# 完整：解压 + 起服（人空时）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\backup-restore-smoke.ps1 -Boot -QqSummary

# 仅解压验证
powershell -File tools\backup-restore-smoke.ps1 -QqSummary

# 复用已解压世界再起服
powershell -File tools\backup-restore-smoke.ps1 -Boot -ReuseWorldDir tmp\backup-restore-smoke\<stamp>\world
```

一键：`一键脚本\一键便携-备份恢复冒烟.bat`（默认带 `-Boot`）

## 示例验收记录

| 项 | 结果 |
|----|------|
| 备份 | `server-world-示例时间.zip`（大小以实际世界为准） |
| 解压 | 成功；`level.dat` 有；`region` 数量大于 0（体积/耗时以本服为准） |
| 影子服 | 使用独立端口；在超时前见到 `Done` |
| 线上 | 原世界未改；未共享在线服配置 |

说明：第一次起服其实也已 Done，但检测脚本漏判（已修）；语音端口与线上冲突仅告警，不影响 Done。

## 注意

- **有玩家时不要 -Boot**（脚本会检测并跳过起服）  
- 影子服共享 `mods`/`libraries` junction，**不**共享 `config`（防 BlueMap/语音抢端口）  
- 产物占盘，确认后可删 `tmp\backup-restore-smoke\`  

## 与结构验证的关系

| | `verify-backup` | `backup-restore-smoke` |
|--|-----------------|------------------------|
| 打开 zip / level.dat 抽样 | ✅ | ✅（整包解压） |
| 真正解压落盘 | ❌ | ✅ |
| 起服到 Done | ❌ | ✅（-Boot） |
