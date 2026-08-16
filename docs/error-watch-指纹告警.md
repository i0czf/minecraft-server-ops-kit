# 日志错误指纹告警去重

> 2026-08-06 落地。**只热更运维监控**，不冷启动 Minecraft。

## 做什么

监控（`tools/discord-watch.ps1`）在读 `logs/latest.log` 时，对 ERROR（可配置含 WARN）做指纹归一化：

- **同一指纹**在 `cooldownSeconds`（默认 600 秒）内只推 **QQ/Discord 一次**
- 文案区分「新」与「重复 ×N」
- 落盘 `logs/error-fingerprints.jsonl`（first / alert / suppress 抽样）

与体检共用 `tools/log-fingerprint.ps1`，避免两套规则。

## 配置

`tools/ops-config.json` → `errorWatch`：

| 字段 | 默认 | 说明 |
|------|------|------|
| enabled | true | 总开关 |
| minLevel | ERROR | ERROR 或 WARN |
| cooldownSeconds | 600 | 同指纹推送冷却 |
| maxSampleLength | 160 | 告警里样例行最大长度 |
| jsonlPath | logs/error-fingerprints.jsonl | 落盘路径 |
| ignorePatterns | moved wrongly, ClassNotFoundException | 正则，命中则忽略 |

开关通知：

- `qq.events.logError`（默认 true；缺键也放行）
- `discord.events.logError`（默认 true；缺键也放行）

## 生效

```text
面板 → 重启运维监控
# 或 一键脚本\一键便携-重启运维监控.bat
```

**不要**为此停 Minecraft。有玩家在线也可以只重启运维。

## 告警样例

```text
[日志告警] 新 ERROR
样例：[…] Parsing error loading recipe …
指纹：[ERROR] : Parsing error loading recipe …
累计：1 次 · 详情：!体检 或 logs/error-fingerprints.jsonl
```

冷却后再出现：

```text
[日志告警] 重复 ERROR ×12（约 10 分钟窗口）
…
```

## 验证记录

- 向 `latest.log` 连续写入 3 条相同 ERROR 测试行
- `error-fingerprints.jsonl` 仅一条 `action=first`（其余在冷却内不推）
- Discord 发送成功（见 `logs/discord-watch.log`）

## 已知噪音示例

**现象**：有人上线时 QQ 偶发弹一次 `[日志告警]`，容易误以为「上线就告警」。

**结论**：不是进退服逻辑误触发，是 **进服加载玩家 NBT** 时 NeoForge 打了真 ERROR：

```text
Encountered unknown or non-serializable data attachment parcool:stamina. Skipping.
Encountered unknown or non-serializable data attachment yes_steve_model:vehicle_model_id. Skipping.
```

| 点 | 说明 |
|----|------|
| 时机 | 进服读玩家数据后约几十毫秒，与 `joined the game` 紧挨着 |
| 原因 | 存档里仍有 **ParCool / Yes Steve Model** 的 data attachment，当前服未装对应模组或附件不可序列化 |
| 影响 | 日志级 ERROR，一般 **Skipping 后仍可进服**，多半无害 |
| 是否每人每次 | 否；只有玩家数据里带这些脏附件时才会响；公版不记录真实玩家昵称或账号 |
| 指纹落盘 | `logs/error-fingerprints.jsonl` 有 `action=first` 对应 parcool 一条 |

**处理建议（默认不自动执行）**

1. 告警侧：`errorWatch.ignorePatterns` 加 `non-serializable data attachment`（热更运维即可）  
2. 根因侧：确认模组是否退役；要清干净需改玩家数据（有人在线勿动）

是否加入忽略规则应由各服根据实际日志决定；根因清理会改玩家数据，有人在线时不要操作。
