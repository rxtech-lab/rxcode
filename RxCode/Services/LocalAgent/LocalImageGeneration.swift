import Foundation
import ImageIO
import RxAgentCore
import RxAgentHarness
import struct RxCodeCore.ImageGenerationSettings
import enum RxCodeCore.VideoGenerationProgress

extension LocalMediaRecipe {
    /// stable-diffusion.cpp needs GGUF or safetensors weights; MLX repos are
    /// a different runtime.
    static func supportsImage(_ model: LocalModelInfo) -> Bool {
        model.studioKind == .image && model.format == .gguf
    }

    /// `sd-cli --mode img_gen` arguments. A refine passes the source image
    /// as `--init-img`, at the source's own size.
    func imageArguments(
        model: URL, directory: URL, prompt: String, output: URL, settings: ImageGenerationSettings,
        seed: Int, refine: (path: String, width: Int, height: Int)?
    ) -> [String] {
        let settings = settings.validated
        let width = refine?.width ?? settings.width
        let height = refine?.height ?? settings.height
        var arguments = ["--mode", "img_gen", "--\(mainFlag)", model.path]
        for companion in companions {
            arguments += ["--\(companion.flag)", directory.appending(path: companion.localName).path]
        }
        arguments += [
            "--prompt", prompt,
            "--width", String(width), "--height", String(height),
            "--steps", String(settings.steps(recommended: steps ?? 20)),
            "--cfg-scale", String(format: "%.2f", settings.cfgScale(recommended: cfgScale ?? 7)),
            "--seed", String(seed),
            "--output", output.path,
        ]
        if !settings.negativePrompt.isEmpty { arguments += ["--negative-prompt", settings.negativePrompt] }
        if let sampler, !sampler.isEmpty { arguments += ["--sampling-method", sampler] }
        if let refine { arguments += ["--init-img", refine.path, "--strength", String(format: "%.2f", settings.refineStrength)] }
        // Tiled decoding keeps large images within the VAE's memory.
        if width * height > 1024 * 1024 { arguments.append("--vae-tiling") }
        return arguments
    }
}

/// Generates an image with stable-diffusion.cpp and saves it as a PNG.
///
/// Registered with the local harness; chat models never see it. Progress
/// goes out as `VideoGenerationProgress` notifications, the studios' shared
/// progress channel.
nonisolated struct ImageGenerationTool: HarnessTool {
    struct Job: Sendable {
        var taskModel: VideoCompanionResolver.TaskModel? = nil
        var repair: (@Sendable (LocalMediaRecipe, String, @escaping @Sendable (String, String?) -> Void) async throws -> (cli: URL, recipe: LocalMediaRecipe))? = nil
        var didValidate: @Sendable (LocalMediaRecipe) async -> Void = { _ in }
        let model: LocalModelInfo
        let modelsRoot: URL
        let outputDirectory: URL
        /// Finds the companion files, installs the engine and downloads what
        /// is missing; returns `sd-cli` and the recipe to run.
        let prepare: @Sendable (_ status: @escaping @Sendable (_ status: String, _ actor: String?) -> Void) async throws
            -> (cli: URL, recipe: LocalMediaRecipe)
    }

    let job: @Sendable (_ modelID: String) async -> Job?
    let manager: LlamaServerManager

    var name: String { "ImageGeneration" }
    var description: String { "Generates or refines an image from a text prompt using the selected local image model." }
    var parameters: RxAgentCore.JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object(["type": .string("string"), "description": .string("What the image shows; may attach a source image to refine.")]),
                "model": .object(["type": .string("string"), "description": .string("The local image model id.")]),
            ]),
            "required": .array([.string("prompt"), .string("model")]),
        ])
    }
    /// Writes only into RxCode's own Generated Images folder.
    var isReadOnly: Bool { true }

    func execute(_ input: RxAgentCore.JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        let savedSettings = ImageGenerationSettings.load()
        let callID = context.callID
        let report: @Sendable (String, String?) -> Void = { VideoGenerationProgress.post(callID: callID, status: $0, actor: $1) }
        let status: @Sendable (String) -> Void = { report($0, nil) }
        guard case .object(let fields) = input, case .string(let message)? = fields["prompt"],
              case .string(let modelID)? = fields["model"], let job = await job(modelID) else {
            return LocalStudioTools.failure("The selected model can't generate images.", title: "Image generation failed")
        }
        let prompt = LocalStudioPrompt(message)
        let settings = savedSettings.applying(
            await StudioConfigAgent.overrides(model: job.model, modelsRoot: job.modelsRoot, prompt: prompt.text, taskModel: job.taskModel, status: status))
        let source = prompt.images.first.flatMap(Self.refineSource)
        if let path = prompt.images.first, source == nil {
            return LocalStudioTools.failure("Couldn't read the image to refine at \(path).", title: "Image generation failed")
        }
        do {
            if job.model.format == .mlx {
                await manager.stop()
                return try await MLXStudioMedia.image(job: job, prompt: prompt, settings: settings,
                                                      session: context.sessionID, status: status)
            }
            // The recipe doesn't depend on the request, so one validated recipe serves the session.
            let key = ImagePipelineMemory.key(session: context.sessionID, model: job.model.id, variant: "sd")
            return try await ImageEngineValidation.remembered(key: key, configure: { (failure: (config: Configured, error: String)?) in
                let initial: Configured
                if let failure {
                    guard let repair = job.repair else { throw MLXStudioMedia.Failure(failure.error) }
                    initial = try await repair(failure.config.recipe, failure.error, report)
                } else {
                    initial = try await job.prepare(report)
                }
                await manager.stop()
                let validated = try await ImageEngineValidation.run(initial: initial, test: { candidate, output in
                    let arguments = candidate.recipe.imageArguments(
                        model: job.model.primaryFile(in: job.modelsRoot), directory: job.model.directory(in: job.modelsRoot),
                        prompt: ImageEngineValidation.prompt, output: output, settings: ImageEngineValidation.settings,
                        seed: 42, refine: nil)
                    try await StableDiffusionProcess.run(cli: candidate.cli, arguments: arguments, status: status)
                }, repair: { candidate, failure in
                    guard let repair = job.repair else { return nil }
                    return try await repair(candidate.recipe, failure, report)
                }, status: status)
                await job.didValidate(validated.recipe)
                return validated
            }, generate: { configured in
                try await generate(job: job, configured: configured, prompt: prompt, source: source, settings: settings, status: status)
            }, status: status)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return LocalStudioTools.failure(error.localizedDescription, title: "Image generation failed")
        }
    }

    typealias Configured = (cli: URL, recipe: LocalMediaRecipe)

    /// One stable-diffusion.cpp run with an already validated engine and recipe.
    private func generate(job: Job, configured: Configured, prompt: LocalStudioPrompt,
                          source: (path: String, width: Int, height: Int)?, settings: ImageGenerationSettings,
                          status: @escaping @Sendable (String) -> Void) async throws -> HarnessToolOutput {
        // The denoiser and encoders need the memory a chat model holds.
        await manager.stop()
        try FileManager.default.createDirectory(at: job.outputDirectory, withIntermediateDirectories: true)
        let output = job.outputDirectory.appending(path: LocalStudioTools.fileName(for: prompt.text, fallback: "image", extension: "png"))
        let seed = LocalStudioTools.resolvedSeed(settings.seed)
        let arguments = configured.recipe.imageArguments(
            model: job.model.primaryFile(in: job.modelsRoot), directory: job.model.directory(in: job.modelsRoot),
            prompt: prompt.text, output: output, settings: settings, seed: seed, refine: source
        )
        status(source == nil ? "Generating…" : "Refining…")
        let started = Date()
        try await StableDiffusionProcess.run(cli: configured.cli, arguments: arguments, status: status)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw MLXStudioMedia.Failure("stable-diffusion.cpp finished without writing an image.")
        }
        let size = Self.pixelSize(of: output.path)
        let result = ImageGenerationResult(
            savedPath: output.path, prompt: prompt.text, model: job.model.displayName,
            elapsedSeconds: Int(Date().timeIntervalSince(started)),
            width: size?.width ?? settings.width, height: size?.height ?? settings.height,
            seed: seed, steps: settings.steps(recommended: configured.recipe.steps ?? 20),
            sourcePath: source?.path
        )
        return HarnessToolOutput(text: LocalStudioTools.encode(result), title: "Generated image")
    }

    /// The source image and its size on the 64-pixel grid, capped at 2048.
    static func refineSource(_ path: String) -> (path: String, width: Int, height: Int)? {
        guard let size = pixelSize(of: path), size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, 2048 / Double(max(size.width, size.height)))
        let fit = { (value: Int) in max(256, Int(Double(value) * scale) / 64 * 64) }
        return (path, fit(size.width), fit(size.height))
    }

    static func pixelSize(of path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (width, height)
    }
}

/// The `ImageGeneration` tool's result, as the image studio reads it.
nonisolated struct ImageGenerationResult: Codable, Equatable {
    let savedPath: String
    let prompt: String
    let model: String
    let elapsedSeconds: Int
    let width: Int
    let height: Int
    let seed: Int
    let steps: Int
    /// The image this one refined, if any.
    let sourcePath: String?
}
