import Foundation
import FoundationModels
import AVFoundation

// MARK: - Apple Intelligence MCP Core Service
// 透過 stdin/stdout JSON line protocol 與 Python MCP server 溝通

struct CoreService {

    static func run() async {
        let generateHandler = GenerateHandler()  // actor，無需 await 初始化
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

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // 告知 Python server 服務已就緒
        fputs("{\"status\":\"ready\",\"version\":\"1.0.0\"}\n", stdout)
        fflush(stdout)

        // 主迴圈：持續讀 stdin，一行一個 JSON 請求
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
                    speechSynth: speechSynthHandler
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

    // MARK: - 請求路由

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
        speechSynth: SpeechSynthHandler
    ) async throws -> IPCResponse {

        switch request.tool {

        case "generate_text":
            guard let prompt = request.params["prompt"]?.stringValue else {
                return .fail(id: request.id, error: "缺少必要參數 prompt")
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
                return .fail(id: request.id, error: "需要提供 image_base64 或 image_path")
            }

        case "translate_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "缺少必要參數 text")
            }
            let from = request.params["from"]?.stringValue ?? "自動偵測"
            let to = request.params["to"]?.stringValue ?? "zh-Hant"
            let result = try await translate.translate(text: text, from: from, to: to)
            return .ok(id: request.id, result: ["text": .string(result)])

        case "analyze_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "缺少必要參數 text")
            }
            let sentiment = analyze.analyzeSentiment(text: text)
            let language = analyze.detectLanguage(text: text)
            let keywords = analyze.extractKeywords(text: text)
            let entities = analyze.extractEntities(text: text)

            let sentimentLabel: String
            if sentiment > 0.2 { sentimentLabel = "正面" }
            else if sentiment < -0.2 { sentimentLabel = "負面" }
            else { sentimentLabel = "中性" }

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
                return .fail(id: request.id, error: "缺少必要參數 audio_path")
            }
            let language = request.params["language"]?.stringValue ?? "zh-TW"
            let text = try await transcribe.transcribe(audioPath: path, language: language)
            return .ok(id: request.id, result: ["text": .string(text)])

        // ── classify_image：圖片內容分類 ──
        case "classify_image":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let results = try await visionExt.classifyImage(base64: base64, path: path)
            let labels = results.map { "\($0.label) (\(String(format: "%.0f", $0.confidence * 100))%)" }
            return .ok(id: request.id, result: [
                "labels": .string(labels.joined(separator: ", ")),
                "top": .string(results.first?.label ?? "unknown")
            ])

        // ── detect_faces：人臉偵測 ──
        case "detect_faces":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectFaces(base64: base64, path: path)
            let faceList = result.faces.enumerated().map { i, f in
                "臉\(i+1)：位置(\(String(format: "%.2f", f.x)),\(String(format: "%.2f", f.y))) 大小(\(String(format: "%.2f", f.width))x\(String(format: "%.2f", f.height))) 信心\(String(format: "%.0f", Double(f.confidence)*100))%"
            }
            return .ok(id: request.id, result: [
                "count": .int(result.count),
                "faces": .string(faceList.joined(separator: "\n")),
                "summary": .string(result.count == 0 ? "未偵測到人臉" : "偵測到 \(result.count) 張人臉")
            ])

        // ── detect_barcodes：條碼/QR Code 辨識 ──
        case "detect_barcodes":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let results = try await visionExt.detectBarcodes(base64: base64, path: path)
            let list = results.map { "\($0.symbology)：\($0.value)" }
            return .ok(id: request.id, result: [
                "count": .int(results.count),
                "barcodes": .string(list.joined(separator: "\n")),
                "summary": .string(results.isEmpty ? "未偵測到條碼" : results.first?.value ?? "")
            ])

        // ── image_similarity：比較兩張圖片的視覺相似度 ──
        case "image_similarity":
            guard let path1 = request.params["image_path_1"]?.stringValue,
                  let path2 = request.params["image_path_2"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path_1 或 image_path_2")
            }
            let distance = try await visionExt.imageSimilarity(path1: path1, path2: path2)
            let description: String
            if distance < 5 { description = "非常相似" }
            else if distance < 15 { description = "相似" }
            else if distance < 30 { description = "有些相近" }
            else { description = "差異明顯" }
            return .ok(id: request.id, result: [
                "distance": .double(distance),
                "description": .string(description)
            ])

        // ── detect_objects：物件偵測（需自訂 Core ML 模型）──
        case "detect_objects":
            guard let imagePath = request.params["image_path"]?.stringValue,
                  let modelPath = request.params["model_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path 或 model_path")
            }
            let results = try await visionExt.detectObjects(path: imagePath, modelPath: modelPath)
            let summary = results.enumerated().map { idx, item in
                "物件\(idx + 1)：\(item.label) 信心\(String(format: "%.0f", Double(item.confidence) * 100))% 位置(\(String(format: "%.2f", item.boundingBox.x)),\(String(format: "%.2f", item.boundingBox.y))) 大小(\(String(format: "%.2f", item.boundingBox.width))x\(String(format: "%.2f", item.boundingBox.height)))"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: [
                "count": .int(results.count),
                "objects": .string(summary.isEmpty ? "未偵測到物件" : summary),
                "summary": .string(results.isEmpty ? "未偵測到物件" : "偵測到 \(results.count) 個物件")
            ])

        // ── detect_contours：輪廓偵測 ──
        case "detect_contours":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectContours(base64: base64, path: path)
            return .ok(id: request.id, result: [
                "contour_count": .int(result.contourCount),
                "point_count": .int(result.pointCount),
                "contours": .string(result.normalizedPath.isEmpty ? "未偵測到輪廓" : result.normalizedPath)
            ])

        // ── detect_text_regions：文字區域偵測 ──
        case "detect_text_regions":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectTextRegions(base64: base64, path: path)
            let summary = result.regions.enumerated().map { idx, region in
                "文字區\(idx + 1)：位置(\(String(format: "%.2f", region.x)),\(String(format: "%.2f", region.y))) 大小(\(String(format: "%.2f", region.width))x\(String(format: "%.2f", region.height))) 字元框\(region.characterBoxes)"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: [
                "count": .int(result.count),
                "regions": .string(summary.isEmpty ? "未偵測到文字區域" : summary)
            ])

        // ── detect_face_landmarks：臉部特徵點 ──
        case "detect_face_landmarks":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectFaceLandmarks(base64: base64, path: path)
            return .ok(id: request.id, result: [
                "count": .int(result.count),
                "landmarks": .string(result.summaries.isEmpty ? "未偵測到臉部特徵點" : result.summaries.joined(separator: "\n"))
            ])

        // ── detect_human_bodies：人體區域偵測 ──
        case "detect_human_bodies":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let upperBodyOnly = request.params["upper_body_only"]?.boolValue ?? false
            let result = try await visionExt.detectHumanBodies(base64: base64, path: path, upperBodyOnly: upperBodyOnly)
            let summary = result.bodies.enumerated().map { idx, body in
                "人體\(idx + 1)：位置(\(String(format: "%.2f", body.x)),\(String(format: "%.2f", body.y))) 大小(\(String(format: "%.2f", body.width))x\(String(format: "%.2f", body.height))) 信心\(String(format: "%.0f", Double(body.confidence) * 100))%"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: [
                "count": .int(result.count),
                "bodies": .string(summary.isEmpty ? "未偵測到人體" : summary)
            ])

        // ── detect_horizon：地平線偵測 ──
        case "detect_horizon":
            let base64 = request.params["image_base64"]?.stringValue
            let path = request.params["image_path"]?.stringValue
            let result = try await visionExt.detectHorizon(base64: base64, path: path)
            return .ok(id: request.id, result: [
                "angle": .double(result.angle),
                "transform": .string(result.transform)
            ])

        // ── word_similarity：詞語語意相似度 ──
        case "word_similarity":
            guard let word1 = request.params["word1"]?.stringValue,
                  let word2 = request.params["word2"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 word1 或 word2")
            }
            let lang = request.params["language"]?.stringValue ?? "en"
            if let sim = nlEmbedding.wordSimilarity(word1: word1, word2: word2, language: lang) {
                let desc = sim > 0.8 ? "非常相似" : sim > 0.5 ? "相似" : sim > 0.3 ? "有些相關" : "不相關"
                return .ok(id: request.id, result: ["similarity": .double(sim), "description": .string(desc)])
            } else {
                return .fail(id: request.id, error: "語言 \(lang) 不支援詞語嵌入")
            }

        // ── sentence_similarity：句子語意相似度 ──
        case "sentence_similarity":
            guard let s1 = request.params["sentence1"]?.stringValue,
                  let s2 = request.params["sentence2"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 sentence1 或 sentence2")
            }
            let lang = request.params["language"]?.stringValue ?? "en"
            if let sim = nlEmbedding.sentenceSimilarity(sentence1: s1, sentence2: s2, language: lang) {
                let desc = sim > 0.8 ? "語意非常接近" : sim > 0.5 ? "語意相近" : sim > 0.3 ? "有些相關" : "語意不同"
                return .ok(id: request.id, result: ["similarity": .double(sim), "description": .string(desc)])
            } else {
                return .fail(id: request.id, error: "語言 \(lang) 不支援句子嵌入")
            }

        // ── classify_sound：聲音分類 ──
        case "classify_sound":
            guard let path = request.params["audio_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少必要參數 audio_path")
            }
            let results = try await sound.classifySound(audioPath: path)
            let list = results.map { "\($0.label) (\(String(format: "%.0f", $0.confidence*100))%)" }
            return .ok(id: request.id, result: [
                "top_sound": .string(results.first?.label ?? "unknown"),
                "sounds": .string(list.joined(separator: ", "))
            ])

        // ── detect_body_pose：人體姿態 ──
        case "detect_body_pose":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let results = try await visionPose.detectBodyPose(imagePath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["summary": .string("未偵測到人體"), "count": .int(0)])
            }
            let summary = results.map { dict in
                dict.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            }.joined(separator: "\n")
            return .ok(id: request.id, result: ["count": .int(results.count), "poses": .string(summary)])

        // ── detect_hand_pose：手部姿態 ──
        case "detect_hand_pose":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let results = try await visionPose.detectHandPose(imagePath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["summary": .string("未偵測到手部"), "count": .int(0)])
            }
            let summary = results.map { dict in
                dict.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            }.joined(separator: "\n")
            return .ok(id: request.id, result: ["count": .int(results.count), "hands": .string(summary)])

        // ── recognize_animals：動物辨識 ──
        case "recognize_animals":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let results = try await visionPose.recognizeAnimals(imagePath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["summary": .string("未偵測到動物"), "count": .int(0)])
            }
            let summary = results.map { "\($0.label) 信心\(String(format: "%.0f", Double($0.confidence)*100))%" }.joined(separator: ", ")
            return .ok(id: request.id, result: ["count": .int(results.count), "animals": .string(summary), "top": .string(results.first?.label ?? "")])

        // ── detect_rectangles：矩形偵測 ──
        case "detect_rectangles":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let results = try await visionPose.detectRectangles(imagePath: path)
            let summary = results.enumerated().map { i, r in
                "矩形\(i+1)：位置(\(String(format: "%.2f", r.x)),\(String(format: "%.2f", r.y))) 大小(\(String(format: "%.2f", r.width))x\(String(format: "%.2f", r.height)))"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: ["count": .int(results.count), "rectangles": .string(summary.isEmpty ? "未偵測到矩形" : summary)])

        // ── detect_saliency：視覺顯著性 ──
        case "detect_saliency":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let result = try await visionPose.detectSaliency(imagePath: path)
            return .ok(id: request.id, result: ["saliency": .string(result)])

        // ── segment_person：人像偵測 ──
        case "segment_person":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let result = try await visionPose.segmentPerson(imagePath: path)
            return .ok(id: request.id, result: ["result": .string(result)])

        // ── detect_document：文件偵測 ──
        case "detect_document":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let result = try await visionPose.detectDocument(imagePath: path)
            return .ok(id: request.id, result: ["result": .string(result)])

        // ── score_image_aesthetics：圖片美學評分 ──
        case "score_image_aesthetics":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let result = try await visionExt.scoreImageAesthetics(path: path)
            let scoreDesc: String
            if result.overallScore >= 0.7 { scoreDesc = "高品質照片" }
            else if result.overallScore >= 0.4 { scoreDesc = "普通照片" }
            else { scoreDesc = "低品質照片" }
            return .ok(id: request.id, result: [
                "overall_score": .double(result.overallScore),
                "is_utility": .bool(result.isUtility),
                "description": .string(result.isUtility ? "截圖或功能性圖片（非攝影作品）" : scoreDesc)
            ])

        // ── segment_foreground_instances：前景實例分割 ──
        case "segment_foreground_instances":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let result = try await visionExt.segmentForegroundInstances(path: path)
            return .ok(id: request.id, result: [
                "instance_count": .int(result.instanceCount),
                "description": .string(result.description)
            ])

        // ── detect_optical_flow：光流偵測 ──
        case "detect_optical_flow":
            guard let ref = request.params["reference_path"]?.stringValue,
                  let target = request.params["target_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 reference_path 或 target_path")
            }
            let result = try await visionExt.detectOpticalFlow(referencePath: ref, targetPath: target)
            return .ok(id: request.id, result: [
                "width": .int(result.width),
                "height": .int(result.height),
                "description": .string(result.description)
            ])

        // ── detect_body_pose_3d：3D 人體姿態 ──
        case "detect_body_pose_3d":
            guard let path = request.params["image_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 image_path")
            }
            let results = try await visionPose.detectBodyPose3D(imagePath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["summary": .string("未偵測到人體"), "count": .int(0)])
            }
            let summary = results.map { dict in
                dict.map { "\($0.key):\($0.value)" }.joined(separator: " ")
            }.joined(separator: "\n")
            return .ok(id: request.id, result: ["count": .int(results.count), "poses_3d": .string(summary)])

        // ── detect_trajectories：軌跡偵測（視訊） ──
        case "detect_trajectories":
            guard let path = request.params["video_path"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 video_path")
            }
            let results = try await visionPose.detectTrajectories(videoPath: path)
            if results.isEmpty {
                return .ok(id: request.id, result: ["count": .int(0), "summary": .string("未偵測到拋物線軌跡")])
            }
            let summary = results.map { t in
                "軌跡\(t.trajectoryId)（信心\(String(format: "%.0f", Double(t.confidence)*100))%）：\(t.points) 方程式：\(t.equation)"
            }.joined(separator: "\n")
            return .ok(id: request.id, result: [
                "count": .int(results.count),
                "trajectories": .string(summary)
            ])

        // ── lemmatize_text：詞形還原 ──
        case "lemmatize_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 text")
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

        // ── generate_text_structured：結構化生成 ──
        case "generate_text_structured":
            guard let prompt = request.params["prompt"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 prompt")
            }
            let schema = request.params["schema"]?.stringValue ?? "summarize"
            let system = request.params["system_prompt"]?.stringValue
            let json = try await generate.generateStructured(prompt: prompt, schema: schema, systemPrompt: system)
            return .ok(id: request.id, result: ["json": .string(json), "schema": .string(schema)])

        // ── tokenize_text：斷詞 ──
        case "tokenize_text":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 text")
            }
            let unit = request.params["unit"]?.stringValue ?? "word"
            let tokens = nlAdvanced.tokenize(text: text, unit: unit)
            return .ok(id: request.id, result: ["tokens": .string(tokens.joined(separator: " | ")), "count": .int(tokens.count)])

        // ── synthesize_speech：文字 → 語音(本地 AVSpeechSynthesizer) ──
        case "synthesize_speech":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 text")
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

        // ── list_voices：列出可用 voice(輔助 synthesize_speech 選 voice) ──
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

        // ── tag_parts_of_speech：詞性標注 ──
        case "tag_parts_of_speech":
            guard let text = request.params["text"]?.stringValue else {
                return .fail(id: request.id, error: "缺少 text")
            }
            let tagged = nlAdvanced.tagPartsOfSpeech(text: text)
            let result = tagged.map { "\($0.word)[\($0.tagZH)]" }.joined(separator: " ")
            return .ok(id: request.id, result: ["tagged": .string(result), "count": .int(tagged.count)])

        default:
            return .fail(
                id: request.id,
                error: "未知工具：\(request.tool)"
            )
        }
    }
}
