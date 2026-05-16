import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// MARK: - Vision OCR（圖片文字辨識）

struct OCRHandler: Sendable {

    /// 短邊小於此值會自動 upscale。Apple Vision OCR 對小字 (<20px 高) 辨識率掉很快;
    /// 拉到 1800 經實測可顯著改善菜單/收據類 input 的字元級準度。
    private static let minSidePixels = 1800

    func recognizeText(from base64: String) async throws -> String {
        guard let imageData = Data(base64Encoded: base64) else {
            throw HandlerError.invalidInput("無效的 base64 圖片資料")
        }
        return try await recognizeText(from: imageData)
    }

    func recognizeText(fromPath path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HandlerError.invalidInput("無法解碼圖片：\(path)")
        }
        let orientation = Self.imageOrientation(source)
        let processed = Self.upscaleIfSmall(cgImage)
        let handler = VNImageRequestHandler(cgImage: processed, orientation: orientation, options: [:])
        return try await recognizeText(from: handler)
    }

    private func recognizeText(from imageData: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HandlerError.invalidInput("無法解碼圖片資料")
        }
        let orientation = Self.imageOrientation(source)
        let processed = Self.upscaleIfSmall(cgImage)
        let handler = VNImageRequestHandler(cgImage: processed, orientation: orientation, options: [:])
        return try await recognizeText(from: handler)
    }

    private static func imageOrientation(_ source: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else {
            return .up
        }
        return orientation
    }

    private static func upscaleIfSmall(_ cgImage: CGImage) -> CGImage {
        let minSide = min(cgImage.width, cgImage.height)
        if minSide >= minSidePixels { return cgImage }
        let scale = Double(minSidePixels) / Double(minSide)

        let ciImage = CIImage(cgImage: cgImage)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = ciImage
        filter.scale = Float(scale)
        filter.aspectRatio = 1.0
        guard let output = filter.outputImage else { return cgImage }
        let context = CIContext(options: nil)
        guard let result = context.createCGImage(output, from: output.extent) else { return cgImage }
        return result
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
