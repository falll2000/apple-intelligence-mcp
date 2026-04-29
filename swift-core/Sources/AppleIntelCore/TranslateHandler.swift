import Foundation
import FoundationModels

// MARK: - 翻譯 Handler
// Translation framework 的 withTranslationSession 只能在 SwiftUI 環境使用
// CLI 環境改用 Foundation Models 本地 LLM 進行翻譯
// 準確度略低於 Apple Translation，但完全離線且不需要 SwiftUI

struct TranslateHandler: Sendable {

    // 語言代碼對應中文名稱（供 prompt 使用）
    private static let langNames: [String: String] = [
        "zh-Hant": "繁體中文",
        "zh-Hans": "簡體中文",
        "en": "英文",
        "ja": "日文",
        "ko": "韓文",
        "fr": "法文",
        "de": "德文",
        "es": "西班牙文",
        "自動偵測": "自動偵測來源語言後翻譯"
    ]

    func translate(
        text: String,
        from sourceLang: String,
        to targetLang: String
    ) async throws -> String {
        let targetName = Self.langNames[targetLang] ?? targetLang
        let sourcePart = sourceLang == "自動偵測"
            ? ""
            : "（來源語言：\(Self.langNames[sourceLang] ?? sourceLang)）"

        let session = LanguageModelSession(
            instructions: "你是專業翻譯。只輸出翻譯結果，不加任何說明或標點以外的文字。"
        )
        let prompt = "請將以下文字翻譯成\(targetName)\(sourcePart)：\n\n\(text)"
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
