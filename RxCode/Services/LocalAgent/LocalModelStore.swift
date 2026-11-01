import AppKit
import CryptoKit
import Foundation
import Observation
import os
import enum RxCodeCore.LocalStudioKind
import struct RxCodeCore.StudioModelConfig

/// Installed local models, downloads in flight, the llama.cpp and MLX
/// runtimes and the server's status — everything the RxCode Agent settings show.
@MainActor @Observable
final class LocalModelStore {
    /// One per process: models on disk and the llama.cpp server are
    /// machine-wide, so every window and workspace shares them.
    static let shared = LocalModelStore()

    /// Called after a model finishes downloading; the app uses it to build
    /// the model's settings form from its README.
    var onModelInstalled: ((LocalModelInfo) -> Void)?

    struct Download: Identifiable, Equatable {
        let id: String
        let title: String
        var receivedBytes: Int64
        var totalBytes: Int64
        var fraction: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }
    }

    enum RuntimeUpdateState: Equatable {
        case unknown
        case checking
        case upToDate
        case available(version: String)
        case failed(String)
    }

    struct Settings: Codable, Equatable {
        /// Minutes without a request before the model is unloaded. 0 = never.
        var idleMinutes: Int = 15
        /// Overrides the hardware-based default when set.
        var contextSize: Int?
        var defaultModelID: String?
        /// The user uninstalled the MLX engine. MLX is linked into RxCode, so
        /// this switches it off rather than deleting files.
        var mlxDisabled = false

        init() {}

        // Tolerant: index files written before a field existed still load.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            idleMinutes = try container.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? 15
            contextSize = try container.decodeIfPresent(Int.self, forKey: .contextSize)
            defaultModelID = try container.decodeIfPresent(String.self, forKey: .defaultModelID)
            mlxDisabled = try container.decodeIfPresent(Bool.self, forKey: .mlxDisabled) ?? false
        }
    }

    private(set) var installed: [LocalModelInfo] = []
    /// Companion files downloaded beside each installed model, by model id.
    private(set) var companions: [String: [LocalCompanionFile]] = [:]
    private(set) var downloads: [String: Download] = [:]
    private(set) var runtime: LlamaRuntimeInstaller.Runtime?
    private(set) var mlxRuntime: LlamaRuntimeInstaller.Runtime?
    private(set) var runtimeDownload: Download?
    /// Result of the last llama.cpp update check.
    private(set) var llamaUpdate: RuntimeUpdateState = .unknown
    /// stable-diffusion.cpp's `sd-cli`, for diffusion GGUF models.
    private(set) var stableDiffusionRuntime: LlamaRuntimeInstaller.Runtime?
    private(set) var stableDiffusionUpdate: RuntimeUpdateState = .unknown
    private(set) var serverStatus: LlamaServerStatus = .stopped
    var settings = Settings() {
        didSet {
            guard settings != oldValue else { return }
            persist()
            Task { await manager.setIdleTimeout(TimeInterval(settings.idleMinutes * 60)) }
        }
    }

    let hardware = LocalHardwareProfile.current
    let manager: LlamaServerManager
    /// The Hugging Face sign-in that unlocks private and gated repos.
    let huggingFace = HuggingFaceAccountStore.shared
    let appSupport: URL
    var modelsRoot: URL { appSupport.appending(path: "LocalModels") }

    @ObservationIgnored private var downloadTasks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var runtimeInstalls: [LocalModelWeightFormat: Task<Void, Error>] = [:]
    @ObservationIgnored private var stableDiffusionInstall: Task<Void, Error>?
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rxlab.RxCode", category: "LocalModels")
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    /// Decision models whose repos had no readout config this launch.
    @ObservationIgnored private var missingReadouts: Set<String> = []

    private struct Persisted: Codable {
        var installed: [LocalModelInfo]
        var settings: Settings
        var companions: [String: [LocalCompanionFile]]?
    }

    init(appSupport: URL? = nil, manager: LlamaServerManager = .shared) {
        let base = appSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "RxCode")
        self.appSupport = base
        self.manager = manager
        load()
        runtime = LlamaRuntimeInstaller.locate(appSupport: base)
        mlxRuntime = settings.mlxDisabled ? nil : MLXRuntimeInstaller.locate(appSupport: base)
        stableDiffusionRuntime = StableDiffusionRuntimeInstaller.locate(appSupport: base)
        let idle = settings.idleMinutes
        Task { [weak self] in
            await manager.setIdleTimeout(TimeInterval(idle * 60))
            await manager.setStatusHandler { status in
                Task { @MainActor in self?.serverStatus = status }
            }
        }
        // `llama-server` is a child process that would otherwise outlive RxCode
        // and keep the model's memory.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached { await manager.stop(); semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 2)
        }
    }

    // MARK: - Queries

    var isAvailable: Bool {
        installed.contains { self.runtime(for: $0.format) != nil }
    }

    func runtime(for format: LocalModelWeightFormat) -> LlamaRuntimeInstaller.Runtime? {
        switch format {
        case .gguf: runtime
        case .mlx: mlxRuntime
        }
    }

    var effectiveContextSize: Int { settings.contextSize ?? hardware.defaultContextSize }

    func model(id: String?) -> LocalModelInfo? {
        if let id, let match = installed.first(where: { $0.id == id }) { return match }
        if let preferred = settings.defaultModelID, let match = installed.first(where: { $0.id == preferred }) { return match }
        return installed.first
    }

    func isInstalled(repoID: String, file: String) -> Bool {
        installed.contains { $0.repoID == repoID && $0.files.first == file }
    }

    /// Whether `variant` of `summary` is on disk. MLX repos are installed whole.
    func isInstalled(summary: HFModelSummary, variant: HFModelVariant) -> Bool {
        switch summary.format {
        case .gguf: isInstalled(repoID: summary.id, file: variant.files.first.map { ($0 as NSString).lastPathComponent } ?? "")
        case .mlx: installed.contains { $0.format == .mlx && $0.repoID == summary.id }
        }
    }

    func fit(bytes: Int64) -> LocalModelFit { hardware.fit(forModelBytes: bytes) }

    // MARK: - Runtime

    /// Installs the runtime for `format`. Concurrent callers — two models of
    /// a new format downloaded at once — share one install instead of racing
    /// into the same folder.
    func installRuntime(for format: LocalModelWeightFormat = .gguf) async throws {
        if format == .mlx {
            mlxRuntime = try await MLXRuntimeInstaller.install(appSupport: appSupport, onProgress: { _, _ in })
            settings.mlxDisabled = false
            return
        }
        if let running = runtimeInstalls[format] {
            try await running.value
            return
        }
        let task = Task { @MainActor in try await performRuntimeInstall(for: format) }
        runtimeInstalls[format] = task
        defer { runtimeInstalls[format] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Asks GitHub for the newest llama.cpp release and records whether the
    /// managed copy is behind it.
    func checkForRuntimeUpdates() async {
        async let stableDiffusion: Void = checkForStableDiffusionUpdate()
        await checkForLlamaUpdate()
        await stableDiffusion
    }

    private func checkForLlamaUpdate() async {
        guard llamaUpdate != .checking else { return }
        llamaUpdate = .checking
        do {
            let latest = try await LlamaRuntimeInstaller.latestVersion()
            if let runtime, LlamaRuntimeInstaller.isManaged(runtime, appSupport: appSupport),
               LlamaRuntimeInstaller.isNewer(latest, than: runtime.version) {
                llamaUpdate = .available(version: latest)
            } else if runtime == nil {
                llamaUpdate = .available(version: latest)
            } else {
                llamaUpdate = .upToDate
            }
        } catch {
            llamaUpdate = .failed(error.localizedDescription)
        }
    }

    /// Installs the newest llama.cpp, replacing the managed copy. A loaded
    /// GGUF model is unloaded first so no server runs from deleted files.
    func updateLlamaRuntime() async throws {
        await unloadServer(format: .gguf)
        try await installRuntime(for: .gguf)
        llamaUpdate = .upToDate
        logger.info("llama.cpp runtime updated to \(self.runtime?.version ?? "-", privacy: .public)")
    }

    /// Removes the managed llama.cpp copy. A Homebrew install, if present,
    /// takes over; otherwise GGUF models need a reinstall before they run.
    func removeLlamaRuntime() async throws {
        await unloadServer(format: .gguf)
        try LlamaRuntimeInstaller.removeManaged(appSupport: appSupport)
        runtime = LlamaRuntimeInstaller.locate(appSupport: appSupport)
        llamaUpdate = .unknown
    }

    /// Switches the MLX engine off and releases a loaded MLX model. MLX models
    /// stay on disk; installing the engine again turns it back on.
    func removeMLXRuntime() async {
        await unloadServer(format: .mlx)
        settings.mlxDisabled = true
        mlxRuntime = nil
    }

    // MARK: - stable-diffusion.cpp

    private func checkForStableDiffusionUpdate() async {
        guard stableDiffusionUpdate != .checking, LlamaRuntimeInstaller.isAppleSilicon else { return }
        stableDiffusionUpdate = .checking
        do {
            let latest = try await StableDiffusionRuntimeInstaller.latestVersion()
            if let runtime = stableDiffusionRuntime,
               !(StableDiffusionRuntimeInstaller.isManaged(runtime, appSupport: appSupport)
                   && StableDiffusionRuntimeInstaller.isNewer(latest, than: runtime.version)) {
                stableDiffusionUpdate = .upToDate
            } else {
                stableDiffusionUpdate = .available(version: latest)
            }
        } catch {
            stableDiffusionUpdate = .failed(error.localizedDescription)
        }
    }

    /// Installs (or updates to) the newest stable-diffusion.cpp release.
    /// Concurrent callers share one install.
    func installStableDiffusionRuntime() async throws {
        if let running = stableDiffusionInstall {
            try await running.value
            return
        }
        let task = Task { @MainActor in
            let root = appSupport
            stableDiffusionRuntime = try await DownloadCenter.track("stable-diffusion.cpp runtime", kind: .modelRuntime) { item in
                try await StableDiffusionRuntimeInstaller.install(appSupport: root) { received, total in
                    DownloadCenter.update(item, phase: received == 0 && total == 0 ? .installing : .downloading,
                                          receivedBytes: received, totalBytes: total)
                }
            }
            stableDiffusionUpdate = .upToDate
            logger.info("stable-diffusion.cpp runtime installed \(self.stableDiffusionRuntime?.version ?? "-", privacy: .public)")
        }
        stableDiffusionInstall = task
        defer { stableDiffusionInstall = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

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
    private func savedVideoRecipes() -> [String: LocalVideoRecipe] {
        guard let data = try? Data(contentsOf: videoRecipesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: LocalVideoRecipe].self, from: data)) ?? [:]
    }

    private func saveVideoRecipes(_ recipes: [String: LocalVideoRecipe]) {
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

    private static func mediaCompanions(_ recipe: LocalMediaRecipe) -> [(repoID: String, file: String, role: String?)] {
        recipe.companions.map { ($0.repoID, $0.file, LocalCompanionFile.role(forFlag: $0.flag)) }
    }

    /// Downloads each `(repo, file)` missing from `model`'s folder and lists
    /// it under the model. Files already on disk are kept.
    func downloadCompanions(
        _ files: [(repoID: String, file: String, role: String?)], beside model: LocalModelInfo,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let directory = model.directory(in: modelsRoot)
        for (repoID, file, role) in files {
            let localName = (file as NSString).lastPathComponent
            let destination = directory.appending(path: localName)
            defer { recordCompanion(repoID: repoID, file: file, role: role, at: destination, for: model) }
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            status("Downloading \(localName) from \(repoID)…")
            let url = HuggingFaceClient.downloadURL(repoID: repoID, file: file)
            // Downloaded beside the target and moved in whole, so an
            // interrupted download is never mistaken for a finished file.
            let partial = directory.appending(path: localName + ".part")
            try await DownloadCenter.track(localName, kind: .localModel) { item in
                let token = try await HuggingFaceCredentials.shared.accessToken()
                _ = try await LocalModelDownloader().download(url, to: partial, bearerToken: token, onTransferProgress: { received, total, transferred in
                    DownloadCenter.update(item, phase: .downloading, receivedBytes: received, totalBytes: total, transferredBytes: transferred)
                }, onProgress: { _, _ in })
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }

    func companionFiles(for model: LocalModelInfo) -> [LocalCompanionFile] {
        companions[model.id] ?? []
    }

    /// Lists a companion on disk under `model`, once.
    private func recordCompanion(repoID: String, file: String, role: String?, at url: URL, for model: LocalModelInfo) {
        guard let size = Self.fileSize(url) else { return }
        var list = companions[model.id] ?? []
        guard !list.contains(where: { $0.localName == url.lastPathComponent }) else { return }
        list.append(LocalCompanionFile(repoID: repoID, file: file, role: role, sizeBytes: size))
        companions[model.id] = list
        persist()
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Companions downloaded before they were listed, found from the saved
    /// recipes and the readout config on disk.
    private func discoveredCompanions(for model: LocalModelInfo) -> [LocalCompanionFile] {
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

    // MARK: - Image, audio and decision studios

    var generatedImagesRoot: URL { appSupport.appending(path: "Generated Images") }
    var generatedAudioRoot: URL { appSupport.appending(path: "Generated Audio") }

    enum StudioSetupError: LocalizedError {
        case unsupported(String)
        case noTaskModel(LocalStudioKind)

        var errorDescription: String? {
            switch self {
            case .unsupported(let reason): reason
            case .noTaskModel(let kind):
                "Choose a setup agent for the \(kind.title) studio (its Setup menu) or a default task agent in Settings → Tasks, so it can find this model's companion files, then retry."
            }
        }
    }

    /// Reuses a saved recipe or asks the setup agent to find one. Lookup
    /// failures never fall back to guessed files.
    func mediaRecipe(
        for model: LocalModelInfo, spec: MediaCompanionResolver.Spec, key: String,
        taskModel: VideoCompanionResolver.TaskModel?, kind: LocalStudioKind,
        report: @escaping @Sendable (_ status: String, _ actor: String?) -> Void
    ) async throws -> LocalMediaRecipe {
        let recipeKey = "\(key):\(model.id)"
        if let saved = savedMediaRecipes()[recipeKey] { return saved }
        guard let taskModel else { throw StudioSetupError.noTaskModel(kind) }
        report("Asking \(taskModel.label) how to run this model…", nil)
        let recipe = try await MediaCompanionResolver(spec: spec, taskModel: taskModel, report: report).resolve(model: model)
        if key == "image" { return recipe } // Cache image recipes only after generation validation.
        var saved = savedMediaRecipes()
        saved[recipeKey] = recipe
        saveMediaRecipes(saved)
        return recipe
    }

    /// Forgets the saved recipe so the next generation asks the setup agent
    /// again — after picking another agent, or when a recipe stopped working.
    func forgetRecipes(for model: LocalModelInfo) {
        var saved = savedMediaRecipes()
        saved = saved.filter { !$0.key.hasSuffix(":\(model.id)") }
        saveMediaRecipes(saved)
        var video = savedVideoRecipes()
        video[model.id] = nil
        saveVideoRecipes(video)
    }

    func hasSavedRecipe(for model: LocalModelInfo) -> Bool {
        savedVideoRecipes()[model.id] != nil || savedMediaRecipes().keys.contains { $0.hasSuffix(":\(model.id)") }
    }

    func acceptImageRecipe(_ recipe: LocalMediaRecipe, model: LocalModelInfo) {
        var saved = savedMediaRecipes()
        saved["image:\(model.id)"] = recipe
        saveMediaRecipes(saved)
    }

    func repairImageGeneration(model: LocalModelInfo, previous: LocalMediaRecipe, failure: String,
                               taskModel: VideoCompanionResolver.TaskModel?,
                               report: @escaping @Sendable (String, String?) -> Void) async throws -> (cli: URL, recipe: LocalMediaRecipe) {
        var saved = savedMediaRecipes()
        saved["image:\(model.id)"] = nil
        saveMediaRecipes(saved)
        guard let taskModel else { throw StudioSetupError.noTaskModel(.image) }
        let previousJSON = String(decoding: try JSONEncoder().encode(previous), as: UTF8.self)
        let recipe = try await MediaCompanionResolver(spec: .image, taskModel: taskModel, report: report,
            validationFailure: "Recipe: \(previousJSON)\nEngine error: \(failure)").resolve(model: model)
        guard recipe != previous else { throw StudioSetupError.unsupported("The setup agent repeated the image recipe that failed validation. \(failure)") }
        try await downloadCompanions(Self.mediaCompanions(recipe), beside: model, status: { report($0, nil) })
        guard let runtime = stableDiffusionRuntime else { throw StableDiffusionRuntimeInstaller.InstallError.binaryNotFound }
        return (URL(filePath: runtime.path), recipe)
    }

    func prepareImageGeneration(
        model: LocalModelInfo, taskModel: VideoCompanionResolver.TaskModel?,
        report: @escaping @Sendable (_ status: String, _ actor: String?) -> Void
    ) async throws -> (cli: URL, recipe: LocalMediaRecipe) {
        guard LocalMediaRecipe.supportsImage(model) else {
            throw StudioSetupError.unsupported("Image models run on stable-diffusion.cpp, which needs GGUF weights.")
        }
        let recipe = try await mediaRecipe(for: model, spec: .image, key: "image", taskModel: taskModel, kind: .image, report: report)
        let status: @Sendable (String) -> Void = { report($0, nil) }
        if stableDiffusionRuntime == nil {
            status("Installing stable-diffusion.cpp…")
            try await installStableDiffusionRuntime()
        }
        guard let runtime = stableDiffusionRuntime else { throw StableDiffusionRuntimeInstaller.InstallError.binaryNotFound }
        try await downloadCompanions(Self.mediaCompanions(recipe), beside: model, status: status)
        return (URL(filePath: runtime.path), recipe)
    }

    func prepareAudio(
        model: LocalModelInfo, mode: LocalAudioMode, taskModel: VideoCompanionResolver.TaskModel?,
        report: @escaping @Sendable (_ status: String, _ actor: String?) -> Void
    ) async throws -> (binary: URL, recipe: LocalMediaRecipe) {
        let recipe = try await mediaRecipe(for: model, spec: mode.spec, key: mode.rawValue, taskModel: taskModel, kind: .audio, report: report)
        let status: @Sendable (String) -> Void = { report($0, nil) }
        let binary = try await llamaTool(named: mode.binaryName, status: status)
        try await downloadCompanions(Self.mediaCompanions(recipe), beside: model, status: status)
        return (binary, recipe)
    }

    /// A llama.cpp tool shipped beside `llama-server`, installing llama.cpp
    /// first when it is missing.
    func llamaTool(named name: String, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        if runtime == nil {
            status("Installing llama.cpp…")
            try await installRuntime(for: .gguf)
        }
        guard let runtime else { throw LlamaRuntimeInstaller.InstallError.binaryNotFound }
        let binary = URL(filePath: runtime.path).deletingLastPathComponent().appending(path: name)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw StudioSetupError.unsupported("This llama.cpp install has no \(name). Update llama.cpp in Settings → Agent → RxCode Agent → Runtimes.")
        }
        return binary
    }

    /// Starts the decision model's server and loads its readout config —
    /// from the model folder, else from the repo or its base model's repo.
    /// Models without one are scored uncalibrated.
    func prepareDecision(
        model: LocalModelInfo, status: @escaping @Sendable (String) -> Void
    ) async throws -> (baseURL: URL, contextSize: Int, readout: DecisionReadout) {
        guard model.format == .gguf else {
            throw StudioSetupError.unsupported("Decision models run on llama.cpp, which needs GGUF weights.")
        }
        let readout = await decisionReadout(for: model, status: status)
        if runtime == nil {
            status("Installing llama.cpp…")
            try await installRuntime(for: .gguf)
        }
        guard let runtime else { throw LlamaRuntimeInstaller.InstallError.binaryNotFound }
        status("Loading \(model.displayName)…")
        // Decisions read a few thousand tokens at most; a smaller window
        // keeps the KV cache light.
        let server = try await manager.ensureServer(
            for: model, modelsRoot: modelsRoot, runtime: URL(filePath: runtime.path),
            contextSize: min(effectiveContextSize, 32_768)
        )
        return (server.baseURL, server.contextSize, readout)
    }

    func decisionReadout(for model: LocalModelInfo, status: @escaping @Sendable (String) -> Void) async -> DecisionReadout {
        let local = model.directory(in: modelsRoot).appending(path: DecisionReadout.configFile)
        if let data = try? Data(contentsOf: local), let readout = DecisionReadout.parse(data) { return readout }
        guard !missingReadouts.contains(model.id) else { return DecisionReadout() }
        let bases = (model.huggingFaceMetadata?.tags ?? []).compactMap { tag -> String? in
            guard tag.hasPrefix("base_model:") else { return nil }
            let repo = String(tag.split(separator: ":").last ?? "")
            return VideoCompanionResolver.isRepoID(repo) ? repo : nil
        }
        for repo in [model.repoID] + bases {
            guard let files = try? await HuggingFaceClient.files(of: repo),
                  let file = files.first(where: { ($0.path as NSString).lastPathComponent == DecisionReadout.configFile })?.path
            else { continue }
            status("Downloading the readout config from \(repo)…")
            do {
                try await downloadCompanions([(repo, file, "Readout config")], beside: model, status: status)
                if let data = try? Data(contentsOf: local), let readout = DecisionReadout.parse(data) { return readout }
            } catch {
                logger.error("readout config download failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        missingReadouts.insert(model.id)
        return DecisionReadout()
    }

    private var mediaRecipesURL: URL { modelsRoot.appending(path: "media-recipes.json") }

    private func savedMediaRecipes() -> [String: LocalMediaRecipe] {
        guard let data = try? Data(contentsOf: mediaRecipesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: LocalMediaRecipe].self, from: data)) ?? [:]
    }

    private func saveMediaRecipes(_ recipes: [String: LocalMediaRecipe]) {
        do {
            try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(recipes).write(to: mediaRecipesURL, options: .atomic)
        } catch {
            logger.error("failed to save media recipes: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the managed copy; a Homebrew `sd-cli`, if present, takes over.
    func removeStableDiffusionRuntime() throws {
        try StableDiffusionRuntimeInstaller.removeManaged(appSupport: appSupport)
        stableDiffusionRuntime = StableDiffusionRuntimeInstaller.locate(appSupport: appSupport)
        stableDiffusionUpdate = .unknown
    }

    private func unloadServer(format: LocalModelWeightFormat) async {
        guard let modelID = serverStatus.modelID,
              installed.first(where: { $0.id == modelID })?.format == format else { return }
        await manager.unload(modelID: modelID)
    }

    private func performRuntimeInstall(for format: LocalModelWeightFormat) async throws {
        runtimeDownload = Download(id: "runtime", title: format.runtimeName, receivedBytes: 0, totalBytes: 0)
        defer { runtimeDownload = nil }
        let root = appSupport
        let installed = try await DownloadCenter.track("\(format.runtimeName) runtime", kind: .modelRuntime) { item in
            // `(0, 0)` marks the end of the download: unpacking and package
            // installs follow with no byte progress.
            let progress: @Sendable (Int64, Int64) -> Void = { received, total in
                DownloadCenter.update(item, phase: received == 0 && total == 0 ? .installing : .downloading,
                                      receivedBytes: received, totalBytes: total)
                Task { @MainActor [weak self] in
                    self?.runtimeDownload?.receivedBytes = received
                    self?.runtimeDownload?.totalBytes = total
                }
            }
            return switch format {
            case .gguf: try await LlamaRuntimeInstaller.install(appSupport: root, onProgress: progress)
            case .mlx: try await MLXRuntimeInstaller.install(appSupport: root, onProgress: progress)
            }
        }
        switch format {
        case .gguf: runtime = installed
        case .mlx: mlxRuntime = installed
        }
    }

    // MARK: - Downloads

    /// Downloads every file of `variant`. Returns when finished; throws on
    /// failure or cancellation, retaining staged files for resumption.
    func download(summary: HFModelSummary, variant: HFModelVariant) async throws {
        let key = "\(summary.id)/\(variant.id)"
        guard downloads[key] == nil else { return }
        let title = summary.format == .mlx ? summary.name : "\(summary.name) · \(variant.displayName)"
        downloads[key] = Download(id: key, title: title, receivedBytes: 0, totalBytes: variant.sizeBytes)
        defer { downloads[key] = nil; downloadTasks[key] = nil }

        // GGUF files are flattened into the model folder; MLX repos keep
        // their layout, which native MLX loads as a directory.
        let localPath: (String) -> String = { summary.format == .mlx ? $0 : ($0 as NSString).lastPathComponent }
        var info = LocalModelInfo(
            repoID: summary.id, author: summary.author, files: variant.files.map(localPath),
            sizeBytes: variant.sizeBytes, parameterCount: summary.parameterCount, contextLength: summary.contextLength,
            architecture: summary.architecture, quantization: variant.quantization, downloadedAt: Date(),
            format: summary.format
        )
        let directory = info.directory(in: modelsRoot)
        let staging = directory.appending(path: ".downloads").appending(path: SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
        let recovery = DownloadCenter.Recovery(summary: summary, variant: variant, directory: directory, stagingDirectory: staging)
        let item = DownloadCenter.shared.begin(title, kind: .localModel, recovery: recovery) { [weak self] in self?.cancelDownload(id: key) }
        DownloadCenter.shared.update(item, phase: .downloading, receivedBytes: 0, totalBytes: variant.sizeBytes)

        let work = Task { @MainActor in
            let metadata = try await HuggingFaceClient.model(summary.id, format: summary.format)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var completedBytes: Int64 = 0
            for file in variant.files {
                try Task.checkCancellation()
                let destination = staging.appending(path: localPath(file))
                let base = completedBytes
                // Fetched per file: a multi-part download can outlive a token.
                let token = try await HuggingFaceCredentials.shared.accessToken()
                if !FileManager.default.fileExists(atPath: destination.path) {
                    _ = try await LocalModelDownloader().download(
                        HuggingFaceClient.downloadURL(repoID: summary.id, file: file), to: destination, bearerToken: token,
                        onTransferProgress: { received, _, transferred in
                            DownloadCenter.update(item, phase: .downloading, receivedBytes: base + received, transferredBytes: transferred)
                        }
                    ) { received, _ in
                        Task { @MainActor [weak self] in self?.downloads[key]?.receivedBytes = base + received }
                    }
                }
                completedBytes += (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            }
            try Task.checkCancellation()
            try JSONEncoder().encode(metadata).write(to: directory.appending(path: "rxcode-huggingface-metadata.json"), options: .atomic)
            info.huggingFaceMetadata = metadata
        }
        downloadTasks[key] = work
        do {
            try await work.value
            DownloadCenter.shared.update(item, phase: .installing)
        } catch {
            DownloadCenter.shared.fail(item, error: error)
            throw error
        }

        do {
            let files = info.files
            try await Task.detached {
                for file in files {
                    let source = staging.appending(path: file)
                    let target = directory.appending(path: file)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.copyItem(at: source, to: target)
                }
                try FileManager.default.removeItem(at: staging)
            }.value
        } catch {
            DownloadCenter.shared.fail(item, error: error)
            throw error
        }

        installed.removeAll { $0.id == info.id }
        installed.append(info)
        installed.sort { $0.downloadedAt > $1.downloadedAt }
        if settings.defaultModelID == nil { settings.defaultModelID = info.id }
        persist()
        DownloadCenter.shared.finish(item)
        logger.info("installed local model \(info.id, privacy: .public)")
        onModelInstalled?(info)
    }

    func cancelDownload(id: String) {
        downloadTasks[id]?.cancel()
    }

    func delete(_ model: LocalModelInfo) async {
        await manager.unload(modelID: model.id)
        StudioModelConfig.remove(modelID: model.id)
        if model.format == .mlx {
            try? FileManager.default.removeItem(at: model.directory(in: modelsRoot))
        }
        for file in model.files where model.format == .gguf {
            try? FileManager.default.removeItem(at: model.directory(in: modelsRoot).appending(path: file))
        }
        let directory = model.directory(in: modelsRoot)
        // Quantizations of one repo share a folder, so a companion another
        // installed quantization lists stays.
        let shared = Set(installed.filter { $0.repoID == model.repoID && $0.id != model.id }
            .flatMap { companionFiles(for: $0).map(\.localName) })
        for companion in companionFiles(for: model) where !shared.contains(companion.localName) {
            try? FileManager.default.removeItem(at: directory.appending(path: companion.localName))
        }
        companions[model.id] = nil
        forgetRecipes(for: model)
        if !installed.contains(where: { $0.repoID == model.repoID && $0.id != model.id }) {
            try? FileManager.default.removeItem(at: directory.appending(path: "rxcode-huggingface-metadata.json"))
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: directory)
        }
        installed.removeAll { $0.id == model.id }
        if settings.defaultModelID == model.id { settings.defaultModelID = installed.first?.id }
        persist()
    }

    func unloadServer() async {
        await manager.stop()
    }

    // MARK: - Persistence

    private var indexURL: URL { modelsRoot.appending(path: "models.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        // Drop entries whose files were removed outside RxCode.
        installed = persisted.installed.filter { FileManager.default.fileExists(atPath: $0.primaryFile(in: modelsRoot).path) }
        settings = persisted.settings
        // Keep what is still on disk; list older downloads found from recipes.
        var listed: [String: [LocalCompanionFile]] = [:]
        for model in installed {
            let directory = model.directory(in: modelsRoot)
            let saved = (persisted.companions?[model.id] ?? []).filter {
                FileManager.default.fileExists(atPath: directory.appending(path: $0.localName).path)
            }
            let files = saved.isEmpty ? discoveredCompanions(for: model) : saved
            if !files.isEmpty { listed[model.id] = files }
        }
        companions = listed
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Persisted(installed: installed, settings: settings, companions: companions))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            logger.error("failed to save local model index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
