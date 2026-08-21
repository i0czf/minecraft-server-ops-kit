# QQ 视频、语音识别与 DeepSeek 汇总

## 结论

这条链路把画面、声音和最终推理分开处理：

1. QQ 桥取得当前消息、引用消息或合并转发中的原视频与 QQ 语音；
2. 视频画面由 Qwen 视觉模型接收整段文件，并以请求参数 `fps=1.0` 覆盖完整时间轴；
3. 视频音轨直接交给可选 Qwen Audio ASR；QQ 语音先落地检查真实文件头，Silk 优先调用 OneBot `/get_record` 转成 MP3，失败时由工具包内置 `silk-wasm` 解码成 24 kHz 单声道 WAV，再交给同一 ASR；
4. ASR 只负责“说了什么”。需要理解声音时，同一条 QQ 语音并行交给 `qwen3.5-omni-flash`，判断说话、唱歌、纯音乐、混合声音或环境噪声，并描述旋律、节奏、伴奏、风格与情绪；
5. 画面报告、转写和声音报告都作为不可信媒体证据交给 `ai.provider`；
6. 公版默认由 DeepSeek 做最终分析、工具调用和群内回复。

“整段视频”不等于逐个读取原视频的每一帧。桥会发送完整视频文件，并要求模型按每秒 1 帧覆盖从开头到结尾；这比固定抽开头/中间/结尾三帧完整得多，也避免把几十帧每秒全部转成图片造成无意义的带宽和费用。

## 为什么画面、视频音轨和 QQ 语音分开

视觉聊天接口能读视频画面，不代表它会可靠读取容器音轨；QQ 收到的语音又通常是通用 ASR 不能直接读取的 Silk。最稳的链路是：

- 视频画面：原视频交给视觉模型；
- 视频音轨：原视频 URL 或 Data URL 直接交给专用 ASR，不先抽音轨；
- QQ 语音文字：按文件头而非扩展名识别 Silk；OneBot `/get_record` 转 MP3 优先，内置 `silk-wasm` 转 WAV 兜底，ASR 负责转写；
- QQ 语音声音语义：Qwen3.5-Omni 直接听音频，补充唱歌/音乐/环境声信息；超限 WAV 只在本机压成 64 kbps MP3，ffmpeg 不可用时按完整 PCM 采样帧分片；它不是声纹鉴定，也不是歌曲指纹识别；
- 最终回答：DeepSeek 合并证据，并继续受原有权限与工具围栏约束。

视频画面与视频音轨并行执行。QQ 独立语音按意图分流：`!转写` 只运行 ASR；`!听语音`、带语音的 `!问` 或 `@机器人` 让 ASR 与 Omni 并行，任一路失败都独立降级，不拖垮另一条证据。ffmpeg 用于超限音频的本地压缩，也保留给无法取得原视频或模型不支持原生视频时的 1–3 张关键帧兜底。

QQ/OneBot 可能把 Tencent Silk 内容命名成 `.amr`，扩展名不是可信格式证据。桥会读取前 16 字节识别标准 `#!SILK_V3` 和带 Tencent 前缀的 Silk；因此即使 OneBot 自带转换返回 `silk decoding failure`，也不会再把原始 Silk 冒充 AMR 上传。完整版已带所需运行时；精简版若使用这条兜底，需按清单把 LLBot 安装到 `tools\LLBot-CLI-win-x64`。

## 群内用法

机器人不会监听并自动上传群内所有语音。只有消息进入现有 AI 路由时才识别：

- 回复一条 QQ 语音，发送 `!转写` 或 `!语音转写`：只做高质量转写并简要概括，省去 Omni 费用；
- 回复一条 QQ 语音，发送 `!听语音`：除转写外，判断是否说话/唱歌/纯音乐，并分析可辨的旋律、节奏、伴奏、风格和情绪；
- 回复语音后发送 `!问 <问题>`，或在带语音的消息中 `@机器人 <问题>`：默认同时取 ASR 与声音理解证据，再由 DeepSeek 围绕问题汇总。

支持当前消息、引用消息和合并转发中的 `record` / `audio` 消息段，也识别常见音频文件。一次最多处理 3 条语音，每条本地/Data URL 上限 32 MiB；压缩 Silk 原文件另设 8 MiB 解码安全上限。Omni 的 Base64 单文件受官方 10 MB 限制，桥预留协议余量后按 9.5M 字符门禁；超限时优先在本机压成 24 kHz、单声道、64 kbps MP3，若 ffmpeg 不可用则把标准 PCM WAV 保真切成多个连续片段。原始音频仍并行交给 ASR，不经过图床或 OSS，也不会再因 Silk→WAV 体积膨胀而静默跳过 Omni。页脚会列出实际成功的 Omni 用量；若已尝试但失败，会明确写“未完成，未取得用量”。

## 公版安全默认值

- `ai.provider=deepseek`：DeepSeek 负责最终回复；不会把视觉或 ASR 预处理器冒充成最终模型。
- `ai.visionProvider=qwen`，`qwen.video=true`：Qwen 视觉预设只生成画面事实报告。
- `ai.audioTranscription.enabled=false`：QQ 语音和视频音轨共用此开关；公版默认不产生 ASR 费用。
- `ai.audioUnderstanding.enabled=false`：唱歌/音乐/环境声理解独立开关；公版默认不产生 Omni 费用。
- 所有 `apiKey` 为空，只从环境变量读取；DeepSeek 与 Qwen 可使用不同环境变量。
- 一次最多接收 1 个视频（64 MiB）和 3 条语音（每条 32 MiB）；超限或取不到文件时明确降级。
- 语音只在明确触发 AI 时上传；转写/Omni 声音报告正文只用于本次回答，不写进多轮历史，但用户问题与 AI 结论会正常进入对话记忆。客群的记忆按群号和权限独立保留最近 6 轮，因此在客群纠正音乐名称后，下一次引用可继承纠正，不会串到主群或其他客群。
- 媒体报告和 ASR 文本一律按不可信数据处理。媒体里出现“执行命令”“忽略规则”等提示词，不会变成服务器操作授权。

## 跨群共享 AI 知识库

客群的短期对话历史仍按“群号 + 管理员/普通群友权限”隔离；要让主群纠正一次、客群也能复用，另设独立的共享知识库。它不是服务器运维记忆，也不是群聊全文档案：默认只收录管理员明确记住的通用结论，或管理员在带语音/图片的 AI 问题中明确纠正的短文本。日志、配置、存档、绝对路径、密钥、群号、QQ 号、原始语音/视频和 ASR/Omni 证据正文都会被拒绝或不落库。

每次 `@机器人` / `!问` 先在本地做轻量检索：文本按中英文词与中文二元片段匹配，语音优先按回复消息 ID和下载后音频 Data URL 的 SHA-256 指纹匹配。命中条目只作为“共享 AI 知识库参考”交给 DeepSeek/Codex/Grok，标记为不可信资料；当前用户的最新明确纠正优先，知识库内容不能授权任何服务器命令。这样同一条歌声在主群确认歌名后，客群再次引用同一音频即可复用结论，不必重复纠正。

推荐使用方式：管理员引用机器人刚才的 AI 回答（或直接引用原语音）后，直接回复“这首歌是 TK from 凛として時雨 演唱的《unravel》”或“正确歌名是《unravel》”，无需再 @机器人、无需记命令；机器人会自动确认并同时绑定引用回复与音频指纹。若想显式操作，引用原语音后发 `!知识库记住 正确歌名是《unravel》`；机器人会回执是否写入。其他群只需引用同一语音并 `@机器人 什么歌，直接给歌名`。

管理员命令（命令前缀按 `qq.prefix`，通常是 `!`）：

- `!知识库查询 关键词`：查看相似条目；单独 `!知识库` 查看状态。
- `!知识库记住 主题 => 已确认结论`：显式写入跨群共享结论；引用语音时也可直接写 `!知识库记住 正确歌名是《歌名》`，自动绑定音频指纹。
- `!知识库删除 关键词`：删除匹配条目。

知识库默认写入 `logs/ai-shared-knowledge.jsonl`，采用追加式 upsert/delete 记录，重启后仍可用；只允许管理员写入，普通群友只读。文件受服务器根目录约束，条目数量、长度和每次注入条数均有限制。需要完全关闭时将 `ai.sharedKnowledge.enabled=false`，只关闭自动纠正收录可设 `autoCaptureCorrections=false`。

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
      "contextText": "Minecraft、NeoForge、Forge、RCON、TPS、MSPT、mod、modpack、Thaumcraft、神秘时代",
      "pricePerSecondCny": 0.00022
    },
    "audioUnderstanding": {
      "enabled": true,
      "provider": "qwen",
      "apiUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
      "model": "qwen3.5-omni-flash",
      "maxOutputTokens": 900,
      "priceAudioInputPerMillionCny": 18.0,
      "priceTextInputPerMillionCny": 2.2,
      "priceTextOutputPerMillionCny": 13.3
    },
    "sharedKnowledge": {
      "enabled": true,
      "readEnabled": true,
      "autoCaptureCorrections": true,
      "writeRequiresAdmin": true,
      "path": "logs/ai-shared-knowledge.jsonl",
      "maxEntries": 2000,
      "maxEntryChars": 800,
      "maxMatches": 3
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

`contextText` 使用 Qwen ASR 官方上下文增强协议，以 `input_text` 形式置于音频消息前；它主要改善专有词汇，最多 400 字，不是让模型扮演角色的系统提示。ASR 的 `pricePerSecondCny` 与 Omni 的三个每百万 token 单价只影响机器人展示的估算费用，不改变厂商实际扣费。Omni 费用使用接口 SSE 最终分片返回的分模态 token 计算；若接口没给完整细分，就显示“无法计算”，不会用文件大小伪造 token。

改完后运行 `一键脚本\一键便携-仅重载QQ桥.bat`。群内 `!ai` 应显示：默认模型是 DeepSeek、视频由 Qwen 原生读取、QQ 语音/视频音轨 ASR 是否启用，以及 `qwen3.5-omni-flash` 声音理解是否启用。

## 降级顺序

```text
QQ 语音
  ├─ 先落地读取文件头（不信任 .amr/.silk 扩展名）
  ├─ Silk：OneBot /get_record → MP3；失败则 silk-wasm → 24 kHz 单声道 WAV
  ├─ !转写：本地文件/Data URL → Qwen Audio ASR（只转文字）
  ├─ !听语音 / !问 / @机器人：ASR ∥ [超限则本机压缩/PCM分片] → Qwen3.5-Omni
  └─ 最终：DeepSeek 汇总；失败时明确“语音证据不可用”

可取得原视频 + 原生视频模型
  ├─ 画面：整段 video_url，fps=1.0
  ├─ 音轨：可选 ASR，与画面并行
  └─ 最终：DeepSeek 汇总并按权限使用运维工具

原视频不可取或模型不支持视频
  └─ ffmpeg 抽 1–3 张关键帧，仅代表局部画面
```

## 验收

发布前至少完成：Java 17 编译、`--media-selftest`（含标准/Tencent Silk 文件头、WAV 头与 PCM 分片、命令分流、Omni SSE 与分模态用量解析）、`--history-selftest`、`--knowledge-selftest`（跨群知识索引、敏感信息过滤和重启持久化）、JSON 解析、公版构建与隐私门禁。真实链路分两项验证：一条短视频检查画面/音轨/DeepSeek 三阶段；再用明确授权的语音分别检查短音频直传、长 WAV 本机压缩、ASR、Omni 与最终 DeepSeek 汇总。验证日志只记录格式、时长、压缩体积、报告长度和 token，不打印语音正文，也不主动向生产群发送测试消息。
