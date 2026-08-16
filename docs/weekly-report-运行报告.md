# 每日/每周服务器运行报告

> 2026-08-06 落地。**只读汇总**，不改配置、不停服；定时推送只热更运维即可。

## 做什么

把已有运维数据合成一份可读报告（完整版 + QQ 短摘要）：

| 数据源 | 用途 |
|--------|------|
| `logs/perf/samples.jsonl` | TPS/MSPT/在线峰值、卡顿样本 |
| `logs/error-fingerprints.jsonl` | 指纹告警次数 |
| `logs/ops-audit.jsonl` | 停服/高危确认/RCON |
| `crash-reports/` | 窗口内崩溃份数 |
| `backups/world/**/*.zip` | 新增备份与总库大小 |
| `logs/server-wrapper.log` | 包装器启动/重启标记 |
| `logs/latest.log` | 进退服、Can't keep up（当前会话为主） |
| RCON `list` / `tps` | 实时在线与 TPS |

输出目录：

- `tmp/weekly-report/<时间戳>/`：`weekly-report.txt`、`weekly-qq.txt`、`weekly-report.json`
- `tmp/weekly-report/latest/`：同上三份的稳定副本（给脚本/机器人读）

## 入口

| 入口 | 说明 |
|------|------|
| QQ `!周报` / `!报告` / `!report` | 管理员；可选 `1d` / `7d` / `30d`（默认 7d） |
| `一键脚本\一键便携-运行报告.bat` | 参数 `1d` / `7d` / `30d` |
| 控制面板「运行报告」 | 调 bat，新窗口输出 |
| 定时 `discord-watch` | 见下方 `weeklyReport` 配置 |
| 命令行 | `powershell -File tools\weekly-report.ps1 -Window 7d -QqSummary` |

## 配置 `ops-config.json` → `weeklyReport`

| 字段 | 默认 | 说明 |
|------|------|------|
| enabled | true | 总开关（关则不自动推，手动/QQ 仍可跑脚本） |
| window | 7d | 汇总窗口：`1d` / `7d` / `30d` |
| dayOfWeek | Monday | 自动推送星期几（英文：Monday…Sunday）；`*` 或 `daily` 表示每天 |
| hourLocal | 9 | 本地钟点（0–23）到达后才推 |
| minuteLocal | 0 | 分钟 |
| pushQq | true | 推 QQ 主群（短摘要） |
| pushDiscord | true | 推 Discord |
| statePath | tmp/weekly-report-state.json | 上次推送日期，防同日重复 |

示例：每周一 09:00 推最近 7 天：

```json
"weeklyReport": {
  "enabled": true,
  "window": "7d",
  "dayOfWeek": "Monday",
  "hourLocal": 9,
  "minuteLocal": 0,
  "pushQq": true,
  "pushDiscord": true
}
```

每天 21:00 推 24h 日报：把 `dayOfWeek` 设为 `daily`，`window` 设为 `1d`，`hourLocal` 设为 21。

## 生效

```text
面板 → 重启运维监控
```

不必停 Minecraft。有玩家在线也可以只重启运维。

## 与盘点文档的关系

对应《运维工具箱-下一阶段功能盘点》第一阶段第 4 项「每周服务器报告」。
