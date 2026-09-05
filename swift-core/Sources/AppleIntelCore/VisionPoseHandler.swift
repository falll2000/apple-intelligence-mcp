import Foundation
import Vision
import AVFoundation
import simd

// MARK: - Pose detection, animal recognition, geometry detection

struct VisionPoseHandler: Sendable {

    private func imageHandler(path: String) throws -> VNImageRequestHandler {
        VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
    }

    // ── Human body pose detection ────────────────────────────
    // Apple recommends using named JointName enums instead of iterating key dictionaries.
    func detectBodyPose(imagePath: String) async throws -> [[String: String]] {
        // Main joint list.
        let joints: [(VNHumanBodyPoseObservation.JointName, String)] = [
            (.nose, "nose"), (.neck, "neck"),
            (.leftShoulder, "left shoulder"), (.rightShoulder, "right shoulder"),
            (.leftElbow, "left elbow"), (.rightElbow, "right elbow"),
            (.leftWrist, "left wrist"), (.rightWrist, "right wrist"),
            (.leftHip, "left hip"), (.rightHip, "right hip"),
            (.leftKnee, "left knee"), (.rightKnee, "right knee"),
            (.leftAnkle, "left ankle"), (.rightAnkle, "right ankle"),
            (.root, "root")
        ]
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectHumanBodyPoseRequest { req, error in
                    if let error = error { resumer.resume(throwing: error); return }
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
                    resumer.resume(returning: results)
                }
                try handler.perform([request])
            } catch { resumer.resume(throwing: error) }
        }
    }

    // ── Hand pose detection ──────────────────────────────────
    // Apple recommends using named JointName enums.
    func detectHandPose(imagePath: String) async throws -> [[String: String]] {
        let joints: [(VNHumanHandPoseObservation.JointName, String)] = [
            (.wrist, "wrist"),
            (.thumbTip, "thumb tip"), (.thumbIP, "thumb IP"), (.thumbMP, "thumb MP"), (.thumbCMC, "thumb CMC"),
            (.indexTip, "index tip"), (.indexDIP, "index DIP"), (.indexPIP, "index PIP"), (.indexMCP, "index MCP"),
            (.middleTip, "middle tip"), (.middleDIP, "middle DIP"), (.middlePIP, "middle PIP"), (.middleMCP, "middle MCP"),
            (.ringTip, "ring tip"), (.ringDIP, "ring DIP"), (.ringPIP, "ring PIP"), (.ringMCP, "ring MCP"),
            (.littleTip, "little tip"), (.littleDIP, "little DIP"), (.littlePIP, "little PIP"), (.littleMCP, "little MCP")
        ]
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectHumanHandPoseRequest { req, error in
                    if let error = error { resumer.resume(throwing: error); return }
                    let observations = req.results as? [VNHumanHandPoseObservation] ?? []
                    var results: [[String: String]] = []
                    for (i, obs) in observations.enumerated() {
                        var hand: [String: String] = [
                            "hand": "\(i+1)",
                            "side": obs.chirality == .right ? "right" : obs.chirality == .left ? "left" : "unknown"
                        ]
                        for (jointName, label) in joints {
                            if let point = try? obs.recognizedPoint(jointName),
                               point.confidence > 0.3 {
                                hand[label] = String(format: "(%.2f,%.2f)", point.location.x, point.location.y)
                            }
                        }
                        results.append(hand)
                    }
                    resumer.resume(returning: results)
                }
                request.maximumHandCount = 2
                try handler.perform([request])
            } catch { resumer.resume(throwing: error) }
        }
    }

    // ── Animal recognition (cats/dogs) ───────────────────────
    struct AnimalResult: Sendable {
        let label: String   // "Cat" or "Dog"
        let confidence: Float
        let boundingBox: (x: Double, y: Double, width: Double, height: Double)
    }

    func recognizeAnimals(imagePath: String) async throws -> [AnimalResult] {
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNRecognizeAnimalsRequest { req, error in
                    if let error = error { resumer.resume(throwing: error); return }
                    let observations = req.results as? [VNRecognizedObjectObservation] ?? []
                    let results = observations.map { obs in
                        let bb = obs.boundingBox
                        return AnimalResult(
                            label: obs.labels.first?.identifier ?? "unknown",
                            confidence: obs.labels.first?.confidence ?? 0,
                            boundingBox: (x: bb.origin.x, y: bb.origin.y, width: bb.size.width, height: bb.size.height)
                        )
                    }
                    resumer.resume(returning: results)
                }
                try handler.perform([request])
            } catch { resumer.resume(throwing: error) }
        }
    }

    // ── Rectangle detection ──────────────────────────────────
    struct RectResult: Sendable {
        let x: Double; let y: Double
        let width: Double; let height: Double
        let confidence: Float
    }

    func detectRectangles(imagePath: String) async throws -> [RectResult] {
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectRectanglesRequest { req, error in
                    if let error = error { resumer.resume(throwing: error); return }
                    let results = (req.results as? [VNRectangleObservation] ?? []).map { obs in
                        RectResult(
                            x: obs.boundingBox.origin.x,
                            y: obs.boundingBox.origin.y,
                            width: obs.boundingBox.size.width,
                            height: obs.boundingBox.size.height,
                            confidence: obs.confidence
                        )
                    }
                    resumer.resume(returning: results)
                }
                request.maximumObservations = 10
                try handler.perform([request])
            } catch { resumer.resume(throwing: error) }
        }
    }

    // ── Visual saliency ──────────────────────────────────────
    // Find the regions that draw the most visual attention.
    func detectSaliency(imagePath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNGenerateAttentionBasedSaliencyImageRequest { req, error in
                    if let error = error { resumer.resume(throwing: error); return }
                    guard let obs = (req.results as? [VNSaliencyImageObservation])?.first,
                          let salientObjects = obs.salientObjects else {
                        resumer.resume(returning: "Could not detect salient regions")
                        return
                    }
                    let regions = salientObjects.map { obj in
                        String(format: "region(%.2f,%.2f) size(%.2fx%.2f)", obj.boundingBox.origin.x, obj.boundingBox.origin.y, obj.boundingBox.size.width, obj.boundingBox.size.height)
                    }
                    resumer.resume(returning: regions.joined(separator: "; "))
                }
                try handler.perform([request])
            } catch { resumer.resume(throwing: error) }
        }
    }

    // ── Person segmentation ──────────────────────────────────
    // Return whether a person exists and the coverage ratio.
    func segmentPerson(imagePath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNGeneratePersonSegmentationRequest { req, error in
                    if let error = error { resumer.resume(throwing: error); return }
                    guard let obs = (req.results as? [VNPixelBufferObservation])?.first else {
                        resumer.resume(returning: "Detected 0 people")
                        return
                    }
                    let pixelBuffer = obs.pixelBuffer
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    resumer.resume(returning: "Detected a person; mask size: \(width)x\(height) pixels")
                }
                request.qualityLevel = .balanced
                try handler.perform([request])
            } catch { resumer.resume(throwing: error) }
        }
    }

    // ── Document detection ───────────────────────────────────
    func detectDocument(imagePath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let resumer = ContinuationResumer(continuation)
            do {
                let handler = try imageHandler(path: imagePath)
                let request = VNDetectDocumentSegmentationRequest { req, error in
                    if let error = error { resumer.resume(throwing: error); return }
                    guard let obs = (req.results as? [VNRectangleObservation])?.first else {
                        resumer.resume(returning: "Detected 0 documents")
                        return
                    }
                    let bb = obs.boundingBox
                    resumer.resume(returning: String(format: "Detected document, position(%.2f,%.2f) size(%.2fx%.2f) confidence %.0f%%", bb.origin.x, bb.origin.y, bb.size.width, bb.size.height, obs.confidence * 100))
                }
                try handler.perform([request])
            } catch { resumer.resume(throwing: error) }
        }
    }

    // ── 3D human body pose detection (macOS 14+) ─────────────
    func detectBodyPose3D(imagePath: String) async throws -> [[String: String]] {
        // FIXME: Re-enable only after isolating or fixing the Vision runtime crash.
        // Tested with `arch -arm64 swift-core/.build/release/AppleIntelCore`
        // and tool `detect_body_pose_3d` on `test-assets/horizon.png`: constructing
        // and performing `VNDetectHumanBodyPose3DRequest` terminates the process
        // with uncaught `NSException` (exit -6), so Swift `do/catch` cannot recover.
        // With this guard in place, the tool returns `unavailable` and the process
        // stays alive for subsequent requests.
        // Notes from follow-up triage: ML Kit version issues, UI-thread updates, and
        // SwiftData/CoreData conflicts do not apply here because this is a macOS CLI
        // process using Apple Vision directly. The crash happens during `perform`,
        // before this code maps `recognizedPoint` values into simd coordinates.
        // Next investigation should run this request in an isolated subprocess and
        // capture the full Objective-C exception name/reason; also try `usesCPUOnly`,
        // explicit Vision request revisions, and a real full-body person image.
        // 1. Do crash containment first.
        //
        //     The root cause occurs inside handler.perform([request]) as an uncaught NSException,
        //     so the main Swift Core process cannot call it directly.
        //     Operationally, keep the unavailable guard or move VNDetectHumanBodyPose3DRequest
        //     into a separate subprocess. The goal is to prevent Vision runtime crashes from
        //     taking down the main MCP service.
        // 2. Then do root-cause investigation.
        //
        //     Re-enable the original request in an isolated test program and test:
        //     usesCPUOnly = true
        //     Specify request revision.
        //     Try a real full-body image.
        //     Capture the full Objective-C exception name/reason.
        //     Determine whether it relates to ANE/backend, image content, request revision,
        //     or the macOS Vision runtime.
        //
        // The current guard is step 1.
        // To truly fix 3D pose later, do not put the original implementation back in the main
        // process. Build an isolated probe/subprocess dedicated to VNDetectHumanBodyPose3DRequest.
        throw HandlerError.unavailable(
            "detect_body_pose_3d is temporarily disabled: Apple Vision's VNDetectHumanBodyPose3DRequest throws an Objective-C exception in this macOS/Vision runtime that Swift do/catch cannot recover from. Use mode=\"body_pose\" instead."
        )
    }

    // ── Trajectory detection (video): track parabolic objects (macOS 11+) ──
    struct TrajectoryResult: Sendable {
        let trajectoryId: Int
        let confidence: Float
        let points: String       // Normalized coordinate sequence
        let equation: String     // Parabola coefficients y = ax^2 + bx + c
    }

    func detectTrajectories(videoPath: String) async throws -> [TrajectoryResult] {
        let url = URL(fileURLWithPath: videoPath)
        let asset = AVURLAsset(url: url)

        // Load properties asynchronously.
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw HandlerError.invalidInput("Could not read video track")
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw HandlerError.unavailable("Could not read video: \(reader.error?.localizedDescription ?? "unknown")")
        }

        let sequenceHandler = VNSequenceRequestHandler()
        // trajectoryLength = minimum number of points required for a complete trajectory.
        let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 10)

        var allResults: [TrajectoryResult] = []
        var seen = Set<UUID>()
        var frameCount = 0

        while reader.status == .reading, frameCount < 300 {
            guard let sample = readerOutput.copyNextSampleBuffer(),
                  CMSampleBufferGetImageBuffer(sample) != nil else { break }
            // Hand Vision the sample buffer, not its CVPixelBuffer: trajectory
            // detection needs each frame's presentation timestamp to fit a curve
            // over time, and a bare pixel buffer carries none. Passing one fails
            // every frame with "No valid presentationTimeStamp was available".
            try sequenceHandler.perform([request], on: sample)
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
