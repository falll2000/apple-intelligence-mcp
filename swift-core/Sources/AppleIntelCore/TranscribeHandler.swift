import Foundation
import Speech

// MARK: - Speech 語音轉文字

struct TranscribeHandler: Sendable {

    func transcribe(audioPath: String, language: String = "zh-TW") async throws -> String {
        let audioURL = URL(fileURLWithPath: audioPath)

        // 請求語音辨識授權
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }

        guard status == .authorized else {
            throw HandlerError.permissionDenied("語音辨識需要使用者授權，請在系統設定中允許")
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else {
            throw HandlerError.unavailable("語言 \(language) 的語音辨識不可用")
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                if let result = result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}
