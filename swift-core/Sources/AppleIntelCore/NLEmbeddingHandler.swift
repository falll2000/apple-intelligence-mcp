import Foundation
import NaturalLanguage

// MARK: - 語意相似度（Word & Sentence Embedding）

struct NLEmbeddingHandler: Sendable {

    // ── 詞語相似度 ────────────────────────────────────────────
    // 先確認詞語在詞彙表內（官方建議做法），再計算距離
    // 回傳 0.0（完全不同）到 1.0（完全相同）
    func wordSimilarity(word1: String, word2: String, language: String = "en") -> Double? {
        let lang = NLLanguage(rawValue: language)
        guard let embedding = NLEmbedding.wordEmbedding(for: lang) else { return nil }
        let w1 = word1.lowercased()
        let w2 = word2.lowercased()
        // vector(for:) 回傳 Optional，是確認詞語是否在詞彙表的標準方式
        guard embedding.vector(for: w1) != nil,
              embedding.vector(for: w2) != nil else { return nil }
        let dist = embedding.distance(between: w1, and: w2)
        return max(0.0, 1.0 - dist / 2.0)
    }

    // ── 句子相似度 ────────────────────────────────────────────
    // 回傳 0.0（完全不同）到 1.0（完全相同）
    func sentenceSimilarity(sentence1: String, sentence2: String, language: String = "en") -> Double? {
        let lang = NLLanguage(rawValue: language)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: lang) else { return nil }
        // 句子嵌入不需要詞彙表確認，直接計算
        let dist = embedding.distance(between: sentence1, and: sentence2)
        return max(0.0, 1.0 - dist / 2.0)
    }

    // ── 最相近的詞（Word Nearest Neighbors）─────────────────
    func nearestWords(to word: String, count: Int = 5, language: String = "en") -> [String] {
        let lang = NLLanguage(rawValue: language)
        guard let embedding = NLEmbedding.wordEmbedding(for: lang) else { return [] }
        return embedding.neighbors(for: word.lowercased(), maximumCount: count).map { $0.0 }
    }
}
