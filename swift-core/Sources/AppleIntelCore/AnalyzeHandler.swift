import Foundation
import NaturalLanguage

// MARK: - Natural Language analysis (sentiment, language detection, keywords)

struct AnalyzeHandler: Sendable {

    // Sentiment analysis: returns -1.0 (very negative) to 1.0 (very positive).
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

    // Language detection
    func detectLanguage(text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "unknown"
    }

    // Named entity recognition (person names, places, organizations)
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

    // Keyword extraction (lexical level)
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
            // Use only nouns and verbs as keywords.
            if tag == .noun || tag == .verb {
                let word = String(text[range]).lowercased()
                let isCJK = word.unicodeScalars.contains { scalar in
                    let v = scalar.value
                    return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
                }
                let minLength = isCJK ? 2 : 3
                if word.count >= minLength && !keywords.contains(word) {
                    keywords.append(word)
                }
            }
            return true
        }
        return Array(keywords.prefix(20))
    }
}
