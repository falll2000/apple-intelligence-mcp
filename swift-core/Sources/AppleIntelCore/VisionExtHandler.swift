import Foundation
import CoreML
@preconcurrency import Vision

// MARK: - Vision 擴充功能

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
                throw HandlerError.invalidInput("無效的 base64 圖片資料")
            }
            return data
        } else if let p = path {
            return try Data(contentsOf: URL(fileURLWithPath: p))
        }
        throw HandlerError.invalidInput("需要提供 image_base64 或 image_path")
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

    // ── 圖片分類：這張圖片裡有什麼？ ─────────────────────────────
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

    // ── 人臉偵測：圖片裡有幾張臉？ ──────────────────────────────
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

    // ── 條碼 / QR Code 辨識 ───────────────────────────────────
    struct BarcodeResult: Sendable {
        let value: String
        let symbology: String  // QR、EAN-13、Code-128 等
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

    // ── 圖片相似度：比較兩張圖片的視覺特徵 ─────────────────────
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
                    resumer.resume(throwing: HandlerError.unavailable("無法產生圖片特徵"))
                    return
                }
                resumer.resume(returning: result)
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── 物件偵測：需要自訂 Core ML 模型 ─────────────────────────
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

    // ── 輪廓偵測：抓圖片中的邊緣與輪廓 ─────────────────────────
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
                    return "輪廓\(idx + 1)：\(points)"
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

    // ── 文字區域偵測：先找出文字位置，不做 OCR ───────────────────
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

    // ── 臉部特徵點：眼睛、鼻子、嘴巴等 ─────────────────────────
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
                        ("左眼", landmarks?.leftEye),
                        ("右眼", landmarks?.rightEye),
                        ("鼻子", landmarks?.nose),
                        ("外嘴唇", landmarks?.outerLips),
                        ("內嘴唇", landmarks?.innerLips),
                        ("左眉", landmarks?.leftEyebrow),
                        ("右眉", landmarks?.rightEyebrow),
                        ("臉部輪廓", landmarks?.faceContour)
                    ]
                    let detected = parts.compactMap { name, region in
                        guard let region else { return nil }
                        return "\(name)(\(region.pointCount)點)"
                    }.joined(separator: "、")
                    return "臉\(idx + 1)：\(detected.isEmpty ? "無特徵點" : detected)"
                }
                resumer.resume(returning: FaceLandmarkResult(count: summaries.count, summaries: summaries))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── 人體區域偵測：找出圖片裡的人 ───────────────────────────
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

    // ── 圖片美學評分：評估照片構圖與質量（macOS 15+）──────────
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
                    resumer.resume(throwing: HandlerError.unavailable("無法計算美學分數"))
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

    // ── 前景實例分割：偵測並分離各個主體（macOS 14+）───────────
    func segmentForegroundInstances(path: String) async throws -> (instanceCount: Int, description: String) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            let handler = VNImageRequestHandler(data: data, options: [:])
            let request = VNGenerateForegroundInstanceMaskRequest { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                guard let obs = (req.results as? [VNInstanceMaskObservation])?.first else {
                    resumer.resume(returning: (instanceCount: 0, description: "未偵測到前景物件"))
                    return
                }
                let count = obs.allInstances.count
                resumer.resume(returning: (
                    instanceCount: count,
                    description: "偵測到 \(count) 個前景物件實例（可個別產生去背遮罩）"
                ))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── 光流偵測：計算兩幀之間的像素移動向量 ───────────────────
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
            // VNGenerateOpticalFlowRequest：targetedImage = 參考幀，handler 的 image = 當前幀
            let handler = VNImageRequestHandler(data: targetData, options: [:])
            let request = VNGenerateOpticalFlowRequest(targetedImageData: referenceData, options: [:]) { req, error in
                if let error = error { resumer.resume(throwing: error); return }
                guard let obs = (req.results as? [VNPixelBufferObservation])?.first else {
                    resumer.resume(throwing: HandlerError.unavailable("無法計算光流"))
                    return
                }
                let buf = obs.pixelBuffer
                let w = CVPixelBufferGetWidth(buf)
                let h = CVPixelBufferGetHeight(buf)
                resumer.resume(returning: OpticalFlowResult(
                    width: w, height: h,
                    description: "光流場 \(w)×\(h) 像素，每像素含 (dx,dy) 移動向量（2 通道 float32）"
                ))
            }
            do { try handler.perform([request]) }
            catch { resumer.resume(throwing: error) }
        }
    }

    // ── 地平線偵測：找出照片是否傾斜 ───────────────────────────
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
                    resumer.resume(throwing: HandlerError.unavailable("無法偵測地平線"))
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
