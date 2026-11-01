import Foundation
import RxAgentHarness
import struct RxCodeCore.ImageGenerationSettings
import struct RxCodeCore.AudioGenerationSettings
import struct RxCodeCore.VideoGenerationSettings

/// Media architectures live in separate MLX packages, not MLX Swift LM.
/// Each package gets a versioned environment; model paths always refer to the
/// selected download, never an engine's default model.
nonisolated enum MLXMediaPackage: String, Sendable {
    case image, audio, video

    var requirements: [String] {
        switch self {
        case .image: ["mflux==0.24.0"]
        // Kokoro's text processing is optional in mlx-audio. misaki's `en` extra is spelled
        // out to leave out its transformer backend, which would pull in PyTorch.
        case .audio: ["mlx-audio==0.6.3", "misaki[zh]==0.9.4", "num2words==0.5.14", "phonemizer-fork==3.3.2",
                      "espeakng-loader==0.2.4", "spacy==3.8.18",
                      "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"]
        case .video: ["mlx-video @ https://github.com/Blaizzy/mlx-video/archive/87db56a51758fefb748a359b90a5283bb8ba4837.zip"]
        }
    }

    /// Stored beside the runtime; a mismatch reinstalls into the same environment.
    var marker: String { requirements.joined(separator: "\n") }

    var version: String {
        switch self {
        case .image: "0.24.0"
        case .audio: "0.6.3"
        case .video: "87db56a51758"
        }
    }
}

actor MLXMediaRuntimeInstaller {
    static let shared = MLXMediaRuntimeInstaller()
    private var installs: [String: Task<URL, Error>] = [:]

    func prepare(_ package: MLXMediaPackage, appSupport: URL, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard LlamaRuntimeInstaller.isAppleSilicon else { throw MLXRuntimeInstaller.InstallError.unsupportedMac }
        let root = appSupport.appending(path: "MLXMedia/\(package.rawValue)-\(package.version)")
        let python = root.appending(path: "bin/python")
        let marker = root.appending(path: ".rxcode-ready")
        if FileManager.default.isExecutableFile(atPath: python.path),
           (try? String(contentsOf: marker, encoding: .utf8)) == package.marker { return root }
        if let existing = installs[root.path] { return try await existing.value }
        let task = Task<URL, Error> {
            try await DownloadCenter.track("MLX \(package.rawValue) runtime", kind: .modelRuntime) { item in
                DownloadCenter.update(item, phase: .installing)
                let candidates = [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/uv").path,
                                  "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
                guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                    throw MLXStudioMedia.Failure("MLX media setup needs uv. Install uv, then generate again; RxCode will create an isolated Python runtime.")
                }
                let uv = URL(filePath: path)
                try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                status("Setting up MLX \(package.rawValue) runtime…")
                if !FileManager.default.isExecutableFile(atPath: python.path) {
                    try await StableDiffusionProcess.run(cli: uv, arguments: ["venv", "--python", "3.12", root.path], engine: "MLX setup", status: status)
                }
                try Task.checkCancellation()
                try await StableDiffusionProcess.run(cli: uv, arguments: ["pip", "install", "--python", python.path] + package.requirements, engine: "MLX setup", status: status)
                try Task.checkCancellation()
                try package.marker.write(to: marker, atomically: true, encoding: .utf8)
                return root
            }
        }
        installs[root.path] = task
        defer { installs[root.path] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

nonisolated enum MLXStudioMedia {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct ImageFamily: Equatable, Sendable {
        let command: String
        let base: String
        let steps: Int
        let guidance: Double
    }

    static func imageFamily(_ model: LocalModelInfo) -> ImageFamily? {
        let name = model.repoID.lowercased()
            .replacingOccurrences(of: "qwen-image-2-1", with: "qwen-image-2.1")
        // Editing and later model generations have different entry points.
        guard !name.contains("edit"), !name.contains("kontext"), !name.contains("controlnet") else { return nil }
        if name.contains("z-image-turbo") || name.contains("z_image_turbo") {
            return ImageFamily(command: "mflux-generate-z-image-turbo", base: "z-image-turbo", steps: 9, guidance: 0)
        }
        if name.contains("flux.1-schnell") || name.contains("flux1-schnell") {
            return ImageFamily(command: "mflux-generate", base: "schnell", steps: 4, guidance: 0)
        }
        if name.contains("flux.1-dev") || name.contains("flux1-dev") {
            return ImageFamily(command: "mflux-generate", base: "dev", steps: 20, guidance: 3.5)
        }
        if name.contains("qwen-image-2.1") {
            let turbo = name.contains("turbo")
            return ImageFamily(command: "mflux-generate-qwen-2.1",
                               base: turbo ? "qwen-image-2.1-turbo" : "qwen-image-2.1",
                               steps: turbo ? 8 : 40, guidance: turbo ? 0 : 1)
        }
        if name.contains("qwen-image"), !name.contains("2.0"), !name.contains("2-0") {
            return ImageFamily(command: "mflux-generate-qwen", base: "qwen-image", steps: 30, guidance: 4)
        }
        return nil
    }

    enum VideoFamily: Sendable { case ltx, wan }
    static func videoFamily(_ model: LocalModelInfo) -> VideoFamily? {
        let name = model.repoID.lowercased()
        if name.contains("ltx-2") || name.contains("ltx2") { return .ltx }
        if name.contains("wan2.1") || name.contains("wan2.2") || name.contains("wan-2.1") || name.contains("wan-2.2") { return .wan }
        return nil
    }

    static func imageArguments(family: ImageFamily, directory: URL, prompt: String, output: URL,
                               settings: ImageGenerationSettings, seed: Int, source: String? = nil, pipeline: ImagePipeline = .imageToImage,
                               editStrength: Double = 1) -> [String] {
        var args = ["--model", directory.path, "--base-model", family.base,
                    "--prompt", prompt, "--output", output.path,
                    "--width", String(settings.width), "--height", String(settings.height),
                    "--steps", String(settings.steps(recommended: family.steps)), "--seed", String(seed)]
        if family.guidance > 0 { args += ["--guidance", String(settings.cfgScale(recommended: family.guidance))] }
        if family.base.hasPrefix("qwen-image") { args += ["--negative-prompt", settings.negativePrompt] }
        if let source, pipeline != .textToImage {
            if pipeline == .instructionEdit {
                args += ["--image-paths", source]
                if editStrength < 1 { args += ["--strength", String(editStrength)] }
            } else {
                args += ["--image-path", source, "--image-strength", String(1 - settings.refineStrength)]
            }
        }
        return args
    }

    /// With a `session`, the pipeline its setup agent chose is reused for later requests of
    /// the same shape; the agent and the validation run only rerun when generation fails.
    static func image(job: ImageGenerationTool.Job, prompt: LocalStudioPrompt, settings: ImageGenerationSettings,
                      session: String? = nil, status: @escaping @Sendable (String) -> Void) async throws -> HarnessToolOutput {
        let settings = settings.validated
        let directory = job.model.directory(in: job.modelsRoot)
        let key = session.map {
            ImagePipelineMemory.key(session: $0, model: job.model.id, variant: prompt.images.isEmpty ? "mlx-text" : "mlx-source")
        }
        let root = try await MLXMediaRuntimeInstaller.shared.prepare(.image, appSupport: job.modelsRoot.deletingLastPathComponent(), status: status)
        // A plan chosen for this request already carries its edit strength; a remembered one does not.
        var configured = false
        return try await ImageEngineValidation.remembered(key: key, configure: { (failure: (config: ImagePlan, error: String)?) in
            // Without a setup agent there is nothing to repair a failed pipeline with.
            if let failure, job.taskModel == nil { throw Failure(failure.error) }
            configured = true
            let initialPlan = try await selectImagePlan(job: job, prompt: prompt, previous: failure?.config,
                                                        failure: failure?.error, status: status)
            return try await ImageEngineValidation.run(initial: initialPlan, test: { candidate, output in
                try await StableDiffusionProcess.run(cli: root.appending(path: "bin/\(candidate.command)"),
                    arguments: imageArguments(family: candidate.family, directory: directory,
                        prompt: candidate.pipeline == .textToImage ? ImageEngineValidation.prompt : "Render this image in cartoon style",
                        output: output, settings: ImageEngineValidation.settings, seed: 42,
                        source: candidate.source(from: prompt), pipeline: candidate.pipeline, editStrength: candidate.strength),
                    engine: "MFLUX validation", status: status)
            }, repair: { candidate, failure in
                try await selectImagePlan(job: job, prompt: prompt, previous: candidate, failure: failure, status: status)
            }, status: status)
        }, generate: { plan in
            let family = plan.family
            let source = plan.source(from: prompt)
            let editStrength = configured ? plan.strength
                : await selectEditStrength(job: job, prompt: prompt, plan: plan, status: status)
            let output = try outputURL(in: job.outputDirectory, prompt: prompt.text, ext: "png")
            let seed = LocalStudioTools.resolvedSeed(settings.seed)
            status(source == nil ? "Generating with MLX…" : "Refining with MLX…")
            let started = Date()
            do {
                try await StableDiffusionProcess.run(cli: root.appending(path: "bin/\(plan.command)"),
                    arguments: imageArguments(family: family, directory: directory, prompt: prompt.text,
                                              output: output, settings: settings, seed: seed, source: source, pipeline: plan.pipeline,
                                              editStrength: editStrength),
                    engine: "MFLUX", status: status)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            guard let size = ImageGenerationTool.pixelSize(of: output.path) else {
                try? FileManager.default.removeItem(at: output)
                throw Failure("MFLUX finished without writing a readable image.")
            }
            let result = ImageGenerationResult(savedPath: output.path, prompt: prompt.text, model: job.model.displayName,
                elapsedSeconds: Int(Date().timeIntervalSince(started)), width: size.width, height: size.height,
                seed: seed, steps: settings.steps(recommended: family.steps), sourcePath: source)
            return HarnessToolOutput(text: LocalStudioTools.encode(result), title: "Generated image")
        }, status: status)
    }

    static func audio(job: AudioGenerationTool.Job, prompt: LocalStudioPrompt, settings: AudioGenerationSettings,
                      status: @escaping @Sendable (String) -> Void) async throws -> HarnessToolOutput {
        let settings = settings.validated
        let root = try await MLXMediaRuntimeInstaller.shared.prepare(.audio, appSupport: job.modelsRoot.deletingLastPathComponent(), status: status)
        let output = try outputURL(in: job.outputDirectory, prompt: prompt.text, ext: job.mode == .speech ? "wav" : "txt")
        let modelPath = job.model.directory(in: job.modelsRoot).path
        let started = Date()
        let result: AudioGenerationResult
        if job.mode == .speech {
            status("Speaking with MLX…")
            // The upstream CLI does not expose a seed; don't report an unused seed.
            var args = ["-m", "mlx_audio.tts.generate", "--verbose", "--model", modelPath, "--text", prompt.text,
                        "--file_prefix", output.deletingPathExtension().path, "--audio_format", "wav", "--join_audio",
                        "--max_tokens", String(settings.maxTokens), "--temperature", String(settings.temperature)]
            if !settings.voice.isEmpty { args += ["--voice", settings.voice] }
            if !settings.language.isEmpty { args += ["--lang_code", settings.language] }
            let log = try await StableDiffusionProcess.run(cli: root.appending(path: "bin/python"), arguments: args, engine: "MLX Audio", capturesOutput: true, status: status)
            guard let duration = await AudioGenerationTool.duration(of: output), duration > 0 else {
                throw Failure(audioEngineError(in: log) ?? "MLX Audio finished without writing playable speech.")
            }
            result = AudioGenerationResult(mode: "speech", savedPath: output.path, prompt: prompt.text, transcript: nil,
                model: job.model.displayName, elapsedSeconds: Int(Date().timeIntervalSince(started)), durationSeconds: duration, seed: nil)
        } else {
            guard let audio = prompt.audio.first else { throw Failure("Attach an audio file to transcribe.") }
            status("Listening with MLX…")
            var args = ["-m", "mlx_audio.stt.generate", "--verbose", "--model", modelPath, "--audio", audio,
                        "--output-path", output.deletingPathExtension().path, "--format", "txt", "--max-tokens", String(settings.maxTokens)]
            if !settings.language.isEmpty { args += ["--language", settings.language] }
            let instruction = prompt.text.isEmpty ? settings.transcriptionInstruction : prompt.text
            if !instruction.isEmpty { args += ["--prompt", instruction] }
            try await StableDiffusionProcess.run(cli: root.appending(path: "bin/python"), arguments: args, engine: "MLX Audio", status: status)
            let transcript = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw Failure("MLX Audio returned an empty transcript.") }
            result = AudioGenerationResult(mode: "transcription", savedPath: audio, prompt: instruction, transcript: transcript,
                model: job.model.displayName, elapsedSeconds: Int(Date().timeIntervalSince(started)),
                durationSeconds: await AudioGenerationTool.duration(of: URL(filePath: audio)), seed: nil)
        }
        return HarnessToolOutput(text: LocalStudioTools.encode(result), title: job.mode == .speech ? "Generated speech" : "Transcript")
    }

    /// `mlx_audio.tts.generate` prints its failures and still exits 0.
    static func audioEngineError(in log: String) -> String? {
        log.split(whereSeparator: \.isNewline).last { $0.hasPrefix("Import error: ") || $0.hasPrefix("Error loading model: ") }
            .map { "MLX Audio couldn't generate speech. \($0.drop { $0 != ":" }.dropFirst(2))" }
    }

    static func videoArguments(family: VideoFamily, model: LocalModelInfo, directory: URL, prompt: LocalStudioPrompt,
                               output: URL, settings: VideoGenerationSettings) throws -> [String] {
        let isLTX = family == .ltx
        let grid = isLTX ? 8 : 4
        let frames = max(grid + 1, ((settings.frames - 1) / grid) * grid + 1)
        var args = ["-m", isLTX ? "mlx_video.models.ltx_2.generate" : "mlx_video.models.wan_2.generate",
                    isLTX ? "--model-repo" : "--model-dir", directory.path,
                    "--prompt", prompt.text, "--output-path", output.path,
                    "--width", String(settings.width), "--height", String(settings.height),
                    "--num-frames", String(frames), "--seed", String(LocalStudioTools.resolvedSeed(settings.seed))]
        if isLTX {
            let distilled = model.repoID.lowercased().contains("distilled")
            args += ["--pipeline", distilled ? "distilled" : "dev", "--fps", String(settings.fps)]
            if !distilled { args += ["--steps", String(settings.steps)] }
        } else {
            // Wan uses the checkpoint's sample_fps and has no CLI fps override.
            args += ["--steps", String(settings.steps)]
        }
        if let image = prompt.images.first { args += ["--image", image] }
        if model.huggingFaceMetadata?.pipelineTag == "image-to-video", prompt.images.isEmpty {
            throw Failure("Attach an image for this image-to-video model.")
        }
        return args
    }

    static func video(job: VideoGenerationTool.Job, prompt: LocalStudioPrompt, settings: VideoGenerationSettings,
                      status: @escaping @Sendable (String) -> Void) async throws -> HarnessToolOutput {
        guard let family = videoFamily(job.model) else { throw Failure("This video architecture has no MLX adapter yet.") }
        let settings = settings.validated
        let output = try outputURL(in: job.outputDirectory, prompt: prompt.text, ext: "mp4")
        let args = try videoArguments(family: family, model: job.model, directory: job.model.directory(in: job.modelsRoot),
                                     prompt: prompt, output: output, settings: settings)
        let root = try await MLXMediaRuntimeInstaller.shared.prepare(.video, appSupport: job.modelsRoot.deletingLastPathComponent(), status: status)
        status(family == .wan ? "Generating with MLX (checkpoint frame rate)…" : "Generating with MLX…")
        let started = Date()
        try await StableDiffusionProcess.run(cli: root.appending(path: "bin/python"), arguments: args, engine: "MLX Video", status: status)
        guard let duration = await AudioGenerationTool.duration(of: output), duration > 0 else { throw Failure("MLX Video finished without writing a playable video.") }
        let result = VideoGenerationResult(savedPath: output.path, prompt: prompt.text, model: job.model.displayName,
            elapsedSeconds: Int(Date().timeIntervalSince(started)), width: settings.width, height: settings.height,
            sourcePath: prompt.images.first)
        return HarnessToolOutput(text: result.json, title: "Generated video")
    }

    private static func outputURL(in directory: URL, prompt: String, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = LocalStudioTools.fileName(for: prompt, fallback: "generation", extension: ext)
        // Separate concurrent takes even when they have the same prompt and second.
        return directory.appending(path: "\(UUID().uuidString.prefix(8))-\(name)")
    }
}
