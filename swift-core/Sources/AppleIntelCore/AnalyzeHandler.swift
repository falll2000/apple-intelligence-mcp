import Foundation
import NaturalLanguage

// MARK: - Natural Language 分析（情感、語言偵測、關鍵詞）

struct AnalyzeHandler: Sendable {

    // 情感分析：回傳 -1.0（極負面）到 1.0（極正面）
    func analyzeSentiment(text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(
            at: text.startIndex,
            unit: .paragraph,
            scheme: .sentimentScore
        )
        return tag.flatMap { Double($0.rawValue) } ?? 0.0
    }

    // 語言偵測
    func detectLanguage(text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "unknown"
    }

    // 命名實體識別（人名、地名、組織名）
    func extractEntities(text: String) -> [String: [String]] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var entities: [String: [String]] = [
            "person": [],
            "place": [],
            "organization": []
        ]

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag = tag else { return true }
            let word = String(text[range])
            switch tag {
            case .personalName:
                entities["person"]?.append(word)
            case .placeName:
                entities["place"]?.append(word)
            case .organizationName:
                entities["organization"]?.append(word)
            default:
                break
            }
            return true
        }
        return entities
    }

    // 關鍵字抽取（詞彙層級）
    func extractKeywords(text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var keywords: [String] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            guard let tag = tag else { return true }
            // 只抓名詞和動詞作為關鍵字
            if tag == .noun || tag == .verb {
                let word = String(text[range]).lowercased()
                if word.count > 2 && !keywords.contains(word) {
                    keywords.append(word)
                }
            }
            return true
        }
        return Array(keywords.prefix(20))
    }
}
