import Foundation
import Observation
import RxAgentCore
import RxCodeCore
import UniformTypeIdentifiers

/// An independent draft conversation; changes reach the library only on Save & Use.
@MainActor @Observable
final class PetLookCreationSession: Identifiable {
    let id = UUID()
    var draft: PetLook?
    static var sessions: [String: PetLookCreationSession] = [:]
    var messages: [ChatMessage] = []
    var chatAgent: TaskAgentConfig? {
        didSet { if chatAgent != oldValue { resumeID = nil } }
    }
    var imageSelection = MediaGenerationPreferences.shared.selection(.image)
    var preview = PetLookPreviewState()
    var isRunning = false
    private(set) var isCancelling = false
    var error: String?
    var status = "Creating look…"
    @ObservationIgnored private var client: (any AgentClient)?
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var resumeID: String?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var mediaOperations: [UUID: Task<RxCodeCore.JSONValue, Error>] = [:]
    @ObservationIgnored private let outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PetLookCreation/\(UUID().uuidString)")

    init(base: PetLook? = nil) { draft = base }

    func send(_ prompt: String, attachments: [Attachment] = [], controller: PetController) async {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !attachments.isEmpty), !isRunning else { return }
        isRunning = true
        status = draft == nil ? "Creating look…" : "Revising look…"
        error = nil
        let token = UUID()
        generation = token
        let sessionKey = "pet-look-\(id.uuidString)"
        let appState = controller.appState
        let resolved = AttachmentFactory.resolvingClipboardImages(attachments).resolved
        let fullPrompt = (resolved.map(\.promptContext) + [prompt.isEmpty ? "Create a pet based on the attached reference." : prompt]).joined(separator: "\n\n")
        let history = messages.filter { !$0.content.isEmpty }.map { AgentMessage.text($0.content, role: $0.role == .user ? .user : .assistant) }
        messages.append(ChatMessage(role: .user, content: prompt, attachments: resolved))
        defer {
            isRunning = false
            isCancelling = false
            client = nil
            turnID = nil
            Self.sessions.removeValue(forKey: sessionKey)
            cleanup = Task { await appState?.ideMCPServer.release(sessionKey: sessionKey) }
        }
        do {
            await cleanup?.value
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            Self.sessions[sessionKey] = self
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let reference = try draft.map { look -> String in
                let json = String(decoding: try JSONEncoder().encode(look), as: UTF8.self)
                return "Current draft metadata: \(json)\nReference atlas: \(look.character.spriteSheetURL?.path ?? "unavailable")\nAdditional sheets: \(look.character.additionalSpriteSheetURLs.map(\.path).joined(separator: ", "))"
            } ?? "This is a new character."
            let context = try PetLookSkill.instructions() + """

            SETTINGS CREATION MODE. Work only in \(outputDirectory.path). Create a draft pack in a new
            subfolder for every turn. Preserve the previous pack. Do not select, import, save, export,
            or change the live pet. Do not modify any project. Use your available tools to author
            the requested character and animation atlas; explain an unavailable capability honestly.
            Use ide__generate_media kind=image for image generation. The chosen image provider is
            \(imageSelection?.provider.rawValue ?? "unconfigured"), model \(imageSelection?.model ?? "none").
            Use ide__pet_draft with path to show the finished draft and control pose, playing, and frame.
            Preserve the reference image's identity when one is attached. Set hasSpeechFrames=true and
            create matching -closed.png and -open.png companion sheets for EVERY body sheet. Every pose
            and frame must have the same body, head position, and silhouette in both mouth variants.
            Never draw a separate mouth overlay at playback. Do not draw a background.
            Finish with exactly {"path":"/absolute/pack/folder"} when the pack is ready.
            \(reference)
            """
            let setup = try await controller.prepareCustomAgentTurn(userText: fullPrompt, resumeSessionID: resumeID,
                sessionKeyOverride: sessionKey, contextOverride: context, workingDirectoryOverride: outputDirectory, agentOverride: chatAgent,
                attachments: Self.agentAttachments(resolved), history: history)
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            client = setup.client
            turnID = setup.sendRequest.turnID
            var reply = ""
            let responseID = UUID()
            messages.append(ChatMessage(id: responseID, role: .assistant, content: "", isStreaming: true))
            defer {
                if let index = messages.firstIndex(where: { $0.id == responseID }) {
                    messages[index].isStreaming = false
                    messages[index].isResponseComplete = true
                }
            }
            for await event in setup.client.send(setup.sendRequest) {
                guard generation == token, !Task.isCancelled else { throw CancellationError() }
                switch event {
                case .sessionStarted(let info): resumeID = info.nativeSessionID
                case .textDelta(let text):
                    reply += text
                    if let index = messages.firstIndex(where: { $0.id == responseID }) {
                        if let last = messages[index].blocks.indices.last, messages[index].blocks[last].isText {
                            messages[index].blocks[last].text = (messages[index].blocks[last].text ?? "") + text
                        } else { messages[index].blocks.append(.text(text)) }
                    }
                case .toolCallStarted(let id, let name):
                    status = "Drawing and animating the draft…"
                    if let index = messages.firstIndex(where: { $0.id == responseID }) {
                        messages[index].blocks.append(.toolCall(ToolCall(id: id, name: name)))
                    }
                case .toolCallInput(let id, let input):
                    updateTool(id: id, responseID: responseID) { $0.input = input.mapValues(RxCodeCore.JSONValue.init) }
                case .toolCallResult(let id, let content, let isError):
                    updateTool(id: id, responseID: responseID) { $0.result = content; $0.isError = isError }
                case .failed(let failure): throw failure
                default: break
                }
            }
            try Task.checkCancellation()
            guard let path = Self.packPath(from: reply) else {
                if reply.isEmpty && draft == nil { throw IDEToolError.handlerFailed("The agent did not return a reply or a draft pet.") }
                return
            }
            let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            let root = outputDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard folder.path.hasPrefix(root) else {
                throw IDEToolError.invalidArguments("The agent's pack must be inside this creation session's output folder.")
            }
            status = "Validating animation sheets…"
            let prepared = try await controller.looks.preparePack(at: folder)
            guard prepared.hasSpeechFrames == true else {
                throw IDEToolError.invalidArguments("New pet drafts need matching open and closed mouth sheets for every pose. Ask the designer to add speech frames before saving.")
            }
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            draft = prepared
            messages.append(ChatMessage(role: .assistant, content: "Created **\(prepared.name)**. Preview the poses, then describe any changes or choose **Save & Use**."))
        } catch is CancellationError {
            // Keep the previous draft available when a turn is cancelled.
        } catch {
            if generation == token { self.error = error.localizedDescription }
        }
    }

    func cancel() {
        generation = UUID()
        guard isRunning else { return }
        isCancelling = true
        for operation in mediaOperations.values { operation.cancel() }
        status = "Stopping…"
        if let client, let turnID { Task { await client.cancel(turn: turnID) } }
        client = nil
        turnID = nil
    }

    func close() {
        cancel()
        Self.sessions.removeValue(forKey: "pet-look-\(id.uuidString)")
    }

    func handlePreview(_ arguments: RxCodeCore.JSONValue, controller: PetController) async throws -> RxCodeCore.JSONValue {
        guard isRunning, !isCancelling else { throw CancellationError() }
        let token = generation
        if let path = arguments["path"]?.stringValue {
            let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard folder.path.hasPrefix(outputDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                throw IDEToolError.invalidArguments("Draft packs must be inside this creation session's folder.")
            }
            let prepared = try await controller.looks.preparePack(at: folder)
            guard prepared.hasSpeechFrames == true else {
                throw IDEToolError.invalidArguments("New pet drafts need matching open and closed mouth sheets for every pose. Ask the designer to add speech frames before saving.")
            }
            guard generation == token, !isCancelling else { throw CancellationError() }
            draft = prepared
        }
        guard let draft else { throw IDEToolError.invalidArguments("Create a draft pack before showing a preview.") }
        if let pose = arguments["pose"]?.stringValue {
            guard let motion = PetMotion(rawValue: pose), motion != .automatic else { throw IDEToolError.invalidArguments("Unknown pose.") }
            preview.motion = motion
        }
        if let playing = arguments["playing"]?.boolValue { preview.isPlaying = playing }
        if let frame = arguments["frame"]?.intValue {
            guard (0..<(draft.columns * (draft.sheetCount ?? 1))).contains(frame) else { throw IDEToolError.invalidArguments("Frame is outside the draft animation.") }
            preview.frame = Double(frame)
            preview.isPlaying = false
        }
        if let mouth = arguments["mouth"]?.stringValue {
            guard let value = PetLookPreviewState.Mouth(rawValue: mouth) else { throw IDEToolError.invalidArguments("Choose automatic, closed or open mouth.") }
            preview.mouth = value
        }
        preview.replay = UUID()
        return .object(["status": .string("preview_updated"), "name": .string(draft.name), "pose": .string(preview.motion.rawValue), "playing": .bool(preview.isPlaying), "frame": .number(preview.frame), "mouth": .string(preview.mouth.rawValue)])
    }

    func runMediaOperation(_ action: @escaping @MainActor @Sendable () async throws -> RxCodeCore.JSONValue) async throws -> RxCodeCore.JSONValue {
        guard isRunning, !isCancelling else { throw CancellationError() }
        let id = UUID()
        let operation = Task { try await action() }
        mediaOperations[id] = operation
        defer { mediaOperations.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await operation.value }
            onCancel: { operation.cancel() }
    }

    private func updateTool(id: String, responseID: UUID, update: (inout ToolCall) -> Void) {
        guard let message = messages.firstIndex(where: { $0.id == responseID }),
              let block = messages[message].blocks.firstIndex(where: { $0.toolCall?.id == id }),
              var tool = messages[message].blocks[block].toolCall else { return }
        update(&tool)
        messages[message].blocks[block].toolCall = tool
    }

    nonisolated static func agentAttachments(_ attachments: [Attachment]) -> [AgentAttachment] {
        attachments.compactMap { attachment in
            switch attachment.type {
            case .image:
                guard let data = attachment.imageData ?? (try? Data(contentsOf: URL(fileURLWithPath: attachment.path))) else { return nil }
                let ext = (attachment.path as NSString).pathExtension.lowercased()
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png"
                return AgentAttachment(id: attachment.id, kind: .image(data, mimeType: mime), label: attachment.name)
            case .file: return .file(URL(fileURLWithPath: attachment.path))
            case .text: return attachment.textContent.map { AgentAttachment(kind: .text($0), label: attachment.name) }
            case .link: return AgentAttachment(kind: .text(attachment.promptContext), label: attachment.name)
            }
        }
    }

    nonisolated static func packPath(from reply: String) -> String? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start <= end,
              let data = String(reply[start...end]).data(using: .utf8),
              let value = try? JSONDecoder().decode(RxCodeCore.JSONValue.self, from: data),
              let path = value["path"]?.stringValue, path.hasPrefix("/") else { return nil }
        return path
    }
}
