import Foundation
import CoreML
@preconcurrency import Vision

// MARK: - Vision extensions

extension VNFeaturePrintObservation: @retroactive @unchecked Sendable {}

final class ContinuationResumer<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Success, Error>

    init(_ continuation: CheckedContinuation<Success, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Success) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(throwing: error)
    }
}

struct VisionExtHandler: Sendable {

    private func loadImageData(base64: String?, path: String?) throws -> Data {
        if let b64 = base64 {
            guard let data = Data(base64Encoded: b64) else {
                throw HandlerError.invalidInput("Invalid base64 image data")
            }
            return data
        } else if let p = path {
            return try Data(contentsOf: URL(fileURLWithPath: p))
        }
        throw HandlerError.invalidInput("Provide image_base64 or image_path")
    }

    private func imageHandler(data: Data) -> VNImageRequestHandler {
        VNImageRequestHandler(data: data, options: [:])
    }

    private func imageHandler(base64: String?, path: String?) throws -> VNImageRequestHandler {
        if let p = path {
            return VNImageRequestHandler(url: URL(fileURLWithPath: p), options: [:])
        }
        return imageHandler(data: try loadImageData(base64: base64, path: nil))
    }

    private func loadModel(from path: String) throws -> MLModel {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "mlmodelc" {
            return try MLModel(contentsOf: url)
        }
        let compiledURL = try MLModel.compileModel(at: url)
        return try MLModel(contentsOf: compiledURL)
    }

    // ── Image classification: what is in this image? ─────────
    func classifyImage(base64: String? = nil, path: String? = nil) async throws -> [(label: String, confidence: Float)] {
        let handler = try imageHandler(base64: base64, path: path)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNClassifyImageRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                let results = (req.results as? [VNClassificationObservation] ?? [])
                    .filter { $0.confidence > 0.05 }
                    .prefix(10)
                    .map { (label: $0.identifier, confidence: $0.confidence) }
                resumer.resume(returning: Array(results))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Face detection: how many faces are in the image? ─────
    struct FaceResult: Sendable {
        let count: Int
        let faces: [(x: Double, y: Double, width: Double, height: Double, confidence: Float)]
    }

    func detectFaces(base64: String? = nil, path: String? = nil) async throws -> FaceResult {
        let handler = try imageHandler(base64: base64, path: path)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNDetectFaceRectanglesRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                let observations = req.results as? [VNFaceObservation] ?? []
                let faces = observations.map { obs in
                    let bb = obs.boundingBox
                    return (
                        x: Double(bb.origin.x),
                        y: Double(bb.origin.y),
                        width: Double(bb.size.width),
                        height: Double(bb.size.height),
                        confidence: obs.confidence
                    )
                }
                resumer.resume(returning: FaceResult(count: faces.count, faces: faces))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Barcode / QR code recognition ────────────────────────
    struct BarcodeResult: Sendable {
        let value: String
        let symbology: String  // QR, EAN-13, Code-128, etc.
    }

    func detectBarcodes(base64: String? = nil, path: String? = nil) async throws -> [BarcodeResult] {
        let handler = try imageHandler(base64: base64, path: path)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNDetectBarcodesRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                let results = (req.results as? [VNBarcodeObservation] ?? [])
                    .compactMap { obs -> BarcodeResult? in
                        guard let value = obs.payloadStringValue else { return nil }
                        return BarcodeResult(
                            value: value,
                            symbology: obs.symbology.rawValue
                        )
                    }
                resumer.resume(returning: results)
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Image similarity: compare visual features between two images ──
    func imageSimilarity(path1: String, path2: String) async throws -> Double {
        let data1 = try Data(contentsOf: URL(fileURLWithPath: path1))
        let data2 = try Data(contentsOf: URL(fileURLWithPath: path2))
        let feature1 = try await featurePrint(for: data1)
        let feature2 = try await featurePrint(for: data2)
        var distance: Float = 0
        try feature1.computeDistance(&distance, to: feature2)
        return Double(distance)
    }

    private func featurePrint(for imageData: Data) async throws -> VNFeaturePrintObservation {
        try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let handler = imageHandler(data: imageData)
            let request = VNGenerateImageFeaturePrintRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                guard let result = (req.results as? [VNFeaturePrintObservation])?.first else {
                    resumer.resume(throwing: HandlerError.unavailable("Could not generate image features"))
                    return
                }
                resumer.resume(returning: result)
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Object detection: requires a custom Core ML model ────
    struct ObjectDetectionResult: Sendable {
        let label: String
        let confidence: Float
        let boundingBox: (x: Double, y: Double, width: Double, height: Double)
    }

    func detectObjects(path: String, modelPath: String) async throws -> [ObjectDetectionResult] {
        let imageData = try Data(contentsOf: URL(fileURLWithPath: path))
        let mlModel = try loadModel(from: modelPath)
        let visionModel = try VNCoreMLModel(for: mlModel)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let handler = imageHandler(data: imageData)
            let request = VNCoreMLRequest(model: visionModel) { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                let observations = req.results as? [VNRecognizedObjectObservation] ?? []
                let results = observations.map { obs in
                    let label = obs.labels.first?.identifier ?? "unknown"
                    let confidence = obs.labels.first?.confidence ?? obs.confidence
                    let bb = obs.boundingBox
                    return ObjectDetectionResult(
                        label: label,
                        confidence: confidence,
                        boundingBox: (
                            x: Double(bb.origin.x),
                            y: Double(bb.origin.y),
                            width: Double(bb.size.width),
                            height: Double(bb.size.height)
                        )
                    )
                }
                resumer.resume(returning: results)
            }
            request.imageCropAndScaleOption = .scaleFill
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Contour detection: find edges and contours in an image ──
    struct ContourResult: Sendable {
        let contourCount: Int
        let pointCount: Int
        let normalizedPath: String
    }

    func detectContours(base64: String? = nil, path: String? = nil) async throws -> ContourResult {
        let handler = try imageHandler(base64: base64, path: path)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNDetectContoursRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                guard let obs = (req.results as? [VNContoursObservation])?.first else {
                    resumer.resume(returning: ContourResult(contourCount: 0, pointCount: 0, normalizedPath: ""))
                    return
                }
                let pathDescription = obs.topLevelContours.prefix(5).enumerated().map { idx, contour in
                    let points = contour.normalizedPoints.prefix(8).map { point in
                        String(format: "(%.2f,%.2f)", point.x, point.y)
                    }.joined(separator: " ")
                    return "Contour \(idx + 1): \(points)"
                }.joined(separator: "\n")
                let pointCount = obs.topLevelContours.reduce(0) { count, contour in
                    count + contour.normalizedPoints.count
                }
                resumer.resume(returning: ContourResult(
                    contourCount: obs.topLevelContourCount,
                    pointCount: pointCount,
                    normalizedPath: pathDescription
                ))
            }
            request.contrastAdjustment = 1.0
            request.detectsDarkOnLight = true
            request.maximumImageDimension = 1024
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Text region detection: find text locations without OCR ──
    struct TextRegionResult: Sendable {
        let count: Int
        let regions: [(x: Double, y: Double, width: Double, height: Double, characterBoxes: Int)]
    }

    func detectTextRegions(base64: String? = nil, path: String? = nil) async throws -> TextRegionResult {
        let handler = try imageHandler(base64: base64, path: path)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNDetectTextRectanglesRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                let observations = req.results as? [VNTextObservation] ?? []
                let regions = observations.map { obs in
                    let bb = obs.boundingBox
                    return (
                        x: Double(bb.origin.x),
                        y: Double(bb.origin.y),
                        width: Double(bb.size.width),
                        height: Double(bb.size.height),
                        characterBoxes: obs.characterBoxes?.count ?? 0
                    )
                }
                resumer.resume(returning: TextRegionResult(count: regions.count, regions: regions))
            }
            request.reportCharacterBoxes = true
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Face landmarks: eyes, nose, mouth, etc. ──────────────
    struct FaceLandmarkResult: Sendable {
        let count: Int
        let summaries: [String]
    }

    func detectFaceLandmarks(base64: String? = nil, path: String? = nil) async throws -> FaceLandmarkResult {
        let handler = try imageHandler(base64: base64, path: path)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNDetectFaceLandmarksRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                let observations = req.results as? [VNFaceObservation] ?? []
                let summaries = observations.enumerated().map { idx, obs in
                    let landmarks = obs.landmarks
                    let parts: [(String, VNFaceLandmarkRegion2D?)] = [
                        ("left eye", landmarks?.leftEye),
                        ("right eye", landmarks?.rightEye),
                        ("nose", landmarks?.nose),
                        ("outer lips", landmarks?.outerLips),
                        ("inner lips", landmarks?.innerLips),
                        ("left eyebrow", landmarks?.leftEyebrow),
                        ("right eyebrow", landmarks?.rightEyebrow),
                        ("face contour", landmarks?.faceContour)
                    ]
                    let detected = parts.compactMap { name, region in
                        guard let region else { return nil }
                        return "\(name)(\(region.pointCount) points)"
                    }.joined(separator: ", ")
                    return "Face \(idx + 1): \(detected.isEmpty ? "no landmarks" : detected)"
                }
                resumer.resume(returning: FaceLandmarkResult(count: summaries.count, summaries: summaries))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Human body region detection: find people in an image ─
    struct HumanBodyResult: Sendable {
        let count: Int
        let bodies: [(x: Double, y: Double, width: Double, height: Double, confidence: Float)]
    }

    func detectHumanBodies(base64: String? = nil, path: String? = nil, upperBodyOnly: Bool = false) async throws -> HumanBodyResult {
        let handler = try imageHandler(base64: base64, path: path)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNDetectHumanRectanglesRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                let observations = req.results as? [VNHumanObservation] ?? []
                let bodies = observations.map { obs in
                    let bb = obs.boundingBox
                    return (
                        x: Double(bb.origin.x),
                        y: Double(bb.origin.y),
                        width: Double(bb.size.width),
                        height: Double(bb.size.height),
                        confidence: obs.confidence
                    )
                }
                resumer.resume(returning: HumanBodyResult(count: bodies.count, bodies: bodies))
            }
            request.upperBodyOnly = upperBodyOnly
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Image aesthetics scoring: evaluate photo composition and quality (macOS 15+) ──
    struct AestheticsResult: Sendable {
        let overallScore: Double
        let isUtility: Bool
    }

    func scoreImageAesthetics(path: String) async throws -> AestheticsResult {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let handler = VNImageRequestHandler(data: data, options: [:])
            let request = VNCalculateImageAestheticsScoresRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                guard let obs = (req.results as? [VNImageAestheticsScoresObservation])?.first else {
                    resumer.resume(throwing: HandlerError.unavailable("Could not calculate aesthetics score"))
                    return
                }
                resumer.resume(returning: AestheticsResult(
                    overallScore: Double(obs.overallScore),
                    isUtility: obs.isUtility
                ))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Foreground instance segmentation: detect and separate subjects (macOS 14+) ──
    func segmentForegroundInstances(path: String) async throws -> (instanceCount: Int, description: String) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let handler = VNImageRequestHandler(data: data, options: [:])
            let request = VNGenerateForegroundInstanceMaskRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                guard let obs = (req.results as? [VNInstanceMaskObservation])?.first else {
                    resumer.resume(returning: (instanceCount: 0, description: "Detected 0 foreground objects"))
                    return
                }
                let count = obs.allInstances.count
                resumer.resume(returning: (
                    instanceCount: count,
                    description: "Detected \(count) foreground object instance\(count == 1 ? "" : "s") (individual masks can be generated)"
                ))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Optical flow detection: compute pixel motion vectors between two frames ──
    struct OpticalFlowResult: Sendable {
        let width: Int
        let height: Int
        let description: String
    }

    func detectOpticalFlow(referencePath: String, targetPath: String) async throws -> OpticalFlowResult {
        let referenceData = try Data(contentsOf: URL(fileURLWithPath: referencePath))
        let targetData   = try Data(contentsOf: URL(fileURLWithPath: targetPath))
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            // VNGenerateOpticalFlowRequest: targetedImage = reference frame, handler image = current frame.
            let handler = VNImageRequestHandler(data: targetData, options: [:])
            let request = VNGenerateOpticalFlowRequest(targetedImageData: referenceData, options: [:]) { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                guard let obs = (req.results as? [VNPixelBufferObservation])?.first else {
                    resumer.resume(throwing: HandlerError.unavailable("Could not calculate optical flow"))
                    return
                }
                let buf = obs.pixelBuffer
                let w = CVPixelBufferGetWidth(buf)
                let h = CVPixelBufferGetHeight(buf)
                resumer.resume(returning: OpticalFlowResult(
                    width: w, height: h,
                    description: "Optical flow field \(w)x\(h) pixels; each pixel contains a (dx,dy) motion vector (2-channel float32)"
                ))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── Horizon detection: determine whether a photo is tilted ──
    struct HorizonResult: Sendable {
        let angle: Double
        let transform: String
    }

    func detectHorizon(base64: String? = nil, path: String? = nil) async throws -> HorizonResult {
        let handler = try imageHandler(base64: base64, path: path)
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let request = VNDetectHorizonRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                guard let obs = (req.results as? [VNHorizonObservation])?.first else {
                    resumer.resume(throwing: HandlerError.unavailable("Could not detect horizon"))
                    return
                }
                let t = obs.transform
                let transform = String(
                    format: "[%.3f %.3f %.3f; %.3f %.3f %.3f]",
                    t.a, t.b, t.tx, t.c, t.d, t.ty
                )
                resumer.resume(returning: HorizonResult(angle: Double(obs.angle), transform: transform))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }
}
