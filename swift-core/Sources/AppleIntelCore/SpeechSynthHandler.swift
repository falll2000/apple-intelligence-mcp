import Foundation
import AVFoundation

// MARK: - Speech Synthesis (text -> speech, local AVSpeechSynthesizer)

struct SpeechSynthResult: Sendable {
    let outputPath: String
    let durationSeconds: Double
    let voiceUsed: String
}

struct SpeechSynthHandler: Sendable {

    /// text -> wav file. If outputPath is nil/empty, write to a temp directory and return the actual path.
    /// voice: either a voice identifier (for example `com.apple.voice.compact.zh-TW.Meijia`)
    ///        or a BCP-47 language code (for example `zh-TW`, `en-US`, `ja-JP`).
    /// rate: 0.0-1.0; nil uses the system default (~0.5).
    func synthesize(
        text: String,
        voice: String?,
        rate: Float?,
        outputPath: String?
    ) async throws -> SpeechSynthResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HandlerError.invalidInput("text must not be empty")
        }

        let outputURL: URL = {
            if let outputPath = outputPath, !outputPath.isEmpty {
                return URL(fileURLWithPath: outputPath)
            }
            let filename = "tts-\(UUID().uuidString).wav"
            return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        }()

        // Delete an existing file first; AVAudioFile(forWriting:) does not overwrite.
        try? FileManager.default.removeItem(at: outputURL)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.resolveVoice(voice)
        if let rate = rate {
            utterance.rate = rate
        }

        let writer = AudioFileWriter(url: outputURL)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumer = ContinuationResumer(continuation)
            let synthesizer = AVSpeechSynthesizer()

            // Capture synthesizer so it stays alive until callbacks complete.
            synthesizer.write(utterance) { [synthesizer] buffer in
                _ = synthesizer  // Keep alive; prevent ARC from releasing it too early.
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    resumer.resume(throwing: HandlerError.unavailable("Unsupported audio buffer type"))
                    return
                }
                if pcm.frameLength == 0 {
                    resumer.resume(returning: ())
                    return
                }
                do {
                    try writer.write(pcm)
                } catch {
                    resumer.resume(throwing: error)
                }
            }
        }

        // Release the AVAudioFile before anyone reads the path: AVFoundation only
        // finalizes the WAV header when the file object goes away. Skipping this
        // leaves a header claiming zero frames, so readers see a 0-second file.
        writer.close()

        let duration = writer.duration
        let voiceUsed = utterance.voice?.identifier ?? "default"

        return SpeechSynthResult(
            outputPath: outputURL.path,
            durationSeconds: duration,
            voiceUsed: voiceUsed
        )
    }

    /// Resolve the voice parameter: try identifier first, then BCP-47 language code, then fallback to zh-TW.
    private static func resolveVoice(_ voice: String?) -> AVSpeechSynthesisVoice? {
        if let v = voice, !v.isEmpty {
            if let resolved = AVSpeechSynthesisVoice(identifier: v) {
                return resolved
            }
            if let resolved = AVSpeechSynthesisVoice(language: v) {
                return resolved
            }
        }
        return AVSpeechSynthesisVoice(language: "zh-TW")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

// MARK: - File writer helper (buffer callbacks may arrive from multiple threads; protect with class + lock)

private final class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var file: AVAudioFile?
    private var totalFrames: AVAudioFrameCount = 0
    private var sampleRate: Double = 0

    init(url: URL) { self.url = url }

    func write(_ pcm: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        if file == nil {
            file = try AVAudioFile(
                forWriting: url,
                settings: pcm.format.settings
            )
            sampleRate = pcm.format.sampleRate
        }
        try file?.write(from: pcm)
        totalFrames += pcm.frameLength
    }

    /// Releasing the AVAudioFile is what writes the final WAV header.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }

    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }
}
