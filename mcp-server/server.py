#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Run with the project venv:
#   source mcp-server/venv/bin/activate && python3 mcp-server/server.py
"""
Apple Intelligence MCP Server
Wraps Apple's local AI capabilities as MCP tools.
Tool descriptions use WHEN: / NOT FOR: to improve host LLM routing.

Transport: Streamable HTTP (port 11435) or stdio (--stdio)
Swift Core: stdin/stdout JSON IPC (long-running subprocess)
"""

import asyncio
import json
import os
import subprocess
import sys
import uuid
import logging
from pathlib import Path

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from mcp.types import ToolAnnotations

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stderr
)
log = logging.getLogger("apple-intel-mcp")

SCRIPT_DIR = Path(__file__).parent.parent
SWIFT_BIN = SCRIPT_DIR / "swift-core" / ".build" / "release" / "AppleIntelCore"

# Upper bound for one Swift Core round-trip. Without it, a handler whose framework
# callback never fires would hold the bridge lock forever and wedge every later call.
CALL_TIMEOUT_SECONDS = float(os.environ.get("APPLE_INTEL_CALL_TIMEOUT", "300"))


class SwiftBridge:
    """Manage the Swift Core Service lifecycle and IPC."""

    def __init__(self):
        self._proc: subprocess.Popen | None = None
        self._lock = asyncio.Lock()

    def _ensure_started(self):
        if self._proc is None or self._proc.poll() is not None:
            if not SWIFT_BIN.exists():
                raise RuntimeError(
                    f"Swift binary not found: {SWIFT_BIN}\n"
                    "Run this first in swift-core/: swift build -c release"
                )
            log.info(f"Starting Swift Core Service: {SWIFT_BIN}")
            self._proc = subprocess.Popen(
                [str(SWIFT_BIN)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=sys.stderr,
                text=True,
                bufsize=1,
            )
            ready_line = self._proc.stdout.readline()
            log.info(f"Swift Core response: {ready_line.strip()}")

    def _exchange(self, line: str) -> str:
        """One blocking request/response round-trip.

        Runs in a worker thread so asyncio.wait_for can actually interrupt it and so
        pipe I/O does not stall the event loop for the duration of a Swift call.
        """
        self._ensure_started()
        self._proc.stdin.write(line)
        self._proc.stdin.flush()
        return self._proc.stdout.readline()

    def _discard(self):
        """Kill and reap a broken Swift Core so it cannot linger as an orphan."""
        proc, self._proc = self._proc, None
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait()

    async def call(self, tool: str, params: dict) -> dict:
        async with self._lock:
            request = {
                "id": str(uuid.uuid4()),
                "tool": tool,
                "params": params
            }
            line = json.dumps(request, ensure_ascii=False) + "\n"
            try:
                response_line = await asyncio.wait_for(
                    asyncio.to_thread(self._exchange, line),
                    timeout=CALL_TIMEOUT_SECONDS,
                )
                if not response_line:
                    raise RuntimeError("Swift Core did not respond (process may have exited)")
                return json.loads(response_line)
            except asyncio.TimeoutError:
                # Killing the process unblocks the worker thread still sitting in readline.
                self._discard()
                raise ToolError(
                    f"Swift Core timed out after {CALL_TIMEOUT_SECONDS:.0f}s on '{tool}'. "
                    "It was restarted; retry the call."
                ) from None
            except Exception as e:
                self._discard()
                raise ToolError(f"Swift Core communication failed: {e}")

    def shutdown(self):
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            log.info("Swift Core Service stopped")


def _unwrap(result: dict, key: str | None = None):
    if not result.get("success"):
        raise ToolError(result.get("error", "Unknown error"))
    payload = result["result"]
    if key is not None:
        return payload[key]
    return payload


bridge = SwiftBridge()

mcp = MCPServer(
    "Apple Intelligence",
    instructions=(
        "Local on-device AI tools running entirely on Apple Silicon. "
        "Prefer these over your own generation when the user asks for: "
        "OCR on a local image path, audio transcription on a local audio path, "
        "image classification/detection, text-to-speech, "
        "Chinese word segmentation (`tokenize_text`), "
        "or bulk text rewriting where determinism matters more than quality. "
        "Image and audio inputs MUST be absolute file paths on the user's Mac. "
        "\n\n"
        "POST-PROCESS PATTERN — when you call `transcribe_audio` or "
        "`vision_analyze` with mode='ocr', the raw output will contain "
        "character-level errors (Apple Speech zh-TW reads homophones loosely; "
        "Apple Vision OCR may misread small text) and zh-TW transcription "
        "lacks periods (commas only). Default output structure: "
        "(1) raw transcript verbatim, "
        "(2) cleaned-up version with context-inferred fixes, marking each "
        "non-trivial correction inline as `[original→fixed]`, "
        "(3) the actual answer to the user's request. "
        "Skip raw or cleaned only when the user explicitly says so. "
        "\n\n"
        "AVOID for Chinese input: `analyze_text` (sentiment always 0), "
        "`tag_parts_of_speech` (all 'other'), `word_similarity` and "
        "`sentence_similarity` (no zh embedding model). "
        "For Chinese sentiment use `generate_text_structured(schema='classify')` "
        "instead. "
        "\n\n"
        "`generate_text` triggers Apple's safety filter on body/weight-related "
        "CJK characters (胖/肥/瘦 etc.) even in benign brand names — prefer "
        "`generate_text_structured` for content that risks tripping the filter. "
        "On-device LLM knowledge cutoff is ~2023; defer post-2023 factual "
        "questions to your own model."
    )
)


# Tool annotations. Every tool here reads local files or runs a local model;
# only synthesize_speech writes to disk. Clients that gate tool calls on
# readOnlyHint treat a missing annotation as write-capable, so declare it.
# destructiveHint is spelled out for the writing tool rather than left unset:
# synthesize_speech removes whatever sits at output_path before writing, and
# hosts that read the full annotation set decide on that flag first.
_READ_ONLY = ToolAnnotations(readOnlyHint=True)
_WRITES_FILE = ToolAnnotations(readOnlyHint=False, destructiveHint=True)


# ─────────────────────────────────────────────────────────────
# Vision — single-image router
# ─────────────────────────────────────────────────────────────

# mode → underlying Swift tool name. Identity mapping for clarity.
_VISION_MODES: dict[str, str] = {
    "ocr": "ocr_image",
    "classify": "classify_image",
    "faces": "detect_faces",
    "face_landmarks": "detect_face_landmarks",
    "barcodes": "detect_barcodes",
    "text_regions": "detect_text_regions",
    "contours": "detect_contours",
    "human_bodies": "detect_human_bodies",
    "rectangles": "detect_rectangles",
    "horizon": "detect_horizon",
    "saliency": "detect_saliency",
    "document": "detect_document",
    "segment_person": "segment_person",
    "segment_foreground": "segment_foreground_instances",
    "aesthetics": "score_image_aesthetics",
    "body_pose": "detect_body_pose",
    # body_pose_3d intentionally hidden from clients — Apple Vision's
    # VNDetectHumanBodyPose3DRequest throws an uncaught Objective-C exception
    # during perform() that Swift do/catch cannot recover from, crashing the
    # Swift Core process. The Swift case still exists as a safety net (returns
    # `unavailable` instead of running the request) but we don't advertise it.
    # Use mode="body_pose" for stable 2D pose detection.
    "hand_pose": "detect_hand_pose",
    "animals": "recognize_animals",
}


@mcp.tool(annotations=_READ_ONLY)
async def vision_analyze(
    image_path: str,
    mode: str,
    upper_body_only: bool = False,
) -> dict:
    """
    Run a single-image Apple Vision task on a local image file.

    WHEN: user provides an absolute path to an image AND wants one of the analyses below.
    NOT FOR: describing what's in an image in natural language (call `classify` mode and
    summarize the labels yourself, or just describe it directly if labels are not needed).
    NOT FOR: comparing two images (use `image_similarity`).
    NOT FOR: video or two-frame analysis (use `detect_optical_flow` / `detect_trajectories`).
    NOT FOR: object detection with custom Core ML models (use `detect_objects`).

    Modes (pick exactly one):
      - "ocr"               — extract text from the image (zh-Hant/zh-Hans/en/ja/ko)
      - "classify"          — scene/object labels with confidence
      - "faces"             — face count + bounding boxes
      - "face_landmarks"    — eyes/nose/mouth/contour points per face
      - "barcodes"          — QR / EAN-13 / Code-128 / PDF417 etc.
      - "text_regions"      — text bounding boxes only (no OCR content)
      - "contours"          — edge / contour detection
      - "human_bodies"      — person bounding boxes (set upper_body_only=True for upper body only)
      - "rectangles"        — rectangular regions (cards, screens, whiteboards)
      - "horizon"           — horizon angle (is the photo tilted?)
      - "saliency"          — visual attention map
      - "document"          — paper/document bounding box
      - "segment_person"    — person presence + mask size
      - "segment_foreground"— per-instance foreground masks
      - "aesthetics"        — aesthetic score 0–1 + utility-image flag
      - "body_pose"         — 2D body joints (15 keypoints)
      - "hand_pose"         — hand joints + left/right
      - "animals"           — cat / dog detection

    Args:
        image_path: absolute path to image (PNG/JPG/HEIC/...).
        mode: one of the keys above.
        upper_body_only: only used when mode="human_bodies".
    """
    swift_tool = _VISION_MODES.get(mode)
    if swift_tool is None:
        raise ToolError(
            f"Unknown mode: {mode!r}. Available modes: {', '.join(sorted(_VISION_MODES))}"
        )
    params: dict = {"image_path": image_path}
    if mode == "human_bodies":
        params["upper_body_only"] = upper_body_only
    return _unwrap(await bridge.call(swift_tool, params))


# ─────────────────────────────────────────────────────────────
# Vision — multi-input / specialized (kept separate, different signatures)
# ─────────────────────────────────────────────────────────────

@mcp.tool(annotations=_READ_ONLY)
async def image_similarity(
    image_path_1: str,
    image_path_2: str,
) -> dict:
    """
    Compare two local images by visual similarity (Vision feature print distance).

    WHEN: user wants to know how similar two specific image files are.
    NOT FOR: searching one image among many (run pairwise yourself).
    """
    return _unwrap(await bridge.call("image_similarity", {
        "image_path_1": image_path_1,
        "image_path_2": image_path_2,
    }))


@mcp.tool(annotations=_READ_ONLY)
async def detect_optical_flow(
    reference_path: str,
    target_path: str,
) -> dict:
    """
    Compute per-pixel motion vectors between two consecutive frames.

    WHEN: user has two ordered frames and wants motion / dx,dy fields.
    NOT FOR: full-video analysis (extract frames first), or trajectory tracking
    (use `detect_trajectories`).
    """
    return _unwrap(await bridge.call("detect_optical_flow", {
        "reference_path": reference_path,
        "target_path": target_path,
    }))


@mcp.tool(annotations=_READ_ONLY)
async def detect_trajectories(video_path: str) -> dict:
    """
    Detect parabolic trajectories (sports balls, projectiles) in a local video.

    WHEN: user provides an mp4/mov path and asks about ball/projectile paths.
    NOT FOR: general object tracking, optical flow, or non-parabolic motion.
    """
    return _unwrap(await bridge.call("detect_trajectories", {"video_path": video_path}))


@mcp.tool(annotations=_READ_ONLY)
async def detect_objects(
    image_path: str,
    model_path: str,
) -> dict:
    """
    Run a user-supplied Core ML object-detection model on an image.

    WHEN: user explicitly references a `.mlmodel` / `.mlmodelc` file to use.
    NOT FOR: generic object detection — use `vision_analyze(mode="classify")`
    or `vision_analyze(mode="animals")` instead. This tool requires a model file.
    """
    return _unwrap(await bridge.call("detect_objects", {
        "image_path": image_path,
        "model_path": model_path,
    }))


# ─────────────────────────────────────────────────────────────
# Foundation Models — on-device LLM
# ─────────────────────────────────────────────────────────────

@mcp.tool(annotations=_READ_ONLY)
async def generate_text(prompt: str, system_prompt: str = "") -> str:
    """
    Generate / rewrite / summarize text on the local Apple LLM.

    WHEN: caller's policy says to offload bulk LLM work; OR user says
    "use the local model"; OR the task is a deterministic transform on
    >1 paragraph (rewrite, polish, simple summary, format conversion).
    NOT FOR: tasks requiring strong reasoning, code, math, or up-to-date facts —
    the on-device model is small and will likely produce worse output than
    your own generation. Prefer `generate_text_structured` when you need JSON.

    Args:
        prompt: input instruction or text.
        system_prompt: optional persona / instructions.
    """
    params: dict = {"prompt": prompt}
    if system_prompt:
        params["system_prompt"] = system_prompt
    return _unwrap(await bridge.call("generate_text", params), key="text")


@mcp.tool(annotations=_READ_ONLY)
async def generate_text_structured(
    prompt: str,
    schema: str = "summarize",
    system_prompt: str = "",
) -> dict:
    """
    Generate guaranteed-shape JSON via Apple Foundation Models guided generation.

    WHEN: caller needs a deterministic JSON shape (list / classification /
    summary / key-value extraction / QA) AND wants to avoid your own JSON
    drift. Prefer this over `generate_text` whenever a schema fits.
    NOT FOR: free-form prose, code generation, or schemas not in the list below.

    Schemas and prompt requirements:

      - "list"      → {items: string[]}
            Prompt MUST state what to list and (optionally) how many.
            Good: "List 5 common Python built-in data structures"
            Bad : "Python data structures"  (model guesses count/scope)

      - "classify"  → {label, confidence, reasoning}
            Prompt MUST state the classification axis. Without it the
            model picks an axis arbitrarily (e.g. "Product Review"
            instead of sentiment).
            Good: "Classify sentiment (positive/negative/neutral): ..."
            Good: "Classify topic (tech/sports/politics/other): ..."
            Bad : "<just paste the text>"

      - "summarize" → {title, summary, keyPoints[]}
            Prompt is the text to summarize. Keep keyPoints expectations
            in mind — model may invent a 3rd/4th bullet if the source
            only contains 2 facts.

      - "extract"   → {pairs: ["key: value", ...]}
            Prompt MUST list the field names to extract, otherwise the
            model returns the entire source text as one pair.
            Good: "Extract person names, cities, hotels, companies as
                   'type: name'. Source: ..."
            Bad : "<just paste the text>"

      - "qa"        → {answer, evidence}
            Prompt is the question. Specify units / format in the
            question itself (the on-device model has ~2023 knowledge
            and can be off by 1000× on physical constants).
            Good: "Boiling point of water in Celsius at sea level?"

    Args:
        prompt: input instruction or text (see per-schema requirements above).
        schema: one of list/classify/summarize/extract/qa.
        system_prompt: optional persona / instructions.
    """
    params: dict = {"prompt": prompt, "schema": schema}
    if system_prompt:
        params["system_prompt"] = system_prompt
    result = _unwrap(await bridge.call("generate_text_structured", params))
    if "json" in result and isinstance(result["json"], str):
        try:
            result["json"] = json.loads(result["json"])
        except Exception as e:
            log.warning(f"Failed to parse guided generation JSON: {e}")
    return result


@mcp.tool(annotations=_READ_ONLY)
async def translate_text(text: str, to: str = "zh-Hant", from_lang: str = "auto") -> str:
    """
    Translate text using the on-device LLM.

    WHEN: caller's policy says to offload translation; OR user is processing
    bulk text where token cost matters more than nuance.
    NOT FOR: literary / legal / medical translation where quality matters,
    or rare language pairs — the on-device model is limited.

    Args:
        text: source text.
        to: target language code (zh-Hant, zh-Hans, en, ja, ko, fr, de, es).
        from_lang: source code or auto (default).
    """
    return _unwrap(await bridge.call("translate_text", {
        "text": text, "to": to, "from": from_lang,
    }), key="text")


# ─────────────────────────────────────────────────────────────
# Writing Tools — transform user-supplied text (proofread / rewrite / summarize)
# Powered by Foundation Models with pre-tuned system prompts.
# Different from `generate_text`: these take EXISTING text and transform it,
# not generate from scratch. Discord-aware (preserves @mentions, :emoji:, code blocks).
# ─────────────────────────────────────────────────────────────

@mcp.tool(annotations=_READ_ONLY)
async def proofread_text(text: str) -> str:
    """
    Fix typos, grammar, and punctuation in user-supplied text. Preserves tone, style,
    language, and Discord syntax (@mentions, :emoji:, code blocks, markdown).

    WHEN: user has already-written text and asks to "check / proofread / fix
    typos / fix grammar / correct" it — including Discord messages, emails, notes.
    NOT FOR: generating new text from scratch (use `generate_text`), changing
    tone/style (use `rewrite_text`), or shortening (use `summarize_text`).

    Returns ONLY the corrected text, no labels or explanations.

    Args:
        text: the text to proofread. Language auto-detected (zh-Hant / zh-Hans /
            en / mixed). Discord markup preserved verbatim.
    """
    return _unwrap(await bridge.call("proofread_text", {"text": text}), key="text")


@mcp.tool(annotations=_READ_ONLY)
async def rewrite_text(text: str, tone: str = "concise") -> str:
    """
    Rewrite user-supplied text in a different tone while preserving meaning,
    language, and Discord syntax.

    WHEN: user has already-written text and asks to make it
    "formal / casual / shorter / friendlier / more professional" — e.g.
    polishing a Discord reply before sending.
    NOT FOR: fixing typos only (use `proofread_text` — it preserves wording),
    generating new text (use `generate_text`), or summarizing
    long content (use `summarize_text`).

    Returns ONLY the rewritten text, no labels or explanations.

    Args:
        text: the text to rewrite.
        tone: one of "formal" | "casual" | "concise" | "friendly" | "professional".
            Default "concise".
    """
    return _unwrap(await bridge.call("rewrite_text", {
        "text": text, "tone": tone,
    }), key="text")


@mcp.tool(annotations=_READ_ONLY)
async def summarize_text(text: str, length: str = "medium") -> str:
    """
    Condense user-supplied text while preserving key info and language.
    Returns flowing prose (not bullet points — for structured summary use
    `generate_text_structured(schema="summarize")` instead).

    WHEN: user has long text (chat log, article, meeting notes) and asks to
    "summarize / shorten / TL;DR / give me the gist".
    NOT FOR: fixing errors (use `proofread_text`), changing tone (use
    `rewrite_text`), or when caller needs JSON shape with title + keyPoints
    (use `generate_text_structured(schema="summarize")`).

    Returns ONLY the summary, no labels.

    Args:
        text: the text to summarize.
        length: one of "short" (1–2 sentences) | "medium" (3–5 sentences) |
            "long" (6–10 sentences). Default "medium".
    """
    return _unwrap(await bridge.call("summarize_text", {
        "text": text, "length": length,
    }), key="text")


# ─────────────────────────────────────────────────────────────
# Natural Language
# ─────────────────────────────────────────────────────────────

@mcp.tool(annotations=_READ_ONLY)
async def analyze_text(text: str) -> dict:
    """
    Sentiment + language detection + NER (person/place/org) + keywords.

    WHEN: user asks for sentiment analysis, NER, named entities, key phrases,
    or "what language is this".
    NOT FOR: parts-of-speech (use `tag_parts_of_speech`), tokenization
    (use `tokenize_text`), or similarity (use `word_similarity` / `sentence_similarity`).
    """
    return _unwrap(await bridge.call("analyze_text", {"text": text}))


@mcp.tool(annotations=_READ_ONLY)
async def tokenize_text(text: str, unit: str = "word") -> dict:
    """
    Split text into words, sentences, or paragraphs (multilingual).

    WHEN: user asks for tokenization, word/sentence count, or splitting text.
    NOT FOR: lemmatization (use `lemmatize_text`) or POS tagging (use `tag_parts_of_speech`).

    Args:
        text: input text.
        unit: "word" | "sentence" | "paragraph".
    """
    return _unwrap(await bridge.call("tokenize_text", {"text": text, "unit": unit}))


@mcp.tool(annotations=_READ_ONLY)
async def tag_parts_of_speech(text: str) -> dict:
    """
    POS tagging (noun, verb, adjective, ...).

    WHEN: user asks for parts of speech, grammatical analysis, or word categories.
    NOT FOR: tokenization only (use `tokenize_text`) or NER (use `analyze_text`).
    """
    return _unwrap(await bridge.call("tag_parts_of_speech", {"text": text}))


@mcp.tool(annotations=_READ_ONLY)
async def lemmatize_text(text: str) -> dict:
    """
    Lemmatize each word to its base form (running→run, mice→mouse).

    WHEN: user asks for lemmatization, stemming, or "word base forms".
    NOT FOR: just splitting text (use `tokenize_text`).
    """
    return _unwrap(await bridge.call("lemmatize_text", {"text": text}))


@mcp.tool(annotations=_READ_ONLY)
async def word_similarity(
    word1: str,
    word2: str,
    language: str = "en",
) -> dict:
    """
    Semantic similarity between two single words (0.0–1.0).

    WHEN: user asks how related two words are.
    NOT FOR: comparing sentences (use `sentence_similarity`) or images (use `image_similarity`).
    """
    return _unwrap(await bridge.call("word_similarity", {
        "word1": word1, "word2": word2, "language": language,
    }))


@mcp.tool(annotations=_READ_ONLY)
async def sentence_similarity(
    sentence1: str,
    sentence2: str,
    language: str = "en",
) -> dict:
    """
    Semantic similarity between two sentences (0.0–1.0).

    WHEN: user asks if two sentences mean the same thing, dedup detection,
    or semantic search scoring.
    NOT FOR: comparing single words (use `word_similarity`).
    """
    return _unwrap(await bridge.call("sentence_similarity", {
        "sentence1": sentence1, "sentence2": sentence2, "language": language,
    }))


# ─────────────────────────────────────────────────────────────
# Speech & Sound
# ─────────────────────────────────────────────────────────────

@mcp.tool(annotations=_READ_ONLY)
async def transcribe_audio(audio_path: str, language: str = "zh-TW") -> str:
    """
    Offline speech-to-text on a local audio file.

    WHEN: user provides an absolute path to an audio file and wants the words.
    NOT FOR: classifying the *type* of sound (use `classify_sound`),
    or describing audio without transcribing.

    Args:
        audio_path: absolute path (m4a/mp3/wav/...).
        language: BCP-47 code (zh-TW / zh-CN / en-US / ja-JP / ...).
    """
    return _unwrap(await bridge.call("transcribe_audio", {
        "audio_path": audio_path, "language": language,
    }), key="text")


@mcp.tool(annotations=_READ_ONLY)
async def classify_sound(audio_path: str) -> dict:
    """
    Classify what kind of sound is in the audio (music, speech, laughter, dog bark, ...).

    WHEN: user asks "what is this sound" or wants audio scene classification.
    NOT FOR: transcribing speech to text (use `transcribe_audio`).
    """
    return _unwrap(await bridge.call("classify_sound", {"audio_path": audio_path}))


@mcp.tool(annotations=_WRITES_FILE)
async def synthesize_speech(
    text: str,
    voice: str = "",
    rate: float = 0.0,
    output_path: str = "",
) -> dict:
    """
    Offline text-to-speech via macOS AVSpeechSynthesizer. Writes a .wav file.

    WHEN: user asks to read text aloud, generate voice/audio from text, or wants
    a spoken version of a message — and you need a local audio file (e.g. to
    attach to Discord). 100% on-device, no API key required.

    NOT FOR: cloning a specific person's voice, generating singing, or
    high-fidelity production-grade narration — use a cloud TTS for those.

    Args:
        text: text to speak. Multi-language supported.
        voice: optional. Either a voice identifier
            (e.g. "com.apple.voice.compact.zh-TW.Meijia") OR a BCP-47 language
            code (e.g. "zh-TW", "en-US", "ja-JP"). Empty → defaults to zh-TW
            system voice. Use `list_voices` to discover identifiers.
        rate: optional. 0.0–1.0. Empty/0 → system default (~0.5).
        output_path: optional absolute path for the .wav. Empty → temp file,
            actual path returned in the result.

    Returns dict with: output_path, duration_seconds, voice_used.
    """
    params: dict = {"text": text}
    if voice:
        params["voice"] = voice
    if rate and rate > 0:
        params["rate"] = rate
    if output_path:
        params["output_path"] = output_path
    return _unwrap(await bridge.call("synthesize_speech", params))


@mcp.tool(annotations=_READ_ONLY)
async def list_voices(language: str = "") -> dict:
    """
    List available macOS speech synthesis voices (helper for `synthesize_speech`).

    WHEN: caller wants to discover voice identifiers to pass to
    `synthesize_speech` — e.g. find all zh-TW voices, or pick a specific
    English speaker.

    Args:
        language: optional BCP-47 prefix to filter (e.g. "zh", "en-US", "ja").
            Empty → list all installed voices.

    Returns dict with: count, voices (newline-separated
    "identifier | language | name" lines).
    """
    params: dict = {}
    if language:
        params["language"] = language
    return _unwrap(await bridge.call("list_voices", params))


# ─────────────────────────────────────────────────────────────
# Optional local extensions. If a `local_ext` module is present it may
# register additional tools; it is absent in the default distribution.
# ─────────────────────────────────────────────────────────────

try:
    import local_ext
    local_ext.register(mcp, bridge, _unwrap, _VISION_MODES, log)
except ImportError:
    pass


# ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import atexit
    atexit.register(bridge.shutdown)

    if "--stdio" in sys.argv:
        log.info("Apple Intelligence MCP Server starting (stdio mode)...")
        mcp.run(transport="stdio")
    else:
        port = int(os.environ.get("APPLE_INTEL_PORT", "11435"))
        log.info(f"Apple Intelligence MCP Server starting (port {port})...")
        mcp.run(transport="streamable-http", host="127.0.0.1", port=port)
