import Foundation
import os
import RxAgentClients
import RxAgentCore
import RxAgentVoice
import RxCodeCore

// MARK: - Pipeline Voice Engine (Local Speech + Custom Agent + Streaming Local Voice)

/// Uses `RxAgentVoice.PipelineVoiceEngine` with a sentence-streaming synthesizer
/// queue so local TTS begins speaking as soon as the first sentence streams from
/// any configured RxCode agent (Claude Code, Codex, ACP client, or Local Agent).
struct PetStreamingPipelineVoiceEngine: VoiceEngine {
    let displayName = "Local Speech + Custom Agent"
    let capabilities = VoiceEngineCapabilities(canCancel: true, runsTools: true)

    let recognizer: PetLocalSpeechRecognizer
    let synthesizer: PetLocalSpeechSynthesizer
    let responder: PetCustomAgentResponder
    let readinessCheck: @Sendable () async -> VoiceEngineReadiness

    func readiness() async -> VoiceEngineReadiness {
        await readinessCheck()
    }

    func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection {
        let queue = SentenceStreamingTTSCoordinator(baseSynthesizer: synthesizer)
        await responder.setSentenceQueue(queue, sessionInstructions: config.instructions)
        let sdkPipeline = PipelineVoiceEngine(
            recognizer: recognizer.asSDKAdapter(),
            synthesizer: queue.asSDKAdapter(),
            responder: responder
        )
        return try await sdkPipeline.connect(config)
    }
}

// MARK: - Sentence-Streaming TTS Coordinator

/// Receives sentences from `PetCustomAgentResponder` as `.textDelta` tokens stream,
/// synthesizes them sequentially in the background, and yields `VoiceAudioFrame`s
/// immediately when `PipelineVoiceEngine` awaits `synthesize(_:)` so there is minimal
/// pause between agent token generation and local voice playback.
actor SentenceStreamingTTSCoordinator {
    private let baseSynthesizer: PetLocalSpeechSynthesizer
    private var chunker = SpokenTextChunker()
    private var frameContinuation: AsyncThrowingStream<VoiceAudioFrame, Error>.Continuation?
    private var prefetchedStream: AsyncThrowingStream<VoiceAudioFrame, Error>?
    private var synthesisChainTask: Task<Void, Never>?
    private var queuedSentences: [String] = []
    private var turnFinished = false
    private var generation = UUID()

    init(baseSynthesizer: PetLocalSpeechSynthesizer) {
        self.baseSynthesizer = baseSynthesizer
    }

    nonisolated func asSDKAdapter() -> LocalSpeechSynthesizerAdapter {
        LocalSpeechSynthesizerAdapter(
            synthesize: { fullText in try await self.consumeOrSynthesize(fallbackFullText: fullText) },
            cancelAll: { await self.cancelAll() }
        )
    }

    func beginTurn() {
        cancelCurrentStreamOnly()
        let token = UUID()
        generation = token
        chunker.reset()
        queuedSentences.removeAll()
        turnFinished = false

        let (stream, continuation) = AsyncThrowingStream<VoiceAudioFrame, Error>.makeStream()
        prefetchedStream = stream
        frameContinuation = continuation

        synthesisChainTask = Task { [weak self] in
            await self?.runWorkerLoop(token: token)
        }
    }

    func appendDelta(_ delta: String) {
        let ready = chunker.append(delta)
        if !ready.isEmpty {
            queuedSentences.append(contentsOf: ready)
        }
    }

    func flushPendingSentences() {
        let trailing = chunker.flush()
        if !trailing.isEmpty {
            queuedSentences.append(contentsOf: trailing)
        }
    }

    func markTurnComplete() {
        flushPendingSentences()
        turnFinished = true
    }

    func consumeOrSynthesize(fallbackFullText: String) async throws -> AsyncThrowingStream<VoiceAudioFrame, Error> {
        markTurnComplete()
        if let stream = prefetchedStream {
            prefetchedStream = nil
            return stream
        }
        return try await baseSynthesizer.synthesize(fallbackFullText)
    }

    func cancelAll() async {
        cancelCurrentStreamOnly()
        await baseSynthesizer.cancelAll()
    }

    private func cancelCurrentStreamOnly() {
        generation = UUID()
        synthesisChainTask?.cancel()
        synthesisChainTask = nil
        queuedSentences.removeAll()
        chunker.reset()
        turnFinished = true
        frameContinuation?.finish()
        frameContinuation = nil
        prefetchedStream = nil
    }

    private func runWorkerLoop(token: UUID) async {
        while !Task.isCancelled && generation == token {
            if !queuedSentences.isEmpty {
                let nextSentence = queuedSentences.removeFirst()
                do {
                    let subStream = try await baseSynthesizer.synthesize(nextSentence)
                    for try await frame in subStream {
                        guard !Task.isCancelled, generation == token else { return }
                        frameContinuation?.yield(frame)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if generation == token {
                        frameContinuation?.finish(throwing: error)
                        frameContinuation = nil
                    }
                    return
                }
            } else if turnFinished {
                break
            } else {
                try? await Task.sleep(for: .milliseconds(35))
            }
        }
        if generation == token {
            frameContinuation?.finish()
            frameContinuation = nil
        }
    }
}

// MARK: - Custom Agent Voice Responder (Supports Codex, Claude, ACP, & Local Agent)

actor PetCustomAgentResponder: VoiceResponder {
    struct ResolvedTurnSetup: Sendable {
        var client: any RxAgentCore.AgentClient
        var sendRequest: AgentSendRequest
        var sessionKey: String
    }

    private let logger = Logger(subsystem: "com.claudework", category: "PetCustomAgentResponder")
    private let buildTurnSetup: @Sendable (_ userText: String, _ instructions: String, _ resumeSessionID: String?) async throws -> ResolvedTurnSetup
    private let onToolEvent: @Sendable (AgentEvent?) async -> Void

    private var activeClient: (any RxAgentCore.AgentClient)?
    private var activeTurnID: UUID?
    private var persistedResumeSessionID: String?
    private var sentenceQueue: SentenceStreamingTTSCoordinator?
    private var sessionInstructions: String = ""

    init(
        buildTurnSetup: @escaping @Sendable (_ userText: String, _ instructions: String, _ resumeSessionID: String?) async throws -> ResolvedTurnSetup,
        onToolEvent: @escaping @Sendable (AgentEvent?) async -> Void
    ) {
        self.buildTurnSetup = buildTurnSetup
        self.onToolEvent = onToolEvent
    }

    func setSentenceQueue(_ queue: SentenceStreamingTTSCoordinator, sessionInstructions: String) {
        self.sentenceQueue = queue
        self.sessionInstructions = sessionInstructions
    }

    func resetConversation() {
        persistedResumeSessionID = nil
    }

    func respond(to text: String) async throws -> AsyncStream<AgentEvent> {
        await cancel()
        let setup = try await buildTurnSetup(text, sessionInstructions, persistedResumeSessionID)
        activeClient = setup.client
        activeTurnID = setup.sendRequest.turnID
        await sentenceQueue?.beginTurn()

        let upstream = setup.client.send(setup.sendRequest)
        let queue = sentenceQueue
        let toolEventHandler = onToolEvent

        return AsyncStream { continuation in
            let forwardTask = Task { [weak self] in
                for await event in upstream {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .sessionStarted(let info):
                        await self?.recordResumeSessionID(info.nativeSessionID)
                        continuation.yield(event)
                    case .textDelta(let delta):
                        await queue?.appendDelta(delta)
                        continuation.yield(event)
                    case .toolCallStarted:
                        await toolEventHandler(event)
                        continuation.yield(event)
                        await queue?.flushPendingSentences()
                    case .toolCallResult:
                        await toolEventHandler(event)
                        continuation.yield(event)
                    case .turnEnded:
                        await toolEventHandler(event)
                        await queue?.markTurnComplete()
                        continuation.yield(event)
                    case .failed:
                        await toolEventHandler(event)
                        await queue?.cancelAll()
                        continuation.yield(event)
                    default:
                        continuation.yield(event)
                    }
                }
                await toolEventHandler(nil)
                await queue?.markTurnComplete()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forwardTask.cancel()
            }
        }
    }

    func cancel() async {
        await onToolEvent(nil)
        await sentenceQueue?.cancelAll()
        if let turnID = activeTurnID, let client = activeClient {
            activeTurnID = nil
            activeClient = nil
            await client.cancel(turn: turnID)
        }
    }

    private func recordResumeSessionID(_ id: String) {
        if !id.isEmpty {
            persistedResumeSessionID = id
        }
    }
}

nonisolated enum PetCodexRealtimeConnectionFriendlyTool {
    static func describe(_ raw: String) -> String {
        // Realtime events already carry a display label; pipeline events carry raw names.
        if ["Using ", "Running ", "Editing ", "Searching "].contains(where: raw.hasPrefix) {
            return raw
        }
        let cleaned = raw
            .replacingOccurrences(of: "mcp__rxcode-ide__", with: "")
            .replacingOccurrences(of: "mcp__rxcode_ide__", with: "")
            .replacingOccurrences(of: "ide__", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return "Using \(cleaned)"
    }
}
