import Foundation
import FoundationModels

// MARK: - @Generable structured output types (module-level definitions for guided generation)

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

// MARK: - Foundation Models (local LLM)

actor GenerateHandler {
    // Each MCP tool call is independent; no cross-call conversation memory is needed.
    // Create a new session each time to avoid context window growth.
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

    // ── Structured generation: have the LLM output JSON objects directly ──
    // Supported schemas: list / classify / summarize / extract / qa
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
            throw HandlerError.invalidInput("Unknown schema: \(schema). Supported schemas: list, classify, summarize, extract, qa")
        }
    }
}
