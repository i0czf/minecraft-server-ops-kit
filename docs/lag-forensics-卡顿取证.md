# 黑匣子卡顿自动取证

> 2026-08-06 落地。**只读/旁路**，不冷启动 Minecraft；热更运维即可。

## 做什么

当性能黑匣子连续采样发现 **MSPT 持续偏高** 时，自动打一份证据包并推 QQ/Discord，回答：

- 当时 TPS/MSPT/在线是谁  
- 近几分钟黑匣子走势  
- 有没有 `Can't keep up` / 日志 ERROR / 指纹告警  
- 有没有线程转储  
- Spark 报告链接（若拿到）

## 触发链路

```text
perf-sampler 每 60s 采一次
  → 连续 consecutiveSamples 次 MSPT ≥ msptThreshold
  → 独立子进程跑 tools/lag-forensics.ps1
  → 写 tmp/lag-forensics/<时间戳>/ + pending/*.json
  → discord-watch 消费 pending → 推 QQ/Discord → 移到 done/
```

冷却：`cooldownSeconds`（默认 900）内不重复取证。

## 证据包内容

| 文件 | 内容 |
|------|------|
| `summary-qq.txt` | 群聊短摘要 |
| `report.txt` | 完整报告 |
| `meta.json` | 结构化元数据 |
| `live-list.txt` / `live-tps.txt` | 实时 RCON |
| `perf-tail.txt` | 近 15 条黑匣子 |
| `thread-dump.txt` | `jcmd <pid> Thread.print`（若有 jcmd） |
| `spark-notes.txt` | latest.log 里 Spark 相关行 |

目录：`tmp/lag-forensics/<stamp>/`，另有 `latest/` 稳定副本。

## Spark 说明

如果服务器安装了 Spark，经 RCON 调用时**回文可能为空**（Adventure 组件不走 RCON 文本），但命令仍会执行；取证脚本会从 `logs/latest.log` 抓 `spark.lucko.me/...` 链接。拿不到链接时仍保留黑匣子/线程/日志证据。

## 配置 `ops-config.json` → `lagWatch`

| 字段 | 默认 | 说明 |
|------|------|------|
| enabled | true | 总开关 |
| msptThreshold | 50 | MSPT 阈值（ms） |
| consecutiveSamples | 2 | 连续超阈次数（×采样间隔≈分钟） |
| cooldownSeconds | 900 | 两次取证最小间隔 |
| sparkProfilerSeconds | 30 | Spark 分析时长；0 或 sparkEnabled=false 跳过 |
| sparkEnabled | true | 是否跑 Spark |
| threadDump | true | 是否 jcmd 线程转储 |
| pushQq / pushDiscord | true | 推送开关 |

## 手动试跑

```powershell
# 快速（不跑 Spark，约数秒）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\lag-forensics.ps1 -Force -NoSpark

# 完整（含约 30s+ Spark）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\lag-forensics.ps1 -Force
```

推送需 discord-watch 在跑；生成 pending 后下一轮轮询（约数秒）会推。

## 生效

```text
面板 → 重启运维监控
```

不必停 Minecraft。有玩家在线也可以只重启运维。

## 与盘点文档的关系

对应《运维工具箱-下一阶段功能盘点》第二阶段「性能黑匣子 · 卡顿自动取证」。


## 通知语言

QQ/Discord 摘要**一律中文**（原因、在线列表、线程转储有/无等）。手动试跑原因显示为「手动试跑」。
