# 高危操作确认与审计

> 2026-08-06 落地。**只重启运维（QQ 桥）**，不冷启动 Minecraft。

## 做什么

管理员在 QQ 里发高危命令时，**先发确认码，确认后再执行**，并写入带 **哈希链** 的审计日志。

## 需要确认的操作

| 来源 | 示例 |
|------|------|
| `!stop` / `!restart` | 安全停服（看门狗常会自动拉起） |
| `!cmd …` / `!控制台 …` / `!/` | `op` `deop` `ban` `whitelist off` 批量 `kill`/`clear @a` 等 |

**不需要确认**（仍仅管理员可用）：`!备份` `!存盘` `!天气` `!公告` `!tps` `!体检` 等。

AI 的 `run_rcon`：高危命令 **拒绝自动执行**，提示管理员走 `!cmd` + `!确认`。

## 群聊流程

```text
管理员：!stop
机器人：[高危确认] … 在 90 秒内发送：!确认 AB3K
管理员：!确认 AB3K
机器人：已确认并下达安全停服…
```

- 作废：`!取消确认`（只取消自己发起的）
- 确认码 **仅发起人** 可用
- 超时默认 90 秒

## 配置 `ops-config.json` → `riskConfirm`

| 字段 | 默认 | 说明 |
|------|------|------|
| enabled | true | false=跳过确认直接执行（仍可审计） |
| ttlSeconds | 90 | 确认码有效期 |
| codeLength | 4 | 码长度 |
| auditEnabled | true | 写审计 |
| auditPath | logs/ops-audit.jsonl | 哈希链 JSONL |

## 审计日志

`logs/ops-audit.jsonl` 每行一条，字段含 `prevHash` / `hash`（SHA-256 链）：

- `risk_request` / `risk_confirm` / `risk_cancel`
- `stop` / `rcon` / `set_server_property`

可事后校验链是否被篡改：从首条 `prevHash=000…` 起逐条重算。

## 生效

```text
面板 → 重启运维监控
```

不必停 Minecraft。有玩家在线也可以只重启运维。

## 与盘点文档的关系

对应《运维工具箱-下一阶段功能盘点》第一阶段第 3 项。  
完整四级权限（Owner/Operator/Moderator/Viewer）未在本版拆完：当前仍沿用 admin 白名单 + 主群群主/管理；高危统一要确认码。
