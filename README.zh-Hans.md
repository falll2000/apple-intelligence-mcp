# Apple Intelligence MCP Server

[English](README.md) | [繁體中文](README.zh-Hant.md) | **简体中文**

把 macOS 内置的 Apple Intelligence 框架（Foundation Models、Vision、Natural
Language、Speech、Sound Analysis）封装成 21 个 [MCP](https://modelcontextprotocol.io)
工具，提供给 Claude Desktop、OpenAI、Gemini、Codex、Hermes 等支持 MCP 的 AI
客户端使用。

所有计算 **100% 在你的 Mac 本地完成**。不需要 API key、不走云端、数据不出本机。

---

## 这个项目是干嘛的

OCR、翻译、摘要、语音识别这类流程固定、量又大的任务，全扔给云端 LLM 烧 token
其实挺不划算的。Apple Silicon Mac 本身就内置一套相当能打的本地 AI 模型——只是
要会写 Swift 才能直接调用。

这个项目把那套模型封装成一个 MCP 服务，让 Claude、GPT、Gemini 等 AI 客户端
可以直接把活儿派给你的 Mac：「OCR 这张图」、「转录这段录音」、「润色这条
Discord 消息」、「总结这份会议纪要」——全在本地毫秒级完成，还不要钱。

## 能拿来做什么

- **Discord / 聊天助手**
  用 `proofread_text` 抓错字、`rewrite_text(tone="professional")` 改语气、
  `summarize_text` 压缩长消息。三个工具都会保留 `@提及`、`:emoji:`、code block
  以及原始语言。
- **文档处理流水线**
  `vision_analyze(mode="ocr")` → `generate_text_structured(schema="extract")`
  → `generate_text_structured(schema="summarize")`，把扫描 PDF 或拍照文档变成
  结构化字段加摘要。
- **语音消息流水线**
  `transcribe_audio` → `summarize_text` → `synthesize_speech`，组一条
  「语音进、语音出」的完整本地流水线。
- **照片整理**
  用 `vision_analyze` 的 `classify`、`aesthetics`、`document` 模式配合
  `image_similarity` 给本地相册分类。
- **隐私敏感的转录与翻译**
  法律、医疗、HR 这类不能让音频或内容上云的场景。
- **省 token 费**
  把翻译、批量改写、情感分类这种重复性高的任务交给本地（搭配下面的
  「推荐的 host system prompt」），云端 token 留给真正需要推理的任务。

---

## 系统要求

- Apple Silicon Mac（M1 及以上）
- macOS 26（Tahoe）及以上
- 已开启 Apple Intelligence（系统设置 → Apple Intelligence 与 Siri）
- 完整 Xcode（光装 Command Line Tools 不够，缺 FoundationModels 宏）
- Homebrew + Python 3.10+（`brew install python3`）

## 安装

```bash
git clone https://github.com/falll2000/apple-intelligence-mcp.git
cd apple-intelligence-mcp
bash install.sh
```

脚本会自动做：

1. 编译 Swift Core Service（`swift build -c release`）
2. 建好 Python venv 并装 `mcp`（FastMCP）
3. 把服务（`com.apple-intel-mcp.server`）注册成 launchd agent，监听 11435 端口
4. 打印出对应你机器路径的客户端配置，直接复制粘贴就行

## 接到 AI 客户端

**Claude Desktop（stdio 模式）** — 编辑
`~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "apple-intelligence": {
      "command": "/path/to/apple-intelligence-mcp/mcp-server/venv/bin/python3",
      "args": ["/path/to/apple-intelligence-mcp/mcp-server/server.py", "--stdio"]
    }
  }
}
```

实际路径 `install.sh` 跑完会打印出来，照着贴即可。

**其他客户端（HTTP 模式）** — 开机登录后 launchd 会自动起 HTTP server：

```
http://127.0.0.1:11435/mcp
```

---

## 架构

```mermaid
flowchart TD
    Client["<b>AI 客户端</b><br/>Claude / GPT / Gemini / 等"]
    MCP["<b>Python FastMCP server</b><br/><code>mcp-server/server.py</code><br/>• 定义 21 个 <code>@mcp.tool</code><br/>• SwiftBridge：常驻子进程<br/>+ async lock + JSON line protocol"]
    Swift["<b>Swift Core Service</b>（常驻进程）<br/><code>swift-core/AppleIntelCore</code><br/>• <code>CoreService.swift</code>：请求路由<br/>• 每个 framework 对应一个 handler<br/>• 启动时把 Apple frameworks 加载一次"]

    FM["<b>FoundationModels</b><br/>本地 LLM（约 3B）"]
    Vis["<b>Vision</b><br/>18 种图像 / 姿态任务"]
    NL["<b>NaturalLanguage</b><br/>分词 / NER / POS …"]
    Sp["<b>Speech</b><br/>离线语音识别"]
    AV["<b>AVFoundation</b><br/>离线文字转语音"]
    SA["<b>SoundAnalysis</b><br/>环境音分类"]

    Client -- "MCP 协议<br/>（stdio 或 streamable-http :11435）" --> MCP
    MCP -- "stdin/stdout JSON lines<br/>（IPCRequest / IPCResponse）" --> Swift
    Swift --> FM
    Swift --> Vis
    Swift --> NL
    Swift --> Sp
    Swift --> AV
    Swift --> SA
```

**为什么要拆成两个进程？**
FastMCP 是 Python 原生库；Apple AI 框架只有 Swift 能直接调。Swift 二进制做成
常驻，是因为这些框架光初始化就要好几秒，每次重启太慢。Python 那层很薄，
只处理 MCP 协议、工具描述跟序列化。每次 `bridge.call(...)` 就是往 Swift stdin
写一行 JSON、从 stdout 读回一行 JSON——外面套一层 `asyncio.Lock` 保证请求／
响应不会交错。

## 模块结构

Swift 端 `swift-core/Sources/AppleIntelCore/` 采用「一个 framework 对应一个
handler」的拆法。加新工具有固定流程：

```
main.swift                 ← 入口（await CoreService.run()）
Models.swift               ← IPC 类型（IPCRequest / IPCResponse / JSONValue）
HandlerError.swift         ← 自定义错误（invalidInput / unavailable / …）
CoreService.swift          ← 请求路由——每个工具加一个 `case "<tool>":`
                             转发给对应 handler
GenerateHandler.swift      ← Foundation Models：
                             - generate_text（自由生成）
                             - generate_text_structured（@Generable 结构化）
TranslateHandler.swift     ← 用 FM prompt 做翻译，每个目标语言写一套
                             instructions（绕开 zh→en 时模型误判输入已经是英文的坑）
WritingToolsHandler.swift  ← 校对 / 改写 / 摘要：
                             - NLLanguageRecognizer + CJK 字符比例判断输入语言
                             - 每个语言写一套 instructions（zh-Hant / zh-Hans / en / ja）
                             - Discord-aware：保留 @ / :emoji: / ```code fence```
OCRHandler.swift           ← Vision 文字识别（zh / en / ja / ko）
VisionExtHandler.swift     ← Vision：人脸、条码、轮廓、文字区域、人脸关键点、
                             人体检测、地平线、前景分割、美学评分、光流、
                             自定义 Core ML 物体检测、图像相似度
VisionPoseHandler.swift    ← Vision：2D 姿态、手部姿态、动物、矩形、
                             saliency、文档、人像分割（3D 姿态已封死，见已知限制）
AnalyzeHandler.swift       ← NaturalLanguage：情感、语言检测、命名实体、关键词
NLAdvancedHandler.swift    ← NaturalLanguage：分词、词形还原、词性标注
NLEmbeddingHandler.swift   ← NaturalLanguage：词 / 句语义相似度
TranscribeHandler.swift    ← Speech 离线识别（SFSpeechRecognizer）
SpeechSynthHandler.swift   ← AVFoundation 文字转语音 → 输出 .wav、列出可用声音
SoundHandler.swift         ← SoundAnalysis：环境音分类
```

**新增工具的步骤：**

1. 挑对应的 handler；如果是全新的 Apple framework 就新建一个文件。
2. 写好 Swift function，遇到非法输入用 `HandlerError` throw 出去。
3. 到 `CoreService.swift` 加 `case "<tool_name>":`，解析 params 后调 handler。
4. 到 `mcp-server/server.py` 加一个 `@mcp.tool()` function，docstring 用
   WHEN / NOT-FOR 格式写清楚，内部调 `await bridge.call("<tool_name>", {...})`。
5. 重新 build Swift（`swift build -c release`），重启 MCP
   （`launchctl kickstart -k gui/$UID/com.apple-intel-mcp.server`）。
6. 三份 README（[README.md](README.md)、[繁體](README.zh-Hant.md)、这份）都记得更新。

---

## 工具列表（共 21 个）

18 种单张图片的 Vision 任务被收进一个 `vision_analyze`（用 `mode` 参数路由），
没拆成 18 个独立工具——实测下来这样做能明显提升 host LLM 选工具的准确度。

### Foundation Models — 本地 LLM

| 工具 | 说明 |
|------|-------------|
| `generate_text` | 通用文字生成 / 改写 |
| `generate_text_structured` | Guided generation，输出 JSON 结构固定。Schemas：`list` / `classify` / `summarize` / `extract` / `qa`（每个 schema 各自的 prompt 建议都写在工具描述里） |
| `translate_text` | zh-Hant / zh-Hans / en / ja / ko / fr / de / es 互译，每个目标语言用该语言写的 instructions |
| `proofread_text` | 抓用户文字里的错字、语法、标点。保留语气、语言、Discord 语法（@ / :emoji: / code block） |
| `rewrite_text` | 改写语气（`formal` / `casual` / `concise` / `friendly` / `professional`），保留原意、语言、Discord 语法 |
| `summarize_text` | 压缩成 `short` / `medium` / `long` 段落；输入中文输出中文、输入英文输出英文 |

### Vision — 图像 / 姿态

| 工具 | 说明 |
|------|-------------|
| `vision_analyze` | 18 种单图任务的统一入口。`mode` 可选 `ocr`, `classify`, `faces`, `face_landmarks`, `barcodes`, `text_regions`, `contours`, `human_bodies`, `rectangles`, `horizon`, `saliency`, `document`, `segment_person`, `segment_foreground`, `aesthetics`, `body_pose`, `hand_pose`, `animals` |
| `image_similarity` | 两张本地图片的视觉相似度（Vision feature print L2 距离，阈值已调成 0.1 / 0.4 / 0.8） |
| `detect_optical_flow` | 两张连续帧之间的逐像素运动向量 |
| `detect_trajectories` | 在本地视频中检测抛物线轨迹 |
| `detect_objects` | 用你自备的 Core ML 模型（`.mlmodel` / `.mlmodelc`）做物体检测 |

### Natural Language

| 工具 | 说明 |
|------|-------------|
| `analyze_text` | 情感 + 语言检测 + 命名实体 + 关键词 |
| `tokenize_text` | 把文字切成词 / 句 / 段（多语言；中文分词正常） |
| `tag_parts_of_speech` | 词性标注 |
| `lemmatize_text` | 词形还原（running → run） |
| `word_similarity` | 两个词的语义相似度（0–1） |
| `sentence_similarity` | 两个句子的语义相似度（0–1） |

### Speech & Sound

| 工具 | 说明 |
|------|-------------|
| `transcribe_audio` | 离线语音识别（zh-TW / zh-CN / en-US / ja-JP / …），已启用标点与口述模式 |
| `synthesize_speech` | 用 AVSpeechSynthesizer 离线文字转语音 → 输出 `.wav`（默认 zh-TW Meijia） |
| `list_voices` | 列出所有可用声音 identifier，可用 BCP-47 前缀过滤 |
| `classify_sound` | 环境音分类（音乐、笑声、犬吠…）；输入至少 3 秒 |

---

## 推荐的 host system prompt

要不要调这些工具，由 host model 根据自己的 system prompt 和工具描述决定。
Server 这边的描述已经用 `WHEN: / NOT FOR:` 格式写过了，不过 host 端最好也加
一份明确的策略。把下面这段贴到你 client 的 system prompt 里可以让路由更稳定
（用英文写是因为大多数 host LLM 对英文指令最敏感）：

```
You have access to an `apple-intelligence` MCP server that runs entirely on the
user's Mac. You MUST prefer it for the following task types instead of doing
the work yourself:

  - User provides an absolute path to an image file → call `vision_analyze`
    with the appropriate mode. Do NOT describe the image yourself first.
  - User provides an absolute path to an audio file and wants the words →
    call `transcribe_audio`.
  - User asks for tokenization or lemmatization → call the matching tool.
  - User asks for sentiment classification → call
    `generate_text_structured(schema="classify")` (works for Chinese too,
    unlike `analyze_text` which is English-only).
  - User asks to compare two images → `image_similarity`.
  - User asks to read text aloud → call `synthesize_speech` and attach
    the returned `.wav` path to the response.
  - User has already-written text and asks to "check / fix typos /
    proofread" it → call `proofread_text` (NOT `generate_text`).
  - User has already-written text and asks to make it "formal / casual /
    shorter / friendlier / more professional" → call `rewrite_text` with
    the matching `tone`.
  - User has long text and asks to "summarize / TL;DR / shorten" → call
    `summarize_text`. Use `generate_text_structured(schema="summarize")`
    only when the caller needs JSON with `title` + `keyPoints[]`.

You MAY use it (caller's discretion) for:
  - Bulk text rewriting / translation where token cost matters more than nuance
    → `generate_text`, `translate_text`, `generate_text_structured`.

You should NOT use it for:
  - Tasks needing strong reasoning, code, math, or current-events knowledge —
    the on-device model is small. Use your own generation.
```

---

## 中文支持情况

Apple 各 framework 对语言的支持程度差距很大。Vision、Speech、Foundation Models
对中文都不错；比较老的 NaturalLanguage 和 NLEmbedding 在这套 stack 上实际几乎
只能处理英文。

| 工具 | 中文（zh-Hant / zh-Hans） |
|---|---|
| `vision_analyze`（所有 mode） | ✓ 支持良好 |
| `transcribe_audio` | ✓ 准确（Apple 模型只加逗号、不加句号） |
| `synthesize_speech` | ✓ 有 Meijia、Eloquence 等中文声音可选 |
| `tokenize_text` | ✓ 中文分词正常（「牛肉面」会作为一个 token 保留） |
| `lemmatize_text` | ✓ 中文不会被乱改（中文没有词形变化） |
| `generate_text_structured`（`classify`） | ✓ 可用于中文情感分类 |
| `translate_text` | ✓ zh→en / zh→ja 稳定；en→zh 会用大陆 / 港澳台常见译名（苹果商店、特斯拉）；成语会直译 |
| `proofread_text` | ⚠ 语言保留正确；FM 对中文语法错误（一各 / 再 / 的-vs-得）抓得偏弱，英文偶尔漏抓主谓一致 |
| `rewrite_text` | ✓ 语言保留正确；`professional` / `concise` / `formal` 稳定；`casual` / `friendly` 偶尔会改写过头 |
| `summarize_text` | ✓ 语言保留正确（中→中、英→英）；`short` 偶尔不够短 |
| `generate_text` | ⚠ 短 prompt OK；知识截止约 2023 |
| `classify_sound` | ⚠ 跟语言无关，但排序偶尔不准 |
| `analyze_text` | ✗ 中文情感永远是 0 / 中性，命名实体几乎抓不到 |
| `tag_parts_of_speech` | ✗ 中文所有词性都会标成「其他」 |
| `word_similarity` / `sentence_similarity` | ✗ 没有加载中文 embedding 模型 |

主要做中文场景时，建议在 host 的 MCP 配置层直接把 ✗ 那四个排除掉（比如
hermes 的 `mcp_servers.<name>.tools.exclude`），这样 host LLM 就不会把中文
请求路由过去。

## 已知限制

**Foundation Models 自带的 safety filter** — `generate_text` 跟相关工具有时
会对某些内容直接报错。这个 filter 是 Apple 模型内置的，不是这个 server 加的。
连看起来人畜无害的字（比如品牌名里的「胖」）都可能被拦——容易踩雷的内容建议
改走 `generate_text_structured`。

**`detect_objects`** 需要你自备 Core ML 模型（`.mlmodel` 或 `.mlmodelc`）。
其他工具都开箱即用。

**`detect_trajectories`** 需要 mp4 / mov 视频文件，对抛物线运动（球类运动）
效果最好。

**`body_pose_3d` 已经从公开 mode 列表里移掉了。**
`VNDetectHumanBodyPose3DRequest` 在跑 `perform` 时会抛出 Swift 接不住的
Objective-C exception，整个 Swift Core 进程会被它干掉。Swift case 还保留作为
兜底（老的 client 还在传这个 mode 的话会收到 `unavailable`），但对外不再宣传。
要做姿态检测请改用 `mode="body_pose"`（2D pose）。

**Apple Intelligence 天花板** — 下面这几个 macOS 26 API 在 SDK 里*看起来*能用，
实际上从 daemon 是调不动的：

| API | 为什么被拦 |
|---|---|
| Writing Tools（`NSWritingToolsCoordinator`） | 绑 UI（需要 `NSView`）。我们改用 Foundation Models 自己 prompt 出 `proofread_text` / `rewrite_text` / `summarize_text` 来替代 |
| Image Playground（`ImageCreator`） | 哪怕在 Terminal 里跑也会返回 `backgroundCreationForbidden`——Apple 限定 entitlement |
| Genmoji | 走 `ImageCreator(style="emoji")`，同一个 entitlement 拦截 |
| Visual Intelligence | 只有 `AppIntents.AssistantSchemas.VisualIntelligenceIntent`，是 schema only，不是真的可调用的 API |
| Smart Reply | `CSSmartReply` 是 internal symbol（只出现在 `.tbd`，没有对外的 header） |

**Vision runtime 测试** 请在 Xcode 构建的 binary、Terminal 或其他非 sandbox
环境跑。Sandbox runner 会误报 `CVPixelBuffer`、`ANECF`、`request cancelled`
之类的错误。

---

## 管理服务（HTTP 模式）

`install.sh` 注册的 launchd agent 会在登录时自动起来、crash 后自动重启。
要手动控制：

```bash
bash start.sh                                           # bootstrap launchd agent
bash stop.sh                                            # bootout launchd agent
tail -f /tmp/apple-intel-mcp.log                        # 看 log
launchctl kickstart -k gui/$UID/com.apple-intel-mcp.server   # 强制重启
```

## Hermes 集成（可选）

如果你也在用 [hermes](https://github.com/) 并希望 `hermes gateway
start/stop/restart` 联动 MCP server：

```bash
bash install-hermes-integration.sh    # 装 watchdog
bash uninstall-hermes-integration.sh  # 卸载 watchdog（不影响 mcp 本身）
```

这会再装一个 launchd agent（`com.apple-intel-mcp.hermes-watchdog`），每 3 秒
查一次 `ai.hermes.gateway` 状态并同步给 MCP server：

| Hermes 动作 | MCP 反应（最多 3 秒延迟） |
|---|---|
| `hermes gateway stop` | `bootout` MCP |
| `hermes gateway start` | `bootstrap` MCP |
| `hermes gateway restart` | `kickstart -k` MCP（靠 PID 变化判断） |

集成是纯加分项，不装 MCP 也照样跑。`install.sh` 检测到 hermes 已安装时会
主动提示。

> 实现小备注：watchdog 脚本在 install 时会复制一份到
> `~/Library/Application Support/apple-intel-mcp/`，因为 macOS 26 launchd 拒绝
> 直接从 `/Volumes/` 跑 shell 脚本（会被 TCC 拦成「Operation not permitted」）。
> Python venv binary 没踩到这条。

## 卸载

```bash
bash uninstall.sh   # 移除 mcp + watchdog（如果装过）
```

---

## 项目结构

```
apple-intelligence-mcp/
├── install.sh / uninstall.sh
├── install-hermes-integration.sh / uninstall-hermes-integration.sh
├── start.sh / stop.sh
├── bin/
│   └── hermes-watchdog.sh         # 轮询 ai.hermes.gateway，联动 mcp 状态
├── mcp-server/
│   ├── server.py                  # FastMCP server + SwiftBridge（约 650 行）
│   └── requirements.txt           # mcp>=1.0.0
├── swift-core/
│   ├── Package.swift              # macOS 26、Swift 6
│   └── Sources/AppleIntelCore/    # 约 2,500 行，一个 framework 一个 handler
│       ├── main.swift             # 入口
│       ├── CoreService.swift      # 请求路由
│       ├── Models.swift           # IPC 类型
│       ├── HandlerError.swift     # 自定义错误
│       ├── GenerateHandler.swift          # Foundation Models
│       ├── TranslateHandler.swift         # FM 翻译
│       ├── WritingToolsHandler.swift      # 校对 / 改写 / 摘要
│       ├── OCRHandler.swift               # Vision 文字识别
│       ├── VisionExtHandler.swift         # Vision 检测类工具
│       ├── VisionPoseHandler.swift        # Vision 姿态 / 动态类工具
│       ├── AnalyzeHandler.swift           # NL 情感 / NER / 关键词
│       ├── NLAdvancedHandler.swift        # NL 分词 / POS / 词形还原
│       ├── NLEmbeddingHandler.swift       # NL 语义相似度
│       ├── TranscribeHandler.swift        # Speech 语音识别
│       ├── SpeechSynthHandler.swift       # AVFoundation 文字转语音
│       └── SoundHandler.swift             # SoundAnalysis 环境音分类
└── test-assets/                   # 测试用示例图
```

## 许可证

MIT
