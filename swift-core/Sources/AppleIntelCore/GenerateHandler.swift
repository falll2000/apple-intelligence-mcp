import Foundation
import FoundationModels

// MARK: - @Generable 結構化輸出型別（模組層級定義，供 guided generation 使用）

@Generable
struct StructuredList: Codable {
    @Guide(description: "The list of extracted or generated items") var items: [String]
}

@Generable
struct ClassificationOutput: Codable {
    @Guide(description: "The classification label or category") var label: String
    @Guide(description: "Confidence level: high, medium, or low") var confidence: String
    @Guide(description: "Brief reasoning for this classification") var reasoning: String
}

@Generable
struct SummaryOutput: Codable {
    @Guide(description: "A concise title for the content") var title: String
    @Guide(description: "A one-paragraph summary") var summary: String
    @Guide(description: "Three to five key points") var keyPoints: [String]
}

@Generable
struct ExtractionOutput: Codable {
    @Guide(description: "Extracted key-value pairs formatted as 'key: value' strings") var pairs: [String]
}

@Generable
struct QAOutput: Codable {
    @Guide(description: "The direct answer to the question") var answer: String
    @Guide(description: "Supporting evidence or reasoning for the answer") var evidence: String
}

// MARK: - Foundation Models（本地 LLM）

actor GenerateHandler {

    // MCP tool 每次呼叫都是獨立任務，不需要跨呼叫的對話記憶。
    // 每次建立新 session，避免歷史累積導致 context window 爆滿。
    private func makeSession(systemPrompt: String?) -> LanguageModelSession {
        if let system = systemPrompt, !system.isEmpty {
            return LanguageModelSession(instructions: system)
        }
        return LanguageModelSession()
    }

    func generate(prompt: String, systemPrompt: String?) async throws -> String {
        let s = makeSession(systemPrompt: systemPrompt)
        let response = try await s.respond(to: prompt)
        return response.content
    }

    // ── 結構化生成：讓 LLM 直接輸出 JSON 物件 ──────────────────
    // schema 可為：list / classify / summarize / extract / qa
    func generateStructured(prompt: String, schema: String, systemPrompt: String?) async throws -> String {
        let s = makeSession(systemPrompt: systemPrompt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        switch schema {
        case "list":
            let r = try await s.respond(to: prompt, generating: StructuredList.self)
            return String(data: try encoder.encode(r.content), encoding: .utf8) ?? "{}"
        case "classify":
            let r = try await s.respond(to: prompt, generating: ClassificationOutput.self)
            return String(data: try encoder.encode(r.content), encoding: .utf8) ?? "{}"
        case "summarize":
            let r = try await s.respond(to: prompt, generating: SummaryOutput.self)
            return String(data: try encoder.encode(r.content), encoding: .utf8) ?? "{}"
        case "extract":
            let r = try await s.respond(to: prompt, generating: ExtractionOutput.self)
            return String(data: try encoder.encode(r.content), encoding: .utf8) ?? "{}"
        case "qa":
            let r = try await s.respond(to: prompt, generating: QAOutput.self)
            return String(data: try encoder.encode(r.content), encoding: .utf8) ?? "{}"
        default:
            throw HandlerError.invalidInput("未知 schema：\(schema)。支援：list, classify, summarize, extract, qa")
        }
    }
}
