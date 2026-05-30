import Foundation
import NaturalLanguage

// MARK: - Advanced NL features (tokenization, part-of-speech tagging)

struct NLAdvancedHandler: Sendable {

    // ── Tokenization ─────────────────────────────────────────
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

    // ── Part-of-speech tagging ───────────────────────────────
    struct TaggedWord: Sendable {
        let word: String
        let tag: String   // Noun, Verb, Adjective, etc.
        let tagZH: String // Normalized English label kept for backward compatibility.
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

    // ── Lemmatization: reduce words to base forms ────────────
    // Examples: running->run, better->good, mice->mouse
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
            let lemma = tag?.rawValue ?? word  // Return the original word when lemma data is unavailable.
            results.append(LemmatizedWord(word: word, lemma: lemma))
            return true
        }
        return results
    }

    private static func tagToZH(_ tag: String) -> String {
        switch tag {
        case "Noun": return "noun"
        case "Verb": return "verb"
        case "Adjective": return "adjective"
        case "Adverb": return "adverb"
        case "Pronoun": return "pronoun"
        case "Determiner": return "determiner"
        case "Particle": return "particle"
        case "Preposition": return "preposition"
        case "Number": return "number"
        case "Conjunction": return "conjunction"
        case "Interjection": return "interjection"
        case "Classifier": return "classifier"
        default: return "other"
        }
    }
}
