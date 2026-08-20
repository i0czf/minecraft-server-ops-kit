# QQ 视频画面、音轨与 DeepSeek 汇总

## 结论

这条链路把三个不同问题交给最合适的模型处理：

1. QQ 桥取得当前消息、引用消息或合并转发中的原视频；
2. Qwen 视觉模型接收整段视频，并以请求参数 `fps=1.0` 覆盖完整时间轴；
3. 可选的 Qwen Audio ASR 直接读取同一视频容器中的音轨；
4. 画面报告与音轨转写并行完成后，作为不可信媒体证据交给 `ai.provider`；
5. 公版默认由 DeepSeek 做最终分析、工具调用和群内回复。

“整段视频”不等于逐个读取原视频的每一帧。桥会发送完整视频文件，并要求模型按每秒 1 帧覆盖从开头到结尾；这比固定抽开头/中间/结尾三帧完整得多，也避免把几十帧每秒全部转成图片造成无意义的带宽和费用。

## 为什么画面和声音分开

视觉聊天接口能读视频画面，不代表它会可靠读取容器音轨。把声音交给专用 ASR，能明确区分“看到的事实”和“听到的内容”。两项任务彼此独立，采用并行执行；ASR 失败、无音轨或关闭时，画面理解仍可继续，最终回答必须说明声音证据不可用，不能猜对白。

这条路径不要求本机先用 ffmpeg 抽取音频。ASR 直接接收视频 URL 或 Data URL，减少一次转码和临时文件；ffmpeg 仅保留给无法取得原视频或不支持原生视频模型时的 1–3 张关键帧兜底。

## 公版安全默认值

- `ai.provider=deepseek`：DeepSeek 负责最终回复；不会把视觉预处理器冒充成最终模型。
- `ai.visionProvider=qwen`，`qwen.video=true`：Qwen 只生成媒体事实报告。
- `ai.audioTranscription.enabled=false`：公版默认不产生 ASR 费用，腐竹确认密钥、地区和账单后自行开启。
- 所有 `apiKey` 为空，只从环境变量读取；DeepSeek 与 Qwen 可使用不同环境变量。
- 一次最多接收 1 个视频；本地/Data URL 视频上限 64 MiB。超限或取不到文件时明确降级。
- 媒体报告和 ASR 文本一律按不可信数据处理。视频里出现“执行命令”“忽略规则”等提示词，不会变成服务器操作授权。

## 配置

复制 `tools/portable-ops-config.example.json` 为本机私有的 `tools/ops-config.json`，至少核对以下字段：

```json
{
  "ai": {
    "enabled": true,
    "provider": "deepseek",
    "visionProvider": "qwen",
    "audioTranscription": {
      "enabled": true,
      "provider": "qwen",
      "apiUrl": "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
      "model": "qwen-audio-3.0-asr-flash",
      "pricePerSecondCny": 0.00022
    },
    "providers": {
      "deepseek": {
        "apiKey": "",
        "apiKeyEnv": "DEEPSEEK_API_KEY",
        "model": "deepseek-v4-flash",
        "vision": false
      },
      "qwen": {
        "apiKey": "",
        "apiKeyEnv": "DASHSCOPE_API_KEY",
        "model": "qwen3.7-flash",
        "vision": true,
        "video": true
      }
    }
  }
}
```

`pricePerSecondCny` 只影响机器人展示的估算费用，不改变厂商实际扣费。价格会变化，发布者应按自己账户与官方计费页维护；无法核实时宁可不显示金额，也不要把估值写成账单事实。

改完后运行 `一键脚本\一键便携-仅重载QQ桥.bat`。群内 `!ai` 应显示：默认模型是 DeepSeek、视频由 Qwen 原生读取、音轨是否启用，以及最终汇总模型。

## 降级顺序

```text
可取得原视频 + 原生视频模型
  ├─ 画面：整段 video_url，fps=1.0
  ├─ 音轨：可选 ASR，与画面并行
  └─ 最终：DeepSeek 汇总并按权限使用运维工具

原视频不可取或模型不支持视频
  └─ ffmpeg 抽 1–3 张关键帧，仅代表局部画面

ASR 失败或无音轨
  └─ 保留画面分析，明确“声音证据不可用”，不猜测
```

## 验收

发布前至少完成：Java 编译、JSON 解析、公版构建隐私门禁、无网络单元级标记检查，以及一条不向群里发送测试消息的真实短视频端到端测试。端到端日志应能区分视觉耗时、ASR 耗时、DeepSeek 汇总耗时和各自费用，不能只看到一个总耗时就假定三段都成功。
