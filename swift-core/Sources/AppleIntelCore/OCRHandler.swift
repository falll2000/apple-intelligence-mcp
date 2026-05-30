import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

// MARK: - Vision OCR (image text recognition)

struct OCRHandler: Sendable {

    /// Images with a short side below this value are upscaled automatically.
    /// Apple Vision OCR accuracy drops quickly for small text (<20px high);
    /// 1800 was measured to improve character-level accuracy for menus/receipts.
    private static let minSidePixels = 1800

    func recognizeText(from base64: String) async throws -> String {
        guard let imageData = Data(base64Encoded: base64) else {
            throw HandlerError.invalidInput("Invalid base64 image data")
        }
        return try await recognizeText(from: imageData)
    }

    func recognizeText(fromPath path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HandlerError.invalidInput("Could not decode image: \(path)")
        }
        let orientation = Self.imageOrientation(source)
        let processed = Self.upscaleIfSmall(cgImage)
        let handler = VNImageRequestHandler(cgImage: processed, orientation: orientation, options: [:])
        return try await recognizeText(from: handler)
    }

    private func recognizeText(from imageData: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HandlerError.invalidInput("Could not decode image data")
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
