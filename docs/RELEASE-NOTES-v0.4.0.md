# v0.4.0 · QQ 整段视频、音轨 ASR 与 DeepSeek 汇总

这次把“看视频”拆成画面、声音和最终推理三项独立职责，避免把抽三帧、看不到音轨或模型名称混用当成完整视频理解。

## 新增

- QQ 当前消息、引用消息与合并转发中的原视频可进入 AI 流水线。
- Qwen3.7 Flash 接收完整视频并按 `fps=1.0` 覆盖时间轴；只有取不到原视频或模型不支持时才抽 1–3 张关键帧。
- 可选 Qwen Audio 3.0 ASR Flash 直接读取视频容器音轨，与画面分析并行。
- DeepSeek V4 Flash 恢复为公版默认最终模型，负责合并画面报告、音轨转写和服务器证据后作答。
- 根目录增加 Web 控制面板快捷入口。

## 安全和费用

- 视觉报告与 ASR 转写被标记为不可信媒体数据；其中的命令或提示词不能触发服务器动作。
- 公版 `ai.enabled=false`、`audioTranscription.enabled=false`，所有 API Key 为空；启用前由腐竹自行确认权限和费用。
- 回答页脚分列 DeepSeek、Qwen 视觉与 ASR 的用量或费用，避免把订阅额度和 API 账单混在一起。
- 构建器支持用独立实机目录做域名、群号、玩家身份、路径和凭据的交叉比对，不回显真实值。

## 兼容与降级

- 不要求本机用 ffmpeg 预先提取音频；ASR 直接接收视频 URL/Data URL。
- ASR 失败不影响画面分析；无原生视频输入才调用 ffmpeg 关键帧兜底。
- 本机 Grok Build 仍可手动切换，但不是默认汇总模型。

完整说明：[QQ 视频画面、音轨与 DeepSeek 汇总](qq-video-audio-ai.md)。

## 发布验收

- 包内 Java 独立编译与 `--media-selftest` 通过；公开模板状态核对为 DeepSeek + Qwen3.7 Flash，ASR 默认关闭。
- 57 个 PowerShell、7 个 JSON、36 个 BAT、1 个 macOS `.command` 及 Python 源码通过格式/解析检查；玩家混源更新器 15 项测试通过。
- 140 文件 ZIP CRC 通过；固定 ZIP 时间戳后，同一源码树连续两次构建的字节数与 SHA-256 完全一致；实机私有值和通用密钥模式扫描均为 0 命中。
- 实机 QQ/OneBot 只读回归 6/6；真实短视频端到端验证过画面、音轨、DeepSeek 三阶段，测试内容未进入发布物。
