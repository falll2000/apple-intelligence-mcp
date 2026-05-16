import Foundation
import AVFoundation

// MARK: - Speech Synthesis（文字 → 語音，本地 AVSpeechSynthesizer）

struct SpeechSynthResult: Sendable {
    let outputPath: String
    let durationSeconds: Double
    let voiceUsed: String
}

struct SpeechSynthHandler: Sendable {

    /// text → wav 檔。若 outputPath 為 nil/空,寫到暫存目錄並回傳實際路徑。
    /// voice: 可填 voice identifier (例 `com.apple.voice.compact.zh-TW.Meijia`)
    ///        或 BCP-47 語言碼 (例 `zh-TW`, `en-US`, `ja-JP`)。
    /// rate: 0.0–1.0,nil 用系統預設 (~0.5)。
    func synthesize(
        text: String,
        voice: String?,
        rate: Float?,
        outputPath: String?
    ) async throws -> SpeechSynthResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HandlerError.invalidInput("text 不可為空")
        }

        let outputURL: URL = {
            if let outputPath = outputPath, !outputPath.isEmpty {
                return URL(fileURLWithPath: outputPath)
            }
            let filename = "tts-\(UUID().uuidString).wav"
            return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        }()

        // 若已存在則先刪,AVAudioFile(forWriting:) 不接受覆寫
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

            // 透過 capture list 把 synthesizer 帶進 closure,確保它活到 callback 完成
            synthesizer.write(utterance) { [synthesizer] buffer in
                _ = synthesizer  // 強制保活,避免 ARC 提早釋放
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    resumer.resume(throwing: HandlerError.unavailable("不支援的音訊 buffer 型別"))
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

        let duration = writer.duration
        let voiceUsed = utterance.voice?.identifier ?? "default"

        return SpeechSynthResult(
            outputPath: outputURL.path,
            durationSeconds: duration,
            voiceUsed: voiceUsed
        )
    }

    /// 解析 voice 參數:先試 identifier,失敗試 BCP-47 語言碼,再失敗 fallback zh-TW。
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

// MARK: - 寫檔 helper(buffer callback 跨執行緒可能被多次呼叫,用 class + lock 保護)

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

    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }
}
