import Foundation
import NaturalLanguage

// MARK: - 進階 NL 功能（斷詞、詞性標注）

struct NLAdvancedHandler: Sendable {

    // ── 斷詞（Tokenization）─────────────────────────────────
    func tokenize(text: String, unit: String = "word") -> [String] {
        let tokenUnit: NLTokenUnit
        switch unit {
        case "sentence": tokenUnit = .sentence
        case "paragraph": tokenUnit = .paragraph
        default: tokenUnit = .word
        }
        let tokenizer = NLTokenizer(unit: tokenUnit)
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(String(text[range]))
            return true
        }
        return tokens
    }

    // ── 詞性標注（Part of Speech Tagging）───────────────────
    struct TaggedWord: Sendable {
        let word: String
        let tag: String   // Noun、Verb、Adjective 等
        let tagZH: String // 中文標注
    }

    func tagPartsOfSpeech(text: String) -> [TaggedWord] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var tagged: [TaggedWord] = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let word = String(text[range])
            let tagStr = tag?.rawValue ?? "Other"
            let tagZH = Self.tagToZH(tagStr)
            tagged.append(TaggedWord(word: word, tag: tagStr, tagZH: tagZH))
            return true
        }
        return tagged
    }

    // ── 詞形還原（Lemmatization）：取詞根原形 ──────────────────
    // 例：running→run、better→good、mice→mouse
    struct LemmatizedWord: Sendable {
        let word: String
        let lemma: String
    }

    func lemmatize(text: String) -> [LemmatizedWord] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var results: [LemmatizedWord] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            let word = String(text[range])
            let lemma = tag?.rawValue ?? word  // 若無詞根資料，回傳原字
            results.append(LemmatizedWord(word: word, lemma: lemma))
            return true
        }
        return results
    }

    private static func tagToZH(_ tag: String) -> String {
        switch tag {
        case "Noun": return "名詞"
        case "Verb": return "動詞"
        case "Adjective": return "形容詞"
        case "Adverb": return "副詞"
        case "Pronoun": return "代詞"
        case "Determiner": return "限定詞"
        case "Particle": return "助詞"
        case "Preposition": return "介詞"
        case "Number": return "數詞"
        case "Conjunction": return "連詞"
        case "Interjection": return "感嘆詞"
        case "Classifier": return "量詞"
        default: return "其他"
        }
    }
}
