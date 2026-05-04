import Foundation
import Vision

// MARK: - Vision OCR（圖片文字辨識）

struct OCRHandler: Sendable {

    func recognizeText(from base64: String) async throws -> String {
        guard let imageData = Data(base64Encoded: base64) else {
            throw HandlerError.invalidInput("無效的 base64 圖片資料")
        }
        return try await recognizeText(from: imageData)
    }

    func recognizeText(fromPath path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        return try await recognizeText(from: VNImageRequestHandler(url: url, options: [:]))
    }

    private func recognizeText(from imageData: Data) async throws -> String {
        return try await recognizeText(from: VNImageRequestHandler(data: imageData, options: [:]))
    }

    private func recognizeText(from requestHandler: VNImageRequestHandler) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    resumer.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { obs in
                    obs.topCandidates(1).first?.string
                }
                resumer.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hant", "zh-Hans", "en-US", "ja", "ko"]

            do {
                try requestHandler.perform([request])
            } catch {
                resumer.resume(throwing: error)
            }
        }
    }
}
