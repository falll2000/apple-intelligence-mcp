import Foundation
import FoundationModels

// MARK: - Translation Handler
// The Translation framework's withTranslationSession can only be used in SwiftUI.
// In the CLI environment, use the Foundation Models local LLM for translation.
// Accuracy is lower than Apple Translation, but this is fully offline and does not require SwiftUI.
//
// Use English instructions and prompts to avoid locking the FM model into Chinese framing;
// otherwise zh->en can be misclassified as already English and returned unchanged.

struct TranslateHandler: Sendable {

    // Language code -> English language name (used in prompts)
    private static let langNames: [String: String] = [
        "zh-Hant": "Traditional Chinese",
        "zh-Hans": "Simplified Chinese",
        "en": "English",
        "ja": "Japanese",
        "ko": "Korean",
        "fr": "French",
        "de": "German",
        "es": "Spanish"
    ]

    // Target-language instructions switch the model into that language's conventions
    // for preserving imported brand names. English instructions can over-localize en->zh
    // translations (for example Apple -> a localized common noun).
    private static let instructionsByTarget: [String: String] = [
        "zh-Hant": """
        你是專業翻譯。請遵守以下規則：
        1. 只輸出繁體中文翻譯結果，不要加引號、標籤、說明、markdown 標記。
        2. 完整翻譯，不要留下未翻譯的源語言詞句。
        3. 品牌名、公司名、產品代號（如 iPhone、Tesla Model 3、Claude API）依該品牌在繁體中文地區的常見用法處理：有官方中文譯名（如 McDonald's → 麥當勞）就用譯名，沒有就保留英文原樣。
        """,
        "zh-Hans": """
        你是专业翻译。请遵守以下规则：
        1. 只输出简体中文翻译结果，不要加引号、标签、说明、markdown 标记。
        2. 完整翻译，不要留下未翻译的源语言词句。
        3. 品牌名、公司名、产品代号（如 iPhone、Tesla Model 3、Claude API）依该品牌在简体中文地区的常见用法处理：有官方中文译名（如 McDonald's → 麦当劳）就用译名，没有就保留英文原样。
        """,
        "en": """
        You are a professional translator. Follow these rules strictly:
        1. Output ONLY the English translation — no quotes, labels, explanations, or markdown formatting.
        2. Translate the text completely. Do not leave any source-language words untranslated.
        3. Preserve brand names, product names, company names, and well-known proper nouns in their original or commonly-recognized English form (e.g., Starbucks, Uniqlo, iPhone, Tesla, Anthropic, AWS).
        """,
        "ja": """
        あなたはプロの翻訳者です。以下のルールに従ってください：
        1. 日本語の翻訳のみを出力してください。引用符、ラベル、説明は不要です。
        2. 翻訳は完全に行い、原文の言語の単語を残さないでください。
        3. ブランド名、製品名、会社名、有名な固有名詞は原形のまま、またはカタカナ表記の慣例形を使用してください。
        4. 「早安」のような朝の挨拶は「おはようございます」と訳してください。「こんにちは」(=日中の挨拶) は不適切です。
        """,
        "ko": """
        당신은 전문 번역가입니다. 다음 규칙을 따르세요:
        1. 한국어 번역만 출력하세요. 따옴표, 라벨, 설명을 추가하지 마세요.
        2. 모든 내용을 완전히 번역하세요. 원본 언어 단어를 남기지 마세요.
        3. 브랜드명, 제품명, 회사명, 잘 알려진 고유명사는 원형 또는 일반적으로 인식되는 형태를 유지하세요.
        """,
        "fr": """
        Vous êtes un traducteur professionnel. Suivez ces règles strictement :
        1. Produisez UNIQUEMENT la traduction française — pas de guillemets, ni d'étiquettes, ni d'explications.
        2. Traduisez le texte complètement. Ne laissez aucun mot dans la langue source.
        3. Conservez les marques, noms de produits, noms d'entreprises et noms propres connus dans leur forme originale ou reconnue.
        """,
        "de": """
        Sie sind ein professioneller Übersetzer. Befolgen Sie diese Regeln strikt:
        1. Geben Sie NUR die deutsche Übersetzung aus — keine Anführungszeichen, keine Beschriftungen, keine Erklärungen.
        2. Übersetzen Sie den Text vollständig. Lassen Sie keine Wörter in der Quellsprache.
        3. Bewahren Sie Markennamen, Produktnamen, Firmennamen und bekannte Eigennamen in ihrer ursprünglichen oder allgemein anerkannten Form.
        """,
        "es": """
        Eres un traductor profesional. Sigue estas reglas estrictamente:
        1. Produce SOLO la traducción al español — sin comillas, etiquetas, ni explicaciones.
        2. Traduce el texto por completo. No dejes ninguna palabra en el idioma original.
        3. Conserva las marcas, nombres de productos, nombres de empresas y nombres propios conocidos en su forma original o comúnmente reconocida.
        """
    ]

    func translate(
        text: String,
        from sourceLang: String,
        to targetLang: String
    ) async throws -> String {
        let targetName = Self.langNames[targetLang] ?? targetLang
        let instructions = Self.instructionsByTarget[targetLang]
            ?? "You are a professional translator. Output ONLY the translation in \(targetName). Preserve brand names and proper nouns. Do not leave source-language words untranslated."

        let sourcePart: String
        if sourceLang == "auto" || Self.langNames[sourceLang] == nil {
            sourcePart = ""
        } else {
            sourcePart = " (source: \(Self.langNames[sourceLang] ?? sourceLang))"
        }

        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Translate to \(targetName)\(sourcePart):\n\n\(text)"
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
