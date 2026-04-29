#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 注意：需用 venv 內的 Python 執行：
#   source mcp-server/venv/bin/activate && python3 mcp-server/server.py
"""
Apple Intelligence MCP Server
把 Apple Intelligence 本地 AI 能力包裝成 MCP 工具
任何支援 MCP 的 AI 客戶端（Claude、OpenAI、Gemini 等）都可以呼叫

Transport: Streamable HTTP（port 11435）
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

# ── 設定 logging ──────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stderr
)
log = logging.getLogger("apple-intel-mcp")

# ── Swift binary 路徑 ─────────────────────────────────────────
SCRIPT_DIR = Path(__file__).parent.parent
SWIFT_BIN = SCRIPT_DIR / "swift-core" / ".build" / "release" / "AppleIntelCore"

# ── Swift Process 管理 ────────────────────────────────────────

class SwiftBridge:
    """管理 Swift Core Service 的生命週期與 IPC 通訊"""

    def __init__(self):
        self._proc: subprocess.Popen | None = None
        self._lock = asyncio.Lock()

    def _ensure_started(self):
        """確保 Swift process 在跑（若掛掉就重啟）"""
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
                bufsize=1,  # line-buffered
            )
            # 等待就緒訊號
            ready_line = self._proc.stdout.readline()
            log.info(f"Swift Core 回應：{ready_line.strip()}")

    async def call(self, tool: str, params: dict) -> dict:
        """發送請求給 Swift Core，等待回應"""
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
                # 重置 process，下次呼叫會重新啟動
                self._proc = None
                raise RuntimeError(f"與 Swift Core 通訊失敗：{e}")

    def shutdown(self):
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            log.info("Swift Core Service 已停止")

# ── 全域 bridge 實例 ──────────────────────────────────────────
bridge = SwiftBridge()

# ── MCP Server ────────────────────────────────────────────────
mcp = FastMCP(
    "Apple Intelligence",
    instructions=(
        "本地 Apple Intelligence 工具集。"
        "使用 Apple Silicon Mac 上的原生 AI 能力，完全離線、不耗 cloud API token。"
        "適合用來處理：大量文字摘要、圖片 OCR、翻譯、情感分析、語音轉文字。"
    )
)

# ── Tool：generate_text ───────────────────────────────────────
@mcp.tool()
async def generate_text(prompt: str, system_prompt: str = "") -> str:
    """
    使用 Apple 本地 LLM（Foundation Models）生成文字。
    適合用於：摘要、改寫、潤飾、簡單問答。
    完全離線、不耗 Claude token，適合處理大量重複性文字任務。

    Args:
        prompt: 輸入給 LLM 的指令或文字
        system_prompt: （可選）系統角色設定，例如「你是專業編輯」
    """
    params = {"prompt": prompt}
    if system_prompt:
        params["system_prompt"] = system_prompt
    result = await bridge.call("generate_text", params)
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]["text"]

# ── Tool：ocr_image ───────────────────────────────────────────
@mcp.tool()
async def ocr_image(image_path: str) -> str:
    """
    使用 Apple Vision framework 辨識圖片中的文字（OCR）。
    支援：繁體中文、簡體中文、英文、日文、韓文。
    完全離線，圖片不離開你的裝置。

    Args:
        image_path: 圖片的絕對路徑（支援 PNG、JPG、HEIC 等格式）
    """
    result = await bridge.call("ocr_image", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]["text"]

# ── Tool：translate_text ──────────────────────────────────────
@mcp.tool()
async def translate_text(text: str, to: str = "zh-Hant", from_lang: str = "自動偵測") -> str:
    """
    使用本地 LLM 翻譯文字，完全離線。
    支援語言代碼：zh-Hant（繁中）、zh-Hans（簡中）、en（英）、ja（日）、ko（韓）、fr（法）、de（德）、es（西班牙）

    Args:
        text: 要翻譯的文字
        to: 目標語言代碼（預設 zh-Hant 繁體中文）
        from_lang: 來源語言代碼（預設自動偵測）
    """
    result = await bridge.call("translate_text", {
        "text": text,
        "to": to,
        "from": from_lang
    })
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]["text"]

# ── Tool：analyze_text ────────────────────────────────────────
@mcp.tool()
async def analyze_text(text: str) -> dict:
    """
    使用 Apple Natural Language framework 分析文字。
    回傳：情感分數（-1 到 1）、情感標籤、語言偵測、關鍵字、命名實體（人名/地名/組織）。
    完全離線，處理速度極快。

    Args:
        text: 要分析的文字
    """
    result = await bridge.call("analyze_text", {"text": text})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：transcribe_audio ────────────────────────────────────
@mcp.tool()
async def transcribe_audio(audio_path: str, language: str = "zh-TW") -> str:
    """
    使用 Apple Speech framework 將音訊檔轉成文字。
    支援語言：zh-TW（台灣中文）、zh-CN（普通話）、en-US（英文）、ja-JP（日文）等。
    完全離線，音訊不離開裝置。

    Args:
        audio_path: 音訊檔的絕對路徑（支援 m4a、mp3、wav 等格式）
        language: 語言代碼（預設 zh-TW）
    """
    result = await bridge.call("transcribe_audio", {
        "audio_path": audio_path,
        "language": language
    })
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]["text"]

# ── Tool：classify_image ─────────────────────────────────────
@mcp.tool()
async def classify_image(image_path: str) -> dict:
    """
    使用 Apple Vision framework 辨識圖片內容（場景/物體分類）。
    回傳最可能的分類標籤與信心分數。完全離線。

    Args:
        image_path: 圖片的絕對路徑（PNG、JPG、HEIC 等）
    """
    result = await bridge.call("classify_image", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_faces ────────────────────────────────────────
@mcp.tool()
async def detect_faces(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中的人臉。
    回傳人臉數量與每張臉的位置資訊。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_faces", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_barcodes ─────────────────────────────────────
@mcp.tool()
async def detect_barcodes(image_path: str) -> dict:
    """
    使用 Apple Vision framework 辨識圖片中的條碼或 QR Code。
    支援 QR Code、EAN-13、Code-128、PDF417 等多種格式。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_barcodes", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：image_similarity ────────────────────────────────────
@mcp.tool()
async def image_similarity(image_path_1: str, image_path_2: str) -> dict:
    """
    使用 Apple Vision framework 比較兩張圖片的視覺相似度。
    回傳 feature print 距離與文字描述。完全離線。

    Args:
        image_path_1: 第一張圖片的絕對路徑
        image_path_2: 第二張圖片的絕對路徑
    """
    result = await bridge.call("image_similarity", {
        "image_path_1": image_path_1,
        "image_path_2": image_path_2,
    })
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_objects ──────────────────────────────────────
@mcp.tool()
async def detect_objects(image_path: str, model_path: str) -> dict:
    """
    使用 Apple Vision + Core ML 偵測圖片中的物件。
    需要提供已訓練的 Core ML 物件偵測模型路徑。完全離線。

    Args:
        image_path: 圖片的絕對路徑
        model_path: Core ML 模型路徑（.mlmodel 或 .mlmodelc）
    """
    result = await bridge.call("detect_objects", {
        "image_path": image_path,
        "model_path": model_path,
    })
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_contours ─────────────────────────────────────
@mcp.tool()
async def detect_contours(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中的輪廓與邊緣。
    回傳輪廓數量與部分路徑摘要。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_contours", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_text_regions ─────────────────────────────────
@mcp.tool()
async def detect_text_regions(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中的文字區域。
    只找出文字位置，不做 OCR 內容辨識。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_text_regions", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_face_landmarks ───────────────────────────────
@mcp.tool()
async def detect_face_landmarks(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測臉部特徵點。
    可找出眼睛、眉毛、鼻子、嘴巴、臉部輪廓等。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_face_landmarks", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_human_bodies ─────────────────────────────────
@mcp.tool()
async def detect_human_bodies(image_path: str, upper_body_only: bool = False) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中的人體區域。
    與姿態偵測不同，這個工具回傳人體所在位置框。完全離線。

    Args:
        image_path: 圖片的絕對路徑
        upper_body_only: 是否只偵測上半身
    """
    result = await bridge.call("detect_human_bodies", {
        "image_path": image_path,
        "upper_body_only": upper_body_only,
    })
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_horizon ──────────────────────────────────────
@mcp.tool()
async def detect_horizon(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中的地平線角度。
    適合用於：照片校正、水平判斷。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_horizon", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：word_similarity ─────────────────────────────────────
@mcp.tool()
async def word_similarity(word1: str, word2: str, language: str = "en") -> dict:
    """
    使用 Apple Natural Language framework 計算兩個詞語的語意相似度。
    回傳 0.0（完全不同）到 1.0（完全相同）的分數。完全離線。

    Args:
        word1: 第一個詞語
        word2: 第二個詞語
        language: 語言代碼（en、zh、ja 等，預設 en）
    """
    result = await bridge.call("word_similarity", {
        "word1": word1, "word2": word2, "language": language
    })
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：sentence_similarity ─────────────────────────────────
@mcp.tool()
async def sentence_similarity(sentence1: str, sentence2: str, language: str = "en") -> dict:
    """
    使用 Apple Natural Language framework 計算兩段句子的語意相似度。
    適合用於：重複內容偵測、語意搜尋、問答匹配。完全離線。

    Args:
        sentence1: 第一段句子
        sentence2: 第二段句子
        language: 語言代碼（en、zh、ja 等，預設 en）
    """
    result = await bridge.call("sentence_similarity", {
        "sentence1": sentence1, "sentence2": sentence2, "language": language
    })
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：classify_sound ──────────────────────────────────────
@mcp.tool()
async def classify_sound(audio_path: str) -> dict:
    """
    使用 Apple Sound Analysis framework 辨識音訊內容類型。
    可辨識：笑聲、掌聲、音樂、狗叫、車聲等數百種聲音。完全離線。

    Args:
        audio_path: 音訊檔的絕對路徑（m4a、mp3、wav 等）
    """
    result = await bridge.call("classify_sound", {"audio_path": audio_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_body_pose ───────────────────────────────────
@mcp.tool()
async def detect_body_pose(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中的人體姿態。
    回傳每個人的關節點位置（肩膀、手肘、膝蓋等）。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_body_pose", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_hand_pose ────────────────────────────────────
@mcp.tool()
async def detect_hand_pose(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中的手部姿態。
    回傳手指關節點位置，並區分左右手。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_hand_pose", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：recognize_animals ───────────────────────────────────
@mcp.tool()
async def recognize_animals(image_path: str) -> dict:
    """
    使用 Apple Vision framework 辨識圖片中的貓或狗。
    回傳動物種類與信心分數。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("recognize_animals", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_rectangles ───────────────────────────────────
@mcp.tool()
async def detect_rectangles(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中的矩形區域。
    適合用於：找出卡片、文件、螢幕、白板等方形物體。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_rectangles", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_saliency ─────────────────────────────────────
@mcp.tool()
async def detect_saliency(image_path: str) -> dict:
    """
    使用 Apple Vision framework 找出圖片中最吸引視線的區域（視覺顯著性）。
    適合用於：找出主體、自動裁切焦點。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_saliency", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：segment_person ──────────────────────────────────────
@mcp.tool()
async def segment_person(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中是否有人物（人像去背前置偵測）。
    回傳人像遮罩的尺寸資訊。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("segment_person", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_document ─────────────────────────────────────
@mcp.tool()
async def detect_document(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中是否有文件（紙張、卡片等）。
    回傳文件的邊界位置。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_document", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：score_image_aesthetics ─────────────────────────────
@mcp.tool()
async def score_image_aesthetics(image_path: str) -> dict:
    """
    使用 Apple Vision framework 評估圖片的美學品質（構圖、清晰度、色彩等）。
    回傳整體評分（0-1）與是否為功能性截圖。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("score_image_aesthetics", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：segment_foreground_instances ───────────────────────
@mcp.tool()
async def segment_foreground_instances(image_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測圖片中各個獨立前景物件（實例分割）。
    回傳前景物件數量，可進一步為每個物件產生去背遮罩。完全離線。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("segment_foreground_instances", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_optical_flow ─────────────────────────────────
@mcp.tool()
async def detect_optical_flow(reference_path: str, target_path: str) -> dict:
    """
    使用 Apple Vision framework 計算兩張圖片（連續幀）之間的光流場。
    回傳每個像素的移動向量場（dx, dy），適合動態分析。完全離線。

    Args:
        reference_path: 參考幀（前一幀）的絕對路徑
        target_path: 目標幀（後一幀）的絕對路徑
    """
    result = await bridge.call("detect_optical_flow", {
        "reference_path": reference_path,
        "target_path": target_path,
    })
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_body_pose_3d ─────────────────────────────────
@mcp.tool()
async def detect_body_pose_3d(image_path: str) -> dict:
    """
    使用 Apple Vision framework 從單張圖片估算人體 3D 關節座標。
    回傳每個人的關節 (x, y, z) 世界座標。完全離線，macOS 14+。

    Args:
        image_path: 圖片的絕對路徑
    """
    result = await bridge.call("detect_body_pose_3d", {"image_path": image_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：detect_trajectories ─────────────────────────────────
@mcp.tool()
async def detect_trajectories(video_path: str) -> dict:
    """
    使用 Apple Vision framework 偵測影片中物體的拋物線軌跡。
    適合運動分析（球、飛盤等）。回傳軌跡座標序列與拋物線方程式。完全離線。

    Args:
        video_path: 影片的絕對路徑（mp4、mov 等格式）
    """
    result = await bridge.call("detect_trajectories", {"video_path": video_path})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：lemmatize_text ──────────────────────────────────────
@mcp.tool()
async def lemmatize_text(text: str) -> dict:
    """
    使用 Apple Natural Language framework 將每個詞還原為詞根原形。
    例如：running→run、better→good、mice→mouse。支援多語言，完全離線。

    Args:
        text: 要進行詞形還原的文字
    """
    result = await bridge.call("lemmatize_text", {"text": text})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：generate_text_structured ───────────────────────────
@mcp.tool()
async def generate_text_structured(
    prompt: str,
    schema: str = "summarize",
    system_prompt: str = ""
) -> dict:
    """
    使用 Apple Foundation Models 產生結構化 JSON 輸出（Guided Generation）。
    比 generate_text 更精確——LLM 保證輸出符合指定 schema，完全離線。

    schema 選項：
    - list       → { "items": ["..."] }
    - classify   → { "label": "...", "confidence": "...", "reasoning": "..." }
    - summarize  → { "title": "...", "summary": "...", "keyPoints": ["..."] }
    - extract    → { "pairs": ["key: value", ...] }
    - qa         → { "answer": "...", "evidence": "..." }

    Args:
        prompt: 輸入指令或文字
        schema: 輸出結構類型（預設 summarize）
        system_prompt: 可選的系統角色設定
    """
    params: dict = {"prompt": prompt, "schema": schema}
    if system_prompt:
        params["system_prompt"] = system_prompt
    result = await bridge.call("generate_text_structured", params)
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：tokenize_text ───────────────────────────────────────
@mcp.tool()
async def tokenize_text(text: str, unit: str = "word") -> dict:
    """
    使用 Apple Natural Language framework 將文字斷詞/斷句。
    完全離線，支援多語言（中文、英文、日文等）自動偵測。

    Args:
        text: 要斷詞的文字
        unit: 斷詞單位（word 詞語、sentence 句子、paragraph 段落，預設 word）
    """
    result = await bridge.call("tokenize_text", {"text": text, "unit": unit})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── Tool：tag_parts_of_speech ─────────────────────────────────
@mcp.tool()
async def tag_parts_of_speech(text: str) -> dict:
    """
    使用 Apple Natural Language framework 標注每個詞語的詞性。
    回傳每個詞加上詞性標注（名詞、動詞、形容詞等）。完全離線。

    Args:
        text: 要標注詞性的文字
    """
    result = await bridge.call("tag_parts_of_speech", {"text": text})
    if not result.get("success"):
        raise RuntimeError(result.get("error", "未知錯誤"))
    return result["result"]

# ── 啟動 ──────────────────────────────────────────────────────
if __name__ == "__main__":
    import atexit
    atexit.register(bridge.shutdown)

    # --stdio：給 Claude Desktop 用（stdio transport）
    # 預設：HTTP transport，給 OpenAI / Gemini 等其他客戶端用
    if "--stdio" in sys.argv:
        log.info("Apple Intelligence MCP Server 啟動（stdio 模式）...")
        mcp.run(transport="stdio")
    else:
        port = int(os.environ.get("APPLE_INTEL_PORT", "11435"))
        mcp.settings.port = port
        mcp.settings.host = "127.0.0.1"
        log.info(f"Apple Intelligence MCP Server 啟動中（port {port}）...")
        mcp.run(transport="streamable-http")
