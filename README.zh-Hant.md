# Apple Intelligence MCP Server

[English](README.md) | **繁體中文** | [简体中文](README.zh-Hans.md)

[![Python syntax](https://github.com/falll2000/apple-intelligence-mcp/actions/workflows/python.yml/badge.svg)](https://github.com/falll2000/apple-intelligence-mcp/actions/workflows/python.yml)

把 macOS 內建的 Apple Intelligence 框架（Foundation Models、Vision、Natural
Language、Speech、Sound Analysis）包成 21 個 [MCP](https://modelcontextprotocol.io)
工具，給 Claude Desktop、OpenAI、Gemini、Codex、Hermes 等支援 MCP 的 AI 客戶端使用。

所有運算 **100% 在你的 Mac 本機跑**。不用 API key、不打雲端、資料不離開機器。

---

## 概覽

### 為什麼會有這個專案

OCR、翻譯、摘要、語音辨識這種流程固定、量又大的工作，丟給雲端 LLM 燒 token
其實很不划算。Apple Silicon Mac 本身就已經內建一套堪用的本機 AI 模型——只是
要會寫 Swift 才能直接呼叫。

這個專案把那套模型包成一個 MCP 服務，讓 Claude、GPT、Gemini 等 AI 客戶端可以
直接把工作丟給你的 Mac：「OCR 這張圖」、「轉錄這段錄音」、「潤稿這則 Discord
訊息」、「摘要這份會議紀錄」——全在本機毫秒內搞定，免費。

### 可以拿來做什麼

- **Discord / 聊天助手**
  用 `proofread_text` 抓錯字、`rewrite_text(tone="professional")` 改語氣、
  `summarize_text` 濃縮長訊息。三個工具都會保留 `@提及`、`:emoji:`、code block
  跟原本的語言。
- **文件處理流程**
  `vision_analyze(mode="ocr")` → `generate_text_structured(schema="extract")`
  → `generate_text_structured(schema="summarize")`，把掃描 PDF 或拍照文件
  變成結構化欄位加摘要。
- **語音訊息流程**
  `transcribe_audio` → `summarize_text` → `synthesize_speech`，組一條
  「語音進、語音出」的完整本機流程。
- **照片整理**
  用 `vision_analyze` 的 `classify`、`aesthetics`、`document` 配合
  `image_similarity` 做本機相簿分類。
- **隱私敏感的轉錄與翻譯**
  法律、醫療、HR 這類不能讓音檔或內容上雲的場景。
- **省 token 錢**
  把翻譯、批次改寫、情感分類這種重複性高的工作派給本機（搭配下面的
  「推薦 host system prompt」），雲端 token 留給真的需要推理的任務。

---

## 快速開始

### 系統需求

- Apple Silicon Mac（M1 以上）
- macOS 26（Tahoe）以上
- 已開啟 Apple Intelligence（系統設定 → Apple 智慧與 Siri）
- 完整 Xcode（只裝 Command Line Tools 不夠，會少 FoundationModels 巨集）
- Homebrew + Python 3.10+（`brew install python3`）

### 安裝

```bash
git clone https://github.com/falll2000/apple-intelligence-mcp.git
cd apple-intelligence-mcp
bash install.sh
```

腳本會自動：

1. 編譯 Swift Core Service（`swift build -c release`）
2. 建立 Python venv 並安裝 `mcp` Python SDK（2.x）
3. 把服務 (`com.apple-intel-mcp.server`) 註冊成 launchd agent，listen on 11435
4. 印出對應你電腦路徑的客戶端設定，可以直接複製貼上

### 接到 AI 客戶端

**Claude Desktop（stdio 模式）** — 編輯
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

實際路徑 `install.sh` 跑完會印出來，照貼就好。

**其他客戶端（HTTP 模式）** — 開機登入後 launchd 會自動起 HTTP server：

```
http://127.0.0.1:11435/mcp
```

**OpenClaw** — 在 `~/.openclaw/openclaw.json` 的 `mcp.servers` 底下註冊。HTTP server
已由 launchd 常駐，所以讓 OpenClaw 直接連它即可（不必讓 OpenClaw 自己拉起行程）：

```json
{
  "mcp": {
    "servers": {
      "apple-intelligence": {
        "url": "http://127.0.0.1:11435/mcp",
        "transport": "streamable-http",
        "connectionTimeoutMs": 10000,
        "requestTimeoutMs": 300000
      }
    }
  }
}
```

或者用 CLI 註冊，免手改檔：

```bash
openclaw mcp set apple-intelligence \
  '{"url":"http://127.0.0.1:11435/mcp","transport":"streamable-http","requestTimeoutMs":300000}'
openclaw mcp list                        # 確認已註冊
openclaw mcp probe                       # 實際連線，列出它宣告了什麼
```

用 `openclaw mcp configure apple-intelligence` 做 per-server 調整（OpenClaw 2026.9+）：

| CLI 旗標 | `openclaw.json` 欄位 | 用途 |
|---|---|---|
| `--include` / `--exclude` | `toolFilter.include` / `toolFilter.exclude` | 要曝露／隱藏的工具名，支援 `*` glob |
| `--approval auto\|prompt\|approve` | `codex.defaultToolsApprovalMode` | 工具核准模式 |
| `--timeout` | `requestTimeoutMs` | 單次呼叫逾時。OpenClaw 預設 **60 秒**，遠低於本 server 自己的 300 秒防呆上界，請調高；否則長音檔轉寫、影片分析會在 server 還在跑的時候就被 client 放棄 |
| `--connect-timeout` | `connectionTimeoutMs` | 連線逾時 |
| `--parallel` | `supportsParallelToolCalls` | 不要開。OpenClaw 預設就是每台 server 串行；開了之後它會並發送出，而 Swift bridge 內部仍然串行化，排隊的那幾個只是在燒掉自己的逾時額度 |

舊的欄位拼法（`timeout`、`connect_timeout`、`ssl_verify`、`client_cert`、
`client_key`、`supports_parallel_tool_calls`、`workingDirectory`、`disabled`）在
現行 OpenClaw 會直接被判為設定錯誤——用 `openclaw doctor --fix` 遷移。

想改用 stdio（由 OpenClaw 拉起行程），就在 server 項目裡填上面 Claude Desktop 區塊
那組相同的 `command` / `args`。

**Hermes** — 用 `hermes mcp` CLI 註冊（指向已常駐的 HTTP server）：

```bash
hermes mcp add apple-intelligence --url http://127.0.0.1:11435/mcp
hermes mcp test apple-intelligence    # 驗證連線 + 工具列表
```

`~/.hermes/config.yaml` 裡 `mcp_servers.apple-intelligence` 底下可用的 key：

| Key | 用途 |
|---|---|
| `tools.exclude` / `tools.include` | 依名稱隱藏或設白名單——例如中文場景排掉那幾個只支援英文的 NL 工具（見[中文支援狀況](#中文支援狀況)） |
| `trust: full \| untrusted` | 設 `untrusted` 時，會寫入的工具每次呼叫都要核准。本專案每支工具都宣告了 `readOnlyHint`，只有 `synthesize_speech` 例外，所以只有它會跳核准 |
| `protocol: auto \| stateless \| legacy` | 握手世代；對本 server 用 `auto` 即可 |
| `timeout` / `connect_timeout` / `keepalive_interval` | 秒 |
| `lazy: true` | 首次使用時才連線，不在 gateway 啟動時連 |

### 推薦的 host system prompt

要不要呼叫這些工具，由 host model 看它的 system prompt 跟工具描述決定。Server
這邊的描述已經用 `WHEN: / NOT FOR:` 格式寫過，但 host 端最好也加一份明確政策。
把下面這段貼到你的 client system prompt 可以讓路由穩定（用英文寫是因為大多
host LLM 對英文指令最敏感）：

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

## 工具清單（共 21 支）

18 種單張圖片的 Vision 任務被收進一支 `vision_analyze`（用 `mode` 參數路由），
沒拆成 18 支獨立工具——實測這樣做能明顯提升 host LLM 選工具的準確度。

每支工具都宣告了 MCP 的 `readOnlyHint` annotation，只有 `synthesize_speech` 會寫檔。
會依 annotation 決定是否攔截呼叫的 host（OpenClaw 的核准模式、hermes 的 trust 分級）
需要這個資訊，否則會把每支工具都當成有寫入風險。

### Foundation Models — 本機 LLM

| 工具 | 說明 |
|------|-------------|
| `generate_text` | 一般文字生成 / 改寫 |
| `generate_text_structured` | Guided generation，輸出 JSON 結構保證固定。Schemas：`list` / `classify` / `summarize` / `extract` / `qa`（每個 schema 都有自己的 prompt 建議寫在工具描述裡） |
| `translate_text` | zh-Hant / zh-Hans / en / ja / ko / fr / de / es 互譯，每個目標語言用該語言的 instructions |
| `proofread_text` | 抓使用者文字裡的錯字、語法、標點。保留語氣、語言、Discord 語法（@ / :emoji: / code block） |
| `rewrite_text` | 改寫語氣（`formal` / `casual` / `concise` / `friendly` / `professional`），保留原意、語言、Discord 語法 |
| `summarize_text` | 濃縮為 `short` / `medium` / `long` 段落；輸入中文輸出中文、英文輸出英文 |

### Vision — 圖像 / 姿態

**`vision_analyze`** 是單張圖片的入口：用一支 MCP 工具，透過 `mode` 參數提供
**18 種不同的 Vision 能力**（一次選一種）：

| `mode` | 能力 |
|--------|------|
| `ocr` | 從圖片擷取文字（zh-Hant / zh-Hans / en / ja / ko） |
| `classify` | 場景 / 物件標籤與信心值 |
| `faces` | 人臉數量 + 邊界框 |
| `face_landmarks` | 每張臉的眼 / 鼻 / 嘴 / 輪廓特徵點 |
| `barcodes` | QR / EAN-13 / Code-128 / PDF417 等 |
| `text_regions` | 只回文字邊界框（不做 OCR 內容） |
| `contours` | 邊緣 / 輪廓偵測 |
| `human_bodies` | 人體邊界框（`upper_body_only=True` 只取上半身） |
| `rectangles` | 矩形區域（卡片、螢幕、白板） |
| `horizon` | 地平線角度——照片有沒有歪？ |
| `saliency` | 視覺注意力熱區圖 |
| `document` | 紙張 / 文件邊界框 |
| `segment_person` | 人物存在與遮罩大小 |
| `segment_foreground` | 各實例前景遮罩 |
| `aesthetics` | 美感分數 0–1 + 工具性圖片旗標 |
| `body_pose` | 2D 人體關節（15 個關鍵點） |
| `hand_pose` | 手部關節 + 左 / 右手 |
| `animals` | 貓 / 狗偵測 |

> **為什麼用一支 router，而不是 18 支工具？** 這每一種底層都是獨立的 Apple
> Vision request（Swift core 裡也各是一個 `case`），但它們的輸入完全相同——一個
> 本機圖片路徑。把它們收成單一的 `vision_analyze(mode=...)`，比起對外宣告 18 支
> 幾乎一模一樣的工具，實測能明顯提升 host LLM 選工具的準確度，也縮小每次請求都要
> 攜帶的工具清單 token。第 19 種能力 `body_pose_3d` 在 Swift core 裡存在，但**刻意
> 不**開成 mode——詳見 [已知限制](#已知限制)。

其餘 Vision 工具維持獨立，因為它們的輸入不同（影片、兩張圖、或自備模型，而非單張
圖片路徑）：

| 工具 | 說明 |
|------|-------------|
| `image_similarity` | **兩張**本機圖片的視覺相似度（Vision feature print L2 距離，閾值已調為 0.1 / 0.4 / 0.8） |
| `detect_optical_flow` | **兩張**連續畫面間的每像素移動向量 |
| `detect_trajectories` | 在本機**影片**中偵測拋物線軌跡 |
| `detect_objects` | 用你**自備的 Core ML 模型**（`.mlmodel` / `.mlmodelc`）做物件偵測 |

### Natural Language

| 工具 | 說明 |
|------|-------------|
| `analyze_text` | 情感 + 語言偵測 + 命名實體 + 關鍵字 |
| `tokenize_text` | 把文字切成詞 / 句 / 段（多語；中文斷詞正常） |
| `tag_parts_of_speech` | 詞性標記 |
| `lemmatize_text` | 詞形還原（running → run） |
| `word_similarity` | 兩個詞的語意相似度（0–1） |
| `sentence_similarity` | 兩個句子的語意相似度（0–1） |

### Speech & Sound

| 工具 | 說明 |
|------|-------------|
| `transcribe_audio` | 離線語音辨識（zh-TW / zh-CN / en-US / ja-JP / …），已開啟標點與口述模式 |
| `synthesize_speech` | 用 AVSpeechSynthesizer 離線文字轉語音 → 輸出 `.wav`（預設 zh-TW Meijia） |
| `list_voices` | 列出所有可用的聲音 identifier，可用 BCP-47 前綴過濾 |
| `classify_sound` | 環境音分類（音樂、笑聲、犬吠…）；輸入至少 3 秒 |

---

## 工具行為與限制

### 中文支援狀況

Apple 各 framework 對語言的支援度差很多。Vision、Speech、Foundation Models
對中文不錯；比較舊的 NaturalLanguage 跟 NLEmbedding 在這套 stack 上實際幾乎
只能處理英文。

| 工具 | 中文（zh-Hant / zh-Hans） |
|---|---|
| `vision_analyze`（所有 mode） | ✓ 支援良好 |
| `transcribe_audio` | ✓ 準確（Apple 模型只加逗號、不加句號） |
| `synthesize_speech` | ✓ 有 Meijia、Eloquence 等中文聲音可選 |
| `tokenize_text` | ✓ 中文斷詞正常（「牛肉麵」會留成一個 token） |
| `lemmatize_text` | ✓ 中文不會被亂改（中文沒有詞形變化） |
| `generate_text_structured`（`classify`） | ✓ 可以拿來做中文情感分類 |
| `translate_text` | ✓ zh→en / zh→ja 穩定；en→zh 會用台灣 / 中國常見譯名（蘋果商店、特斯拉）；成語會直譯 |
| `proofread_text` | ⚠ 語言保留正確；FM 對中文文法錯（一各 / 再 / 的-vs-得）抓得弱，英文偶爾漏抓主動詞一致性 |
| `rewrite_text` | ✓ 語言保留正確；`professional` / `concise` / `formal` 穩；`casual` / `friendly` 偶爾改寫過頭 |
| `summarize_text` | ✓ 語言保留正確（中→中、英→英）；`short` 偶爾不夠短 |
| `generate_text` | ⚠ 短 prompt OK；知識截止約 2023 |
| `classify_sound` | ⚠ 與語言無關，但排序偶爾不準 |
| `analyze_text` | ✗ 中文情感永遠是 0 / 中性，命名實體幾乎抓不到 |
| `tag_parts_of_speech` | ✗ 中文每個詞都會被標成 `other` |
| `word_similarity` / `sentence_similarity` | ✗ 沒有載入中文 embedding 模型 |

主要做中文場景時，建議在 host 的 MCP 設定層直接把 ✗ 那四支排除掉（例如
hermes 的 `mcp_servers.<name>.tools.exclude`），這樣 host LLM 就不會把中文
需求送過去。

### 已知限制

**Foundation Models 內建的 safety filter** — `generate_text` 跟相關工具有時
會對特定內容直接回錯。這個 filter 是 Apple 模型內建的，不是這個 server 加的。
連看起來無害的字（例如品牌名裡的「胖」）都可能被擋——容易踩到的內容建議改走
`generate_text_structured`。

**`detect_objects`** 需要你自備 Core ML 模型（`.mlmodel` 或 `.mlmodelc`）。
其他工具都開箱即用。

**`detect_trajectories`** 需要 mp4 / mov 影片，對拋物線運動（球類運動）效果最好。

**`body_pose_3d` 已經從公開 mode 列表移掉。**
`VNDetectHumanBodyPose3DRequest` 在跑 `perform` 時會丟出 Swift 接不到的
Objective-C exception，整個 Swift Core process 會被它幹掉。Swift case 仍保留
作為防呆網（舊 client 還傳這個 mode 的話會收到 `unavailable`），但不再對外
公告。要用姿態請改 `mode="body_pose"`（2D pose）。

**Apple Intelligence 天花板** — 下面這幾個 macOS 26 API 在 SDK 上*看起來*能用，
實際上從 daemon 是叫不動的：

| API | 為什麼擋住 |
|---|---|
| Writing Tools（`NSWritingToolsCoordinator`） | 綁 UI（需要 `NSView`）。我們改用 Foundation Models prompt 出 `proofread_text` / `rewrite_text` / `summarize_text` 取代 |
| Image Playground（`ImageCreator`） | 連在 Terminal 跑都會回 `backgroundCreationForbidden`——Apple 限定 entitlement |
| Genmoji | 走 `ImageCreator(style="emoji")`，同一個 entitlement 擋 |
| Visual Intelligence | 只有 `AppIntents.AssistantSchemas.VisualIntelligenceIntent`，是 schema only，不是真的可以呼叫的 API |
| Smart Reply | `CSSmartReply` 是 internal symbol（只在 `.tbd`，沒對外的 header） |

**Vision runtime 測試** 請在 Xcode build 出來的 binary、Terminal 或其他非
sandbox 環境跑。Sandbox runner 會誤報 `CVPixelBuffer`、`ANECF`、
`request cancelled` 之類錯誤。

---

## 維運

### 管理服務（HTTP 模式）

`install.sh` 註冊的 launchd agent 會在登入時自動起來、crash 也會自動重啟。
要手動操作：

```bash
bash start.sh                                           # bootstrap launchd agent
bash stop.sh                                            # bootout launchd agent
tail -f /tmp/apple-intel-mcp.log                        # 看 log
launchctl kickstart -k gui/$UID/com.apple-intel-mcp.server   # 強制重啟
```

環境變數（寫在 launchd plist，或直接跑 `server.py` 時指定）：

| 變數 | 預設 | 意義 |
|---|---|---|
| `APPLE_INTEL_PORT` | `11435` | HTTP 埠 |
| `APPLE_INTEL_CALL_TIMEOUT` | `300` | 單次 Swift Core 呼叫的秒數上限，超過就殺掉並重啟它 |

`APPLE_INTEL_CALL_TIMEOUT` 是防當機用的上界，不是速度限制——只有在 Swift Core
完全不回應時才會觸發。hermes 自己的工具呼叫預設也是 300 秒，兩邊本來就一致；
OpenClaw 預設 60 秒，該調的是它的 `requestTimeoutMs`，不是把這個值降下來。

### Agent 生命週期整合（選用）

如果你在跑 agent gateway——[hermes](https://github.com/NousResearch/hermes-agent)（`ai.hermes.gateway`）
或 [OpenClaw](https://openclaw.ai)（`ai.openclaw.gateway`）——並希望它的
start/stop 連動 MCP server：

```bash
bash install-integration.sh    # 裝 watchdog
bash uninstall-integration.sh  # 移除 watchdog（不影響 mcp 本體）
```

這會裝一個 launchd agent（`com.apple-intel-mcp.watchdog`），定期輪詢這些
gateway，只要有 gateway 在就讓 MCP 維持運行。它是 **consumer-aware**：只要**任一** gateway 還在，
MCP 就維持；**全部**都停了才停 MCP。

| Gateway 動作 | MCP 反應（延遲一個輪詢週期） |
|---|---|
| 任一 gateway 啟動 | `bootstrap` MCP |
| 全部 gateway 停止 | `bootout` MCP |
| 某個 gateway 重啟 | 不動作——MCP 維持，由該 gateway 自行重連 |

watchdog 是 **keep-alive only**：gateway 重啟時它**不會**重啟 MCP。MCP 是穩定的
HTTP endpoint，各 gateway 會自己重連；硬重啟它只會無謂打斷其他已連線的 agent。
MCP 真的 crash 時，它的 launchd plist（`KeepAlive=true`）會自動拉起。

驗證整合狀態：

```bash
launchctl print gui/$UID/com.apple-intel-mcp.watchdog
launchctl print gui/$UID/com.apple-intel-mcp.server
```

watchdog 是 interval job，所以兩次輪詢之間常會顯示 `spawn scheduled` 或
`not running`。看 `runs` 和 `last exit code = 0` 就能確認它是否健康。

整合是純加值的，不裝也照樣跑。要支援其他 agent，把它的 launchd label 加進
`bin/mcp-watchdog.sh` 的 `CONSUMER_LABELS`，然後重跑
`bash install-integration.sh`，讓 `~/Library/Application Support/apple-intel-mcp/`
底下的複本刷新。`install.sh` 偵測到 gateway 已安裝時會主動提示。

手動生命週期腳本仍可使用：

```bash
bash stop.sh   # 先停 watchdog，再停 MCP
bash start.sh  # 先啟動 MCP；若已安裝整合，也會啟動 watchdog
```

`start.sh` 會在 `/tmp/apple-intel-mcp.manual-start` 放一個標記，這樣即使當下沒有
任何 gateway 在跑，watchdog 也不會把你剛叫起來的 server 收掉。之後第一次輪詢
看到 gateway 就會清掉標記，把 MCP 交還給 gateway 驅動的生命週期；`stop.sh` 和
重開機也會清掉它。

> plist 裡寫的是 `StartInterval` 3，但 launchd 對重複性工作有十秒下限，實際上
> 大約每 10 秒才輪詢一次。不要照 3 秒去估算反應時間。

> 實作小備註：watchdog 腳本在 install 時會複製一份到
> `~/Library/Application Support/apple-intel-mcp/`，因為 macOS 26 launchd 拒絕
> 直接從 `/Volumes/` 執行 shell script（會被 TCC 擋成「Operation not permitted」）。
> Python venv binary 沒有踩到這條。

### 升級

```bash
bash upgrade.sh          # 最新 GitHub Release
bash upgrade.sh v1.2.3   # 指定 GitHub Release tag
```

這會解析 GitHub Release tag、fetch tags、以 detached HEAD 切到該 release、
重建 Swift core、更新 Python venv 依賴、重啟或啟動已安裝的 launchd 服務，
並在 watchdog 已安裝時刷新它（順便把舊的 per-agent watchdog migrate 成統一版）。
如果已追蹤檔案有本機變更，腳本會在 checkout 前停止，避免覆蓋你的修改。
若 remote 不是標準 GitHub URL，可設定 `APPLE_INTEL_RELEASE_REPO=owner/repo`。

### 解除安裝

```bash
bash uninstall.sh   # 移除 mcp + watchdog（如果裝過）
```

---

## 開發

### 架構

```mermaid
flowchart TD
    Client["<b>AI 客戶端</b><br/>Claude / GPT / Gemini / 等"]
    MCP["<b>Python MCP server（mcp SDK 2.x）</b><br/><code>mcp-server/server.py</code><br/>• 定義 21 個 <code>@mcp.tool</code><br/>• SwiftBridge：常駐 subprocess<br/>+ async lock + JSON line protocol"]
    Swift["<b>Swift Core Service</b>（常駐 process）<br/><code>swift-core/AppleIntelCore</code><br/>• <code>CoreService.swift</code>：請求路由<br/>• 各 framework 對應一支 handler<br/>• 啟動時把 Apple frameworks 載入一次"]

    FM["<b>FoundationModels</b><br/>本機 LLM（約 3B）"]
    Vis["<b>Vision</b><br/>18 種圖像 / 姿態任務"]
    NL["<b>NaturalLanguage</b><br/>斷詞 / NER / POS …"]
    Sp["<b>Speech</b><br/>離線語音辨識"]
    AV["<b>AVFoundation</b><br/>離線文字轉語音"]
    SA["<b>SoundAnalysis</b><br/>環境音分類"]

    Client -- "MCP 協議<br/>（stdio 或 streamable-http :11435）" --> MCP
    MCP -- "stdin/stdout JSON lines<br/>（IPCRequest / IPCResponse）" --> Swift
    Swift --> FM
    Swift --> Vis
    Swift --> NL
    Swift --> Sp
    Swift --> AV
    Swift --> SA
```

**為什麼要分兩個 process？**
MCP Python SDK 是 Python 原生套件；Apple AI 框架只有 Swift 能直接呼叫。Swift binary
做成常駐是因為這些框架光初始化就要好幾秒，每次重啟太慢。Python 那層很薄，
只處理 MCP 協議、工具描述跟序列化。每次 `bridge.call(...)` 就是往 Swift stdin
寫一行 JSON、從 stdout 讀回一行 JSON，外面包一層 `asyncio.Lock` 確保請求／
回應不會交錯。

### 模組結構

Swift 端 `swift-core/Sources/AppleIntelCore/` 採「一個 framework 配一支
handler」的切法。要加新工具有固定流程：

```
main.swift                 ← 進入點（await CoreService.run()）
Models.swift               ← IPC 型別（IPCRequest / IPCResponse / JSONValue）
HandlerError.swift         ← 自訂錯誤（invalidInput / unavailable / …）
CoreService.swift          ← 請求路由——每個工具加一個 `case "<tool>":`
                             轉給對應 handler
GenerateHandler.swift      ← Foundation Models：
                             - generate_text（自由生成）
                             - generate_text_structured（@Generable 結構化）
TranslateHandler.swift     ← 用 FM prompt 做翻譯，每個目標語言寫一套
                             instructions（避開 zh→en 時模型誤判輸入已是英文的坑）
WritingToolsHandler.swift  ← 校對 / 改寫 / 摘要：
                             - NLLanguageRecognizer + CJK 比例判斷輸入語言
                             - 每個語言寫一套 instructions（zh-Hant / zh-Hans / en / ja）
                             - Discord-aware：保留 @ / :emoji: / ```code fence```
OCRHandler.swift           ← Vision 文字辨識（zh / en / ja / ko）
VisionExtHandler.swift     ← Vision：人臉、條碼、輪廓、文字區域、臉部特徵點、
                             人體偵測、地平線、前景分割、美學評分、光流、
                             自訂 Core ML 物件偵測、圖像相似度
VisionPoseHandler.swift    ← Vision：2D 姿態、手部姿態、動物、矩形、
                             saliency、文件、人像分割（3D 姿態已封死，見已知限制）
AnalyzeHandler.swift       ← NaturalLanguage：情感、語言偵測、命名實體、關鍵字
NLAdvancedHandler.swift    ← NaturalLanguage：斷詞、詞形還原、詞性標記
NLEmbeddingHandler.swift   ← NaturalLanguage：詞 / 句語意相似度
TranscribeHandler.swift    ← Speech 離線辨識（SFSpeechRecognizer）
SpeechSynthHandler.swift   ← AVFoundation 文字轉語音 → 輸出 .wav、列出可用聲音
SoundHandler.swift         ← SoundAnalysis：環境音分類
```

**新增工具的 checklist：**

1. 挑對應的 handler；如果是全新的 Apple framework 就新開一支檔案。
2. 寫好 Swift function，遇到壞輸入用 `HandlerError` throw 出去。
3. 到 `CoreService.swift` 加 `case "<tool_name>":`，解析 params 後叫 handler。
4. 到 `mcp-server/server.py` 加一個 `@mcp.tool()` function，docstring 用
   WHEN / NOT-FOR 格式寫清楚，內部呼叫 `await bridge.call("<tool_name>", {...})`。
5. 重新 build Swift（`swift build -c release`），重啟 MCP
   （`launchctl kickstart -k gui/$UID/com.apple-intel-mcp.server`）。
6. 兩份 README（這份跟 [README.md](README.md)）都記得更新。

---

### 專案結構

```
apple-intelligence-mcp/
├── install.sh / upgrade.sh / uninstall.sh
├── install-integration.sh / uninstall-integration.sh
├── start.sh / stop.sh
├── bin/
│   └── mcp-watchdog.sh            # 輪詢 hermes/openclaw gateway，連動 mcp 狀態
├── mcp-server/
│   ├── server.py                  # MCPServer + SwiftBridge（約 720 行）
│   └── requirements.txt           # mcp>=2,<3
├── swift-core/
│   ├── Package.swift              # macOS 26、Swift 6
│   └── Sources/AppleIntelCore/    # 約 2,500 行，一個 framework 一支 handler
│       ├── main.swift             # 進入點
│       ├── CoreService.swift      # 請求路由
│       ├── Models.swift           # IPC 型別
│       ├── HandlerError.swift     # 自訂錯誤
│       ├── GenerateHandler.swift          # Foundation Models
│       ├── TranslateHandler.swift         # FM 翻譯
│       ├── WritingToolsHandler.swift      # 校對 / 改寫 / 摘要
│       ├── OCRHandler.swift               # Vision 文字辨識
│       ├── VisionExtHandler.swift         # Vision 偵測類工具
│       ├── VisionPoseHandler.swift        # Vision 姿態 / 動態類工具
│       ├── AnalyzeHandler.swift           # NL 情感 / NER / 關鍵字
│       ├── NLAdvancedHandler.swift        # NL 斷詞 / POS / 詞形還原
│       ├── NLEmbeddingHandler.swift       # NL 語意相似度
│       ├── TranscribeHandler.swift        # Speech 語音辨識
│       ├── SpeechSynthHandler.swift       # AVFoundation 文字轉語音
│       └── SoundHandler.swift             # SoundAnalysis 環境音分類
└── test-assets/                   # 測試用範例圖
```

---

## 免責聲明

本專案僅供學習與個人生產力用途，依「現狀」提供，不附帶任何形式的擔保。你需自行
為所處理的內容負責，並遵守相關法律以及你所接觸之任何第三方網站或服務的服務條款。
作者對任何濫用行為不負任何責任。

---

## 授權

MIT
