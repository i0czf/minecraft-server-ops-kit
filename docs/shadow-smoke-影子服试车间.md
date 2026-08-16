# 影子服试车间

> 2026-08-06 落地。用**当前整合包**在独立目录起服到 Done，验证发版前能不能开起来。  
> **不碰线上 world**，不改线上 `server.properties`。

## 做什么

1. 在 `tmp/shadow-smoke/<时间戳>/smoke-server` 搭影子实例  
2. junction 共享 `libraries` / `mods` 等重目录  
3. **不**共享 `config`/`bluemap`（防抢端口）  
4. **新世界**（不挂线上存档）  
5. 独立端口（默认 **25567**）起服，等到 `Done` 后自动停  

与「备份恢复冒烟」区别：

| | 备份恢复冒烟 | 影子服试车间 |
|--|--------------|--------------|
| 世界来源 | 备份 zip 解压 | 新生成空世界 |
| 目的 | 备份能否回档 | **当前包能否启动** |
| 典型场景 | 灾后信心 | **发版/改模组前** |

## 用法

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\shadow-smoke.ps1 -QqSummary

# 指定端口 / 超时
powershell -File tools\shadow-smoke.ps1 -SmokePort 25567 -BootTimeoutMinutes 30
```

一键：`一键脚本\一键便携-影子服试车间.bat`

有玩家时默认拒绝起服（IO/端口风险）。若坚持：`-AllowWithPlayers`（不推荐）。

## 示例验收记录

| 项 | 结果 |
|----|------|
| 端口 | 独立测试端口（默认 25567） |
| 到 Done | 在配置的超时前完成 |
| 结论 | 通过 |
| 线上 | 原世界与线上配置未动 |

## 产物

- `tmp/shadow-smoke/<stamp>/`：报告 + 控制台日志  
- `tmp/shadow-smoke/latest/`  

确认后可删整个 `tmp\shadow-smoke\` 腾空间。
