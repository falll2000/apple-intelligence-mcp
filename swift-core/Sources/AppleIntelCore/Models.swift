import Foundation

// MARK: - IPC 協議定義（stdin/stdout JSON line protocol）

struct IPCRequest: Codable, Sendable {
    let id: String
    let tool: String
    let params: [String: JSONValue]
}

struct IPCResponse: Codable, Sendable {
    let id: String
    let success: Bool
    let result: [String: JSONValue]?
    let error: String?

    static func ok(id: String, result: [String: JSONValue]) -> IPCResponse {
        IPCResponse(id: id, success: true, result: result, error: nil)
    }

    static func fail(id: String, error: String) -> IPCResponse {
        IPCResponse(id: id, success: false, result: nil, error: error)
    }
}

// MARK: - 通用 JSON 值型別（處理任意 JSON 參數）

enum JSONValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        }
    }
}
