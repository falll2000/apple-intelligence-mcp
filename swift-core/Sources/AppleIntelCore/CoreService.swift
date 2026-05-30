import Foundation
import FoundationModels
import AVFoundation

// MARK: - Apple Intelligence MCP Core Service
// Communicates with the Python MCP server via a stdin/stdout JSON line protocol.

struct CoreService {

    static func run() async {
        let generateHandler = GenerateHandler()  // Actor; initialization does not require await.
        let ocrHandler = OCRHandler()
        let analyzeHandler = AnalyzeHandler()
        let transcribeHandler = TranscribeHandler()
        let translateHandler = TranslateHandler()
        let visionExtHandler = VisionExtHandler()
        let nlEmbeddingHandler = NLEmbeddingHandler()
        let soundHandler = SoundHandler()
        let visionPoseHandler = VisionPoseHandler()
        let nlAdvancedHandler = NLAdvancedHandler()
        let speechSynthHandler = SpeechSynthHandler()
        let writingToolsHandler = WritingToolsHandler()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Notify the Python server that the service is ready.
        fputs("{\"status\":\"ready\",\"version\":\"1.0.0\"}\n", stdout)
        fflush(stdout)

        // Main loop: keep reading stdin, one JSON request per line.
        while let line = readLine() {
            guard !line.isEmpty else { continue }

            let response: IPCResponse
            var requestId = "unknown"

            do {
                guard let data = line.data(using: .utf8) else { continue }
                let request = try decoder.decode(IPCRequest.self, from: data)
                requestId = request.id
                response = try await handleRequest(
                    request,
                    generate: generateHandler,
                    ocr: ocrHandler,
                    translate: translateHandler,
                    analyze: analyzeHandler,
                    transcribe: transcribeHandler,
                    visionExt: visionExtHandler,
                    nlEmbedding: nlEmbeddingHandler,
                    sound: soundHandler,
                    visionPose: visionPoseHandler,
                    nlAdvanced: nlAdvancedHandler,
                    speechSynth: speechSynthHandler,
                    writingTools: writingToolsHandler
                )
            } catch {
                let fallback = IPCResponse.fail(id: requestId, error: error.localizedDescription)
                if let data = try? encoder.encode(fallback),
                   let json = String(data: data, encoding: .utf8) {
                    print(json)
                    fflush(stdout)
                }
                continue
            }

            if let data = try? encoder.encode(response),
               let json = String(data: data, encoding: .utf8) {
                print(json)
                fflush(stdout)
            }
        }
    }

    // MARK: - Request routing

    static func handleRequest(
        _ request: IPCRequest,
        generate: GenerateHandler,
        ocr: OCRHandler,
        translate: TranslateHandler,
        analyze: AnalyzeHandler,
        transcribe: TranscribeHandler,
        visionExt: VisionExtHandler,
        nlEmbedding: NLEmbeddingHandler,
        sound: SoundHandler,
        visionPose: VisionPoseHandler,
        nlAdvanced: NLAdvancedHandler,
        speechSynth: SpeechSynthHandler,
        writingTools: WritingToolsHandler
    ) async throws -> IPCResponse {
        switch request.tool {

        case "generate_text":
            guard let prompt = request.params["prompt"]?.stringValue else {
                return .fail(id: request.id, error: "Missing required parameter: prompt")
            }
            let system = request.params["system_prompt"]?.stringValue
            let text = try await generate.generate(prompt: prompt, systemPrompt: system)
            return .ok(id: request.id, result: ["text": .string(text)])

        case "ocr_image":
            if let base64 = request.params["image_base64"]?.stringValue {
                let text = try await ocr.recognizeText(from: base64)
                return .ok(id: request.id, result: ["text": .string(text)])
            } else if let path = request.params["image_path"]?.stringValue {
                let text = try await ocr.recognizeText(fromPath: path)
                return .ok(id: request.id, result: ["text": .string(text)])
            } else {
                return .fail(id: request.id, error: "Provide image_base64 or image_path")
            }

        case "translate_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing required parameter: text")
            }
            let from = request.params["from"]?.stringValue ?? "auto"
            let to = request.params["to"]?.stringValue ?? "zh-Hant"
            let result = try await translate.translate(text: text, from: from, to: to)
            return .ok(id: request.id, result: ["text": .string(result)])

        case "analyze_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing required parameter: text")
            }
            let sentiment = analyze.analyzeSentiment(text: text)
            let language = analyze.detectLanguage(text: text)
            let keywords = analyze.extractKeywords(text: text)
            let entities = analyze.extractEntities(text: text)

            let sentimentLabel: String
            if sentiment > 0.2 { sentimentLabel = "positive" }
            else if sentiment < -0.2 { sentimentLabel = "negative" }
            else { sentimentLabel = "neutral" }

            return .ok(id: request.id, result: [
                "sentiment_score": .double(sentiment),
                "sentiment_label": .string(sentimentLabel),
                "language": .string(language),
                "keywords": .string(keywords.joined(separator: ", ")),
                "entities_person": .string((entities["person"] ?? []).joined(separator: ", ")),
                "entities_place": .string((entities["place"] ?? []).joined(separator: ", ")),
                "entities_org": .string((entities["organization"] ?? []).joined(separator: ", "))
            ])

        case "transcribe_audio":
            guard let path = request.params["audio_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing required parameter: audio_path")
            }
            let language = request.params["language"]?.stringValue ?? "zh-TW"
            let text = try await transcribe.transcribe(audioPath: path, language: language)
            return .ok(id: request.id, result: ["text": .string(text)])

        // ── classify_image: image content classification ──
        case "classify_image":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let results = try await visionExt.classifyImage(base64: base64, path: path)
            let labels = results.map { "\($0.label) (\(String(format: "%.0f", $0.confidence * 100))%)" }
            return .ok(id: request.id, result: [
                "labels": .string(labels.joined(separator: ", ")),
                "top": .string(results.first?.label ?? "unknown")
            ])

        // ── detect_faces: face detection ──
        case "detect_faces":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectFaces(base64: base64, path: path)
            let faceList = result.faces.enumerated().map { i, f in
                "Face \(i + 1): position(\(String(format: "%.2f", f.x)),\(String(format: "%.2f", f.y))) size(\(String(format: "%.2f", f.width))x\(String(format: "%.2f", f.height))) confidence \(String(format: "%.0f", Double(f.confidence) * 100))%"
            }
            return .ok(id: request.id, result: [
                "count": .int(result.count),
                "faces": .string(faceList.joined(separator: "\n")),
                "summary": .string(result.count == 0 ? "Detected 0 faces" : "Detected \(result.count) face\(result.count == 1 ? "" : "s")")
            ])

        // ── detect_barcodes: barcode / QR code recognition ──
        case "detect_barcodes":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let results = try await visionExt.detectBarcodes(base64: base64, path: path)
            let list = results.map { "\($0.symbology): \($0.value)" }
            return .ok(id: request.id, result: [
                "count": .int(results.count),
                "barcodes": .string(list.joined(separator: "\n")),
                "summary": .string(results.isEmpty ? "Detected 0 barcodes" : results.first?.value ?? "")
            ])

        // ── image_similarity: compare visual similarity between two images ──
        case "image_similarity":
            guard let path1 = request.params["image_path_1"]?.stringValue,
                  let path2 = request.params["image_path_2"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path_1 or image_path_2")
            }
            let distance = try await visionExt.imageSimilarity(path1: path1, path2: path2)
            // VNFeaturePrintObservation.computeDistance returns L2 distance, roughly in [0, 2].
            // 0=same file, 0.04≈near-duplicate, 0.5~0.8≈same category, >0.8≈unrelated.
            let description: String
            if distance < 0.1 { description = "very similar" }
            else if distance < 0.4 { description = "similar" }
            else if distance < 0.8 { description = "somewhat similar" }
            else { description = "clearly different" }
            return .ok(id: request.id, result: [
                "distance": .double(distance),
                "description": .string(description)
            ])

        // ── detect_objects: object detection (requires a custom Core ML model) ──
        case "detect_objects":
            guard let imagePath = request.params["image_path"]?.stringValue,
                  let modelPath = request.params["model_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path or model_path")
            }
            let results = try await visionExt.detectObjects(path: imagePath, modelPath: modelPath)
            let summary = results.enumerated().map { idx, item in
                "Object \(idx + 1): \(item.label) confidence \(String(format: "%.0f", Double(item.confidence) * 100))% position(\(String(format: "%.2f", item.boundingBox.x)),\(String(format: "%.2f", item.boundingBox.y))) size(\(String(format: "%.2f", item.boundingBox.width))x\(String(format: "%.2f", item.boundingBox.height)))"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: [
                "count": .int(results.count),
                "objects": .string(summary.isEmpty ? "Detected 0 objects" : summary),
                "summary": .string(results.isEmpty ? "Detected 0 objects" : "Detected \(results.count) object\(results.count == 1 ? "" : "s")")
            ])

        // ── detect_contours: contour detection ──
        case "detect_contours":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectContours(base64: base64, path: path)
            return .ok(id: request.id, result: [
                "contour_count": .int(result.contourCount),
                "point_count": .int(result.pointCount),
                "contours": .string(result.normalizedPath.isEmpty ? "Detected 0 contours" : result.normalizedPath)
            ])

        // ── detect_text_regions: text region detection ──
        case "detect_text_regions":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectTextRegions(base64: base64, path: path)
            let summary = result.regions.enumerated().map { idx, region in
                "Text region \(idx + 1): position(\(String(format: "%.2f", region.x)),\(String(format: "%.2f", region.y))) size(\(String(format: "%.2f", region.width))x\(String(format: "%.2f", region.height))) character boxes \(region.characterBoxes)"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: [
                "count": .int(result.count),
                "regions": .string(summary.isEmpty ? "Detected 0 text regions" : summary)
            ])

        // ── detect_face_landmarks: face landmarks ──
        case "detect_face_landmarks":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectFaceLandmarks(base64: base64, path: path)
            return .ok(id: request.id, result: [
                "count": .int(result.count),
                "landmarks": .string(result.summaries.isEmpty ? "Detected 0 face landmarks" : result.summaries.joined(separator: "\n"))
            ])

        // ── detect_human_bodies: human body region detection ──
        case "detect_human_bodies":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let upperBodyOnly = request.params["upper_body_only"]?.boolValue ?? false
            let result = try await visionExt.detectHumanBodies(base64: base64, path: path, upperBodyOnly: upperBodyOnly)
            let summary = result.bodies.enumerated().map { idx, body in
                "Human body \(idx + 1): position(\(String(format: "%.2f", body.x)),\(String(format: "%.2f", body.y))) size(\(String(format: "%.2f", body.width))x\(String(format: "%.2f", body.height))) confidence \(String(format: "%.0f", Double(body.confidence) * 100))%"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: [
                "count": .int(result.count),
                "bodies": .string(summary.isEmpty ? "Detected 0 human bodies" : summary)
            ])

        // ── detect_horizon: horizon detection ──
        case "detect_horizon":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectHorizon(base64: base64, path: path)
            return .ok(id: request.id, result: [
                "angle": .double(result.angle),
                "transform": .string(result.transform)
            ])

        // ── word_similarity: word semantic similarity ──
        case "word_similarity":
            guard let word1 = request.params["word1"]?.stringValue,
                  let word2 = request.params["word2"]?.stringValue else {
                return .fail(id: request.id, error: "Missing word1 or word2")
            }
            let lang = request.params["language"]?.stringValue ?? "en"
            if let sim = nlEmbedding.wordSimilarity(word1: word1, word2: word2, language: lang) {
                let desc = sim > 0.8 ? "very similar" : sim > 0.5 ? "similar" : sim > 0.3 ? "somewhat related" : "not related"
                return .ok(id: request.id, result: ["similarity": .double(sim), "description": .string(desc)])
            } else {
                return .fail(id: request.id, error: "Language \(lang) does not support word embeddings")
            }

        // ── sentence_similarity: sentence semantic similarity ──
        case "sentence_similarity":
            guard let s1 = request.params["sentence1"]?.stringValue,
                  let s2 = request.params["sentence2"]?.stringValue else {
                return .fail(id: request.id, error: "Missing sentence1 or sentence2")
            }
            let lang = request.params["language"]?.stringValue ?? "en"
            if let sim = nlEmbedding.sentenceSimilarity(sentence1: s1, sentence2: s2, language: lang) {
                let desc = sim > 0.8 ? "semantically very close" : sim > 0.5 ? "semantically similar" : sim > 0.3 ? "somewhat related" : "semantically different"
                return .ok(id: request.id, result: ["similarity": .double(sim), "description": .string(desc)])
            } else {
                return .fail(id: request.id, error: "Language \(lang) does not support sentence embeddings")
            }

        // ── classify_sound: sound classification ──
        case "classify_sound":
            guard let path = request.params["audio_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing required parameter: audio_path")
            }
            let results = try await sound.classifySound(audioPath: path)
            let list = results.map { "\($0.label) (\(String(format: "%.0f", $0.confidence*100))%)" }
            return .ok(id: request.id, result: [
                "top_sound": .string(results.first?.label ?? "unknown"),
                "sounds": .string(list.joined(separator: ", "))
            ])

        // ── detect_body_pose: human body pose ──
        case "detect_body_pose":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let results = try await visionPose.detectBodyPose(imagePath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["summary": .string("Detected 0 human bodies"), "count": .int(0)])
            }
            let summary = results.map { dict in
                dict.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            }.joined(separator: "\n")
            return .ok(id: request.id, result: ["count": .int(results.count), "poses": .string(summary)])

        // ── detect_hand_pose: hand pose ──
        case "detect_hand_pose":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let results = try await visionPose.detectHandPose(imagePath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["summary": .string("Detected 0 hands"), "count": .int(0)])
            }
            let summary = results.map { dict in
                dict.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            }.joined(separator: "\n")
            return .ok(id: request.id, result: ["count": .int(results.count), "hands": .string(summary)])

        // ── recognize_animals: animal recognition ──
        case "recognize_animals":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let results = try await visionPose.recognizeAnimals(imagePath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["summary": .string("Detected 0 animals"), "count": .int(0)])
            }
            let summary = results.map { "\($0.label) confidence \(String(format: "%.0f", Double($0.confidence) * 100))%" }.joined(separator: ", ")
            return .ok(id: request.id, result: ["count": .int(results.count), "animals": .string(summary), "top": .string(results.first?.label ?? "")])

        // ── detect_rectangles: rectangle detection ──
        case "detect_rectangles":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let results = try await visionPose.detectRectangles(imagePath: path)
            let summary = results.enumerated().map { i, r in
                "Rectangle \(i + 1): position(\(String(format: "%.2f", r.x)),\(String(format: "%.2f", r.y))) size(\(String(format: "%.2f", r.width))x\(String(format: "%.2f", r.height)))"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: ["count": .int(results.count), "rectangles": .string(summary.isEmpty ? "Detected 0 rectangles" : summary)])

        // ── detect_saliency: visual saliency ──
        case "detect_saliency":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let result = try await visionPose.detectSaliency(imagePath: path)
            return .ok(id: request.id, result: ["saliency": .string(result)])

        // ── segment_person: person segmentation ──
        case "segment_person":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let result = try await visionPose.segmentPerson(imagePath: path)
            return .ok(id: request.id, result: ["result": .string(result)])

        // ── detect_document: document detection ──
        case "detect_document":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let result = try await visionPose.detectDocument(imagePath: path)
            return .ok(id: request.id, result: ["result": .string(result)])

        // ── score_image_aesthetics: image aesthetics scoring ──
        case "score_image_aesthetics":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let result = try await visionExt.scoreImageAesthetics(path: path)
            let scoreDesc: String
            if result.overallScore >= 0.7 { scoreDesc = "high-quality photo" }
            else if result.overallScore >= 0.4 { scoreDesc = "average photo" }
            else { scoreDesc = "low-quality photo" }
            return .ok(id: request.id, result: [
                "overall_score": .double(result.overallScore),
                "is_utility": .bool(result.isUtility),
                "description": .string(result.isUtility ? "screenshot or utility image (not a photograph)" : scoreDesc)
            ])

        // ── segment_foreground_instances: foreground instance segmentation ──
        case "segment_foreground_instances":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let result = try await visionExt.segmentForegroundInstances(path: path)
            return .ok(id: request.id, result: [
                "instance_count": .int(result.instanceCount),
                "description": .string(result.description)
            ])

        // ── detect_optical_flow: optical flow detection ──
        case "detect_optical_flow":
            guard let ref = request.params["reference_path"]?.stringValue,
                  let target = request.params["target_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing reference_path or target_path")
            }
            let result = try await visionExt.detectOpticalFlow(referencePath: ref, targetPath: target)
            return .ok(id: request.id, result: [
                "width": .int(result.width),
                "height": .int(result.height),
                "description": .string(result.description)
            ])

        // ── detect_body_pose_3d: 3D human body pose ──
        case "detect_body_pose_3d":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing image_path")
            }
            let results = try await visionPose.detectBodyPose3D(imagePath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["summary": .string("Detected 0 human bodies"), "count": .int(0)])
            }
            let summary = results.map { dict in
                dict.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            }.joined(separator: "\n")
            return .ok(id: request.id, result: ["count": .int(results.count), "poses_3d": .string(summary)])

        // ── detect_trajectories: trajectory detection (video) ──
        case "detect_trajectories":
            guard let path = request.params["video_path"]?.stringValue else {
                return .fail(id: request.id, error: "Missing video_path")
            }
            let results = try await visionPose.detectTrajectories(videoPath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["count": .int(0), "summary": .string("Detected 0 parabolic trajectories")])
            }
            let summary = results.map { t in
                "Trajectory \(t.trajectoryId) (confidence \(String(format: "%.0f", Double(t.confidence) * 100))%): \(t.points) equation: \(t.equation)"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: [
                "count": .int(results.count),
                "trajectories": .string(summary)
            ])

        // ── lemmatize_text: lemmatization ──
        case "lemmatize_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing text")
            }
            let results = nlAdvanced.lemmatize(text: text)
            let display = results.map { w in
                w.lemma == w.word ? w.word : "\(w.word)→\(w.lemma)"
            }.joined(separator: " | ")
            let changed = results.filter { $0.lemma != $0.word }.count
            return .ok(id: request.id, result: [
                "lemmatized": .string(display),
                "changed_count": .int(changed),
                "total_count": .int(results.count)
            ])

        // ── generate_text_structured: structured generation ──
        case "generate_text_structured":
            guard let prompt = request.params["prompt"]?.stringValue else {
                return .fail(id: request.id, error: "Missing prompt")
            }
            let schema = request.params["schema"]?.stringValue ?? "summarize"
            let system = request.params["system_prompt"]?.stringValue
            let json = try await generate.generateStructured(prompt: prompt, schema: schema, systemPrompt: system)
            return .ok(id: request.id, result: ["json": .string(json), "schema": .string(schema)])

        // ── tokenize_text: tokenization ──
        case "tokenize_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing text")
            }
            let unit = request.params["unit"]?.stringValue ?? "word"
            let tokens = nlAdvanced.tokenize(text: text, unit: unit)
            return .ok(id: request.id, result: ["tokens": .string(tokens.joined(separator: " | ")), "count": .int(tokens.count)])

        // ── synthesize_speech: text -> speech (local AVSpeechSynthesizer) ──
        case "synthesize_speech":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing text")
            }
            let voice = request.params["voice"]?.stringValue
            let rateValue = request.params["rate"]?.doubleValue.map { Float($0) }
            let outputPath = request.params["output_path"]?.stringValue
            let result = try await speechSynth.synthesize(
                text: text,
                voice: voice,
                rate: rateValue,
                outputPath: outputPath
            )
            return .ok(id: request.id, result: [
                "output_path": .string(result.outputPath),
                "duration_seconds": .double(result.durationSeconds),
                "voice_used": .string(result.voiceUsed)
            ])

        // ── list_voices: list available voices (helper for synthesize_speech voice selection) ──
        case "list_voices":
            let langFilter = request.params["language"]?.stringValue
            let voices = AVSpeechSynthesisVoice.speechVoices().filter { v in
                guard let f = langFilter, !f.isEmpty else { return true }
                return v.language.hasPrefix(f)
            }
            let lines = voices.map { v in
                "\(v.identifier) | \(v.language) | \(v.name)"
            }
            return .ok(id: request.id, result: [
                "count": .int(voices.count),
                "voices": .string(lines.joined(separator: "\n"))
            ])

        // ── proofread_text: proofread (fix typos/grammar/punctuation without changing style) ──
        case "proofread_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing required parameter: text")
            }
            let result = try await writingTools.proofread(text: text)
            return .ok(id: request.id, result: ["text": .string(result)])

        // ── rewrite_text: rewrite tone (formal/casual/concise/friendly/professional) ──
        case "rewrite_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing required parameter: text")
            }
            let tone = request.params["tone"]?.stringValue ?? "concise"
            let result = try await writingTools.rewrite(text: text, tone: tone)
            return .ok(id: request.id, result: ["text": .string(result)])

        // ── summarize_text: condense text (length=short/medium/long) ──
        case "summarize_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing required parameter: text")
            }
            let length = request.params["length"]?.stringValue ?? "medium"
            let result = try await writingTools.summarize(text: text, length: length)
            return .ok(id: request.id, result: ["text": .string(result)])

        // ── tag_parts_of_speech: part-of-speech tagging ──
        case "tag_parts_of_speech":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "Missing text")
            }
            let tagged = nlAdvanced.tagPartsOfSpeech(text: text)
            let result = tagged.map { "\($0.word)[\($0.tagZH)]" }.joined(separator: " ")
            return .ok(id: request.id, result: ["tagged": .string(result), "count": .int(tagged.count)])

        default:
            return .fail(
                id: request.id,
                error: "Unknown tool: \(request.tool)"
            )
        }
    }
}
