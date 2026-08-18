# DeepSeek 价格核实与自动更新

> 核实日期：2026-08-18
> 官方来源：[DeepSeek 模型与价格页面](https://api-docs.deepseek.com/zh-cn/quick_start/pricing/)
> 适用组件：QQ 群机器人 AI 用量统计与费用估算

## 结论

本次优化把 DeepSeek 的固定单价改为“官方价目自动同步 + 峰谷时段计价”：

- 启动 QQ 桥时先检查一次官方价目，之后默认每 360 分钟检查一次。
- 只处理直连 `api.deepseek.com` 的 `deepseek-v4-flash` 和 `deepseek-v4-pro`。
- 费用估算分开计算输入未命中缓存、缓存命中和输出，并按北京时间峰值时段选价。
- 页面、模型、价格或时段校验失败时保留当前有效价格，不阻塞 QQ 桥和 AI 请求。

自动同步只影响机器人显示的费用估算，不会修改 DeepSeek 实际账单；真实扣费仍以官方账单为准。

## 2026-08-18 官方价格快照

单位：元 / 百万 token。价格顺序明确拆开如下：

| 模型 API ID | 官方版本名 | 输入未命中（空闲） | 缓存命中（空闲） | 输出（空闲） | 输入未命中（高峰） | 缓存命中（高峰） | 输出（高峰） |
|---|---|---:|---:|---:|---:|---:|---:|
| `deepseek-v4-flash` | `DeepSeek-V4-Flash-0731` | 1.5 | 0.05 | 4.5 | 3 | 0.10 | 9 |
| `deepseek-v4-pro` | `DeepSeek-V4-Pro-0813` | 4.5 | 0.15 | 13.5 | 9 | 0.30 | 27 |

官方高峰时段为北京时间 **09:00–12:00、14:00–18:00**，区间左闭右开；其余时间为空闲时段。DeepSeek 可能调整价格，表格只是本次核实快照，运行时以校验通过的官方页面为准。

## 费用计算

每次 API 响应按接口返回的 `usage` 逐次累计：

```text
未命中输入 = max(0, 输入 token - 缓存命中 token)
费用 = (未命中输入 × 输入未命中价
      + 缓存命中 token × 缓存命中价
      + 输出 token × 输出价) / 1,000,000
```

- token 数只取模型接口返回的 `usage`，不按字数本地估算。
- 一次提问如果触发多轮工具调用，每一轮都计入总用量，避免只统计最后一轮而低估。
- 运行时按每次 API 响应记录的北京时间选择峰/谷价格；跨时段的多轮请求可以分别计价。
- 缓存字段缺失时不虚构缓存命中量；`!ai` 和回答尾注中的金额均属于“约”值。

### 费用核对示例

2026-08-18 17:20 属于高峰时段。某次 Flash 请求返回：

- 输入：24,209 token
- 其中缓存命中：22,656 token
- 输出：626 token

按 Flash 高峰价格计算：

```text
((24,209 - 22,656) × 3 + 22,656 × 0.10 + 626 × 9) / 1,000,000
= 0.0125586 元
≈ 0.0126 元
```

旧固定单价（输入 1 元、缓存 0.02 元、输出 2 元）会显示约 0.0033 元，因此不能继续作为 V4 的固定真值。

## 自动同步设计

配置入口：

- `tools/ops-config.json`：服务器实际配置，建议保留在本地，不提交密钥。
- [`tools/portable-ops-config.example.json`](../tools/portable-ops-config.example.json)：公开配置模板。
- `ai.officialPricing.enabled=true`：启用同步。
- `ai.officialPricing.url`：默认官方价目页。
- `ai.officialPricing.refreshMinutes`：默认 360 分钟。
- `ai.officialPricing.timeoutSeconds`：请求超时，程序限制在 3–30 秒范围内。

安全与回退规则：

1. 只接受 HTTPS 且主机名严格为 `api-docs.deepseek.com` 的地址；跳转后的地址也必须满足同样条件。
2. 先把 HTML 转成文本，再同时校验 V4 Flash/Pro 模型名、缓存命中/未命中/输出三类价格和两段北京时间峰值窗口。
3. 整个快照校验成功后才应用到预设；失败时保留配置回退价或上次成功同步的价格。
4. `!ai` 会显示当前价、官方同步时间和同步状态；失败原因写入运行日志与内存状态。
5. 自动同步只更新直连 DeepSeek V4 预设，不覆盖 Qwen、Grok、Ollama 等其它厂商的单价。

## 本次变更文件

- [`tools/QQConsoleBridge.java`](../tools/QQConsoleBridge.java)：官方价目抓取、校验、定时刷新、峰谷价选择和逐次费用累计。
- [`tools/portable-ops-config.example.json`](../tools/portable-ops-config.example.json)：增加 `officialPricing` 与 `pricePeak*` 示例，并更新 V4 回退价格。
- [`docs/qq-ai-provider-switch.md`](qq-ai-provider-switch.md)：补充官方同步和回退单价说明。

QQ 桥已在目标服务器重新编译并重载；运行日志已确认成功同步 2 个 DeepSeek 预设。公开仓库不包含服务器实际配置、日志、API 密钥或运行时备份。

## 回退与安全提醒

自动同步失败时继续使用当前有效价格，不会因为价目页改版而把费用覆盖成异常数据。发布前已在目标服务器完成本地备份，备份目录不纳入公开仓库。

当前服务器配置仍可能存在明文 API/机器人凭据。建议轮换相关密钥并改用环境变量；本次公开提交只包含示例配置，未提交实际凭据。
