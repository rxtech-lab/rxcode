import Foundation
import os

extension LocalModelStore {
    // MARK: - stable-diffusion.cpp

    /// Where generated videos are saved.
    var generatedVideosRoot: URL { appSupport.appending(path: "Generated Videos") }

    /// Reuses a previously discovered recipe or asks the task model to find
    /// companion files on Hugging Face. Lookup failures never select defaults.
    func videoRecipe(
        for model: LocalModelInfo, taskModel: VideoCompanionResolver.TaskModel?,
        report: @escaping @Sendable (_ status: String, _ actor: String?) -> Void
    ) async throws -> LocalVideoRecipe {
        guard LocalVideoRecipe.supports(model) else { throw VideoRecipeError.notVideoModel }
        if let saved = savedVideoRecipes()[model.id] { return saved }
        guard let taskModel else { throw VideoRecipeError.noTaskModel }
        report("Asking \(taskModel.label) to find the companion files…", nil)
        let recipe = try await VideoCompanionResolver(taskModel: taskModel, report: report).resolve(model: model)
        var saved = savedVideoRecipes()
        saved[model.id] = recipe
        saveVideoRecipes(saved)
        return recipe
    }

    enum VideoRecipeError: LocalizedError {
        case notVideoModel
        case noTaskModel
        var errorDescription: String? {
            switch self {
            case .notVideoModel: "The selected model can't generate video."
            case .noTaskModel: "Configure a default task model to discover the text encoder and VAEs, then retry."
            }
        }
    }

    private var videoRecipesURL: URL { modelsRoot.appending(path: "video-recipes.json") }

    /// Companion files the task model found, by model id.
    func savedVideoRecipes() -> [String: LocalVideoRecipe] {
        guard let data = try? Data(contentsOf: videoRecipesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: LocalVideoRecipe].self, from: data)) ?? [:]
    }

    func saveVideoRecipes(_ recipes: [String: LocalVideoRecipe]) {
        do {
            try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(recipes).write(to: videoRecipesURL, options: .atomic)
        } catch {
            logger.error("failed to save video recipes: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Makes `model` ready to generate: finds its companion files, installs
    /// stable-diffusion.cpp and downloads what is missing next to the
    /// denoiser. Files already on disk are kept.
    func prepareVideoGeneration(
        model: LocalModelInfo, taskModel: VideoCompanionResolver.TaskModel?,
        report: @escaping @Sendable (_ status: String, _ actor: String?) -> Void
    ) async throws -> (cli: URL, recipe: LocalVideoRecipe) {
        let recipe = try await videoRecipe(for: model, taskModel: taskModel, report: report)
        let status: @Sendable (String) -> Void = { report($0, nil) }
        if stableDiffusionRuntime == nil {
            status("Installing stable-diffusion.cpp…")
            try await installStableDiffusionRuntime()
        }
        guard let runtime = stableDiffusionRuntime else { throw StableDiffusionRuntimeInstaller.InstallError.binaryNotFound }

        try await downloadCompanions(Self.videoCompanions(recipe), beside: model, status: status)
        return (URL(filePath: runtime.path), recipe)
    }

    private static func videoCompanions(_ recipe: LocalVideoRecipe) -> [(repoID: String, file: String, role: String?)] {
        [
            (recipe.textEncoder.repoID, recipe.textEncoder.file, "Text encoder"),
            (recipe.videoVAE.repoID, recipe.videoVAE.file, "Video VAE"),
            (recipe.audioVAE.repoID, recipe.audioVAE.file, "Audio VAE"),
        ]
    }

    static func mediaCompanions(_ recipe: LocalMediaRecipe) -> [(repoID: String, file: String, role: String?)] {
        recipe.companions.map { ($0.repoID, $0.file, LocalCompanionFile.role(forFlag: $0.flag)) }
    }

    /// Companions downloaded before they were listed, found from the saved
    /// recipes and the readout config on disk.
    func discoveredCompanions(for model: LocalModelInfo) -> [LocalCompanionFile] {
        var candidates: [(repoID: String, file: String, role: String?)] = []
        if let video = savedVideoRecipes()[model.id] { candidates += Self.videoCompanions(video) }
        for (key, recipe) in savedMediaRecipes() where key.hasSuffix(":\(model.id)") {
            candidates += Self.mediaCompanions(recipe)
        }
        candidates.append((model.repoID, DecisionReadout.configFile, "Readout config"))
        let directory = model.directory(in: modelsRoot)
        var found: [LocalCompanionFile] = []
        for (repoID, file, role) in candidates {
            let url = directory.appending(path: (file as NSString).lastPathComponent)
            guard !found.contains(where: { $0.localName == url.lastPathComponent }),
                  let size = Self.fileSize(url) else { continue }
            found.append(LocalCompanionFile(repoID: repoID, file: file, role: role, sizeBytes: size))
        }
        return found
    }
}
