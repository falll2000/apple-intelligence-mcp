import Foundation
import NaturalLanguage

// MARK: - Natural Language analysis (sentiment, language detection, keywords)

struct AnalyzeHandler: Sendable {

    // Sentiment analysis: returns -1.0 (very negative) to 1.0 (very positive).
    //
    // NLTagger scores one paragraph at a time, so asking for the tag at
    // text.startIndex only ever returns the FIRST paragraph and silently drops the
    // rest of a multi-paragraph input. Walk every paragraph instead and combine
    // them, weighted by length: a one-line aside should not outweigh the long
    // paragraph next to it. Paragraphs the tagger cannot score are skipped rather
    // than counted as neutral, which would drag the result toward zero.
    func analyzeSentiment(text: String) -> Double {
        guard !text.isEmpty else { return 0.0 }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text

        // NLTagger has no sentiment model for every language (Chinese among them) and
        // signals that by tagging the document "Other" instead of a number. In that
        // state its per-paragraph scores are noise: the same Traditional Chinese
        // sentence measures 0.0 as the first paragraph and -0.6 as the third, so
        // averaging them invents a confident-looking verdict out of nothing. Report
        // neutral instead, which is what the single-paragraph code did anyway.
        let (documentTag, _) = tagger.tag(
            at: text.startIndex,
            unit: .paragraph,
            scheme: .sentimentScore
        )
        guard let documentTag, Double(documentTag.rawValue) != nil else { return 0.0 }

        var weightedSum = 0.0
        var totalWeight = 0.0
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .paragraph,
            scheme: .sentimentScore,
            options: [.omitWhitespace]
        ) { tag, range in
            guard let score = tag.flatMap({ Double($0.rawValue) }) else { return true }
            let weight = Double(text[range].trimmingCharacters(in: .whitespacesAndNewlines).count)
            guard weight > 0 else { return true }
            weightedSum += score * weight
            totalWeight += weight
            return true
        }
        return totalWeight > 0 ? weightedSum / totalWeight : 0.0
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
