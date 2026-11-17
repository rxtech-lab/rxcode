import Foundation
import ImageIO
import RxAgentClients
import RxAgentCore
import RxAgentHarness
import RxCodeCore

extension AppState {
    func handleMediaTool(name: String, arguments: RxCodeCore.JSONValue, sessionKey: String) async throws -> RxCodeCore.JSONValue {
        if name == "ide__pet_draft" {
            guard let session = PetLookCreationSession.sessions[sessionKey] else {
                throw IDEToolError.notSupported("Open a pet creation conversation before controlling a draft.")
            }
            return try await session.handlePreview(arguments, controller: PetController.shared)
        }
        if name == "ide__media_models" {
            var cloud: [FlowcyMediaModel] = []
            var catalogError: String?
            do { cloud = try await FlowcyMediaClient(auth: rxAuth).allModels() }
            catch is CancellationError { throw CancellationError() }
            catch { catalogError = error.localizedDescription }
            return .object([
                "flowcy_error": catalogError.map(RxCodeCore.JSONValue.string) ?? .null,
                "configured": .object(MediaGenerationPreferences.shared.selections.mapValues {
                    .object(["provider": .string($0.provider.rawValue), "model": .string($0.model)])
                }),
                "codex": .array([.string("image")]),
                "local": .array(localModels.installed.filter { model in MediaGenerationKind.allCases.contains { $0.supports(model) } }.map {
                    .object(["id": .string($0.id), "name": .string($0.displayName), "kind": .string($0.studioKind.rawValue)])
                }),
                "flowcy": .array(cloud.map { .object(["id": .string($0.id), "name": .string($0.alias), "labels": .array($0.labels.map(RxCodeCore.JSONValue.string))]) })
            ])
        }
        if let session = PetLookCreationSession.sessions[sessionKey] {
            return try await session.runMediaOperation { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.handleMediaGeneration(arguments: arguments, sessionKey: sessionKey)
            }
        }
        return try await handleMediaGeneration(arguments: arguments, sessionKey: sessionKey)
    }

    private func handleMediaGeneration(arguments: RxCodeCore.JSONValue, sessionKey: String) async throws -> RxCodeCore.JSONValue {
        guard let kind = arguments["kind"]?.stringValue.flatMap(MediaGenerationKind.init(rawValue:)) else {
            throw IDEToolError.invalidArguments("Choose image, video, or audio.")
        }
        if let job = arguments["job_id"]?.stringValue {
            guard kind == .video, job.hasPrefix("flowcy-"), job.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw IDEToolError.invalidArguments("Use a Flowcy video job_id returned by this tool.")
            }
            return try await FlowcyMediaClient(auth: rxAuth).request("jobs/\(job)")
        }
        guard let prompt = arguments["prompt"]?.stringValue, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("A prompt is required.")
        }
        var selection: MediaGenerationSelection?
        if kind == .image, let session = PetLookCreationSession.sessions[sessionKey] {
            selection = session.imageSelection
        } else { selection = MediaGenerationPreferences.shared.selection(kind) }
        if let provider = arguments["provider"]?.stringValue {
            guard let provider = MediaGenerationSelection.Provider(rawValue: provider) else { throw IDEToolError.invalidArguments("Unknown media provider.") }
            selection = .init(provider: provider, model: arguments["model"]?.stringValue ?? "")
        } else if let model = arguments["model"]?.stringValue { selection?.model = model }
        guard let selection else { throw IDEToolError.notSupported("Choose a \(kind.rawValue) model in Settings → Media first.") }
        let source = arguments["source_path"]?.stringValue
        if let source {
            guard kind == .image, source.hasPrefix("/"), ImageGenerationTool.pixelSize(of: source) != nil else {
                throw IDEToolError.invalidArguments("source_path must be a readable absolute image path.")
            }
        }
        switch selection.provider {
        case .codex:
            guard kind == .image else { throw IDEToolError.notSupported("Codex supports image generation only.") }
            return try await generateCodexImage(prompt: prompt, source: source)
        case .local:
            guard localModels.installed.contains(where: { $0.id == selection.model && kind.supports($0) }) else {
                throw IDEToolError.notSupported("The selected \(kind.rawValue) model is not installed.")
            }
            let tool: any HarnessTool
            let taskModel: LocalAgentBackendFactory.TaskModelProvider = { [weak self] kind in self?.studioSetupTaskModel(for: kind) }
            switch kind {
            case .image: tool = LocalAgentBackendFactory.imageTool(store: localModels, manager: localModels.manager, taskModel: taskModel)
            case .video: tool = LocalAgentBackendFactory.videoTool(store: localModels, manager: localModels.manager, taskModel: taskModel)
            case .audio: tool = LocalAgentBackendFactory.audioTool(store: localModels, manager: localModels.manager, taskModel: taskModel)
            }
            let fullPrompt = source.map { "[Attached image: \($0)]\n\n\(prompt)" } ?? prompt
            let result = try await tool.execute(.object(["prompt": .string(fullPrompt), "model": .string(selection.model)]), context: HarnessToolContext(
                sessionID: sessionKey, callID: UUID().uuidString, workingDirectory: localModels.modelsRoot,
                terminals: HarnessTerminalManager()))
            guard !result.isError else { throw IDEToolError.handlerFailed(result.text) }
            return (try? JSONDecoder().decode(RxCodeCore.JSONValue.self, from: Data(result.text.utf8))) ?? .object(["result": .string(result.text)])
        case .flowcy:
            guard source == nil else { throw IDEToolError.notSupported("Flowcy's image API currently accepts text only. Choose Codex or a downloaded image model to refine an image.") }
            return try await generateFlowcyMedia(kind: kind, selection: selection, prompt: prompt, options: arguments["options"])
        }
    }

    private func generateFlowcyMedia(kind: MediaGenerationKind, selection: MediaGenerationSelection, prompt: String, options: RxCodeCore.JSONValue?) async throws -> RxCodeCore.JSONValue {
        let client = FlowcyMediaClient(auth: rxAuth)
        let models = try await client.allModels()
        guard let model = models.first(where: { $0.id == selection.model && $0.labels.contains(kind.rawValue) }) else {
            throw IDEToolError.notSupported("The selected Flowcy model is not enabled for \(kind.rawValue). Refresh Settings → Media.")
        }
        var body = options?.objectValue ?? [:]
        // Files stay out of serverless JSON bodies. These tools currently accept text prompts only.
        for key in ["base64", "first_frame", "last_frame", "reference_images", "object_key"] where body[key] != nil {
            throw IDEToolError.invalidArguments("This tool accepts text media prompts. File inputs require a presigned S3 upload flow.")
        }
        body["model"] = .string(model.id)
        let route: String
        switch kind {
        case .image:
            body["prompt"] = .string(prompt); route = "ai/images"
        case .video:
            body["prompt"] = .string(prompt)
            body["aspect_ratio"] = body["aspect_ratio"] ?? .string("16:9")
            body["duration_seconds"] = body["duration_seconds"] ?? .number(8)
            body["person_generation"] = body["person_generation"] ?? .string("allow_adult")
            route = "ai/videos"
        case .audio:
            route = "ai/speech"
            if model.provider == "google" || model.provider == "gemini" {
                body["provider"] = .string("gemini")
                body["transcript"] = .string(prompt)
                body["speakers"] = body["speakers"] ?? .array([.object(["name": .string("Speaker"), "voice": .string("Kore")])])
            } else if model.provider == "azure" {
                guard let voice = body["voice"]?.stringValue, !voice.isEmpty else { throw IDEToolError.invalidArguments("Azure speech requires options.voice.") }
                func escaped(_ text: String) -> String {
                    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
                }
                body["provider"] = .string("azure")
                body["ssml"] = .string("<speak version='1.0' xml:lang='en-US'><voice name='\(escaped(voice))'>\(escaped(prompt))</voice></speak>")
            } else {
                body["provider"] = .string("gateway"); body["text"] = .string(prompt)
                guard body["voice"]?.stringValue != nil else { throw IDEToolError.invalidArguments("Speech generation requires options.voice.") }
            }
        }
        let result = try await client.request(route, body: .object(body))
        if kind == .video { return result }
        return try await Task.detached {
            var paths: [RxCodeCore.JSONValue] = []
            if kind == .image {
                for entry in result["images"]?.arrayValue ?? [] {
                    guard let encoded = entry["b64_json"]?.stringValue else { continue }
                    let mime = entry["mime_type"]?.stringValue ?? "image/png"
                    paths.append(.string(try Self.saveMedia(encoded, extension: mime.contains("jpeg") ? "jpg" : mime.contains("webp") ? "webp" : "png").path))
                }
            } else if let encoded = result["audio_base64"]?.stringValue {
                let mime = result["mime_type"]?.stringValue ?? "audio/wav"
                paths.append(.string(try Self.saveMedia(encoded, extension: mime.contains("mpeg") ? "mp3" : mime.contains("ogg") ? "ogg" : "wav").path))
            }
            guard !paths.isEmpty else { throw IDEToolError.handlerFailed("Flowcy returned no media files.") }
            return .object(["savedPath": paths[0], "paths": .array(paths), "kind": .string(kind.rawValue), "provider": .string("flowcy"), "model": .string(model.id)])
        }.value
    }

    nonisolated private static func saveMedia(_ encoded: String, extension ext: String) throws -> URL {
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else { throw IDEToolError.handlerFailed("Invalid generated media data.") }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RxCode/GeneratedMedia")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func generateCodexImage(prompt: String, source: String?) async throws -> RxCodeCore.JSONValue {
        let client = CodexClient()
        guard await client.isAvailable() else { throw IDEToolError.notSupported("Install and sign in to Codex, or choose another image provider in Settings → Media.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RxCodeImages/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let request = AgentSendRequest(threadID: AgentThreadID(), prompt: prompt,
            attachments: source.map { PetLookCreationSession.agentAttachments([Attachment(type: .image, name: URL(fileURLWithPath: $0).lastPathComponent, path: $0)]) } ?? [], workingDirectory: directory,
            permissionMode: .bypassPermissions,
            contextText: "Use your native image generation tool to create or refine the requested image. Save the result inside \(directory.path). Return exactly {\"path\":\"/absolute/image/path.png\"}. Do not use MCP tools, delegate to another agent, or change project files.")
        var reply = ""
        var generated: URL?
        try await withTaskCancellationHandler {
            for await event in client.send(request) {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let text): reply += text
                case .toolCallResult(_, let content, let isError):
                    if !isError, content.count > 128, let data = Data(base64Encoded: content),
                       let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0 {
                        generated = try Self.saveMedia(content, extension: "png")
                    }
                case .failed(let failure): throw failure
                default: break
                }
            }
        } onCancel: { Task { await client.cancel(turn: request.turnID) } }
        if generated == nil, let path = PetLookCreationSession.packPath(from: reply),
           path.hasPrefix(directory.path + "/"), ImageGenerationTool.pixelSize(of: path) != nil {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            generated = try Self.saveMedia(data.base64EncodedString(), extension: URL(fileURLWithPath: path).pathExtension)
        }
        guard let generated else { throw IDEToolError.handlerFailed("Codex did not return a generated image. Verify that your Codex account supports image generation.") }
        return .object(["savedPath": .string(generated.path), "paths": .array([.string(generated.path)]), "kind": .string("image"), "provider": .string("codex")])
    }
}
