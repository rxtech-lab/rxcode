import Foundation
import os
import RxAgentVoice

// MARK: - Persistent MLX TTS Worker Process

actor MLXVoiceWorker {
    private let logger = Logger(subsystem: "com.claudework", category: "MLXVoiceWorker")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var loadedModelPath: String?
    private var activeContinuations: [String: AsyncThrowingStream<VoiceAudioFrame, Error>.Continuation] = [:]
    private var workerGeneration = UUID()
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?

    func ensureStarted(
        modelDirectory: URL,
        appSupport: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        // Model preparation suspends this actor. Replacement previews must share
        // startup instead of launching two workers and losing a ready waiter.
        if let startupTask {
            try await startupTask.value
        }
        try Task.checkCancellation()
        if let process, process.isRunning, loadedModelPath == modelDirectory.path {
            return
        }
        let task = Task {
            try await startWorker(modelDirectory: modelDirectory, appSupport: appSupport, onStatus: onStatus)
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
        try Task.checkCancellation()
    }

    private func startWorker(
        modelDirectory: URL,
        appSupport: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        await shutdown()
        let token = UUID()
        workerGeneration = token

        let runtimeRoot = try await MLXMediaRuntimeInstaller.shared.prepare(
            .audio,
            appSupport: appSupport,
            status: onStatus
        )
        guard let scriptURL = Self.resolveWorkerScriptURL() else {
            throw VoiceError.unavailable("Missing bundled mlx_voice_worker.py resource.")
        }

        let proc = Process()
        proc.executableURL = runtimeRoot.appending(path: "bin/python")
        proc.arguments = ["-u", scriptURL.path, modelDirectory.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        onStatus("Warming up local voice model…")
        try proc.run()

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.loadedModelPath = modelDirectory.path

        let outHandle = outPipe.fileHandleForReading
        let outputChunks = Self.pipeChunks(outHandle)
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            var buffer = Data()
            for await chunk in outputChunks {
                guard !Task.isCancelled else { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    await self?.handleWorkerLine(line, generation: token)
                }
            }
            await self?.handleWorkerExit(generation: token)
        }

        // Drain stderr quietly for diagnostics without blocking the pipe
        let errorChunks = Self.pipeChunks(errPipe.fileHandleForReading)
        stderrTask = Task.detached(priority: .utility) { [logger] in
            for await chunk in errorChunks {
                guard !Task.isCancelled else { return }
                logger.debug("[mlx-voice] \(String(decoding: chunk, as: UTF8.self), privacy: .public)")
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyWaiter = cont
        }
    }

    private nonisolated static func pipeChunks(_ handle: FileHandle) -> AsyncStream<Data> {
        // Match ACP's pipe reader: FileHandle.bytes.lines can buffer a live
        // Darwin pipe until EOF, which a persistent voice worker never sends.
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Double,
        langCode: String,
        locale: String,
        seed: Int
    ) throws -> AsyncThrowingStream<VoiceAudioFrame, Error> {
        guard let stdinHandle, let process, process.isRunning else {
            throw VoiceError.invalidState
        }
        let requestID = UUID().uuidString
        let (stream, continuation) = AsyncThrowingStream<VoiceAudioFrame, Error>.makeStream()
        activeContinuations[requestID] = continuation

        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.cancelRequest(id: requestID) }
            }
        }

        let payload: [String: Any] = [
            "op": "speak",
            "id": requestID,
            "text": text,
            "voice": voice,
            "speed": speed,
            "lang_code": langCode,
            // Qwen3-TTS resolves its language from the conversation locale;
            // `lang_code` follows the Kokoro preset and is only a fallback.
            "locale": locale,
            "seed": seed,
        ]
        let lineData = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A])
        try stdinHandle.write(contentsOf: lineData)
        return stream
    }

    func cancelAll() {
        if let stdinHandle, let data = try? JSONSerialization.data(withJSONObject: ["op": "cancel"]) {
            try? stdinHandle.write(contentsOf: data + Data([0x0A]))
        }
        let pending = activeContinuations.values
        activeContinuations.removeAll()
        for cont in pending {
            cont.finish()
        }
    }

    func shutdown() async {
        workerGeneration = UUID()
        cancelAll()
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(throwing: VoiceError.invalidState)
        }
        if let stdinHandle, let quit = try? JSONSerialization.data(withJSONObject: ["op": "quit"]) {
            try? stdinHandle.write(contentsOf: quit + Data([0x0A]))
            try? stdinHandle.close()
        }
        stdinHandle = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        loadedModelPath = nil
        readerTask?.cancel()
        readerTask = nil
        stderrTask?.cancel()
        stderrTask = nil
    }

    private func cancelRequest(id: String) {
        guard let cont = activeContinuations.removeValue(forKey: id) else { return }
        cont.finish()
        // The worker's cancel operation stops its current generation. A stale
        // stream must not cancel a newer preview that is already synthesizing.
        guard activeContinuations.isEmpty else { return }
        if let stdinHandle, let data = try? JSONSerialization.data(withJSONObject: ["op": "cancel", "id": id]) {
            try? stdinHandle.write(contentsOf: data + Data([0x0A]))
        }
    }

    private func handleWorkerLine(_ line: String, generation: UUID) {
        guard generation == workerGeneration else { return }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }

        switch event {
        case "ready":
            if let waiter = readyWaiter {
                readyWaiter = nil
                waiter.resume()
            }
        case "audio":
            guard let id = json["id"] as? String,
                  let b64 = json["pcm"] as? String,
                  let pcm = Data(base64Encoded: b64),
                  let cont = activeContinuations[id],
                  let frame = try? VoiceAudioFrame(
                      data: pcm,
                      format: VoicePCMFormat(sampleRate: 24_000, channels: 1)
                  ) else {
                return
            }
            cont.yield(frame)
        case "done", "cancelled":
            if let id = json["id"] as? String, let cont = activeContinuations.removeValue(forKey: id) {
                cont.finish()
            }
        case "error":
            let message = (json["message"] as? String) ?? "MLX voice synthesis failed."
            if let waiter = readyWaiter {
                readyWaiter = nil
                waiter.resume(throwing: VoiceError.unavailable(message))
            }
            if let id = json["id"] as? String, let cont = activeContinuations.removeValue(forKey: id) {
                cont.finish(throwing: VoiceError.transport(message))
            }
        default:
            break
        }
    }

    private func handleWorkerExit(generation: UUID) {
        guard generation == workerGeneration else { return }
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(throwing: VoiceError.transport("MLX voice worker exited unexpectedly."))
        }
        let pending = activeContinuations.values
        activeContinuations.removeAll()
        for cont in pending {
            cont.finish(throwing: VoiceError.transport("MLX voice worker exited before speech completed."))
        }
    }

    private static func resolveWorkerScriptURL() -> URL? {
        if let flat = Bundle.main.url(forResource: "mlx_voice_worker", withExtension: "py") {
            return flat
        }
        if let nested = Bundle.main.url(forResource: "mlx_voice_worker", withExtension: "py", subdirectory: "Pet") {
            return nested
        }
        let sourceCandidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Pet/mlx_voice_worker.py")
        if FileManager.default.fileExists(atPath: sourceCandidate.path) {
            return sourceCandidate
        }
        return nil
    }
}
