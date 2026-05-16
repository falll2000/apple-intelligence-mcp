# Apple Intelligence MCP Server

**English** | [繁體中文](README.zh-Hant.md)

Wraps Apple's on-device AI frameworks (Vision, Natural Language, Speech, Sound Analysis, Foundation Models) as [MCP](https://modelcontextprotocol.io) tools — so any AI client that speaks MCP (Claude, OpenAI, Gemini, Codex…) can call them as local tools.

Everything runs **100% on-device**. No cloud API calls, no data leaves your Mac.

---

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 26 (Tahoe) or later
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew + Python 3.10+ (`brew install python3`)

---

## Install

```bash
git clone https://github.com/YOUR_USERNAME/apple-intelligence-mcp.git
cd apple-intelligence-mcp
bash install.sh
```

The script will:
1. Compile the Swift Core Service (release build)
2. Create a Python venv and install dependencies
3. Start an HTTP MCP server on port 11435 via launchd
4. Print the exact config snippet to paste into your AI client

---

## Connect to Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

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

> `install.sh` prints the exact paths for your machine at the end — just copy-paste.

## Connect to other AI clients (OpenAI, Gemini, etc.)

```
http://127.0.0.1:11435/mcp
```

The HTTP server starts automatically at login via launchd.

---

## Architecture

```
AI Client (Claude / OpenAI / etc.)
        │  MCP protocol
        ▼
Python FastMCP server  ←── stdio (Claude Desktop)
mcp-server/server.py   ←── streamable-http :11435 (other clients)
        │  JSON lines over stdin/stdout
        ▼
Swift Core Service
swift-core/AppleIntelCore   ← persistent process, frameworks loaded once
        │
        ├── FoundationModels   (on-device LLM)
        ├── Vision             (image analysis)
        ├── NaturalLanguage    (text analysis)
        ├── Speech             (audio → text)
        └── SoundAnalysis      (audio classification)
```

---

## Tools (21 total)

The 18 single-image Vision capabilities are routed through one tool (`vision_analyze`) with a `mode` parameter, instead of 18 individual tools — this measurably improves host-LLM tool-selection accuracy.

### Foundation Models — on-device LLM

| Tool | Description |
|------|-------------|
| `generate_text` | General text generation / rewriting on the local LLM |
| `generate_text_structured` | Guided generation — guaranteed JSON. Schemas: `list` / `classify` / `summarize` / `extract` / `qa` |
| `translate_text` | Translation between zh-Hant / zh-Hans / en / ja / ko / fr / de / es |
| `proofread_text` | Fix typos / grammar / punctuation in user-supplied text. Preserves tone, language, and Discord syntax (@mentions, :emoji:, code blocks) |
| `rewrite_text` | Rewrite text in a different tone (`formal` / `casual` / `concise` / `friendly` / `professional`) while preserving meaning, language, and Discord syntax |
| `summarize_text` | Condense text to short / medium / long prose. Same-language in/out (zh→zh, en→en) |

### Vision — image / pose

| Tool | Description |
|------|-------------|
| `vision_analyze` | One router for 18 single-image tasks. `mode` ∈ {`ocr`, `classify`, `faces`, `face_landmarks`, `barcodes`, `text_regions`, `contours`, `human_bodies`, `rectangles`, `horizon`, `saliency`, `document`, `segment_person`, `segment_foreground`, `aesthetics`, `body_pose`, `hand_pose`, `animals`} |
| `image_similarity` | Visual similarity score between two image files |
| `detect_optical_flow` | Per-pixel motion vectors between two frames |
| `detect_trajectories` | Parabolic trajectory detection from a video file |
| `detect_objects` | Object detection with a user-supplied Core ML model |

### Natural Language

| Tool | Description |
|------|-------------|
| `analyze_text` | Sentiment + language detection + NER + keywords |
| `tokenize_text` | Split into words / sentences / paragraphs |
| `tag_parts_of_speech` | POS tagging |
| `lemmatize_text` | Reduce words to base form |
| `word_similarity` | Semantic similarity between two words (0–1) |
| `sentence_similarity` | Semantic similarity between two sentences (0–1) |

### Speech & Sound

| Tool | Description |
|------|-------------|
| `transcribe_audio` | Offline speech-to-text (zh-TW / zh-CN / en-US / ja-JP / ...) |
| `synthesize_speech` | Offline text-to-speech via AVSpeechSynthesizer → `.wav` (zh-TW Meijia by default) |
| `list_voices` | Discover available TTS voice identifiers, filterable by BCP-47 prefix |
| `classify_sound` | Classify ambient sound (music, laughter, dog bark, ...) |

---

## Recommended host system prompt

The host model decides whether to call these tools based on its system prompt and the tool descriptions. Tool descriptions in this server are written in `WHEN: / NOT FOR:` format to help, but the host needs a clear policy too. Paste this into your client's system prompt to make routing reliable:

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

## Usage notes

**Language coverage is uneven across Apple frameworks.** Vision, Speech, and
FoundationModels handle Chinese well; the older NaturalLanguage and
NLEmbedding frameworks are essentially English-only on this stack.

| Tool | zh-Hant / zh-Hans |
|---|---|
| `vision_analyze` (all modes) | ✓ strong |
| `transcribe_audio` | ✓ accurate (Apple model adds commas only, no periods) |
| `synthesize_speech` | ✓ Meijia / Eloquence voices |
| `tokenize_text` | ✓ proper word segmentation (牛肉麵 stays as one token) |
| `lemmatize_text` | ✓ correctly a no-op (Chinese has no inflection) |
| `generate_text_structured` (`classify`) | ✓ usable for sentiment |
| `translate_text` | ✓ zh→en/zh→ja reliable, en→zh uses standard localized brand forms (蘋果商店, 特斯拉); idioms translate literally |
| `proofread_text` | ⚠ language preserved correctly; FM misses some zh grammar errors (一各/再/的-vs-得) and some en subject-verb agreement |
| `rewrite_text` | ✓ language preserved; `professional` / `concise` / `formal` stable; `casual` / `friendly` occasionally paraphrases beyond original meaning |
| `summarize_text` | ✓ language preserved (zh→zh, en→en); `short` length sometimes loose |
| `generate_text` | ⚠ short prompts OK, knowledge cutoff is ~2023 |
| `classify_sound` | ⚠ language-agnostic but ranking can be off |
| `analyze_text` | ✗ sentiment always 0/中性, NER misses Chinese entities |
| `tag_parts_of_speech` | ✗ all tags return as 「其他」 |
| `word_similarity` / `sentence_similarity` | ✗ no embedding model loaded |

For Chinese-heavy deployments, exclude the four ✗ tools at the host's MCP
config layer (e.g. hermes' `mcp_servers.<name>.tools.exclude`) so the host
LLM never tries to route Chinese requests to them.

**Apple Foundation Models safety filter** — `generate_text` and related tools may return an error for certain content. This is enforced by the on-device model, not by this server. Includes seemingly innocuous body-related characters (e.g. 「胖」 in a brand name) — prefer `generate_text_structured` for content that risks tripping the filter.

**`detect_objects`** requires a user-supplied Core ML model (`.mlmodel` or `.mlmodelc`). All other tools work out of the box.

**`detect_trajectories`** requires a video file (mp4/mov) and works best with footage of objects following a parabolic path (sports, balls, etc.).

**`body_pose_3d` is removed from the public mode list.** `VNDetectHumanBodyPose3DRequest` terminates the Swift Core process with an uncaught Objective-C exception during `perform`, before Swift can handle the error. The Swift case still exists as a safety net (returns `unavailable` if a stale client tries the mode) but it's no longer advertised. Use `mode="body_pose"` for stable 2D pose detection.

**Vision runtime tests** should be run from an Xcode-built binary, Terminal, or another unsandboxed local process. Sandboxed runners may produce false `CVPixelBuffer`, `ANECF`, or `request cancelled` errors.

---

## Start / stop (HTTP mode)

`install.sh` registers the server as a launchd agent (`com.apple-intel-mcp.server`) that starts at login and auto-restarts on crash. You normally don't need to touch it. To control it manually:

```bash
bash start.sh    # bootstrap the launchd agent
bash stop.sh     # bootout the launchd agent
tail -f /tmp/apple-intel-mcp.log   # view logs
```

---

## Hermes integration (optional)

If you use hermes and want `hermes gateway start/stop/restart` to automatically control the MCP server too:

```bash
bash install-hermes-integration.sh    # add watchdog
bash uninstall-hermes-integration.sh  # remove watchdog (keeps mcp running)
```

This installs a second launchd agent (`com.apple-intel-mcp.hermes-watchdog`) that polls every 3 seconds and mirrors the state of `ai.hermes.gateway` onto the MCP server:

| Hermes action | MCP reaction (≤ 3 s lag) |
|---|---|
| `hermes gateway stop` | `bootout` MCP |
| `hermes gateway start` | `bootstrap` MCP |
| `hermes gateway restart` | `kickstart -k` MCP (PID-change detection) |

The integration is purely additive — MCP runs fine on its own without it. `install.sh` will print a hint if it detects hermes installed.

---

## Uninstall

```bash
bash uninstall.sh   # removes mcp + watchdog (if installed)
```

---

## Project structure

```
apple-intelligence-mcp/
├── install.sh / uninstall.sh
├── install-hermes-integration.sh / uninstall-hermes-integration.sh
├── start.sh / stop.sh
├── bin/
│   └── hermes-watchdog.sh    # polls ai.hermes.gateway, syncs mcp state
├── mcp-server/
│   ├── server.py          # Python FastMCP server
│   └── requirements.txt
├── swift-core/
│   ├── Package.swift
│   └── Sources/AppleIntelCore/
│       ├── main.swift
│       ├── CoreService.swift      # request router
│       ├── GenerateHandler.swift  # Foundation Models
│       ├── OCRHandler.swift
│       ├── AnalyzeHandler.swift   # NL sentiment/NER/keywords
│       ├── NLAdvancedHandler.swift # tokenize/POS/lemma
│       ├── NLEmbeddingHandler.swift # word/sentence similarity
│       ├── TranslateHandler.swift
│       ├── WritingToolsHandler.swift # proofread/rewrite/summarize
│       ├── TranscribeHandler.swift
│       ├── SoundHandler.swift
│       ├── VisionExtHandler.swift  # Vision image tools
│       ├── VisionPoseHandler.swift # Vision pose/motion tools
│       ├── Models.swift           # IPC types
│       └── HandlerError.swift
└── test-assets/           # sample images for testing
```

---

## License

MIT
