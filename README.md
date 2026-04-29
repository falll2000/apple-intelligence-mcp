# Apple Intelligence MCP Server

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

## Tools (34 total)

### Foundation Models — on-device LLM

| Tool | Description |
|------|-------------|
| `generate_text` | General text generation, summarisation, rewriting |
| `translate_text` | Translation between languages (offline) |
| `generate_text_structured` | Guided generation — guaranteed JSON output. Schemas: `list` / `classify` / `summarize` / `extract` / `qa` |

### Vision — image analysis

| Tool | Description |
|------|-------------|
| `ocr_image` | Extract text from images (zh-Hant/zh-Hans/en/ja/ko) |
| `classify_image` | Scene/object classification with confidence scores |
| `detect_faces` | Face detection — count + bounding boxes |
| `detect_face_landmarks` | Facial landmark points (eyes, nose, mouth, contour) |
| `detect_face_capture_quality` | *(coming soon)* |
| `detect_barcodes` | QR Code, EAN-13, Code-128, PDF417, and more |
| `detect_objects` | Object detection with a custom Core ML model |
| `detect_text_regions` | Find text regions without OCR (bounding boxes only) |
| `detect_contours` | Edge and contour detection |
| `detect_human_bodies` | Human body bounding boxes (`upper_body_only` option) |
| `detect_rectangles` | Detect rectangular regions (cards, screens, whiteboards) |
| `detect_horizon` | Horizon angle — detect if a photo is tilted |
| `detect_saliency` | Attention-based saliency — what draws the human eye |
| `detect_document` | Document / paper detection and bounding box |
| `detect_optical_flow` | Per-pixel motion vectors between two frames |
| `segment_person` | Person segmentation — detect presence + mask size |
| `segment_foreground_instances` | Per-instance foreground segmentation |
| `image_similarity` | Visual similarity score between two images |
| `score_image_aesthetics` | Aesthetic quality score + utility image detection |

### Vision — pose & motion

| Tool | Description |
|------|-------------|
| `detect_body_pose` | 2D body joint positions (15 keypoints) |
| `detect_hand_pose` | Hand joint positions + left/right classification |
| `detect_body_pose_3d` | 3D body joint world coordinates |
| `detect_trajectories` | Parabolic trajectory detection from video |
| `recognize_animals` | Cat / dog detection with confidence |

### Natural Language

| Tool | Description |
|------|-------------|
| `analyze_text` | Sentiment score, language detection, NER (person/place/org), keywords |
| `tokenize_text` | Tokenise by word / sentence / paragraph |
| `tag_parts_of_speech` | POS tagging (noun, verb, adjective…) |
| `lemmatize_text` | Lemmatisation — reduce words to base form |
| `word_similarity` | Semantic similarity between two words (0–1) |
| `sentence_similarity` | Semantic similarity between two sentences (0–1) |

### Speech

| Tool | Description |
|------|-------------|
| `transcribe_audio` | Offline speech-to-text (zh-TW/zh-CN/en-US/ja-JP…) |

### Sound Analysis

| Tool | Description |
|------|-------------|
| `classify_sound` | Classify audio — music, speech, laughter, dog bark, etc. |

---

## Usage notes

**Apple Foundation Models safety filter** — `generate_text` and related tools may return an error for certain content. This is enforced by the on-device model, not by this server.

**`detect_objects`** requires a user-supplied Core ML model (`.mlmodel` or `.mlmodelc`). All other tools work out of the box.

**`detect_trajectories`** requires a video file (mp4/mov) and works best with footage of objects following a parabolic path (sports, balls, etc.).

**`detect_body_pose_3d`** uses monocular depth estimation — no LiDAR required, but accuracy improves with clear full-body shots.

---

## Start / stop (HTTP mode)

```bash
bash start.sh    # start HTTP server in background
bash stop.sh     # stop it
tail -f /tmp/apple-intel-mcp.log   # view logs
```

---

## Uninstall

```bash
bash uninstall.sh
```

---

## Project structure

```
apple-intelligence-mcp/
├── install.sh
├── uninstall.sh
├── start.sh / stop.sh
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
