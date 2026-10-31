import AppKit
import Foundation
import Observation
import os

/// Installed local models, downloads in flight, the llama.cpp and MLX
/// runtimes and the server's status — everything the RxCode Agent settings show.
@MainActor @Observable
final class LocalModelStore {
    /// One per process: models on disk and the llama.cpp server are
    /// machine-wide, so every window and workspace shares them.
    static let shared = LocalModelStore()

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

    private struct Persisted: Codable {
        var installed: [LocalModelInfo]
        var settings: Settings
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

        let directory = model.directory(in: modelsRoot)
        for companion in recipe.companions {
            let destination = directory.appending(path: companion.localName)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            status("Downloading \(companion.localName) from \(companion.repoID)…")
            let url = HuggingFaceClient.downloadURL(repoID: companion.repoID, file: companion.file)
            // Downloaded beside the target and moved in whole, so an
            // interrupted download is never mistaken for a finished file.
            let partial = directory.appending(path: companion.localName + ".part")
            try await DownloadCenter.track(companion.localName, kind: .localModel) { item in
                let token = try await HuggingFaceCredentials.shared.accessToken()
                _ = try await LocalModelDownloader().download(url, to: partial, bearerToken: token) { received, total in
                    DownloadCenter.update(item, phase: .downloading, receivedBytes: received, totalBytes: total)
                }
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        return (URL(filePath: runtime.path), recipe)
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
    /// failure or cancellation, leaving nothing half-installed.
    func download(summary: HFModelSummary, variant: HFModelVariant) async throws {
        let key = "\(summary.id)/\(variant.id)"
        guard downloads[key] == nil else { return }
        let title = summary.format == .mlx ? summary.name : "\(summary.name) · \(variant.displayName)"
        downloads[key] = Download(id: key, title: title, receivedBytes: 0, totalBytes: variant.sizeBytes)
        defer { downloads[key] = nil; downloadTasks[key] = nil }
        let item = DownloadCenter.shared.begin(title, kind: .localModel) { [weak self] in self?.cancelDownload(id: key) }
        DownloadCenter.shared.update(item, phase: .downloading, receivedBytes: 0, totalBytes: variant.sizeBytes)

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

        let work = Task { @MainActor in
            let metadata = try await HuggingFaceClient.model(summary.id, format: summary.format)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var completedBytes: Int64 = 0
            for file in variant.files {
                try Task.checkCancellation()
                let destination = directory.appending(path: localPath(file))
                let base = completedBytes
                // Fetched per file: a multi-part download can outlive a token.
                let token = try await HuggingFaceCredentials.shared.accessToken()
                _ = try await LocalModelDownloader().download(
                    HuggingFaceClient.downloadURL(repoID: summary.id, file: file), to: destination, bearerToken: token
                ) { received, _ in
                    DownloadCenter.update(item, phase: .downloading, receivedBytes: base + received)
                    Task { @MainActor [weak self] in self?.downloads[key]?.receivedBytes = base + received }
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
            if info.format == .mlx {
                try? FileManager.default.removeItem(at: directory)
            } else {
                for file in info.files { try? FileManager.default.removeItem(at: directory.appending(path: file)) }
            }
            throw error
        }

        installed.removeAll { $0.id == info.id }
        installed.append(info)
        installed.sort { $0.downloadedAt > $1.downloadedAt }
        if settings.defaultModelID == nil { settings.defaultModelID = info.id }
        persist()
        DownloadCenter.shared.finish(item)
        logger.info("installed local model \(info.id, privacy: .public)")
    }

    func cancelDownload(id: String) {
        downloadTasks[id]?.cancel()
    }

    func delete(_ model: LocalModelInfo) async {
        await manager.unload(modelID: model.id)
        if model.format == .mlx {
            try? FileManager.default.removeItem(at: model.directory(in: modelsRoot))
        }
        for file in model.files where model.format == .gguf {
            try? FileManager.default.removeItem(at: model.directory(in: modelsRoot).appending(path: file))
        }
        let directory = model.directory(in: modelsRoot)
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
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Persisted(installed: installed, settings: settings))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            logger.error("failed to save local model index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
