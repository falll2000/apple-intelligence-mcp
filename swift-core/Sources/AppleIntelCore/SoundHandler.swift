import Foundation
import SoundAnalysis

// MARK: - 聲音分類（Sound Analysis）

struct SoundHandler: Sendable {

    func classifySound(audioPath: String) async throws -> [(label: String, confidence: Double)] {
        let audioURL = URL(fileURLWithPath: audioPath)

        // SNAudioFileAnalyzer 使用 delegate pattern
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let analyzer = try SNAudioFileAnalyzer(url: audioURL)
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                let observer = SoundObserver(continuation: continuation)
                try analyzer.add(request, withObserver: observer)
                analyzer.analyze()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Sound Analysis Observer

private final class SoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {

    typealias Result = [(label: String, confidence: Double)]
    private let continuation: CheckedContinuation<Result, Error>
    private var results: Result = []
    private var resumed = false

    init(continuation: CheckedContinuation<Result, Error>) {
        self.continuation = continuation
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }
        // 收集每個時間窗口的最高分類
        if let top = classificationResult.classifications.first(where: { $0.confidence > 0.1 }) {
            let exists = results.contains { $0.label == top.identifier }
            if !exists {
                results.append((label: top.identifier, confidence: top.confidence))
            }
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }

    func requestDidComplete(_ request: SNRequest) {
        guard !resumed else { return }
        resumed = true
        // 按信心值排序
        let sorted = results.sorted { $0.confidence > $1.confidence }
        continuation.resume(returning: Array(sorted.prefix(5)))
    }
}
