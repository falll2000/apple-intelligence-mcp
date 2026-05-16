# Apple Intelligence MCP Server

[English](README.md) | **繁體中文**

把 Apple 的本地 AI 框架（Vision、Natural Language、Speech、Sound Analysis、Foundation Models）包成 [MCP](https://modelcontextprotocol.io) 工具——只要 AI client 支援 MCP（Claude、OpenAI、Gemini、Codex…）就能把它們當本地工具呼叫。

一切都在 **100% 本機執行**。不打雲端 API，資料不離開你的 Mac。

---

## 系統需求

- Apple Silicon Mac（M1 或更新）
- macOS 26（Tahoe）或更新
- 已啟用 Apple Intelligence（系統設定 → Apple 智慧與 Siri）
- Xcode Command Line Tools（`xcode-select --install`）
- Homebrew + Python 3.10+（`brew install python3`）

---

## 安裝

```bash
git clone https://github.com/YOUR_USERNAME/apple-intelligence-mcp.git
cd apple-intelligence-mcp
bash install.sh
```

腳本會做：
1. 編譯 Swift Core Service（release build）
2. 建立 Python venv 並安裝相依套件
3. 透過 launchd 在 port 11435 啟動 HTTP MCP server
4. 印出可直接貼到 AI client 的設定片段

---

## 接到 Claude Desktop

編輯 `~/Library/Application Support/Claude/claude_desktop_config.json`：

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

> `install.sh` 跑完會印出你機器上的實際路徑，直接複製貼上即可。

## 接到其他 AI client（OpenAI / Gemini 等）

```
http://127.0.0.1:11435/mcp
```

HTTP server 透過 launchd 在登入時自動啟動。

---

## 架構

```
AI Client（Claude / OpenAI / 等）
        │  MCP 協議
        ▼
Python FastMCP server  ←── stdio（Claude Desktop 走這條）
mcp-server/server.py   ←── streamable-http :11435（其他 client 走這條）
        │  JSON lines over stdin/stdout
        ▼
Swift Core Service
swift-core/AppleIntelCore   ← 常駐 process，frameworks 只載入一次
        │
        ├── FoundationModels   （本地 LLM）
        ├── Vision             （圖像分析）
        ├── NaturalLanguage    （文字分析）
        ├── Speech             （語音 → 文字）
        └── SoundAnalysis      （音訊分類）
```

---

## 工具一覽（共 21 支）

19 種單張圖片的 Vision 能力被收進一支 `vision_analyze`（以 `mode` 參數路由），而不是拆成 19 支。實測這樣做能明顯提升 host LLM 選工具的準確度。

### Foundation Models — 本地 LLM

| 工具 | 說明 |
|------|-------------|
| `generate_text` | 一般文字生成 / 改寫 |
| `generate_text_structured` | Guided generation — 保證 JSON 形狀。Schemas：`list` / `classify` / `summarize` / `extract` / `qa` |
| `translate_text` | 翻譯：zh-Hant / zh-Hans / en / ja / ko / fr / de / es 互譯 |
| `proofread_text` | 校對：抓使用者已輸入文字的錯字 / 語法 / 標點。保留語氣、語言、Discord 語法（@提及、:emoji:、code block） |
| `rewrite_text` | 改寫語氣（`formal` / `casual` / `concise` / `friendly` / `professional`），保留原意、語言、Discord 語法 |
| `summarize_text` | 濃縮為 short / medium / long 散文。輸入輸出同語言（中→中、英→英） |

### Vision — 圖像 / 姿態

| 工具 | 說明 |
|------|-------------|
| `vision_analyze` | 19 種單張圖片任務的單一入口。`mode` ∈ {`ocr`, `classify`, `faces`, `face_landmarks`, `barcodes`, `text_regions`, `contours`, `human_bodies`, `rectangles`, `horizon`, `saliency`, `document`, `segment_person`, `segment_foreground`, `aesthetics`, `body_pose`, `body_pose_3d`, `hand_pose`, `animals`} |
| `image_similarity` | 兩張圖檔的視覺相似度評分 |
| `detect_optical_flow` | 兩個畫面間的每像素移動向量 |
| `detect_trajectories` | 從影片中偵測拋物線軌跡 |
| `detect_objects` | 用使用者自備的 Core ML model 做物件偵測 |

### Natural Language

| 工具 | 說明 |
|------|-------------|
| `analyze_text` | 情感 + 語言偵測 + 命名實體 + 關鍵字 |
| `tokenize_text` | 切成詞 / 句 / 段落 |
| `tag_parts_of_speech` | 詞性標記 |
| `lemmatize_text` | 詞形還原（base form） |
| `word_similarity` | 兩個詞的語意相似度（0–1） |
| `sentence_similarity` | 兩個句子的語意相似度（0–1） |

### Speech & Sound

| 工具 | 說明 |
|------|-------------|
| `transcribe_audio` | 離線語音轉文字（zh-TW / zh-CN / en-US / ja-JP / ...） |
| `synthesize_speech` | 離線文字轉語音（AVSpeechSynthesizer）→ `.wav`（預設 zh-TW Meijia） |
| `list_voices` | 列出可用的 TTS voice identifier，可用 BCP-47 前綴過濾 |
| `classify_sound` | 環境音分類（音樂、笑聲、犬吠…） |

---

## 推薦的 host system prompt

要不要呼叫這些工具，是由 host model 根據它自己的 system prompt 跟工具描述判斷的。本 server 的工具描述用 `WHEN: / NOT FOR:` 格式幫忙，但 host 端也需要明確的政策。把下面這段貼到你的 client system prompt 裡，可以讓路由更穩定：

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

## 使用注意事項

**不同 Apple framework 對中文支援度落差很大。** Vision、Speech、FoundationModels 對中文支援良好；較舊的 NaturalLanguage 跟 NLEmbedding 在這套 stack 上實際只支援英文。

| 工具 | zh-Hant / zh-Hans |
|---|---|
| `vision_analyze`（所有 mode） | ✓ 支援良好 |
| `transcribe_audio` | ✓ 準確（Apple 模型只加逗號、不加句號） |
| `synthesize_speech` | ✓ Meijia / Eloquence 等中文聲音 |
| `tokenize_text` | ✓ 正確中文斷詞（「牛肉麵」會保留為單一 token） |
| `lemmatize_text` | ✓ 中文正確 no-op（中文沒有屈折變化） |
| `generate_text_structured`（`classify`） | ✓ 可用於中文情感分析 |
| `translate_text` | ✓ zh→en / zh→ja 可靠；en→zh 用標準在地化品牌名（蘋果商店、特斯拉）；成語會直譯 |
| `proofread_text` | ⚠ 語言保留正確；FM 會漏掉部分中文文法錯（一各 / 再 / 的-vs-得），英文偶爾漏抓主動詞一致性 |
| `rewrite_text` | ✓ 語言保留正確；`professional` / `concise` / `formal` 穩定；`casual` / `friendly` 偶爾改寫過頭 |
| `summarize_text` | ✓ 語言保留正確（中→中、英→英）；`short` 長度偶爾不夠短 |
| `generate_text` | ⚠ 短 prompt OK；知識截止約 2023 |
| `classify_sound` | ⚠ 與語言無關但排序偶爾不準 |
| `analyze_text` | ✗ 中文情感永遠是 0 / 中性、NER 抓不到中文實體 |
| `tag_parts_of_speech` | ✗ 中文所有 tag 都變「其他」 |
| `word_similarity` / `sentence_similarity` | ✗ 沒有載入中文 embedding model |

中文使用為主時，建議在 host MCP 設定層把 ✗ 那四支排除掉（例如 hermes 的 `mcp_servers.<name>.tools.exclude`），讓 host LLM 不會把中文需求路由過去。

**Apple Foundation Models safety filter** — `generate_text` 跟相關工具可能對某些內容回錯誤。這是本機模型的限制，不是這個 server 加的。連看起來無害的字（像品牌名中的「胖」）都可能被擋——容易踩到 filter 的內容建議改用 `generate_text_structured`。

**`detect_objects`** 需要使用者自備 Core ML model（`.mlmodel` 或 `.mlmodelc`）。其他工具都開箱即用。

**`detect_trajectories`** 需要影片檔（mp4 / mov），對拋物線運動（球類運動等）效果最好。

**`vision_analyze(mode="body_pose_3d")`** 暫時停用，會回 `unavailable`。`VNDetectHumanBodyPose3DRequest` 在 `perform` 期間會用未捕獲的 Objective-C exception 終止 Swift Core process，Swift 端無法 catch。請用 `mode="body_pose"`（2D pose）做穩定的姿態偵測。

**Vision runtime 測試** 應該在 Xcode build 出來的 binary、Terminal 或其他非 sandbox 環境跑。Sandbox runner 會誤報 `CVPixelBuffer`、`ANECF`、`request cancelled` 之類的錯誤。

---

## 啟動 / 停止（HTTP 模式）

`install.sh` 會註冊一個 launchd agent（`com.apple-intel-mcp.server`），開機登入時自動啟動、crash 時自動重啟。一般不用碰它。要手動控制：

```bash
bash start.sh    # bootstrap launchd agent
bash stop.sh     # bootout launchd agent
tail -f /tmp/apple-intel-mcp.log   # 看 log
```

---

## Hermes 整合（選用）

如果你用 hermes 並希望 `hermes gateway start/stop/restart` 自動連動 MCP server：

```bash
bash install-hermes-integration.sh    # 安裝 watchdog
bash uninstall-hermes-integration.sh  # 移除 watchdog（不影響 mcp）
```

這會額外裝一個 launchd agent（`com.apple-intel-mcp.hermes-watchdog`），每 3 秒輪詢一次，把 `ai.hermes.gateway` 的狀態鏡像到 MCP server 上：

| Hermes 動作 | MCP 反應（≤ 3 秒延遲） |
|---|---|
| `hermes gateway stop` | `bootout` MCP |
| `hermes gateway start` | `bootstrap` MCP |
| `hermes gateway restart` | `kickstart -k` MCP（PID 變化偵測） |

整合是純附加性的——不裝它 MCP 也跑得好好的。`install.sh` 偵測到 hermes 已安裝時會印出提示。

---

## 解除安裝

```bash
bash uninstall.sh   # 移除 mcp + watchdog（如果裝過）
```

---

## 專案結構

```
apple-intelligence-mcp/
├── install.sh / uninstall.sh
├── install-hermes-integration.sh / uninstall-hermes-integration.sh
├── start.sh / stop.sh
├── bin/
│   └── hermes-watchdog.sh    # 輪詢 ai.hermes.gateway，連動 mcp 狀態
├── mcp-server/
│   ├── server.py          # Python FastMCP server
│   └── requirements.txt
├── swift-core/
│   ├── Package.swift
│   └── Sources/AppleIntelCore/
│       ├── main.swift
│       ├── CoreService.swift      # 請求路由
│       ├── GenerateHandler.swift  # Foundation Models
│       ├── OCRHandler.swift
│       ├── AnalyzeHandler.swift   # NL 情感 / NER / 關鍵字
│       ├── NLAdvancedHandler.swift # 斷詞 / POS / 詞形還原
│       ├── NLEmbeddingHandler.swift # 詞 / 句相似度
│       ├── TranslateHandler.swift
│       ├── WritingToolsHandler.swift # 校對 / 改寫 / 摘要
│       ├── TranscribeHandler.swift
│       ├── SoundHandler.swift
│       ├── VisionExtHandler.swift  # Vision 圖像工具
│       ├── VisionPoseHandler.swift # Vision 姿態 / 動態工具
│       ├── Models.swift           # IPC 型別
│       └── HandlerError.swift
└── test-assets/           # 測試用範例圖
```

---

## 授權

MIT
