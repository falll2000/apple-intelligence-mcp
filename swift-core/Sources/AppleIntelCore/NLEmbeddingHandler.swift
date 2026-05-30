import Foundation
import NaturalLanguage

// MARK: - Semantic similarity (Word & Sentence Embedding)

struct NLEmbeddingHandler: Sendable {

    // ── Word similarity ──────────────────────────────────────
    // Check whether words are in the vocabulary first (Apple's recommended pattern), then compute distance.
    // Returns 0.0 (completely different) to 1.0 (identical).
    func wordSimilarity(word1: String, word2: String, language: String = "en") -> Double? {
        let lang = NLLanguage(rawValue: language)
        guard let embedding = NLEmbedding.wordEmbedding(for: lang) else { return nil }
        let w1 = word1.lowercased()
        let w2 = word2.lowercased()
        // vector(for:) returns Optional and is the standard way to check vocabulary membership.
        guard embedding.vector(for: w1) != nil,
              embedding.vector(for: w2) != nil else { return nil }
        let dist = embedding.distance(between: w1, and: w2)
        return max(0.0, 1.0 - dist / 2.0)
    }

    // ── Sentence similarity ──────────────────────────────────
    // Returns 0.0 (completely different) to 1.0 (identical).
    func sentenceSimilarity(sentence1: String, sentence2: String, language: String = "en") -> Double? {
        let lang = NLLanguage(rawValue: language)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: lang) else { return nil }
        // Sentence embeddings do not require vocabulary checks; compute directly.
        let dist = embedding.distance(between: sentence1, and: sentence2)
        return max(0.0, 1.0 - dist / 2.0)
    }

    // ── Word nearest neighbors ───────────────────────────────
    func nearestWords(to word: String, count: Int = 5, language: String = "en") -> [String] {
        let lang = NLLanguage(rawValue: language)
        guard let embedding = NLEmbedding.wordEmbedding(for: lang) else { return [] }
        return embedding.neighbors(for: word.lowercased(), maximumCount: count).map { $0.0 }
    }
}
