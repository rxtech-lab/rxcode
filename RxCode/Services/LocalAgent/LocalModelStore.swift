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

    struct Settings: Codable, Equatable {
        /// Minutes without a request before the model is unloaded. 0 = never.
        var idleMinutes: Int = 15
        /// Overrides the hardware-based default when set.
        var contextSize: Int?
        var defaultModelID: String?
    }

    private(set) var installed: [LocalModelInfo] = []
    private(set) var downloads: [String: Download] = [:]
    private(set) var runtime: LlamaRuntimeInstaller.Runtime?
    private(set) var mlxRuntime: LlamaRuntimeInstaller.Runtime?
    private(set) var runtimeDownload: Download?
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
        mlxRuntime = MLXRuntimeInstaller.locate(appSupport: base)
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
        let info = LocalModelInfo(
            repoID: summary.id, author: summary.author, files: variant.files.map(localPath),
            sizeBytes: variant.sizeBytes, parameterCount: summary.parameterCount, contextLength: summary.contextLength,
            architecture: summary.architecture, quantization: variant.quantization, downloadedAt: Date(),
            format: summary.format
        )
        let directory = info.directory(in: modelsRoot)

        let work = Task { @MainActor in
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
