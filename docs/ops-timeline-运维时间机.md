# 运维时间机

> 2026-08-06 落地。**只读聚合**，不改配置、不停服；热更运维即可。

## 做什么

把已有落盘数据串成时间线，事故时快速回答：

- 从哪一刻开始不对？
- 中间有没有启停、高危确认、指纹告警、卡顿取证、备份与验证？

## 数据源

| 来源 | 事件 |
|------|------|
| `logs/server-wrapper.log` | 启动 / Java 退出 / 计划重启 |
| `logs/ops-audit.jsonl` | 高危确认、RCON、停服等 |
| `logs/error-fingerprints.jsonl` | 指纹告警（first/alert） |
| `logs/perf/samples.jsonl` | MSPT 连续偏高片段 |
| `tmp/lag-forensics/*/` | 卡顿取证包 |
| `tmp/backup-verify/*/` | 备份验证结果 |
| `backups/world/**/*.zip` | 窗口内新增备份 |
| `crash-reports/` | 崩溃报告 |

## 入口

| 入口 | 说明 |
|------|------|
| QQ `!时间线` / `!timeline` | 管理员；窗口 `1h` `6h` `24h` `7d`（默认 6h） |
| `一键脚本\一键便携-运维时间线.bat` | 同上参数 |
| 控制面板「运维时间线」 | 新窗口输出 |
| 命令行 | `powershell -File tools\ops-timeline.ps1 -Window 6h -QqSummary` |

## 输出

- `tmp/ops-timeline/<时间戳>/timeline.txt` 完整时间线  
- `timeline-qq.txt` QQ 短摘要  
- `timeline.json` / `events.json` 结构化  
- `tmp/ops-timeline/latest/` 稳定副本  

## QQ 摘要示例

```text
【时间线】最近 6 小时
统计：启停12 · 卡顿4 · 指纹2 · 审计4 · 备份2 · 验备份2
最近：
20:27 [启停] 服务端启动
20:36 [指纹] 新指纹告警
21:41 [验备份] 备份验证通过
…
```

## 与其它功能的关系

| 功能 | 关系 |
|------|------|
| 周报 | 周期健康摘要；时间机偏「事件序列」 |
| 卡顿取证 | 时间机收录取证包时间点 |
| 验备份 | 时间机收录验证通过/失败 |
| 体检 | 当下风险评分；时间机看历史脉络 |

## 生效

改 QQ 桥后：**面板 → 重启运维监控**（不冷启动 Minecraft）。