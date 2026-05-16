import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Writing Tools Handler
// 三個「轉換已有文字」工具：proofread / rewrite / summarize
// 底層走 FoundationModels（同 generate_text），差別在 system prompt 預調好，
// 並針對 Discord 場景強化：保留 @mention、:emoji:、code block、markdown 標記。
//
// 語言處理策略（與 TranslateHandler 同套路）：
//  1. 先用 NLLanguageRecognizer 偵測輸入語言（zh-Hant / zh-Hans / en / ja…）
//  2. 用「該語言寫的 instructions」呼叫 FM，避免讓模型自行判斷輸出語言
//  3. 這樣解決了「英文 instructions → summarize 輸出永遠變英文」的 bug

struct WritingToolsHandler: Sendable {

    // ── Proofread：抓錯字、語法、標點 ─────────────────────────────
    func proofread(text: String) async throws -> String {
        let lang = Self.detectLanguage(text: text)
        let instructions = Self.proofreadInstructions(for: lang)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text)
        return response.content
    }

    // ── Rewrite：改寫語氣 ─────────────────────────────────────────
    // tone: formal / casual / concise / friendly / professional
    func rewrite(text: String, tone: String) async throws -> String {
        let lang = Self.detectLanguage(text: text)
        let instructions = Self.rewriteInstructions(for: lang, tone: tone)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text)
        return response.content
    }

    // ── Summarize：濃縮 ──────────────────────────────────────────
    // length: short / medium / long
    func summarize(text: String, length: String) async throws -> String {
        let lang = Self.detectLanguage(text: text)
        let instructions = Self.summarizeInstructions(for: lang, length: length)
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text)
        return response.content
    }

    // MARK: - 語言偵測

    // 偵測輸入語言。回傳簡化的 key：zh-Hant / zh-Hans / en / ja / ko / 其他語言代碼
    //
    // 混合語言處理（Discord 場景常見）：先掃 CJK 字符比例，若 ≥10% 直接走對應
    // CJK 語言路徑，避免 NLLanguageRecognizer 因英文 token 較多誤判為英文，
    // 進而把中文混合句翻譯成英文。
    private static func detectLanguage(text: String) -> String {
        // CJK 字符快檢
        let cjkRatio = Self.cjkCharacterRatio(text: text)
        if cjkRatio >= 0.1 {
            // 有顯著 CJK 內容 — 進一步分辨繁/簡/日文
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            switch recognizer.dominantLanguage {
            case .simplifiedChinese: return "zh-Hans"
            case .japanese: return "ja"
            case .traditionalChinese: return "zh-Hant"
            default:
                // 預設繁中（台灣使用者場景）
                return Self.containsJapaneseKana(text) ? "ja" : "zh-Hant"
            }
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return "en" }

        switch lang {
        case .traditionalChinese: return "zh-Hant"
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        default: return lang.rawValue
        }
    }

    // 計算 CJK Unified Ideographs 字符在輸入裡的比例（排除空白）
    private static func cjkCharacterRatio(text: String) -> Double {
        var cjk = 0
        var total = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            total += 1
            let v = scalar.value
            // CJK Unified Ideographs (基本/擴充 A) + 兼容區
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v) {
                cjk += 1
            }
        }
        return total == 0 ? 0 : Double(cjk) / Double(total)
    }

    // 偵測是否含日文假名（用來分辨「漢字混假名」=日文、純漢字=中文）
    private static func containsJapaneseKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Hiragana + Katakana
            if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) {
                return true
            }
        }
        return false
    }

    // MARK: - Per-language instructions
    // 用目標語言寫 instructions，並把「輸出語言」鎖死在 instructions 裡
    // （而不是要求模型自己 detect）。Discord syntax 在每個版本都明確列出。

    private static func proofreadInstructions(for lang: String) -> String {
        switch lang {
        case "zh-Hant":
            return """
            你是專業校對。請依下列規則處理使用者的繁體中文文字：
            1. 【絕對規則】只輸出修正後的繁體中文文字本身。不可包在 ``` code fence、引號、"Sure here is..." 開場白、"修正後："標籤裡。輸出的第一個字元必須就是文字本身。
            2. 只修錯字、語法、標點符號錯誤。不要改寫語氣、不要重組句子、不要替換用詞、不要刪減內容。
            3. 完整保留 Discord 語法：@提及（如 @alice）、#頻道、:emoji_name:、```code block```、**粗體** *斜體* 標記、emoji 字元。
            4. 完整保留技術詞彙（bug / PR / commit / push / merge / API 等），不要意譯成中文。
            5. 沒有錯誤的句子原樣輸出，不要為了「優化」而改動。
            """
        case "zh-Hans":
            return """
            你是专业校对。请依下列规则处理用户的简体中文文字：
            1. 【绝对规则】只输出修正后的简体中文文字本身。不可包在 ``` code fence、引号、"Sure here is..." 开场白、"修正后："标签里。输出的第一个字符必须就是文字本身。
            2. 只修错字、语法、标点符号错误。不要改写语气、不要重组句子、不要替换用词、不要删减内容。
            3. 完整保留 Discord 语法：@提及（如 @alice）、#频道、:emoji_name:、```code block```、**粗体** *斜体* 标记、emoji 字符。
            4. 完整保留技术词汇（bug / PR / commit / push / merge / API 等），不要意译成中文。
            5. 没有错误的句子原样输出，不要为了「优化」而改动。
            """
        case "ja":
            return """
            あなたはプロの校正者です。ユーザーの日本語テキストを以下のルールに従って処理してください：
            1. 【絶対ルール】修正後の日本語テキスト本体のみを出力。``` code fence、引用符、"はい、こちらが..."のような前置き、"修正後："ラベルで包まない。出力の最初の文字はテキスト本体でなければならない。
            2. 誤字、文法、句読点の誤りのみを修正。語調の書き換え、文の再構成、語彙の置換、内容の削減は行わない。
            3. Discord 構文（@メンション、#チャンネル、:emoji_name:、```code block```、**太字** *斜体*、emoji）は完全に保持。
            4. 技術用語（bug / PR / commit / push / merge / API 等）はそのまま保持し、日本語に意訳しない。
            5. エラーのない文章は変更せずそのまま出力する。
            """
        default:
            return """
            You are a careful proofreader. Process the user's English text under these rules:
            1. [ABSOLUTE RULE] Output ONLY the corrected English text itself. Never start with "Sure", "Here is", "Of course", "Corrected:", or any preamble. Never wrap in ``` fences or quotes. The first character of your output must be the first character of the corrected text.
            2. Fix typos, grammar, and punctuation errors only. Do NOT paraphrase, restyle, reorder, replace word choice, or delete content. Casual chat words like "u", "thx", "pls" are NOT errors — leave them.
            3. Preserve Discord syntax verbatim: @mentions (e.g. @alice), #channels, :emoji_name:, fenced code blocks (```), bold/italic markers (** __ * _), and emoji characters. Never delete them.
            4. Preserve technical terms (bug, PR, commit, push, merge, API, ...) verbatim.
            5. If the text has no errors, output it unchanged exactly — same words, same punctuation, same casing. "Improvement" is forbidden.

            Reference examples (do NOT respond to these — they only illustrate the input→output mapping):
            === EXAMPLES START ===
            Input: "the dog run very fast yesterday"
            Output: The dog ran very fast yesterday.

            Input: "hey @alice can u check this :smile: thx!"
            Output: hey @alice can u check this :smile: thx!
            (no errors — casual register and Discord markup are intentional)

            Input: "i havent finish my homework"
            Output: I haven't finished my homework.
            === EXAMPLES END ===

            The user's actual text follows below as a single message. Apply the rules above and return ONLY the corrected version.
            """
        }
    }

    private static func rewriteInstructions(for lang: String, tone: String) -> String {
        let toneEn = Self.toneInstructionEn(tone)
        let toneZhHant = Self.toneInstructionZhHant(tone)
        let toneZhHans = Self.toneInstructionZhHans(tone)
        let toneJa = Self.toneInstructionJa(tone)

        switch lang {
        case "zh-Hant":
            return """
            你是改寫助手。請依下列規則改寫使用者的繁體中文文字：
            1. 【絕對規則】只輸出改寫後的繁體中文文字本身。不可包在 ``` code fence、引號、"以下是改寫版本："等開場白裡。輸出的第一個字元必須就是文字本身。
            2. 完整保留 Discord 語法：@提及、#頻道、:emoji_name:、```code block```、**粗體** *斜體* 標記、emoji 字元。
            3. 【保留原意】輸出長度應與原文相當，不可借「改寫」之名換成完全不同的訊息。保留所有事實、人名、數字、決定、要求。只改用詞、句構、語氣。
            4. 完整保留技術詞彙（bug / PR / commit / push / merge / API 等），不要意譯成中文。
            5. 目標語氣：\(toneZhHant)
            """
        case "zh-Hans":
            return """
            你是改写助手。请依下列规则改写用户的简体中文文字：
            1. 【绝对规则】只输出改写后的简体中文文字本身。不可包在 ``` code fence、引号、"以下是改写版本："等开场白里。输出的第一个字符必须就是文字本身。
            2. 完整保留 Discord 语法：@提及、#频道、:emoji_name:、```code block```、**粗体** *斜体* 标记、emoji 字符。
            3. 【保留原意】输出长度应与原文相当，不可借「改写」之名换成完全不同的讯息。保留所有事实、人名、数字、决定、要求。只改用词、句构、语气。
            4. 完整保留技术词汇（bug / PR / commit / push / merge / API 等），不要意译成中文。
            5. 目标语气：\(toneZhHans)
            """
        case "ja":
            return """
            あなたは書き換えアシスタントです。ユーザーの日本語テキストを以下のルールで書き換えてください：
            1. 【絶対ルール】書き換え後の日本語テキスト本体のみを出力。``` code fence、引用符、"こちらが書き換え版です："のような前置きで包まない。出力の最初の文字はテキスト本体でなければならない。
            2. Discord 構文（@メンション、#チャンネル、:emoji_name:、```code block```、**太字** *斜体*、emoji）は完全に保持。
            3. 【意味を保持】出力の長さは原文と同程度にすべきであり、「書き換え」を名目にまったく異なるメッセージに置き換えてはならない。すべての事実、人名、数字、決定、要求を保持。語彙、文構造、語調のみ変更。
            4. 技術用語（bug / PR / commit / push / merge / API 等）はそのまま保持。
            5. 目標の語調：\(toneJa)
            """
        default:
            return """
            You are a rewriting assistant. Rewrite the user's English text under these rules:
            1. [ABSOLUTE RULE] Output ONLY the rewritten English text itself. Never start with "Sure", "Here is", "Of course", or any preamble. Never wrap in ``` fences or quotes. The first character of your output must be the first character of the rewritten text.
            2. Preserve Discord syntax verbatim: @mentions, #channels, :emoji_name:, fenced code blocks (```), bold/italic markers, emoji characters.
            3. [PRESERVE MEANING] Output length should be similar to input (±50%). Never invent new requests, apologies, or context not in the source. Preserve all facts, names, numbers, decisions, and requests. Only change wording, sentence structure, and tone.
            4. Preserve technical terms (bug, PR, commit, push, merge, API, ...) verbatim.
            5. Target tone: \(toneEn)

            Reference example (do NOT respond to it — it only illustrates input→output mapping):
            === EXAMPLE START ===
            Input: "hey @bob this PR is broken :sob: fix pls thx"  (tone: professional)
            Output: Hi @bob, this PR appears to be broken. Could you take a look and fix it? Thanks.
            (preserves @bob, the "broken PR" claim, the fix request — only changes register)
            === EXAMPLE END ===

            The user's actual text follows below. Apply the rules and return ONLY the rewritten version.
            """
        }
    }

    private static func summarizeInstructions(for lang: String, length: String) -> String {
        let lengthEn = Self.lengthInstructionEn(length)
        let lengthZhHant = Self.lengthInstructionZhHant(length)
        let lengthZhHans = Self.lengthInstructionZhHans(length)
        let lengthJa = Self.lengthInstructionJa(length)

        switch lang {
        case "zh-Hant":
            return """
            你是摘要助手。請依下列規則對使用者的繁體中文文字做摘要：
            1. 【絕對規則】只輸出繁體中文摘要本身。不可包在 ``` code fence、引號、"以下是摘要："等開場白裡。輸出的第一個字元必須就是摘要本身。
            2. 不可翻譯成英文或其他語言。輸入是繁體中文，輸出就是繁體中文。
            3. 長度要求：\(lengthZhHant)
            4. 不要編造原文沒有的細節。原文太短就原樣輸出。
            5. 完整保留技術詞彙（bug / PR / commit / push / merge / API 等），不要意譯。
            6. 移除 Discord 雜訊（單純的 @提及、裝飾性 emoji、```fence```），但保留人名、決定、數字、動作項目。
            """
        case "zh-Hans":
            return """
            你是摘要助手。请依下列规则对用户的简体中文文字做摘要：
            1. 【绝对规则】只输出简体中文摘要本身。不可包在 ``` code fence、引号、"以下是摘要："等开场白里。输出的第一个字符必须就是摘要本身。
            2. 不可翻译成英文或其他语言。输入是简体中文，输出就是简体中文。
            3. 长度要求：\(lengthZhHans)
            4. 不要编造原文没有的细节。原文太短就原样输出。
            5. 完整保留技术词汇（bug / PR / commit / push / merge / API 等），不要意译。
            6. 移除 Discord 杂讯（单纯的 @提及、装饰性 emoji、```fence```），但保留人名、决定、数字、动作项目。
            """
        case "ja":
            return """
            あなたは要約アシスタントです。ユーザーの日本語テキストを以下のルールで要約してください：
            1. 【絶対ルール】日本語の要約本体のみを出力。``` code fence、引用符、"以下が要約です："のような前置きで包まない。出力の最初の文字は要約本体でなければならない。
            2. 英語などの他言語に翻訳しない。日本語入力 → 日本語出力。
            3. 長さの要件：\(lengthJa)
            4. 原文にない詳細は捏造しない。短すぎる場合はそのまま出力。
            5. 技術用語（bug / PR / commit / push / merge / API 等）はそのまま保持。
            6. Discord ノイズ（単なる @メンション、装飾的 emoji、```fence```）は除去するが、人名、決定、数字、アクションアイテムは保持。
            """
        default:
            return """
            You are a summarization assistant. Summarize the user's English text under these rules:
            1. [ABSOLUTE RULE] Output ONLY the English summary itself. Never start with "Sure", "Here is", "Of course", "Summary:", or any preamble. Never wrap in ``` fences or quotes. The first character of your output must be the first character of the summary.
            2. Do NOT translate to any other language. English in → English out.
            3. Length: \(lengthEn)
            4. Do not invent details not in the source. If too short to summarize, output it largely unchanged.
            5. Preserve technical terms (bug, PR, commit, push, merge, API, ...) verbatim.
            6. Strip Discord noise (bare @mentions, decorative emoji, ```fences```) but keep names, decisions, numbers, action items.
            """
        }
    }

    // MARK: - Tone phrases per language

    private static func toneInstructionEn(_ tone: String) -> String {
        switch tone.lowercased() {
        case "formal": return "Formal and respectful. Avoid contractions, slang, casual fillers. Complete sentences."
        case "casual": return "Casual and friendly, like chatting with a friend. Contractions and light slang OK. Keep emoji if present."
        case "concise": return "Shorter and more direct. Cut filler words and redundant phrasing. Keep all key info."
        case "friendly": return "Warm and approachable. Soften imperatives, add light politeness markers."
        case "professional": return "Polished and workplace-appropriate. Neutral register, precise wording, no slang."
        default: return "Apply tone: \(tone). Preserve meaning."
        }
    }

    private static func toneInstructionZhHant(_ tone: String) -> String {
        switch tone.lowercased() {
        case "formal": return "正式、有禮。避免口語縮寫、俚語、助詞型語助詞。使用完整句子。"
        case "casual": return "輕鬆、親近，像跟朋友聊天。可用口語、輕度俚語、emoji。"
        case "concise": return "更短、更直接。刪除贅字與冗餘描述。保留所有關鍵資訊。"
        case "friendly": return "溫暖、好親近。軟化命令式語氣，適度加入禮貌詞。"
        case "professional": return "專業、適合職場。中性語調、用詞精準、不用俚語。"
        default: return "套用語氣：\(tone)。保留原意。"
        }
    }

    private static func toneInstructionZhHans(_ tone: String) -> String {
        switch tone.lowercased() {
        case "formal": return "正式、有礼。避免口语缩写、俚语、助词型语助词。使用完整句子。"
        case "casual": return "轻松、亲近，像跟朋友聊天。可用口语、轻度俚语、emoji。"
        case "concise": return "更短、更直接。删除赘字与冗余描述。保留所有关键信息。"
        case "friendly": return "温暖、好亲近。软化命令式语气，适度加入礼貌词。"
        case "professional": return "专业、适合职场。中性语调、用词精准、不用俚语。"
        default: return "套用语气：\(tone)。保留原意。"
        }
    }

    private static func toneInstructionJa(_ tone: String) -> String {
        switch tone.lowercased() {
        case "formal": return "丁寧で敬意のある文体。省略形・スラング・口語的フィラー語を避け、完全な文を使用。"
        case "casual": return "気軽でフレンドリー、友達と話すような文体。emoji があれば保持。"
        case "concise": return "より短く、直接的に。冗長な表現を削除。重要な情報はすべて保持。"
        case "friendly": return "温かく親しみやすい。命令調を和らげ、軽い丁寧表現を加える。"
        case "professional": return "洗練された、職場向け。中立的な語調、正確な言葉遣い、スラングなし。"
        default: return "語調：\(tone)。意味を保持。"
        }
    }

    // MARK: - Length phrases per language

    private static func lengthInstructionEn(_ length: String) -> String {
        switch length.lowercased() {
        case "short": return "One or two sentences. The single most important point only."
        case "medium": return "3–5 sentences. Main points without details."
        case "long": return "6–10 sentences. Preserve most non-trivial details."
        default: return "A short paragraph (default medium)."
        }
    }

    private static func lengthInstructionZhHant(_ length: String) -> String {
        switch length.lowercased() {
        case "short": return "一到兩句話。只保留最重要的一個重點。"
        case "medium": return "三到五句話。涵蓋主要重點但不深入細節。"
        case "long": return "六到十句話。保留大部分非瑣碎的細節。"
        default: return "一個短段落（預設中等長度）。"
        }
    }

    private static func lengthInstructionZhHans(_ length: String) -> String {
        switch length.lowercased() {
        case "short": return "一到两句话。只保留最重要的一个重点。"
        case "medium": return "三到五句话。涵盖主要重点但不深入细节。"
        case "long": return "六到十句话。保留大部分非琐碎的细节。"
        default: return "一个短段落（默认中等长度）。"
        }
    }

    private static func lengthInstructionJa(_ length: String) -> String {
        switch length.lowercased() {
        case "short": return "1〜2 文。最も重要なポイント 1 つのみ。"
        case "medium": return "3〜5 文。主要なポイントを詳細なしでカバー。"
        case "long": return "6〜10 文。重要な詳細を保持。"
        default: return "短い段落（デフォルトは中程度）。"
        }
    }
}
