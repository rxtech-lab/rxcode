import AVFoundation
import Foundation
import os
import RxAgentClients
import RxAgentCore
import RxAgentProcess
import RxAgentVoice
import RxCodeCore
@preconcurrency import WebRTC

// MARK: - Codex Realtime Voice Engine (WebRTC + WebSocket)

struct PetCodexRealtimeEngine: VoiceEngine {
    let displayName = "Codex Realtime"
    let capabilities = VoiceEngineCapabilities(canCancel: false, canTruncate: false, runsTools: true)

    struct LaunchParameters: Sendable {
        var workingDirectory: URL
        var transportPreference: CodexRealtimeTransportPreference
        var voice: String
        var model: String?
        var configOverrides: [String]
        var sessionKey: String
        var idePort: UInt16?
        var requestApproval: @Sendable (RxAgentCore.JSONValue) async -> Bool
        var onUserTurn: @Sendable () async -> Void
    }

    let prepareLaunch: @Sendable () async throws -> LaunchParameters
    let releaseIDEMCP: @Sendable (String) async -> Void
    let onLevels: @Sendable (Float, Float) -> Void
    let onConnected: @Sendable () async -> Void
    let onToolEvent: @Sendable (AgentEvent?) async -> Void
    let bindWebRTCMuteHandler: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    /// Scope automatic tool access to the trusted IDE bridge, preserving shell, file,
    /// external MCP and resource-access approval policies.
    nonisolated static var ideToolApprovalOverrides: [String] {
        ["mcp_servers.rxcode-ide.default_tools_approval_mode=\"approve\""]
            + IDEToolRegistry.tools(for: RxCodeCore.AgentProvider.codex.staticCapabilities).map {
                "mcp_servers.rxcode-ide.tools.\($0.name).approval_mode=\"approve\""
            }
    }

    nonisolated static func describeToolItem(_ item: RxAgentCore.JSONValue?) -> String? {
        guard let item else { return nil }
        let type = item["type"]?.stringValue ?? ""
        switch type {
        case "mcpToolCall":
            let tool = item["tool"]?.stringValue ?? "MCP tool"
            return PetCodexRealtimeConnectionFriendlyTool.describe(tool)
        case "commandExecution":
            let cmd = item["command"]?.stringValue ?? "command"
            return "Running \(cmd.prefix(36))"
        case "fileChange":
            return "Editing files"
        case "webSearch":
            return "Searching web"
        default:
            if let name = item["name"]?.stringValue, !name.isEmpty {
                return PetCodexRealtimeConnectionFriendlyTool.describe(name)
            }
            return nil
        }
    }


    /// Shared by the live app-server callback and regression tests.
    nonisolated static func toolEvent(method: String, params: RxAgentCore.JSONValue) -> AgentEvent? {
        guard let item = params["item"], let label = describeToolItem(item) else { return nil }
        // These calls are displayed at the IDE execution boundary, before the
        // app-server's potentially delayed start/completion notifications.
        let tool = item["tool"]?.stringValue ?? ""
        if item["type"]?.stringValue == "mcpToolCall",
           tool.hasPrefix("ide__") || tool.contains("__ide__") {
            return nil
        }
        switch method {
        case "item/started":
            return .toolCallStarted(id: item["id"]?.stringValue ?? UUID().uuidString, name: label)
        case "item/completed":
            return completedToolEvent(item)
        default:
            return nil
        }
    }

    /// Completion of an MCP request is not proof that the tool succeeded or returned an image.
    nonisolated static func completedToolEvent(_ item: RxAgentCore.JSONValue) -> AgentEvent {
        var result = item["result"] ?? item["output"] ?? .null
        if let raw = result.stringValue,
           let decoded = try? JSONDecoder().decode(RxAgentCore.JSONValue.self, from: Data(raw.utf8)) {
            result = decoded
        }
        let blocks = result["content"]?.arrayValue ?? []
        let tool = item["tool"]?.stringValue ?? item["toolName"]?.stringValue ?? item["tool_name"]?.stringValue ?? ""
        let isCapture = tool.hasSuffix("ide__pet_capture")
        let hasImage = blocks.contains { $0["type"]?.stringValue == "image" && !($0["data"]?.stringValue ?? "").isEmpty }
        let error = item["error"]
        let hasError = error != nil && error != .null && error != .bool(false)
        let failed = hasError || item["status"]?.stringValue == "failed"
            || item["isError"]?.boolValue == true || result["isError"]?.boolValue == true
            || result["structuredContent"]?["status"]?.stringValue == "failed"
            || (isCapture && !hasImage)
        let text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        return .toolCallResult(id: item["id"]?.stringValue ?? "", content: text, isError: failed)
    }

    nonisolated static func isAuthorizedIDEToolApproval(_ params: RxAgentCore.JSONValue) -> Bool {
        let server = params["serverName"]?.stringValue ?? params["server_name"]?.stringValue ?? params["server"]?.stringValue
        let request = params["request"] ?? params
        let meta = request["_meta"] ?? params["_meta"] ?? .object([:])
        guard server == "rxcode-ide",
              meta["codex_approval_kind"]?.stringValue == "mcp_tool_call",
              meta["codex_requires_user_input"]?.boolValue != true,
              meta["codex_sensitive_action"]?.boolValue != true,
              let name = meta["tool_name"]?.stringValue else { return false }
        return IDEToolRegistry.tools(for: RxCodeCore.AgentProvider.codex.staticCapabilities).contains { $0.name == name }
    }

    nonisolated static func approvalResponse(
        method: String,
        params: RxAgentCore.JSONValue,
        requestApproval: @Sendable (RxAgentCore.JSONValue) async -> Bool
    ) async -> RxAgentCore.JSONValue? {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "request/approval":
            let allowed = await requestApproval(params)
            return .object(["decision": .string(allowed ? "accept" : "reject")])
        case "item/permissions/requestApproval":
            let allowed = await requestApproval(params)
            return .object([
                "permissions": allowed ? (params["permissions"] ?? .object([:])) : .object([:]),
                "scope": .string("turn")
            ])
        case "mcpServer/elicitation/request":
            // Some CLI versions still emit the access gate despite server approval config.
            // This accepts tool access only; ide__show_confirmation still waits for the user.
            let allowed: Bool
            if isAuthorizedIDEToolApproval(params) {
                allowed = true
            } else {
                allowed = await requestApproval(params)
            }
            return .object(["action": .string(allowed ? "accept" : "decline")])
        default:
            return nil
        }
    }

    func readiness() async -> VoiceEngineReadiness {
        let client = CodexClient()
        return await client.isAvailable()
            ? .ready
            : .needsSetup("Codex CLI is not installed or signed in. Configure Codex in Settings → Agent first.")
    }

    func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection {
        let launch = try await prepareLaunch()
        let connection = PetCodexRealtimeConnection(
            launch: launch,
            instructions: config.instructions,
            releaseIDEMCP: releaseIDEMCP,
            onLevels: onLevels,
            onConnected: onConnected,
            onToolEvent: onToolEvent,
            bindWebRTCMuteHandler: bindWebRTCMuteHandler
        )
        try await connection.start()
        return connection
    }
}

// MARK: - Codex Realtime Voice Connection

private actor PetCodexRealtimeConnection: VoiceConnection {
    nonisolated let inputFormat = VoicePCMFormat(sampleRate: 24_000, channels: 1)
    nonisolated let events: AsyncStream<VoiceEngineEvent>

    private let logger = Logger(subsystem: "com.claudework", category: "PetCodexRealtime")
    private let output: AsyncStream<VoiceEngineEvent>.Continuation
    private let launch: PetCodexRealtimeEngine.LaunchParameters
    private let instructions: String
    private let releaseIDEMCP: @Sendable (String) async -> Void
    private let onLevels: @Sendable (Float, Float) -> Void
    private let onConnected: @Sendable () async -> Void
    private let onToolEvent: @Sendable (AgentEvent?) async -> Void
    private let bindWebRTCMuteHandler: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

    private var session: CodexRealtimeSession?
    private var peer: CodexRealtimePeer?
    private var eventReaderTask: Task<Void, Never>?
    private var levelPollingTask: Task<Void, Never>?
    private var currentAssistantItemID: String?
    private var receivedAssistantDeltas = false
    private var receivedUserDeltas = false
    private var isReadyEmitted = false
    private var closed = false

    init(
        launch: PetCodexRealtimeEngine.LaunchParameters,
        instructions: String,
        releaseIDEMCP: @escaping @Sendable (String) async -> Void,
        onLevels: @escaping @Sendable (Float, Float) -> Void,
        onConnected: @escaping @Sendable () async -> Void,
        onToolEvent: @escaping @Sendable (AgentEvent?) async -> Void,
        bindWebRTCMuteHandler: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    ) {
        self.launch = launch
        self.instructions = instructions
        self.releaseIDEMCP = releaseIDEMCP
        self.onLevels = onLevels
        self.onConnected = onConnected
        self.onToolEvent = onToolEvent
        self.bindWebRTCMuteHandler = bindWebRTCMuteHandler
        (events, output) = AsyncStream.makeStream()
    }

    func start() async throws {
        let client = CodexClient(
            approvalPolicy: .onRequest,
            sandbox: .workspaceWrite,
            configOverrides: launch.configOverrides
        )

        let transport: CodexRealtimeTransport
        if launch.transportPreference == .webRTC {
            let webrtcPeer = CodexRealtimePeer { [weak self] state in
                Task { await self?.handlePeerStateChange(state) }
            }
            self.peer = webrtcPeer
            bindWebRTCMuteHandler { muted in
                webrtcPeer.setMicrophoneMuted(muted)
            }
            let sdpOffer = try await webrtcPeer.makeOffer()
            transport = .webRTC(offer: sdpOffer)
        } else {
            transport = .websocket
        }

        do {
            let realtimeSession = try await client.startRealtime(
                workingDirectory: launch.workingDirectory,
                instructions: instructions,
                voice: launch.voice.isEmpty ? nil : launch.voice,
                model: (launch.model?.isEmpty == false) ? launch.model : nil,
                transport: transport,
                onRequest: { [launch] method, params in
                    guard let response = await PetCodexRealtimeEngine.approvalResponse(
                        method: method, params: params, requestApproval: launch.requestApproval
                    ) else { return .failure(.methodNotFound) }
                    return .success(response)
                }
            )
            guard !closed else {
                await realtimeSession.close()
                throw CancellationError()
            }
            self.session = realtimeSession

            eventReaderTask = Task { [weak self] in
                for await event in realtimeSession.events {
                    guard !Task.isCancelled else { return }
                    await self?.handleCodexEvent(event)
                }
                await self?.handleStreamEnded()
            }
        } catch {
            peer?.close()
            peer = nil
            await releaseIDEMCP(launch.sessionKey)
            throw VoiceError.transport(error.localizedDescription)
        }
    }

    func send(audio: VoiceAudioFrame) async throws {
        guard !closed else { throw VoiceError.invalidState }
        // In WebRTC mode, audio flows over the RTCPeerConnection directly.
        guard launch.transportPreference == .websocket else { return }
        guard audio.format == inputFormat else { throw VoiceError.invalidAudio }
        guard let session else { throw VoiceError.invalidState }
        try await session.appendAudio(
            audio.data,
            sampleRate: UInt32(inputFormat.sampleRate),
            channels: UInt16(inputFormat.channels)
        )
    }

    func send(text: String) async throws {
        guard !closed, let session else { throw VoiceError.invalidState }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        output.yield(.userTranscript(itemID: UUID().uuidString, text: trimmed, isFinal: true))
        try await session.appendText(trimmed)
    }

    func interrupt(_ interruption: VoiceInterruption) async throws {
        // Codex Realtime performs server-side turn barge-in automatically on WebRTC;
        // VoiceSession flushes local playback for WebSocket.
        _ = interruption
    }

    func submitToolResult(callID: String, result: AgentToolResult) async throws {
        throw VoiceError.unavailable("Codex Realtime executes MCP tools directly.")
    }

    func close() async {
        guard !closed else { return }
        closed = true
        eventReaderTask?.cancel()
        eventReaderTask = nil
        levelPollingTask?.cancel()
        levelPollingTask = nil
        await onToolEvent(nil)
        onLevels(0, 0)
        peer?.close()
        peer = nil
        let oldSession = session
        session = nil
        await oldSession?.close()
        await releaseIDEMCP(launch.sessionKey)
        output.finish()
    }

    // MARK: - Event Handling

    private func handleCodexEvent(_ event: CodexRealtimeSession.Event) async {
        guard !closed else { return }
        let params = event.params
        let isUser = params["role"]?.stringValue == "user"

        switch event.method {
        case "thread/realtime/started":
            if launch.transportPreference == .websocket && !isReadyEmitted {
                isReadyEmitted = true
                output.yield(.ready)
                await onConnected()
            }

        case "thread/realtime/sdp":
            guard let peer, let sdp = params["sdp"]?.stringValue else { return }
            do {
                try await peer.accept(answer: sdp)
            } catch {
                await failAndClose("WebRTC SDP negotiation failed: \(error.localizedDescription)")
            }

        case "thread/realtime/outputAudio/delta":
            guard launch.transportPreference == .websocket else { return }
            guard let audio = params["audio"],
                  let encoded = audio["data"]?.stringValue,
                  let data = Data(base64Encoded: encoded),
                  let rate = audio["sampleRate"]?.numberValue,
                  let channels = audio["numChannels"]?.numberValue,
                  rate > 0, rate <= 192_000, channels > 0, channels <= 8 else {
                return
            }
            let itemID = audio["itemId"]?.stringValue ?? ensureAssistantItemID()
            if let frame = try? VoiceAudioFrame(
                data: data,
                format: VoicePCMFormat(sampleRate: Int(rate), channels: Int(channels))
            ) {
                output.yield(.assistantAudio(itemID: itemID, frame))
            }

        case "thread/realtime/transcript/delta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty else { return }
            if isUser {
                if !receivedUserDeltas {
                    output.yield(.userSpeechStarted)
                    await launch.onUserTurn()
                }
                receivedUserDeltas = true
                return
            }
            let itemID = ensureAssistantItemID()
            let normalized = receivedAssistantDeltas ? delta : String(delta.drop(while: \.isWhitespace))
            receivedAssistantDeltas = true
            if !normalized.isEmpty {
                output.yield(.assistantText(itemID: itemID, delta: normalized))
            }

        case "thread/realtime/transcript/done":
            let text = (params["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if isUser {
                if !text.isEmpty {
                    output.yield(.userSpeechStopped)
                    if !receivedUserDeltas { await launch.onUserTurn() }
                    output.yield(.userTranscript(itemID: UUID().uuidString, text: text, isFinal: true))
                }
                receivedUserDeltas = false
            } else {
                let itemID = currentAssistantItemID ?? UUID().uuidString
                if !receivedAssistantDeltas && !text.isEmpty {
                    output.yield(.assistantText(itemID: itemID, delta: text))
                }
                output.yield(.assistantDone(itemID: itemID))
                currentAssistantItemID = nil
                receivedAssistantDeltas = false
            }

        case "item/started", "item/completed":
            if let activity = PetCodexRealtimeEngine.toolEvent(method: event.method, params: params) {
                await onToolEvent(activity)
                output.yield(.toolActivity(activity))
            }

        case "turn/completed":
            await onToolEvent(.turnEnded(TurnResult()))

        case "thread/realtime/error":
            let msg = params["message"]?.stringValue ?? "Codex Realtime reported an error."
            await failAndClose(msg)

        case "thread/realtime/closed":
            let reason = params["reason"]?.stringValue
            output.yield(.closed(reason: reason))
            await close()

        default:
            break
        }
    }

    private func handlePeerStateChange(_ state: CodexRealtimePeer.State) async {
        guard !closed else { return }
        switch state {
        case .connected:
            if !isReadyEmitted {
                isReadyEmitted = true
                output.yield(.ready)
                await onConnected()
                startLevelPolling()
            }
        case .failed:
            await failAndClose("WebRTC audio connection to Codex Realtime was lost.")
        }
    }

    private func startLevelPolling() {
        guard let peer else { return }
        levelPollingTask?.cancel()
        levelPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let levels = await peer.levels()
                guard !Task.isCancelled, let self else { break }
                let inLevel = Float(min(1.0, levels.input * 3.5))
                let outLevel = PetSpeechEnvelope.openness(rms: Float(levels.output))
                self.onLevels(inLevel, outLevel)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func handleStreamEnded() async {
        guard !closed else { return }
        output.yield(.closed(reason: nil))
        await close()
    }

    private func failAndClose(_ message: String) async {
        guard !closed else { return }
        logger.error("Codex realtime error: \(message, privacy: .public)")
        output.yield(.failed(.transport(message)))
        await close()
    }

    private func ensureAssistantItemID() -> String {
        if let existing = currentAssistantItemID {
            return existing
        }
        let next = UUID().uuidString
        currentAssistantItemID = next
        return next
    }


}

// Realtime tool activity reaches PetController for visuals and gated activity cues.

// MARK: - Nonisolated WebRTC Peer Connection

nonisolated final class CodexRealtimePeer: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    enum State: Sendable {
        case connected
        case failed
    }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let onStateChange: @Sendable (State) -> Void
    private let lock = NSLock()
    private var connection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var eventsChannel: RTCDataChannel?
    private var remoteSpeechEnergy = PetRemoteSpeechEnergy()

    init(onStateChange: @escaping @Sendable (State) -> Void) {
        self.onStateChange = onStateChange
        super.init()
    }

    func makeOffer() async throws -> String {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard let peerConn = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw VoiceError.unavailable("Failed to create WebRTC peer connection.")
        }

        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
            "googEchoCancellation": "true",
            "googNoiseSuppression": "true",
            "googAutoGainControl": "true",
            "googHighpassFilter": "true",
        ])
        let source = Self.factory.audioSource(with: audioConstraints)
        let micTrack = Self.factory.audioTrack(with: source, trackId: "rxcode-mic")
        peerConn.add(micTrack, streamIds: ["rxcode-pet"])
        let dataChannel = peerConn.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())

        lock.withLock {
            connection = peerConn
            audioTrack = micTrack
            eventsChannel = dataChannel
        }

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peerConn.offer(for: constraints) { @Sendable sdp, error in
                if let sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: error ?? VoiceError.invalidState)
                }
            }
        }

        try await applyDescription(offer, setter: peerConn.setLocalDescription)

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while peerConn.iceGatheringState != .complete && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(45))
        }

        guard let completeSDP = peerConn.localDescription?.sdp else {
            throw VoiceError.invalidState
        }
        return completeSDP
    }

    func accept(answer: String) async throws {
        let peerConn = lock.withLock { connection }
        guard let peerConn else { throw VoiceError.invalidState }
        let desc = RTCSessionDescription(type: .answer, sdp: answer)
        try await applyDescription(desc, setter: peerConn.setRemoteDescription)
    }

    func setMicrophoneMuted(_ muted: Bool) {
        lock.lock()
        let track = audioTrack
        lock.unlock()
        track?.isEnabled = !muted
    }

    func levels() async -> (input: Double, output: Double) {
        let peerConn = lock.withLock { connection }
        guard let peerConn else { return (0, 0) }
        return await withCheckedContinuation { continuation in
            peerConn.statistics { @Sendable report in
                var result = (input: 0.0, output: 0.0)
                for stat in report.statistics.values {
                    let level = (stat.values["audioLevel"] as? NSNumber)?.doubleValue ?? 0
                    switch stat.type {
                    case "media-source":
                        result.input = max(result.input, level)
                    case "inbound-rtp" where (stat.values["kind"] as? String ?? stat.values["mediaType"] as? String) == "audio":
                        self.lock.lock()
                        let audible = self.remoteSpeechEnergy.level(
                            id: stat.id,
                            energy: (stat.values["totalAudioEnergy"] as? NSNumber)?.doubleValue,
                            duration: (stat.values["totalSamplesDuration"] as? NSNumber)?.doubleValue
                        )
                        self.lock.unlock()
                        result.output = max(result.output, audible)
                    default:
                        break
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    func close() {
        lock.lock()
        let ch = eventsChannel
        let conn = connection
        eventsChannel = nil
        audioTrack = nil
        connection = nil
        lock.unlock()
        ch?.close()
        conn?.close()
    }

    private func applyDescription(
        _ description: RTCSessionDescription,
        setter: (RTCSessionDescription, @escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setter(description) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        switch state {
        case .connected:
            onStateChange(.connected)
        case .failed:
            onStateChange(.failed)
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
