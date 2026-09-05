import Foundation
import Speech

// MARK: - Speech transcription

struct TranscribeHandler: Sendable {

    func transcribe(audioPath: String, language: String = "zh-TW") async throws -> String {
        let audioURL = URL(fileURLWithPath: audioPath)

        // Request speech recognition authorization.
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }

        guard status == .authorized else {
            throw HandlerError.permissionDenied("Speech recognition requires user authorization. Enable it in System Settings.")
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else {
            throw HandlerError.unavailable("Speech recognition is not available for language \(language)")
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        // SFSpeechRecognizer can invoke this callback more than once (a final result
        // followed by an error, or an error after cancellation). Guard the continuation
        // so a second resume does not trap and kill the whole Core Service process.
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    resumer.resume(throwing: error)
                    return
                }
                if let result = result, result.isFinal {
                    resumer.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}
