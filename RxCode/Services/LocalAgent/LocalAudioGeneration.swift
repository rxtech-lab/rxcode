import AVFoundation
import Foundation
import RxAgentCore
import RxAgentHarness
import struct RxCodeCore.AudioGenerationSettings
import enum RxCodeCore.VideoGenerationProgress

/// What a local audio model does, from its Hugging Face task.
nonisolated enum LocalAudioMode: String, Codable, Sendable {
    /// Text in, speech out — `llama-tts`.
    case speech
    /// Audio in, text out — `llama-mtmd-cli --audio`.
    case transcription

    init?(model: LocalModelInfo) {
        guard model.studioKind == .audio else { return nil }
        switch model.huggingFaceMetadata?.pipelineTag {
        case "automatic-speech-recognition", "audio-text-to-text": self = .transcription
        default: self = .speech
        }
    }

    /// The llama.cpp tool beside `llama-server` that runs this mode.
    var binaryName: String {
        switch self {
        case .speech: "llama-tts"
        case .transcription: "llama-mtmd-cli"
        }
    }

    var spec: MediaCompanionResolver.Spec {
        switch self {
        case .speech: .speech
        case .transcription: .transcription
        }
    }
}

extension LocalMediaRecipe {
    func speechArguments(model: URL, directory: URL, text: String, output: URL, settings: AudioGenerationSettings, seed: Int) -> [String] {
        let settings = settings.validated
        var arguments = ["-m", model.path]
        for companion in companions where companion.flag == "mmproj" {
            arguments += ["-mm", directory.appending(path: companion.localName).path]
        }
        arguments += [
            "-p", text, "-o", output.path,
            "-n", String(settings.maxTokens),
            "--temp", String(format: "%.2f", settings.temperature),
            "--seed", String(seed),
        ]
        if !settings.voice.isEmpty { arguments += ["--tts-voice", settings.voice] }
        if !settings.language.isEmpty { arguments += ["--tts-lang", settings.language] }
        return arguments
    }

    func transcriptionArguments(model: URL, directory: URL, audio: String, instruction: String, settings: AudioGenerationSettings) -> [String] {
        let settings = settings.validated
        var arguments = ["-m", model.path]
        for companion in companions where companion.flag == "mmproj" {
            arguments += ["--mmproj", directory.appending(path: companion.localName).path]
        }
        var prompt = instruction
        if !settings.language.isEmpty { prompt += " The audio is in language code \(settings.language)." }
        arguments += [
            "--audio", audio, "-p", prompt,
            "-n", String(settings.maxTokens), "--temp", "0",
            "--no-warmup",
        ]
        return arguments
    }
}

/// Speaks text or transcribes audio with a local audio model.
///
/// Registered with the local harness; chat models never see it.
nonisolated struct AudioGenerationTool: HarnessTool {
    struct Job: Sendable {
        /// Picks settings per prompt when the model's settings form is in auto mode.
        var taskModel: VideoCompanionResolver.TaskModel? = nil
        let model: LocalModelInfo
        let mode: LocalAudioMode
        let modelsRoot: URL
        let outputDirectory: URL
        /// Finds the companion files, makes sure llama.cpp is installed and
        /// downloads what is missing; returns the binary and recipe to run.
        let prepare: @Sendable (_ status: @escaping @Sendable (_ status: String, _ actor: String?) -> Void) async throws
            -> (binary: URL, recipe: LocalMediaRecipe)
    }

    let job: @Sendable (_ modelID: String) async -> Job?
    let manager: LlamaServerManager

    var name: String { "AudioGeneration" }
    var description: String { "Speaks text or transcribes an attached audio file with the selected local audio model." }
    var parameters: RxAgentCore.JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object(["type": .string("string"), "description": .string("Text to speak, or an attached audio file to transcribe.")]),
                "model": .object(["type": .string("string"), "description": .string("The local audio model id.")]),
            ]),
            "required": .array([.string("prompt"), .string("model")]),
        ])
    }
    var isReadOnly: Bool { true }

    func execute(_ input: RxAgentCore.JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        let savedSettings = AudioGenerationSettings.load()
        let callID = context.callID
        let report: @Sendable (String, String?) -> Void = { VideoGenerationProgress.post(callID: callID, status: $0, actor: $1) }
        let status: @Sendable (String) -> Void = { report($0, nil) }
        guard case .object(let fields) = input, case .string(let message)? = fields["prompt"],
              case .string(let modelID)? = fields["model"], let job = await job(modelID) else {
            return LocalStudioTools.failure("The selected model can't make or read audio.", title: "Audio failed")
        }
        let prompt = LocalStudioPrompt(message)
        if job.mode == .transcription, prompt.audio.isEmpty {
            return LocalStudioTools.failure("Attach an audio file to transcribe.", title: "Audio failed")
        }
        if job.mode == .speech, prompt.text.isEmpty {
            return LocalStudioTools.failure("Type the text to speak.", title: "Audio failed")
        }
        let settings = savedSettings.applying(
            await StudioConfigAgent.overrides(model: job.model, modelsRoot: job.modelsRoot, prompt: prompt.text, taskModel: job.taskModel, status: status))
        do {
            if job.model.format == .mlx {
                await manager.stop()
                return try await MLXStudioMedia.audio(job: job, prompt: prompt, settings: settings, status: status)
            }
            let (binary, recipe) = try await job.prepare(report)
            await manager.stop()
            let started = Date()
            let primary = job.model.primaryFile(in: job.modelsRoot)
            let directory = job.model.directory(in: job.modelsRoot)
            let result: AudioGenerationResult
            switch job.mode {
            case .speech:
                try FileManager.default.createDirectory(at: job.outputDirectory, withIntermediateDirectories: true)
                let output = job.outputDirectory.appending(path: LocalStudioTools.fileName(for: prompt.text, fallback: "speech", extension: "wav"))
                let seed = LocalStudioTools.resolvedSeed(settings.seed)
                status("Speaking…")
                try await StableDiffusionProcess.run(
                    cli: binary, arguments: recipe.speechArguments(model: primary, directory: directory, text: prompt.text,
                                                                   output: output, settings: settings, seed: seed),
                    engine: "llama-tts", status: status
                )
                guard FileManager.default.fileExists(atPath: output.path) else {
                    return LocalStudioTools.failure("llama-tts finished without writing audio.", title: "Audio failed")
                }
                result = AudioGenerationResult(
                    mode: LocalAudioMode.speech.rawValue, savedPath: output.path, prompt: prompt.text,
                    transcript: nil, model: job.model.displayName,
                    elapsedSeconds: Int(Date().timeIntervalSince(started)),
                    durationSeconds: await Self.duration(of: output), seed: seed
                )
            case .transcription:
                let audio = prompt.audio[0]
                let instruction = prompt.text.isEmpty ? settings.transcriptionInstruction : prompt.text
                status("Listening…")
                let output = try await StableDiffusionProcess.run(
                    cli: binary, arguments: recipe.transcriptionArguments(model: primary, directory: directory, audio: audio,
                                                                          instruction: instruction, settings: settings),
                    engine: "llama-mtmd-cli", capturesOutput: true, status: status
                )
                let transcript = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else {
                    return LocalStudioTools.failure("The model returned no text for this audio.", title: "Audio failed")
                }
                result = AudioGenerationResult(
                    mode: LocalAudioMode.transcription.rawValue, savedPath: audio, prompt: instruction,
                    transcript: transcript, model: job.model.displayName,
                    elapsedSeconds: Int(Date().timeIntervalSince(started)),
                    durationSeconds: await Self.duration(of: URL(fileURLWithPath: audio)), seed: nil
                )
            }
            return HarnessToolOutput(text: LocalStudioTools.encode(result), title: job.mode == .speech ? "Generated speech" : "Transcript")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return LocalStudioTools.failure(error.localizedDescription, title: "Audio failed")
        }
    }

    static func duration(of url: URL) async -> Double? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return (duration.seconds * 10).rounded() / 10
    }
}

/// The `AudioGeneration` tool's result, as the audio studio reads it.
nonisolated struct AudioGenerationResult: Codable, Equatable {
    /// `speech` or `transcription`.
    let mode: String
    /// The spoken clip, or the transcribed source.
    let savedPath: String
    let prompt: String
    let transcript: String?
    let model: String
    let elapsedSeconds: Int
    let durationSeconds: Double?
    let seed: Int?
}
