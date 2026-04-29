import Foundation

enum HandlerError: Error, LocalizedError {
    case invalidInput(String)
    case permissionDenied(String)
    case unavailable(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return "輸入錯誤：\(msg)"
        case .permissionDenied(let msg): return "權限不足：\(msg)"
        case .unavailable(let msg): return "功能不可用：\(msg)"
        case .unknown(let msg): return "未知錯誤：\(msg)"
        }
    }
}
