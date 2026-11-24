import AppKit
import Foundation
import Observation
import os
import RxCodeCore
import RxCodeExtensionBuild
import RxCodeExtensionDistribution

typealias ExtensionCatalogItem = CatalogExtensionRelease

@MainActor @Observable final class ExtensionCatalogController {
    static let shared = ExtensionCatalogController()
    private(set) var available: [ExtensionCatalogItem] = []
    private(set) var installed: [String: InstalledExtensionMetadata] = [:]
    private(set) var disabledIDs = Set<String>()
    private(set) var unknownSigningKeyUpdates = Set<String>()
    private(set) var revocationsRefreshedAt: Date?
    private(set) var needsSystemEnablement = Set<String>()
    var enablementRequested = false
    @ObservationIgnored private var backgroundInstalls = Set<String>()
    @ObservationIgnored private var preparedSeeds = Set<String>()
    @ObservationIgnored private var sceneActivations: [URL: [String: Task<Void, Error>]] = [:]
    @ObservationIgnored private var usageActivations: [URL: [String: Task<Void, Error>]] = [:]

    @ObservationIgnored private var service: ExtensionCatalogService?
    @ObservationIgnored private var starting: Task<ExtensionCatalogService, Error>?
    @ObservationIgnored private var policy: ExtensionRevocationStore?
    @ObservationIgnored private var installationWorkspace: [String: URL] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Error>?
    @ObservationIgnored private let usageStates = NSHashTable<AppState>.weakObjects()
    @ObservationIgnored weak var appState: AppState? {
        didSet { if let appState { usageStates.add(appState) } }
    }
    private let logger = Logger(subsystem: "app.rxlab.flowcy.code", category: "Extensions")

    private func initialize() async throws -> ExtensionCatalogService {
        guard ExtensionPluginAPI.v2Enabled else { throw ExtensionVerificationError.unknownKey }
        if let service { return service }
        if let starting { return try await starting.value }
        let task = Task { try await makeService() }
        starting = task
        defer { starting = nil }
        let initialized = try await task.value
        service = initialized
        return initialized
    }

    private func makeService() async throws -> ExtensionCatalogService {
        let support = AppSupport.bundleScopedURL
        let productionFile = support.appending(path: "extension-revocations.json")
        let primaryPolicy: ExtensionRevocationStore
        let remote: FlowcyExtensionCatalog
        var catalogKeys = ExtensionTrust.rxlabPublicKeys
        let bundledPolicy: BundledExtensionPolicy?
        #if DEBUG
        let developmentPolicy = try ExtensionRevocationStore(file: support.appending(path: "DebugExtensions/extension-revocations.json"),
                                                             publicKey: ExtensionTrust.debugRevocationKey)
        try await developmentPolicy.migrateSignedBaseline(from: productionFile)
        if let key = ExtensionTrust.revocationPublicKey {
            primaryPolicy = try ExtensionRevocationStore(file: productionFile, publicKey: key)
        } else {
            primaryPolicy = developmentPolicy
        }
        let override = UserDefaults.standard.string(forKey: "RxCodeExtensionCatalogURL").flatMap(URL.init(string:))
        let isFixtureCatalog = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(override?.host?.lowercased() ?? "")
        if isFixtureCatalog { catalogKeys = ExtensionTrust.debugKeys }
        remote = override.map { FlowcyExtensionCatalog(testBaseURL: $0) } ?? FlowcyExtensionCatalog()
        bundledPolicy = BundledExtensionPolicy(keyIDs: Set(ExtensionTrust.debugKeys.keys), store: developmentPolicy,
                                               useForCatalog: isFixtureCatalog)
        #else
        guard let key = ExtensionTrust.revocationPublicKey else { throw ExtensionVerificationError.unknownKey }
        primaryPolicy = try ExtensionRevocationStore(file: productionFile, publicKey: key)
        remote = FlowcyExtensionCatalog()
        bundledPolicy = nil
        #endif
        let service = ExtensionCatalogService(support: support, keys: ExtensionTrust.verificationKeys,
            revocations: primaryPolicy, catalog: remote, developerIDSignedKeys: ExtensionTrust.developerIDSignedKeys,
            catalogKeys: catalogKeys, bundledPolicy: bundledPolicy, activate: { [weak self] release in
                guard let self else { throw CancellationError() }
                try await self.activateForInstall(release)
            }, deactivate: { release in
                await AgentExtensionRuntime.shared.closeSessions(bundleIdentifier: release.envelope.id + ".service")
                // LSRegisterURL registers an item. Launch Services' unregister operation is provided by lsregister.
                let utility = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                try await Task.detached { _ = try ExtensionCompiler.run(utility, ["-u", release.container.path]) }.value
            }, blocked: { [weak self] id in
                await self?.blockUsageProvider(id)
            })
        self.policy = bundledPolicy?.useForCatalog == true ? bundledPolicy?.store : primaryPolicy
        if let base = Bundle.main.url(forResource: "revocations", withExtension: "json", subdirectory: "BundledExtensions") {
            do {
                let signature = try String(contentsOf: base.appendingPathExtension("sig"), encoding: .utf8)
                try await service.seedBaseline(data: Data(contentsOf: base), signature: signature.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                logger.error("Bundled revocation baseline rejected: \(error.localizedDescription, privacy: .public)")
            }
        }
        return service
    }

    private func blockUsageProvider(_ id: String) async {
        AgentExtensionRuntime.shared.closeSessions(bundleIdentifier: id + ".service")
        for state in usageStates.allObjects {
            await state.markUsageExtension(id, manifest: installed[id]?.manifest, status: .blocked)
        }
    }

    func refresh() async throws {
        if let refreshing { return try await refreshing.value }
        let task = Task<Void, Error> {
            let service = try await initialize()
            do { try await service.refreshRevocations() } catch {
                logger.error("Revocation refresh failed: \(error.localizedDescription, privacy: .public)")
            }
            revocationsRefreshedAt = await policy?.lastRefreshed
            try await loadInstalled(from: service)
            let releases = try await service.available()
            available = releases
            for release in releases where installed[release.id] != nil && ExtensionTrust.verificationKeys[release.keyId] == nil {
                unknownSigningKeyUpdates.insert(release.id)
            }
            for release in releases where ExtensionTrust.verificationKeys[release.keyId] != nil {
                await updateReferencedProvider(release, service: service)
            }
        }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    private func updateReferencedProvider(_ release: ExtensionCatalogItem, service: ExtensionCatalogService) async {
        guard installationWorkspace[release.id] == nil, !disabledIDs.contains(release.id),
              installed[release.id]?.version != release.version else { return }
        let roots = usageStates.allObjects.flatMap { state in
            state.usageDashboard.integrations.compactMap { integration -> URL? in
                let owner = usageMetadata(integration.pluginID)?.manifest?.id ?? BundledUsageExtensions.releaseID(for: integration.pluginID)
                return owner == release.id ? state.usageExtensionWorkspace(for: integration) : nil
            }
        }
        guard let root = roots.first else { return }
        // Finish the offline seed before looking for its replacement, including on first launch.
        guard preparedSeeds.contains(release.id) || installed[release.id] != nil else { return }
        installationWorkspace[release.id] = root
        backgroundInstalls.insert(release.id)
        defer {
            installationWorkspace[release.id] = nil
            backgroundInstalls.remove(release.id)
        }
        do {
            guard try await service.install(release, explicit: false) != nil else { return }
            preparedSeeds.insert(release.id)
            unknownSigningKeyUpdates.remove(release.id)
            try await loadInstalled(from: service)
            await refreshUsageForExtension(release.id)
        } catch { logger.debug("Extension update deferred: \(error.localizedDescription, privacy: .public)") }
    }

    private func loadInstalled(from service: ExtensionCatalogService) async throws {
        var items: [String: InstalledExtensionMetadata] = [:]
        var disabled = Set<String>()
        for release in try await service.installed() {
            let envelope = release.envelope
            if try await service.isDisabled(id: envelope.id) { disabled.insert(envelope.id) }
            guard let key = ExtensionTrust.verificationKeys[envelope.keyId] else { continue }
            // Verification labels are derived exclusively from local signature and binary checks.
            let blocked: Bool
            do { _ = try await service.verifiedForDisplay(id: envelope.id); blocked = false }
            catch ExtensionVerificationError.revoked { blocked = true }
            catch { logger.error("Cannot verify installed release: \(error.localizedDescription, privacy: .public)"); continue }
            let metadata = await Task.detached {
                let resources = release.container.appending(path: "Contents/Resources")
                let icon = resources.appending(path: "Icon.png")
                var item = InstalledExtensionMetadata(bundleIdentifier: envelope.id + ".service", name: release.manifest.name,
                    version: envelope.version, pluginAPIVersion: envelope.pluginApi,
                    readme: try? String(contentsOf: resources.appending(path: "README.md"), encoding: .utf8), readmeBaseURL: resources,
                    icon: FileManager.default.fileExists(atPath: icon.path) ? .image(icon) : .application(release.container),
                    containerURL: release.container, isDevelopment: false, manifest: release.manifest)
                item.verification = .init(keyId: envelope.keyId, fingerprint: ExtensionReleaseVerifier.digest(key),
                                          sha256: envelope.sha256, blocked: blocked, source: release.source.rawValue)
                return item
            }.value
            items[envelope.id] = metadata
        }
        installed = items
        disabledIDs = disabled
    }

    func install(_ item: ExtensionCatalogItem, workspace: URL) async throws {
        let service = try await initialize()
        guard installationWorkspace[item.id] == nil else { throw ExtensionCatalogService.InstallError.busy }
        installationWorkspace[item.id] = workspace
        defer { installationWorkspace[item.id] = nil }
        do { _ = try await service.install(item, explicit: true) }
        catch ExtensionVerificationError.unknownKey {
            unknownSigningKeyUpdates.insert(item.id)
            throw ExtensionVerificationError.unknownKey
        }
        preparedSeeds.insert(item.id)
        unknownSigningKeyUpdates.remove(item.id)
        try await loadInstalled(from: service)
        await refreshUsageForExtension(item.id)
    }

    func setEnabled(_ enabled: Bool, id: String, workspace: URL? = nil) async throws {
        let service = try await initialize()
        if enabled {
            let fallback = appState?.registeredWindows().compactMap { appState?.effectiveCwd(in: $0) }.first
            guard let root = workspace ?? fallback.map({ URL(filePath: $0) }) else {
                throw ExtensionBuildError("Open a project before enabling this extension.")
            }
            guard installationWorkspace[id] == nil else { throw ExtensionCatalogService.InstallError.busy }
            installationWorkspace[id] = root
        }
        defer { if enabled { installationWorkspace[id] = nil } }
        try await service.setEnabled(enabled, id: id)
        try await loadInstalled(from: service)
        if enabled { await refreshUsageForExtension(id) }
        else {
            for state in usageStates.allObjects { await state.markUsageExtension(id, manifest: installed[id]?.manifest, status: .enable) }
        }
    }

    func uninstall(_ id: String) async throws {
        let service = try await initialize()
        let manifest = installed[id]?.manifest
        try await service.uninstall(id: id)
        for state in usageStates.allObjects { await state.markUsageExtension(id, manifest: manifest, status: .install) }
        unknownSigningKeyUpdates.remove(id)
        needsSystemEnablement.remove(id)
        try await loadInstalled(from: service)
    }

    func loadInstalledMetadata() async throws {
        let service = try await initialize()
        try await loadInstalled(from: service)
    }

    func openScene(_ scene: String, item: InstalledExtensionMetadata, workspace: URL, state: AppState) async throws {
        guard item.verification != nil, let manifest = item.manifest, manifest.contributes.sceneIDs.contains(scene) else {
            throw UsageExtensionStatus.unavailable
        }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let id = manifest.id
        if let pending = sceneActivations[root]?[id] { return try await pending.value }
        let job = Task {
            let service = try await initialize()
            let verified = try await service.verifiedForActivation(id: id)
            guard verified.manifest.contributes.sceneIDs.contains(scene) else { throw UsageExtensionStatus.unavailable }
            if let panel = AgentExtensionRuntime.shared.panels.first(where: {
                $0.bundleIdentifier == item.bundleIdentifier && $0.workspace.path == root.path
            }) {
                try await panel.revalidate?()
                return
            }
            // The visible scene reviews high-risk permissions once it has connected.
            try await activate(verified, workspace: root, interactive: false, sceneState: state)
        }
        sceneActivations[root, default: [:]][id] = job
        defer {
            sceneActivations[root]?[id] = nil
            if sceneActivations[root]?.isEmpty == true { sceneActivations[root] = nil }
        }
        try await job.value
    }

    private func activateForInstall(_ release: InstalledRelease) async throws {
        guard let workspace = installationWorkspace[release.envelope.id] else { throw ExtensionCatalogService.InstallError.missingRelease }
        do {
            try await activate(release, workspace: workspace, interactive: !backgroundInstalls.contains(release.envelope.id))
        } catch ExtensionCatalogService.InstallError.disabled where needsSystemEnablement.contains(release.envelope.id) {
            // macOS registered the verified bundle. Leave it installed until the user enables it.
        }
    }

    private func activate(_ release: InstalledRelease, workspace: URL, interactive: Bool, sceneState: AppState? = nil) async throws {
        guard let service else { throw ExtensionCatalogService.InstallError.missingRelease }
        let id = release.envelope.id
        let checked = try await service.verifiedForActivation(id: id)
        guard checked.envelope == release.envelope else { throw ExtensionVerificationError.codeHashMismatch }
        let generation = try await Task.detached {
            let data = try Data(contentsOf: release.container.appending(path: "Contents/Info.plist"))
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let digest = info["RxCodeSourceDigest"] as? String else { throw ExtensionVerificationError.invalidPayload }
            return digest
        }.value
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let expectedHash = try checked.envelope.architectureHashes()[architecture]
        let state = sceneState ?? usageStates.allObjects.first { state in
            state.usageDashboard.integrations.contains { integration in
                release.manifest.contributes.usageProviders?.contains(where: { $0.pluginID == integration.pluginID }) == true &&
                    state.usageExtensionWorkspace(for: integration)?.standardizedFileURL.path == workspace.standardizedFileURL.path
            }
        } ?? appState
        try await AgentExtensionRuntime.shared.reload(workspace: workspace, bundleIdentifier: id + ".service",
            container: release.container, generation: generation, usesManifest: true, distributed: true,
            requiresDeveloperID: ExtensionTrust.developerIDSignedKeys.contains(release.envelope.keyId),
            reviewPermissions: interactive, appState: state, expectedCodeHash: expectedHash, revalidate: {
                let current = try await service.verifiedForActivation(id: id)
                guard current.envelope == checked.envelope else { throw ExtensionVerificationError.codeHashMismatch }
            }, requestEnablement: { enabled in
                self.needsSystemEnablement.insert(id)
                guard interactive, !self.enablementRequested else { throw ExtensionCatalogService.InstallError.disabled }
                self.enablementRequested = true
                defer { self.enablementRequested = false }
                while !enabled() {
                    guard self.enablementRequested else { throw CancellationError() }
                    try await Task.sleep(for: .milliseconds(250))
                }
            })
        needsSystemEnablement.remove(id)
    }

    func refreshUsageForExtension(_ id: String) async {
        guard installed[id]?.manifest?.contributes.usageProviders?.isEmpty == false else { return }
        for state in usageStates.allObjects { await state.refreshUsageForExtension(id) }
    }

    func usageMetadata(_ pluginID: String) -> InstalledExtensionMetadata? {
        installed.values.first { item in
            item.manifest?.contributes.usageProviders?.contains { $0.pluginID == pluginID } == true
        }
    }

    func installedUsagePanel(pluginID: String, workspace: URL) -> ActivatedExtension? {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let panels = AgentExtensionRuntime.shared.panels.filter { $0.workspace == root }
        if let item = usageMetadata(pluginID), let id = item.manifest?.id {
            guard item.verification?.blocked == false, !disabledIDs.contains(id) else { return nil }
            return panels.first { $0.bundleIdentifier == item.bundleIdentifier }
        }
        // Reserved first-party IDs never select a development copy for a saved integration.
        guard !AppState.usagePluginIDs.contains(pluginID) else { return nil }
        let development = panels.filter { panel in
            panel.revalidate == nil && panel.manifest.contributes.usageProviders?.contains { $0.pluginID == pluginID } == true
        }
        return development.count == 1 ? development.first : nil
    }

    func seedUsage(_ pluginID: String, workspace: URL, explicit: Bool = false) async throws {
        let id = BundledUsageExtensions.releaseID(for: pluginID)
        guard explicit || !preparedSeeds.contains(id) else { return }
        let service = try await initialize()
        guard installationWorkspace[id] == nil else { throw ExtensionCatalogService.InstallError.busy }
        installationWorkspace[id] = workspace
        if !explicit { backgroundInstalls.insert(id) }
        defer {
            installationWorkspace[id] = nil
            backgroundInstalls.remove(id)
        }
        if let root = Bundle.main.resourceURL {
            let resources = BundledUsageExtensions(directory: root.appending(path: "BundledExtensions"))
            do { _ = try await service.seedUsageProvider(pluginID, from: resources, explicit: explicit) }
            catch ExtensionVerificationError.revoked where !explicit {
                // Keep any newer installed replacement and allow catalog recovery of a revoked seed.
                logger.notice("Bundled usage extension is revoked: \(id, privacy: .public)")
            }
        }
        try await loadInstalled(from: service)
        preparedSeeds.insert(id)
    }

    func usagePanel(pluginID: String, workspace: URL) async throws -> ActivatedExtension {
        if let panel = installedUsagePanel(pluginID: pluginID, workspace: workspace),
           panel.revalidate == nil || preparedSeeds.contains(panel.manifest.id) { return panel }
        if let job = usageActivations[workspace]?[pluginID] { try await job.value }
        else {
            let job = Task {
                try await seedUsage(pluginID, workspace: workspace)
                guard let item = usageMetadata(pluginID), let id = item.manifest?.id else { throw UsageExtensionStatus.install }
                if item.verification?.blocked == true { throw UsageExtensionStatus.blocked }
                if disabledIDs.contains(id) { throw UsageExtensionStatus.enable }
                guard installedUsagePanel(pluginID: pluginID, workspace: workspace) == nil else { return }
                let service = try await initialize()
                let release = try await service.verifiedForActivation(id: id)
                try await activate(release, workspace: workspace, interactive: false)
            }
            usageActivations[workspace, default: [:]][pluginID] = job
            defer {
                usageActivations[workspace]?[pluginID] = nil
                if usageActivations[workspace]?.isEmpty == true { usageActivations[workspace] = nil }
            }
            try await job.value
        }
        guard let panel = installedUsagePanel(pluginID: pluginID, workspace: workspace) else { throw UsageExtensionStatus.unavailable }
        return panel
    }
}
