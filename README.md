# Apple Intelligence MCP Server

**English** | [繁體中文](README.zh-Hant.md) | [简体中文](README.zh-Hans.md)

[![Python syntax](https://github.com/falll2000/apple-intelligence-mcp/actions/workflows/python.yml/badge.svg)](https://github.com/falll2000/apple-intelligence-mcp/actions/workflows/python.yml)

A [Model Context Protocol](https://modelcontextprotocol.io) server that exposes
Apple's on-device AI stack — **Foundation Models, Vision, Natural Language,
Speech, and Sound Analysis** — as 21 tools any MCP-speaking client can call
(Claude Desktop, OpenAI, Gemini, Codex, Hermes, …).

Everything runs **100% on-device**. No API keys, no cloud round-trips, no data
leaves your Mac.

---

## Why this exists

Cloud LLM tokens are expensive for high-volume deterministic work (translation,
summarization, OCR, transcription). Apple Silicon Macs ship a capable on-device
AI stack — Foundation Models, Vision, Speech — but only if you write Swift.
This server wraps that stack as a single MCP endpoint so any host LLM (Claude,
GPT, Gemini) can offload bulk work to your Mac instead of burning tokens.

Concretely it lets a host model say *"OCR this image"*, *"transcribe this
audio"*, *"polish this Discord reply"*, *"summarize this meeting log"* — and
the work happens locally in milliseconds, free.

## What you can build with it

- **Discord / chat copilot**
  `proofread_text`, `rewrite_text(tone="professional")`, `summarize_text`
  preserve `@mentions`, `:emoji:`, code fences, and the input language.
- **Document workflow**
  `vision_analyze(mode="ocr")` → `generate_text_structured(schema="extract")` →
  `generate_text_structured(schema="summarize")` to turn a scanned PDF or
  photo into structured fields plus a summary.
- **Voice-message pipeline**
  `transcribe_audio` → `summarize_text` → `synthesize_speech` builds a full
  "spoken-in / spoken-out" loop without leaving the device.
- **Image cataloging**
  `vision_analyze(mode="classify"/"aesthetics"/"document")` plus
  `image_similarity` for local-photo organization.
- **Privacy-sensitive transcription / translation**
  Legal, medical, HR contexts where audio or text must not leave the machine.
- **Token-cost optimization for AI clients**
  Push translation / bulk rewrite / sentiment classification to the local model
  via the recommended host system prompt below, reserve cloud tokens for
  reasoning-heavy work.

---

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 26 (Tahoe) or later
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Full Xcode (Command Line Tools alone don't ship the FoundationModels macros)
- Homebrew + Python 3.10+ (`brew install python3`)

## Install

```bash
git clone https://github.com/falll2000/apple-intelligence-mcp.git
cd apple-intelligence-mcp
bash install.sh
```

The script will:
1. Compile the Swift Core Service (release build, `swift build -c release`)
2. Create a Python venv and install `mcp` (FastMCP)
3. Register the server as a launchd agent (`com.apple-intel-mcp.server`) on port 11435
4. Print the exact config snippet for your AI client

## Connect a client

**Claude Desktop (stdio)** — edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

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

`install.sh` prints the absolute paths for your machine. Copy-paste them.

**Other clients (HTTP)** — the HTTP server starts at login via launchd:

```
http://127.0.0.1:11435/mcp
```

---

## Architecture

```
┌────────────────────────────────────────────┐
│        AI Client (Claude / GPT / etc.)     │
└──────────────────┬─────────────────────────┘
                   │  MCP protocol
                   │  (stdio  OR  streamable-http :11435)
                   ▼
┌────────────────────────────────────────────┐
│   Python FastMCP server                    │
│   mcp-server/server.py                     │
│   - 21 @mcp.tool definitions               │
│   - SwiftBridge: persistent subprocess +   │
│     async lock + JSON line protocol        │
└──────────────────┬─────────────────────────┘
                   │  stdin/stdout JSON lines
                   │  (IPCRequest / IPCResponse)
                   ▼
┌────────────────────────────────────────────┐
│   Swift Core Service (long-lived process)  │
│   swift-core/AppleIntelCore                │
│   - CoreService.swift   (request router)   │
│   - per-domain handlers (see modules)      │
│   - Apple frameworks loaded once on launch │
└──────────────────┬─────────────────────────┘
                   │
                   ▼
       FoundationModels  ←─ on-device LLM (~3B)
       Vision            ←─ 18 image / pose tasks
       NaturalLanguage   ←─ tokenize / NER / POS …
       Speech            ←─ offline STT
       AVFoundation      ←─ offline TTS
       SoundAnalysis     ←─ audio classification
```

**Why two processes?** FastMCP is Python-native; Apple AI frameworks are
Swift-only. The Swift binary stays resident so frameworks (which take seconds
to initialize) load once. The Python layer is thin — it handles MCP protocol,
schema/description, and serialization. Each `await bridge.call(...)` writes one
JSON line to stdin, reads one JSON line from stdout, under an `asyncio.Lock`
to keep the request/response stream serialized.

## Module structure

`swift-core/Sources/AppleIntelCore/` is split one handler per Apple-framework
concern. Adding a new tool follows a predictable pattern:

```
main.swift                 ← entry point (await CoreService.run())
Models.swift               ← IPCRequest / IPCResponse / JSONValue
HandlerError.swift         ← typed errors (invalidInput / unavailable / …)
CoreService.swift          ← request router — adds a `case "<tool>":` per tool
                             and forwards to the right handler
GenerateHandler.swift      ← FoundationModels:
                             - generate_text (free-form)
                             - generate_text_structured (@Generable schemas)
TranslateHandler.swift     ← FM-prompt translation w/ per-target-language
                             instructions (avoids the "model thinks input is
                             already English" trap on zh→en)
WritingToolsHandler.swift  ← FM-prompt proofread / rewrite / summarize:
                             - NLLanguageRecognizer + CJK ratio routing
                             - per-language instructions (zh-Hant/zh-Hans/en/ja)
                             - Discord-aware (preserves @/:emoji:/```fences)
OCRHandler.swift           ← Vision text recognition (zh/en/ja/ko)
VisionExtHandler.swift     ← Vision: faces, barcodes, contours, text regions,
                             face landmarks, human bodies, horizon,
                             segment_foreground, aesthetics, optical_flow,
                             custom Core ML object detection, image similarity
VisionPoseHandler.swift    ← Vision: 2D body pose, hand pose, animals,
                             rectangles, saliency, document, person segment,
                             3D body pose (guarded — see Known limits)
AnalyzeHandler.swift       ← NL: sentiment, language detection, NER, keywords
NLAdvancedHandler.swift    ← NL: tokenize, lemmatize, POS tagging
NLEmbeddingHandler.swift   ← NL: word / sentence semantic similarity
TranscribeHandler.swift    ← Speech: offline STT (SFSpeechRecognizer)
SpeechSynthHandler.swift   ← AVFoundation TTS → .wav file + voice list
SoundHandler.swift         ← SoundAnalysis: ambient sound classification
```

**Adding a tool — checklist:**

1. Pick the matching handler (or create a new one if the framework is new).
2. Implement the Swift function — return a value, throw `HandlerError` on bad input.
3. In `CoreService.swift`, add a `case "<tool_name>":` that decodes params and calls the handler.
4. In `mcp-server/server.py`, add an `@mcp.tool()` function with WHEN/NOT-FOR docstring and an `await bridge.call("<tool_name>", {...})`.
5. Rebuild Swift (`swift build -c release`), restart MCP (`launchctl kickstart -k gui/$UID/com.apple-intel-mcp.server`).
6. Document in this README + `README.zh-Hant.md`.

---

## Tools (21 total)

The 18 single-image Vision capabilities are routed through one tool
(`vision_analyze`) with a `mode` parameter, instead of 18 individual tools —
this measurably improves host-LLM tool-selection accuracy.

### Foundation Models — on-device LLM

| Tool | Description |
|------|-------------|
| `generate_text` | General text generation / rewriting |
| `generate_text_structured` | Guided generation — guaranteed JSON. Schemas: `list` / `classify` / `summarize` / `extract` / `qa` (each has its own prompt-quality guidance in the tool description) |
| `translate_text` | Translation between zh-Hant / zh-Hans / en / ja / ko / fr / de / es. Uses per-target-language instructions |
| `proofread_text` | Fix typos / grammar / punctuation in user-supplied text. Preserves tone, language, and Discord syntax (@mentions, :emoji:, code blocks) |
| `rewrite_text` | Rewrite in a different tone (`formal` / `casual` / `concise` / `friendly` / `professional`) while preserving meaning, language, and Discord syntax |
| `summarize_text` | Condense text to `short` / `medium` / `long` prose. Same-language in/out (zh→zh, en→en) |

### Vision — image / pose

**`vision_analyze`** is a single-image router: one MCP tool exposing **18 distinct
Vision capabilities**, selected via the `mode` argument (pick exactly one):

| `mode` | Capability |
|--------|------------|
| `ocr` | Extract text from the image (zh-Hant / zh-Hans / en / ja / ko) |
| `classify` | Scene / object labels with confidence |
| `faces` | Face count + bounding boxes |
| `face_landmarks` | Eyes / nose / mouth / contour points per face |
| `barcodes` | QR / EAN-13 / Code-128 / PDF417 etc. |
| `text_regions` | Text bounding boxes only (no OCR content) |
| `contours` | Edge / contour detection |
| `human_bodies` | Person bounding boxes (`upper_body_only=True` for upper body) |
| `rectangles` | Rectangular regions (cards, screens, whiteboards) |
| `horizon` | Horizon angle — is the photo tilted? |
| `saliency` | Visual attention map |
| `document` | Paper / document bounding box |
| `segment_person` | Person presence + mask size |
| `segment_foreground` | Per-instance foreground masks |
| `aesthetics` | Aesthetic score 0–1 + utility-image flag |
| `body_pose` | 2D body joints (15 keypoints) |
| `hand_pose` | Hand joints + left / right |
| `animals` | Cat / dog detection |

> **Why one router, not 18 tools?** Each of these is a separate Apple Vision
> request under the hood (and a separate `case` in the Swift core), but they all
> share the same input — one local image path. Collapsing them into a single
> `vision_analyze(mode=...)` tool measurably improves host-LLM tool-selection
> accuracy and shrinks the tool-list tokens every request carries, versus
> advertising 18 near-identical tools. A 19th capability, `body_pose_3d`, exists
> in the Swift core but is intentionally **not** exposed as a mode — see
> [Known limits](#known-limits).

The remaining Vision tools stay separate because their inputs differ (video,
two images, or a custom model — not a single image path):

| Tool | Description |
|------|-------------|
| `image_similarity` | Visual similarity score between **two** image files (Vision feature print L2 distance, thresholds tuned 0.1 / 0.4 / 0.8) |
| `detect_optical_flow` | Per-pixel motion vectors between **two** frames |
| `detect_trajectories` | Parabolic trajectory detection on a local **video** file |
| `detect_objects` | Object detection with a **user-supplied Core ML model** (`.mlmodel` / `.mlmodelc`) |

### Natural Language

| Tool | Description |
|------|-------------|
| `analyze_text` | Sentiment + language detection + NER + keywords |
| `tokenize_text` | Split into words / sentences / paragraphs (multilingual; correctly segments Chinese) |
| `tag_parts_of_speech` | POS tagging |
| `lemmatize_text` | Reduce words to base form (running → run) |
| `word_similarity` | Semantic similarity between two words (0–1) |
| `sentence_similarity` | Semantic similarity between two sentences (0–1) |

### Speech & Sound

| Tool | Description |
|------|-------------|
| `transcribe_audio` | Offline STT (zh-TW / zh-CN / en-US / ja-JP / …). Punctuation + dictation hints enabled |
| `synthesize_speech` | Offline TTS via AVSpeechSynthesizer → `.wav` (zh-TW Meijia by default) |
| `list_voices` | Discover voice identifiers, filterable by BCP-47 prefix |
| `classify_sound` | Classify ambient audio (music, laughter, dog bark, …). Needs ≥ 3 s input |

---

## Recommended host system prompt

The host model decides whether to call these tools based on its system prompt
plus the tool descriptions. The server uses `WHEN: / NOT FOR:` descriptions to
help, but the host needs an explicit policy too. Paste the following into your
client's system prompt for reliable routing:

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

## Language coverage

Apple's frameworks are uneven across languages. Vision, Speech, and
FoundationModels handle Chinese well; the older NaturalLanguage and
NLEmbedding frameworks are essentially English-only on this stack.

| Tool | zh-Hant / zh-Hans |
|---|---|
| `vision_analyze` (all modes) | ✓ strong |
| `transcribe_audio` | ✓ accurate (Apple model adds commas only, no periods) |
| `synthesize_speech` | ✓ Meijia / Eloquence voices available |
| `tokenize_text` | ✓ proper word segmentation (牛肉麵 stays as one token) |
| `lemmatize_text` | ✓ correctly a no-op (Chinese has no inflection) |
| `generate_text_structured` (`classify`) | ✓ usable for Chinese sentiment |
| `translate_text` | ✓ zh→en / zh→ja reliable; en→zh uses standard localized brand forms (蘋果商店, 特斯拉); idioms translate literally |
| `proofread_text` | ⚠ language preserved correctly; FM misses some zh grammar errors (一各/再/的-vs-得) and some en subject-verb agreement |
| `rewrite_text` | ✓ language preserved; `professional` / `concise` / `formal` stable; `casual` / `friendly` occasionally paraphrases beyond meaning |
| `summarize_text` | ✓ language preserved (zh→zh, en→en); `short` length sometimes loose |
| `generate_text` | ⚠ short prompts OK; knowledge cutoff ~2023 |
| `classify_sound` | ⚠ language-agnostic but ranking can be off |
| `analyze_text` | ✗ Chinese sentiment always 0/中性, NER misses Chinese entities |
| `tag_parts_of_speech` | ✗ Chinese tags all return as 「其他」 |
| `word_similarity` / `sentence_similarity` | ✗ no Chinese embedding model |

For Chinese-heavy deployments, exclude the four ✗ tools at the host's MCP
config layer (e.g. hermes' `mcp_servers.<name>.tools.exclude`) so the host
LLM never tries to route Chinese requests to them.

## Known limits

**Foundation Models safety filter** — `generate_text` and related tools may
error on certain content. The filter is enforced inside the on-device model,
not by this server. Even innocuous body-related characters (e.g. 「胖」 in a
brand name) can trip it. Use `generate_text_structured` for content that
might trigger it.

**`detect_objects`** requires a user-supplied Core ML model (`.mlmodel` or
`.mlmodelc`). All other tools work out of the box.

**`detect_trajectories`** requires a video file (mp4/mov). Works best with
footage of objects following a parabolic path (sports, balls).

**`body_pose_3d` is removed from the public mode list.**
`VNDetectHumanBodyPose3DRequest` terminates the Swift Core process with an
uncaught Objective-C exception during `perform`, before Swift can catch it.
The Swift case still exists as a safety net (returns `unavailable` if a stale
client tries) but it's no longer advertised. Use `mode="body_pose"` for stable
2D pose detection.

**Apple Intelligence ceilings** — the following macOS 26 APIs *look* callable
in the SDK but are not actually usable from a daemon:

| API | Why blocked |
|---|---|
| Writing Tools (`NSWritingToolsCoordinator`) | UI-bound (requires `NSView`) — we provide `proofread_text` / `rewrite_text` / `summarize_text` via Foundation Models instead |
| Image Playground (`ImageCreator`) | Returns `backgroundCreationForbidden` even from Terminal — Apple-only entitlement |
| Genmoji | Same path as `ImageCreator(style="emoji")`, same entitlement block |
| Visual Intelligence | Only `AppIntents.AssistantSchemas.VisualIntelligenceIntent` — schema-only, no callable API |
| Smart Reply | `CSSmartReply` is an internal symbol (only in `.tbd`, no public header) |

**Vision runtime tests** should run from an Xcode-built binary, Terminal, or
another unsandboxed local process. Sandboxed runners produce false
`CVPixelBuffer`, `ANECF`, or `request cancelled` errors.

---

## Manage the service (HTTP mode)

`install.sh` registers a launchd agent that starts at login and auto-restarts
on crash. Manual control:

```bash
bash start.sh                                           # bootstrap launchd agent
bash stop.sh                                            # bootout launchd agent
tail -f /tmp/apple-intel-mcp.log                        # logs
launchctl kickstart -k gui/$UID/com.apple-intel-mcp.server   # force restart
```

## Upgrade

```bash
bash upgrade.sh          # latest GitHub Release
bash upgrade.sh v1.2.3   # a specific GitHub Release tag
```

This resolves a GitHub Release tag, fetches tags, checks out that release in
detached HEAD mode, rebuilds the Swift core, updates the Python venv
dependencies, and restarts or starts the installed launchd service. If tracked
files have local changes, the script stops before checkout so it does not
overwrite your work. For non-standard GitHub remotes, set
`APPLE_INTEL_RELEASE_REPO=owner/repo`.

## Hermes integration (optional)

If you use [hermes](https://github.com/) and want `hermes gateway
start/stop/restart` to drive the MCP server too:

```bash
bash install-hermes-integration.sh    # install watchdog
bash uninstall-hermes-integration.sh  # remove watchdog (keeps mcp running)
```

This installs a second launchd agent (`com.apple-intel-mcp.hermes-watchdog`)
that polls every 3 s and mirrors `ai.hermes.gateway` onto the MCP server:

| Hermes action | MCP reaction (≤ 3 s lag) |
|---|---|
| `hermes gateway stop` | `bootout` MCP |
| `hermes gateway start` | `bootstrap` MCP |
| `hermes gateway restart` | `kickstart -k` MCP (PID change detection) |

The integration is purely additive — MCP runs fine on its own. `install.sh`
prints a hint if it detects hermes installed.

> Implementation note: the watchdog script is copied into
> `~/Library/Application Support/apple-intel-mcp/` at install time, because
> launchd refuses to execute shell scripts directly from `/Volumes/` on
> macOS 26 (TCC blocks it as "Operation not permitted"). The Python venv
> binary doesn't hit this restriction.

## Uninstall

```bash
bash uninstall.sh   # removes mcp + watchdog (if installed)
```

---

## Project structure

```
apple-intelligence-mcp/
├── install.sh / upgrade.sh / uninstall.sh
├── install-hermes-integration.sh / uninstall-hermes-integration.sh
├── start.sh / stop.sh
├── bin/
│   └── hermes-watchdog.sh         # polls ai.hermes.gateway, syncs mcp state
├── mcp-server/
│   ├── server.py                  # FastMCP server + SwiftBridge (~650 LOC)
│   └── requirements.txt           # mcp>=1.0.0
├── swift-core/
│   ├── Package.swift              # macOS 26, Swift 6
│   └── Sources/AppleIntelCore/    # ~2,500 LOC, one handler per framework
│       ├── main.swift             # entry point
│       ├── CoreService.swift      # request router
│       ├── Models.swift           # IPC types
│       ├── HandlerError.swift     # typed errors
│       ├── GenerateHandler.swift          # Foundation Models
│       ├── TranslateHandler.swift         # FM translation
│       ├── WritingToolsHandler.swift      # proofread/rewrite/summarize
│       ├── OCRHandler.swift               # Vision OCR
│       ├── VisionExtHandler.swift         # Vision detect tools
│       ├── VisionPoseHandler.swift        # Vision pose / motion
│       ├── AnalyzeHandler.swift           # NL sentiment/NER/keywords
│       ├── NLAdvancedHandler.swift        # NL tokenize/POS/lemma
│       ├── NLEmbeddingHandler.swift       # NL similarity
│       ├── TranscribeHandler.swift        # Speech STT
│       ├── SpeechSynthHandler.swift       # AVFoundation TTS
│       └── SoundHandler.swift             # SoundAnalysis
└── test-assets/                   # sample images for testing
```

## Disclaimer

This project is provided for educational and personal-productivity purposes
only, on an "as is" basis without warranty of any kind. You are solely
responsible for the content you process with it and for complying with all
applicable laws and the terms of service of any third-party website or service
you interact with. The authors accept no liability for any misuse.

## License

MIT
