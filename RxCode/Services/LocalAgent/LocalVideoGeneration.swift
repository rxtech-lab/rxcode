import Foundation
import Synchronization
import RxAgentCore
import RxAgentHarness
// RxCodeCore also has a `JSONValue`; the harness speaks RxAgentCore's, so
// it is qualified throughout this file.
import RxCodeCore

/// How to run a downloaded video model with stable-diffusion.cpp: the
/// companion files it needs beside the denoiser, and the `sd-cli` flags.
///
/// Video classification uses saved Hugging Face task metadata. This recipe
/// selects supported runtime flags by repository and filename; currently only
/// MiniMax-H3 has a recipe. Which companion files to use is looked up by
/// the task model (`VideoCompanionResolver`), without built-in companion paths.
nonisolated struct LocalVideoRecipe: Codable, Equatable, Sendable {
    struct Companion: Codable, Equatable, Sendable {
        let repoID: String
        /// Path in the repository.
        let file: String
        var localName: String { (file as NSString).lastPathComponent }
    }

    let textEncoder: Companion
    let videoVAE: Companion
    let audioVAE: Companion

    var companions: [Companion] { [textEncoder, videoVAE, audioVAE] }

    init(textEncoder: Companion, videoVAE: Companion, audioVAE: Companion) {
        self.textEncoder = textEncoder
        self.videoVAE = videoVAE
        self.audioVAE = audioVAE
    }

    /// Runtime compatibility is separate from discovering companion files.
    static func supports(_ model: LocalModelInfo) -> Bool {
        guard model.format == .gguf, model.repoID.lowercased().contains("minimax-h3"),
              let file = model.files.first?.lowercased() else { return false }
        return file.replacingOccurrences(of: "-", with: "_").hasPrefix("minimax_h3_")
            && file.hasSuffix(".gguf")
    }

    /// `--mode vid_gen` and `--cfg-scale 1.0` are required: H3 otherwise takes
    /// the image path or aborts on the default guidance of 7.0. The 32B text
    /// encoder runs on the CPU so the denoiser keeps the GPU's working set.
    func arguments(denoiser: URL, directory: URL, prompt: String, output: URL, settings: VideoGenerationSettings = .init()) -> [String] {
        let settings = settings.validated
        return
        [
            "--mode", "vid_gen",
            "--diffusion-model", denoiser.path,
            "--llm", directory.appending(path: textEncoder.localName).path,
            "--vae", directory.appending(path: videoVAE.localName).path,
            "--audio-vae", directory.appending(path: audioVAE.localName).path,
            "--prompt", prompt,
            "--width", String(settings.width), "--height", String(settings.height),
            "--video-frames", String(settings.frames), "--fps", String(settings.fps),
            "--steps", String(settings.steps), "--cfg-scale", "1.0",
            // sd-cli otherwise seeds every clip with 42.
            "--seed", String(settings.seed),
            "--backend", "te=cpu", "--diffusion-fa",
            "--output", output.path,
        ]
    }
}

/// A "model" that answers each chat message by calling the
/// `VideoGeneration` tool, so the chat shows the clip in a dedicated card.
///
/// It has no language model of its own: a user message becomes one tool call
/// with that message as the prompt, and the tool's result ends the turn.
nonisolated struct LocalVideoHarnessModel: HarnessModel {
    let modelID: String

    var contextWindow: Int? { nil }

    func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in Self.reply(to: request, modelID: modelID) { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    static func reply(to request: HarnessModelRequest, modelID: String) -> [HarnessModelChunk] {
        // Summaries and other one-off prompts are not video requests, and a
        // returned tool result means this turn's clip is done.
        guard request.mode == .streaming, let last = request.messages.last, last.role == .user else {
            return [.finished(reason: "stop")]
        }
        let prompt = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return [.textDelta("Describe the video you want, for example: a red panda stepping along a mossy log in a misty forest, cinematic."),
                    .finished(reason: "stop")]
        }
        let arguments: RxAgentCore.JSONValue = .object(["prompt": .string(prompt), "model": .string(modelID)])
        let json = (try? JSONEncoder().encode(arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [.toolCall(HarnessToolCall(id: "video-\(UUID().uuidString)", name: VideoGenerationProgress.toolName, argumentsJSON: json)),
                .finished(reason: "tool_calls")]
    }

    /// `2026-10-31-201502-red-panda-stepping.mp4`
    static func fileName(for prompt: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let words = prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
        let slug = words.isEmpty ? "video" : words.joined(separator: "-")
        return "\(formatter.string(from: date))-\(slug).mp4"
    }
}

/// Generates a clip with stable-diffusion.cpp and saves it as an MP4.
///
/// Registered with the local harness; chat models never see it (see
/// `LocalModelContext.compact`). Progress goes out as `VideoGenerationProgress`
/// notifications because the SDK drops tool progress events.
nonisolated struct VideoGenerationTool: HarnessTool {
    struct Job: Sendable {
        let model: LocalModelInfo
        let modelsRoot: URL
        let outputDirectory: URL
        /// Finds the companion files, installs the runtime and downloads what
        /// is missing; returns `sd-cli` and the recipe to run.
        let prepare: @Sendable (_ status: @escaping @Sendable (_ status: String, _ actor: String?) -> Void) async throws
            -> (cli: URL, recipe: LocalVideoRecipe)
    }

    /// Looks up the job for a model id; nil when it is not a video model.
    let job: @Sendable (_ modelID: String) async -> Job?
    let manager: LlamaServerManager

    var name: String { VideoGenerationProgress.toolName }
    var description: String { "Generates a short video with audio from a text prompt using the selected local video model." }
    var parameters: RxAgentCore.JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object(["type": .string("string"), "description": .string("What the video shows.")]),
                "model": .object(["type": .string("string"), "description": .string("The local video model id.")]),
            ]),
            "required": .array([.string("prompt"), .string("model")]),
        ])
    }
    /// Writes only into RxCode's own Generated Videos folder.
    var isReadOnly: Bool { true }

    func execute(_ input: RxAgentCore.JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        let settings = VideoGenerationSettings.load()
        let callID = context.callID
        let report: @Sendable (String, String?) -> Void = {
            VideoGenerationProgress.post(callID: callID, status: $0, actor: $1)
        }
        let status: @Sendable (String) -> Void = { report($0, nil) }
        guard case .object(let fields) = input, case .string(let prompt)? = fields["prompt"],
              case .string(let modelID)? = fields["model"], let job = await job(modelID) else {
            return Self.failure("The selected model can't generate video.")
        }
        do {
            let (cli, recipe) = try await job.prepare(report)
            // The denoiser and encoder need the memory a chat model holds.
            await manager.stop()

            try FileManager.default.createDirectory(at: job.outputDirectory, withIntermediateDirectories: true)
            let output = job.outputDirectory.appending(path: VideoGenerationTool.fileName(for: prompt))
            // sd-cli's AVI is the one container whose audio converts cleanly.
            let avi = FileManager.default.temporaryDirectory.appending(path: "rxcode-\(UUID().uuidString).avi")
            defer { try? FileManager.default.removeItem(at: avi) }
            let arguments = recipe.arguments(
                denoiser: job.model.primaryFile(in: job.modelsRoot), directory: job.model.directory(in: job.modelsRoot),
                prompt: prompt, output: avi, settings: settings
            )
            status("Generating…")
            let started = Date()
            try await StableDiffusionProcess.run(cli: cli, arguments: arguments, status: status)
            status("Saving MP4…")
            try await AVIToMP4Converter.convert(avi: avi, to: output)
            let result = VideoGenerationResult(
                savedPath: output.path, prompt: prompt, model: job.model.displayName,
                elapsedSeconds: Int(Date().timeIntervalSince(started)),
                width: settings.width, height: settings.height
            )
            return HarnessToolOutput(text: result.json, title: "Generated video")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.failure(error.localizedDescription)
        }
    }

    static func fileName(for prompt: String) -> String { LocalVideoHarnessModel.fileName(for: prompt) }

    static func failure(_ message: String) -> HarnessToolOutput {
        let json = (try? JSONEncoder().encode(["displayError": message])).map { String(decoding: $0, as: UTF8.self) } ?? message
        return HarnessToolOutput(text: json, isError: true, title: "Video generation failed")
    }
}

/// The `VideoGeneration` tool's result, as the chat's video card reads it.
nonisolated struct VideoGenerationResult: Codable, Equatable {
    let savedPath: String
    let prompt: String
    let model: String
    let elapsedSeconds: Int
    let width: Int
    let height: Int

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Runs `sd-cli` and turns its sampling progress bar into status lines.
nonisolated enum StableDiffusionProcess {
    enum RunError: LocalizedError {
        case failed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .failed(let code, let log): "stable-diffusion.cpp exited with status \(code).\n\(log)"
            }
        }
    }

    private static let running = Mutex<Set<pid_t>>([])

    /// Physical footprint (weights, Metal buffers and runtime) of the
    /// `sd-cli` renders in flight, or nil while none is running.
    static func memoryFootprint() -> UInt64? {
        let pids = running.withLock { $0 }
        guard !pids.isEmpty else { return nil }
        return pids.reduce(UInt64(0)) { total, pid in
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return result == 0 ? total + info.ri_phys_footprint : total
        }
    }

    static func run(cli: URL, arguments: [String], status: @escaping @Sendable (String) -> Void) async throws {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        // The release keeps its dylib next to the binary.
        process.currentDirectoryURL = cli.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = ProgressReader(status: status)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { reader.consume(data) }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    _ = running.withLock { $0.remove(process.processIdentifier) }
                    pipe.fileHandleForReading.readabilityHandler = nil
                    reader.consume(pipe.fileHandleForReading.readDataToEndOfFile())
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: RunError.failed(process.terminationStatus, reader.tail))
                    }
                }
                do {
                    try process.run()
                    _ = running.withLock { $0.insert(process.processIdentifier) }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Parses `|====>   | 3/4 - 12.34s/it` and remembers the last log lines.
    final class ProgressReader: @unchecked Sendable {
        private let lock = NSLock()
        private let status: @Sendable (String) -> Void
        private var buffer = ""
        private var lines: [String] = []
        private var lastStep: String?

        init(status: @escaping @Sendable (String) -> Void) { self.status = status }

        var tail: String { lock.withLock { lines.suffix(12).joined(separator: "\n") } }

        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            let updates: [String] = lock.withLock {
                buffer += String(decoding: data, as: UTF8.self)
                // The progress bar redraws in place with carriage returns.
                var parts = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                buffer = parts.removeLast()
                var updates: [String] = []
                for part in parts where !part.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(part)
                    if lines.count > 200 { lines.removeFirst(lines.count - 200) }
                    if let step = Self.step(in: part), step != lastStep {
                        lastStep = step
                        updates.append(step)
                    }
                }
                return updates
            }
            updates.forEach(status)
        }

        /// `"Step 3/4 · 12.34s/it"` for a progress-bar line.
        static func step(in line: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: #"(\d+)/(\d+)\s*-\s*([0-9.]+)\s*(s/it|it/s)"#),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let done = Range(match.range(at: 1), in: line), let total = Range(match.range(at: 2), in: line),
                  let rate = Range(match.range(at: 3), in: line), let unit = Range(match.range(at: 4), in: line)
            else { return nil }
            return "Step \(line[done])/\(line[total]) · \(line[rate])\(line[unit])"
        }
    }
}
