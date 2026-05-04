#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 注意：需用 venv 內的 Python 執行：
#   source mcp-server/venv/bin/activate && python3 mcp-server/server.py
"""
Apple Intelligence MCP Server
把 Apple 本地 AI 能力包裝成 MCP 工具。
工具描述採 WHEN: / NOT FOR: 格式以提升 host LLM 的路由準確度。

Transport: Streamable HTTP（port 11435）或 stdio（--stdio）
Swift Core: stdin/stdout JSON IPC（subprocess 常駐）
"""

import asyncio
import json
import os
import subprocess
import sys
import uuid
import logging
from pathlib import Path

from mcp.server.fastmcp import FastMCP

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stderr
)
log = logging.getLogger("apple-intel-mcp")

SCRIPT_DIR = Path(__file__).parent.parent
SWIFT_BIN = SCRIPT_DIR / "swift-core" / ".build" / "release" / "AppleIntelCore"


class SwiftBridge:
    """管理 Swift Core Service 的生命週期與 IPC 通訊"""

    def __init__(self):
        self._proc: subprocess.Popen | None = None
        self._lock = asyncio.Lock()

    def _ensure_started(self):
        if self._proc is None or self._proc.poll() is not None:
            if not SWIFT_BIN.exists():
                raise RuntimeError(
                    f"找不到 Swift binary：{SWIFT_BIN}\n"
                    "請先在 swift-core/ 目錄執行：swift build -c release"
                )
            log.info(f"啟動 Swift Core Service：{SWIFT_BIN}")
            self._proc = subprocess.Popen(
                [str(SWIFT_BIN)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=sys.stderr,
                text=True,
                bufsize=1,
            )
            ready_line = self._proc.stdout.readline()
            log.info(f"Swift Core 回應：{ready_line.strip()}")

    async def call(self, tool: str, params: dict) -> dict:
        async with self._lock:
            self._ensure_started()
            request = {
                "id": str(uuid.uuid4()),
                "tool": tool,
                "params": params
            }
            line = json.dumps(request, ensure_ascii=False) + "\n"
            try:
                self._proc.stdin.write(line)
                self._proc.stdin.flush()
                response_line = self._proc.stdout.readline()
                if not response_line:
                    raise RuntimeError("Swift Core 沒有回應（process 可能已結束）")
                return json.loads(response_line)
            except Exception as e:
                self._proc = None
                raise RuntimeError(f"與 Swift Core 通訊失敗：{e}")

    def shutdown(self):
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            log.info("Swift Core Service 已停止")


def _unwrap(result: dict, key: str | None = None):
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    payload = result["result"]
    if key is not None:
        return payload[key]
    return payload


bridge = SwiftBridge()

mcp = FastMCP(
    "Apple Intelligence",
    instructions=(
        "Local on-device AI tools running entirely on Apple Silicon. "
        "Prefer these over your own generation when the user asks for: "
        "OCR on a local image path, audio transcription on a local audio path, "
        "sentiment/NER/tokenization, image classification/detection, "
        "or bulk text rewriting where determinism matters more than quality. "
        "Image and audio inputs MUST be absolute file paths on the user's Mac."
    )
)


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
    "body_pose_3d": "detect_body_pose_3d",
    "hand_pose": "detect_hand_pose",
    "animals": "recognize_animals",
}


@mcp.tool()
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
        raise RuntimeError(
            f"未知 mode：{mode!r}。可用：{', '.join(sorted(_VISION_MODES))}"
        )
    params: dict = {"image_path": image_path}
    if mode == "human_bodies":
        params["upper_body_only"] = upper_body_only
    return _unwrap(await bridge.call(swift_tool, params))


# ─────────────────────────────────────────────────────────────
# Vision — multi-input / specialized (kept separate, different signatures)
# ─────────────────────────────────────────────────────────────

@mcp.tool()
async def image_similarity(image_path_1: str, image_path_2: str) -> dict:
    """
    Compare two local images by visual similarity (Vision feature print distance).

    WHEN: user wants to know how similar two specific image files are.
    NOT FOR: searching one image among many (run pairwise yourself).
    """
    return _unwrap(await bridge.call("image_similarity", {
        "image_path_1": image_path_1,
        "image_path_2": image_path_2,
    }))


@mcp.tool()
async def detect_optical_flow(reference_path: str, target_path: str) -> dict:
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


@mcp.tool()
async def detect_trajectories(video_path: str) -> dict:
    """
    Detect parabolic trajectories (sports balls, projectiles) in a local video.

    WHEN: user provides an mp4/mov path and asks about ball/projectile paths.
    NOT FOR: general object tracking, optical flow, or non-parabolic motion.
    """
    return _unwrap(await bridge.call("detect_trajectories", {"video_path": video_path}))


@mcp.tool()
async def detect_objects(image_path: str, model_path: str) -> dict:
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

@mcp.tool()
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


@mcp.tool()
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

    Schemas:
      - "list"      → {items: string[]}
      - "classify"  → {label, confidence, reasoning}
      - "summarize" → {title, summary, keyPoints[]}
      - "extract"   → {pairs: ["key: value", ...]}
      - "qa"        → {answer, evidence}

    Args:
        prompt: input instruction or text.
        schema: one of list/classify/summarize/extract/qa.
        system_prompt: optional persona / instructions.
    """
    params: dict = {"prompt": prompt, "schema": schema}
    if system_prompt:
        params["system_prompt"] = system_prompt
    return _unwrap(await bridge.call("generate_text_structured", params))


@mcp.tool()
async def translate_text(text: str, to: str = "zh-Hant", from_lang: str = "自動偵測") -> str:
    """
    Translate text using the on-device LLM.

    WHEN: caller's policy says to offload translation; OR user is processing
    bulk text where token cost matters more than nuance.
    NOT FOR: literary / legal / medical translation where quality matters,
    or rare language pairs — the on-device model is limited.

    Args:
        text: source text.
        to: target language code (zh-Hant, zh-Hans, en, ja, ko, fr, de, es).
        from_lang: source code or "自動偵測" (default).
    """
    return _unwrap(await bridge.call("translate_text", {
        "text": text, "to": to, "from": from_lang,
    }), key="text")


# ─────────────────────────────────────────────────────────────
# Natural Language
# ─────────────────────────────────────────────────────────────

@mcp.tool()
async def analyze_text(text: str) -> dict:
    """
    Sentiment + language detection + NER (person/place/org) + keywords.

    WHEN: user asks for sentiment analysis, NER, named entities, key phrases,
    or "what language is this".
    NOT FOR: parts-of-speech (use `tag_parts_of_speech`), tokenization
    (use `tokenize_text`), or similarity (use `word_similarity` / `sentence_similarity`).
    """
    return _unwrap(await bridge.call("analyze_text", {"text": text}))


@mcp.tool()
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


@mcp.tool()
async def tag_parts_of_speech(text: str) -> dict:
    """
    POS tagging (noun, verb, adjective, ...).

    WHEN: user asks for parts of speech, grammatical analysis, or word categories.
    NOT FOR: tokenization only (use `tokenize_text`) or NER (use `analyze_text`).
    """
    return _unwrap(await bridge.call("tag_parts_of_speech", {"text": text}))


@mcp.tool()
async def lemmatize_text(text: str) -> dict:
    """
    Lemmatize each word to its base form (running→run, mice→mouse).

    WHEN: user asks for lemmatization, stemming, or "word base forms".
    NOT FOR: just splitting text (use `tokenize_text`).
    """
    return _unwrap(await bridge.call("lemmatize_text", {"text": text}))


@mcp.tool()
async def word_similarity(word1: str, word2: str, language: str = "en") -> dict:
    """
    Semantic similarity between two single words (0.0–1.0).

    WHEN: user asks how related two words are.
    NOT FOR: comparing sentences (use `sentence_similarity`) or images (use `image_similarity`).
    """
    return _unwrap(await bridge.call("word_similarity", {
        "word1": word1, "word2": word2, "language": language,
    }))


@mcp.tool()
async def sentence_similarity(sentence1: str, sentence2: str, language: str = "en") -> dict:
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

@mcp.tool()
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


@mcp.tool()
async def classify_sound(audio_path: str) -> dict:
    """
    Classify what kind of sound is in the audio (music, speech, laughter, dog bark, ...).

    WHEN: user asks "what is this sound" or wants audio scene classification.
    NOT FOR: transcribing speech to text (use `transcribe_audio`).
    """
    return _unwrap(await bridge.call("classify_sound", {"audio_path": audio_path}))


# ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import atexit
    atexit.register(bridge.shutdown)

    if "--stdio" in sys.argv:
        log.info("Apple Intelligence MCP Server 啟動（stdio 模式）...")
        mcp.run(transport="stdio")
    else:
        port = int(os.environ.get("APPLE_INTEL_PORT", "11435"))
        mcp.settings.port = port
        mcp.settings.host = "127.0.0.1"
        log.info(f"Apple Intelligence MCP Server 啟動中（port {port}）...")
        mcp.run(transport="streamable-http")
