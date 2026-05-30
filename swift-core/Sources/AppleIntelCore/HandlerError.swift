import Foundation

enum HandlerError: Error, LocalizedError {
    case invalidInput(String)
    case permissionDenied(String)
    case unavailable(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return "Invalid input: \(msg)"
        case .permissionDenied(let msg): return "Permission denied: \(msg)"
        case .unavailable(let msg): return "Feature unavailable: \(msg)"
        case .unknown(let msg): return "Unknown error: \(msg)"
        }
    }
}
