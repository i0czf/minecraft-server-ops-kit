# 可验证备份

> 2026-08-06 落地。**只读检查**，不碰线上 world、不停服；热更运维即可。

## 做什么

对 `backups/world/**/*.zip` 做「能不能当回档候选」的验证：

1. 能否打开 zip  
2. 是否含 `level.dat`  
3. `region/*.mca` 数量  
4. 玩家档数量  
5. **抽样读取** `level.dat`（验证该条目可解压）  

默认**不解压整包**（大型世界完整解压会占盘且 IO 重）。  
`-Deep` 可对每个条目试读前几 KB（更慢）。

本脚本刻意**不在每次结构验证时完整解压并冷启**，避免周期任务制造数 GiB IO；完整恢复到 Minecraft `Done` 已由独立的 [备份恢复冒烟](./backup-restore-smoke-恢复冒烟.md) 落地并实测。

## 入口

| 入口 | 说明 |
|------|------|
| QQ `!验备份` / `!验证备份` | 管理员；`deep` / `3` / `deep3` |
| `一键脚本\一键便携-验证备份.bat` | 参数 `deep` / `3` / `deep3` |
| 定时 `discord-watch` | 见 `backupVerify`（默认周日 10:00） |
| 命令行 | `powershell -File tools\verify-backup.ps1 -Count 1 -QqSummary` |

## 配置 `ops-config.json` → `backupVerify`

| 字段 | 默认 | 说明 |
|------|------|------|
| enabled | true | 定时总开关 |
| count | 1 | 每次检查最近几份 |
| deep | false | 是否深度试读 |
| dayOfWeek | Sunday | 星期几；`daily`/`*` 每天 |
| hourLocal / minuteLocal | 10 / 0 | 本地时刻 |
| pushOnFail | true | 失败才推 QQ/Discord |
| pushAlways | false | 成功也推 |
| pushQq / pushDiscord | true | 推送通道 |
| statePath | tmp/backup-verify-state.json | 同日不重复跑 |

## 输出

- `tmp/backup-verify/<时间戳>/`：`summary-qq.txt`、`report.txt`、`meta.json`  
- `tmp/backup-verify/latest/`：稳定副本  

QQ 摘要示例：

```text
【备份验证】
检查 1 份 · 通过 1 · 失败 0
· [通过] server-world-….zip
  大小 <按实际显示> · <按实际时间> · 条目 <实际数量>
  level.dat=有 region区块=<实际数量> 玩家档=<实际数量>
结论：备份包结构正常，可作回档候选（未做完整开服冒烟）。
```

## 生效

```text
面板 → 重启运维监控
```

有玩家在线也可以只热更运维。

## 与盘点文档的关系

对应「可验证备份和恢复演练」的**快速结构验证**部分；完整恢复、隔离起服到 `Done` 由 `tools\backup-restore-smoke.ps1` 承担。验收标准是归档可完整解压、含 `level.dat` 与有效 region 文件，并在隔离端口于超时前启动到 `Done`；不在公版文档记录本服世界规模。
