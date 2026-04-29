import Foundation
import Vision
import AVFoundation
import simd

// MARK: - 姿態偵測、動物辨識、幾何偵測

struct VisionPoseHandler: Sendable {

    private func imageHandler(path: String) throws -> VNImageRequestHandler {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return VNImageRequestHandler(data: data, options: [:])
    }

    // ── 人體姿態偵測（Body Pose）────────────────────────────
    // 官方建議：用具名 JointName enum，不迭代 key dictionary
    func detectBodyPose(imagePath: String) async throws -> [[String: String]] {
        // 主要關節點清單
        let joints: [(VNHumanBodyPoseObservation.JointName, String)] = [
            (.nose, "鼻子"), (.neck, "頸部"),
            (.leftShoulder, "左肩"), (.rightShoulder, "右肩"),
            (.leftElbow, "左手肘"), (.rightElbow, "右手肘"),
            (.leftWrist, "左手腕"), (.rightWrist, "右手腕"),
            (.leftHip, "左髖"), (.rightHip, "右髖"),
            (.leftKnee, "左膝"), (.rightKnee, "右膝"),
            (.leftAnkle, "左腳踝"), (.rightAnkle, "右腳踝"),
            (.root, "重心")
        ]
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectHumanBodyPoseRequest { req, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    let observations = req.results as? [VNHumanBodyPoseObservation] ?? []
                    var results: [[String: String]] = []
                    for (i, obs) in observations.enumerated() {
                        var person: [String: String] = ["person": "\(i+1)"]
                        for (jointName, label) in joints {
                            if let point = try? obs.recognizedPoint(jointName),
                               point.confidence > 0.3 {
                                person[label] = String(format: "(%.2f,%.2f)", point.location.x, point.location.y)
                            }
                        }
                        results.append(person)
                    }
                    continuation.resume(returning: results)
                }
                try handler.perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    // ── 手部姿態偵測（Hand Pose）────────────────────────────
    // 官方建議：用具名 JointName enum
    func detectHandPose(imagePath: String) async throws -> [[String: String]] {
        let joints: [(VNHumanHandPoseObservation.JointName, String)] = [
            (.wrist, "手腕"),
            (.thumbTip, "拇指尖"), (.thumbIP, "拇指IP"), (.thumbMP, "拇指MP"), (.thumbCMC, "拇指CMC"),
            (.indexTip, "食指尖"), (.indexDIP, "食指DIP"), (.indexPIP, "食指PIP"), (.indexMCP, "食指MCP"),
            (.middleTip, "中指尖"), (.middleDIP, "中指DIP"), (.middlePIP, "中指PIP"), (.middleMCP, "中指MCP"),
            (.ringTip, "無名指尖"), (.ringDIP, "無名指DIP"), (.ringPIP, "無名指PIP"), (.ringMCP, "無名指MCP"),
            (.littleTip, "小指尖"), (.littleDIP, "小指DIP"), (.littlePIP, "小指PIP"), (.littleMCP, "小指MCP")
        ]
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectHumanHandPoseRequest { req, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    let observations = req.results as? [VNHumanHandPoseObservation] ?? []
                    var results: [[String: String]] = []
                    for (i, obs) in observations.enumerated() {
                        var hand: [String: String] = [
                            "hand": "\(i+1)",
                            "side": obs.chirality == .right ? "右手" : obs.chirality == .left ? "左手" : "未知"
                        ]
                        for (jointName, label) in joints {
                            if let point = try? obs.recognizedPoint(jointName),
                               point.confidence > 0.3 {
                                hand[label] = String(format: "(%.2f,%.2f)", point.location.x, point.location.y)
                            }
                        }
                        results.append(hand)
                    }
                    continuation.resume(returning: results)
                }
                request.maximumHandCount = 2
                try handler.perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    // ── 動物辨識（貓狗）────────────────────────────────────
    struct AnimalResult: Sendable {
        let label: String   // "Cat" or "Dog"
        let confidence: Float
        let boundingBox: (x: Double, y: Double, width: Double, height: Double)
    }

    func recognizeAnimals(imagePath: String) async throws -> [AnimalResult] {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNRecognizeAnimalsRequest { req, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    let observations = req.results as? [VNRecognizedObjectObservation] ?? []
                    let results = observations.map { obs in
                        let bb = obs.boundingBox
                        return AnimalResult(
                            label: obs.labels.first?.identifier ?? "unknown",
                            confidence: obs.labels.first?.confidence ?? 0,
                            boundingBox: (x: bb.origin.x, y: bb.origin.y, width: bb.size.width, height: bb.size.height)
                        )
                    }
                    continuation.resume(returning: results)
                }
                try handler.perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    // ── 矩形偵測（Rectangle Detection）─────────────────────
    struct RectResult: Sendable {
        let x: Double; let y: Double
        let width: Double; let height: Double
        let confidence: Float
    }

    func detectRectangles(imagePath: String) async throws -> [RectResult] {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectRectanglesRequest { req, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    let results = (req.results as? [VNRectangleObservation] ?? []).map { obs in
                        RectResult(
                            x: obs.boundingBox.origin.x,
                            y: obs.boundingBox.origin.y,
                            width: obs.boundingBox.size.width,
                            height: obs.boundingBox.size.height,
                            confidence: obs.confidence
                        )
                    }
                    continuation.resume(returning: results)
                }
                request.maximumObservations = 10
                try handler.perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    // ── 視覺顯著性（Saliency）───────────────────────────────
    // 找出圖片中最吸引視線的區域
    func detectSaliency(imagePath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNGenerateAttentionBasedSaliencyImageRequest { req, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    guard let obs = (req.results as? [VNSaliencyImageObservation])?.first,
                          let salientObjects = obs.salientObjects else {
                        continuation.resume(returning: "無法偵測顯著區域")
                        return
                    }
                    let regions = salientObjects.map { obj in
                        String(format: "區域(%.2f,%.2f)大小(%.2fx%.2f)", obj.boundingBox.origin.x, obj.boundingBox.origin.y, obj.boundingBox.size.width, obj.boundingBox.size.height)
                    }
                    continuation.resume(returning: regions.joined(separator: "；"))
                }
                try handler.perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    // ── 人像去背（Person Segmentation）──────────────────────
    // 回傳是否有人，以及覆蓋面積比例
    func segmentPerson(imagePath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNGeneratePersonSegmentationRequest { req, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    guard let obs = (req.results as? [VNPixelBufferObservation])?.first else {
                        continuation.resume(returning: "未偵測到人物")
                        return
                    }
                    let pixelBuffer = obs.pixelBuffer
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    continuation.resume(returning: "偵測到人物，遮罩尺寸：\(width)×\(height) 像素")
                }
                request.qualityLevel = .balanced
                try handler.perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    // ── 文件偵測（Document Detection）──────────────────────
    func detectDocument(imagePath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectDocumentSegmentationRequest { req, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    guard let obs = (req.results as? [VNRectangleObservation])?.first else {
                        continuation.resume(returning: "未偵測到文件")
                        return
                    }
                    let bb = obs.boundingBox
                    continuation.resume(returning: String(format: "偵測到文件，位置(%.2f,%.2f) 大小(%.2fx%.2f) 信心%.0f%%", bb.origin.x, bb.origin.y, bb.size.width, bb.size.height, obs.confidence * 100))
                }
                try handler.perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    // ── 3D 人體姿態偵測（macOS 14+）────────────────────────────
    func detectBodyPose3D(imagePath: String) async throws -> [[String: String]] {
        let joints: [(VNHumanBodyPose3DObservation.JointName, String)] = [
            (.centerHead, "頭中心"), (.topHead, "頭頂"),
            (.leftShoulder, "左肩"), (.rightShoulder, "右肩"),
            (.leftElbow, "左手肘"), (.rightElbow, "右手肘"),
            (.leftWrist, "左手腕"), (.rightWrist, "右手腕"),
            (.root, "重心"),
            (.leftHip, "左髖"), (.rightHip, "右髖"),
            (.leftKnee, "左膝"), (.rightKnee, "右膝"),
            (.leftAnkle, "左腳踝"), (.rightAnkle, "右腳踝")
        ]
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectHumanBodyPose3DRequest { req, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    let observations = req.results as? [VNHumanBodyPose3DObservation] ?? []
                    var results: [[String: String]] = []
                    for (i, obs) in observations.enumerated() {
                        var person: [String: String] = ["person": "\(i + 1)"]
                        for (jointName, label) in joints {
                            if let point = try? obs.recognizedPoint(jointName) {
                                // 從 4×4 世界座標矩陣取平移向量（最後一列）
                                let col = point.position.columns.3
                                person[label] = String(format: "(%.2f,%.2f,%.2f)", col.x, col.y, col.z)
                            }
                        }
                        results.append(person)
                    }
                    continuation.resume(returning: results)
                }
                try handler.perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    // ── 軌跡偵測（視訊）：追蹤拋物線物體（macOS 11+）──────────
    struct TrajectoryResult: Sendable {
        let trajectoryId: Int
        let confidence: Float
        let points: String       // 正規化座標序列
        let equation: String     // 拋物線係數 y = ax² + bx + c
    }

    func detectTrajectories(videoPath: String) async throws -> [TrajectoryResult] {
        let url = URL(fileURLWithPath: videoPath)
        let asset = AVURLAsset(url: url)

        // 非同步載入屬性
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw HandlerError.invalidInput("無法讀取影片視訊軌道")
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw HandlerError.unavailable("無法讀取影片：\(reader.error?.localizedDescription ?? "unknown")")
        }

        let sequenceHandler = VNSequenceRequestHandler()
        // trajectoryLength = 至少需幾個點才算完整軌跡
        let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 10)

        var allResults: [TrajectoryResult] = []
        var seen = Set<UUID>()
        var frameCount = 0

        while reader.status == .reading, frameCount < 300 {
            guard let sample = readerOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { break }
            try sequenceHandler.perform([request], on: pixelBuffer)
            if let observations = request.results {
                for obs in observations where !seen.contains(obs.uuid) {
                    seen.insert(obs.uuid)
                    let pts = obs.detectedPoints.prefix(8).map {
                        String(format: "(%.2f,%.2f)", $0.x, $0.y)
                    }.joined(separator: "→")
                    let eq = obs.equationCoefficients
                    allResults.append(TrajectoryResult(
                        trajectoryId: allResults.count + 1,
                        confidence: obs.confidence,
                        points: pts,
                        equation: String(format: "y=%.3fx²+%.3fx+%.3f", eq.x, eq.y, eq.z)
                    ))
                }
            }
            frameCount += 1
        }
        reader.cancelReading()
        return allResults
    }
}
