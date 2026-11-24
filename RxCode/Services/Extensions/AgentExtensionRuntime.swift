import AppKit
import ExtensionFoundation
import Foundation
import LightweightCodeRequirements
import Observation
import os
import RxCodeCore
import RxCodeExtensionSDK
import Security
import RxCodeExtensionBuild
import XPC

private struct ExtensionRuntimeError: LocalizedError {
    let errorDescription: String?
    nonisolated init(_ message: String) { errorDescription = message }
}

typealias ExtensionEnablementHandler = @MainActor @Sendable (_ isEnabled: @MainActor () -> Bool) async throws -> Void

struct ActivatedExtension: Identifiable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String { identity.bundleIdentifier }
    let identity: AppExtensionIdentity
    let permissionIdentity: String
    let manifest: ExtensionManifest
    let generation: String
    let codeHash: Data
    var requiresDeveloperID = false
    let workspace: URL
    let broker: ExtensionBroker
    let project: Project?
    let revalidate: (@MainActor @Sendable () async throws -> Void)?
}

@MainActor @Observable
final class AgentExtensionRuntime {
    static let shared = AgentExtensionRuntime()

    private struct Key: Hashable {
        let workspace: URL
        let bundleIdentifier: String

        init(_ workspace: URL, _ bundleIdentifier: String) {
            self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
            self.bundleIdentifier = bundleIdentifier
        }
    }

    private(set) var panels: [ActivatedExtension] = []
    @ObservationIgnored private var sessions: [Key: DevelopmentSession] = [:]
    @ObservationIgnored private let usageScheduler = ExtensionUsageScheduler()
    @ObservationIgnored private var fetchSessions: [Key: [UUID: DevelopmentSession]] = [:]
    @ObservationIgnored private var busy: Set<Key> = []

    func reload(workspace: URL, bundleIdentifier: String, container: URL, generation: String, usesManifest: Bool = false,
                distributed: Bool = false, requiresDeveloperID: Bool = false, reviewPermissions: Bool = true, appState: AppState? = nil, expectedCodeHash: String? = nil,
                revalidate: (@MainActor @Sendable () async throws -> Void)? = nil,
                requestEnablement: ExtensionEnablementHandler) async throws {
        let key = Key(workspace, bundleIdentifier)
        try begin(key)
        defer { busy.remove(key) }
        guard !usesManifest || ExtensionPluginAPI.v2Enabled else { throw ExtensionCallError.invalidRequest }
        let extensionPoint: AppExtensionPoint = usesManifest ? .workspaceContributions : .workspaceServices
        let point = extensionPoint.id
        let validation = try await Task.detached(priority: .userInitiated) {
            try Self.validateBuild(container: container, bundleIdentifier: bundleIdentifier,
                              generation: generation, extensionPoint: point, distributed: distributed, requiresDeveloperID: requiresDeveloperID)
        }.value
        try Task.checkCancellation()

        let manifest = validation.manifest
        guard (manifest != nil) == usesManifest else { throw ExtensionCallError.invalidRequest }
        if distributed {
            let observedHash = validation.hash.map { String(format: "%02x", $0) }.joined()
            guard let revalidate, observedHash == expectedCodeHash else { throw ExtensionCallError.extensionBlocked }
            try await revalidate()
        }

        if let manifest {
            try await ExtensionPermissionStore.shared.review(manifest: manifest,
                identity: distributed ? manifest.id : bundleIdentifier, interactive: reviewPermissions)
        }

        // Launch Services can record an unopened app without publishing its embedded extensions.
        // Open the generated, windowless container before querying the system extension browser.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: container, configuration: configuration)
        try Task.checkCancellation()

        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: extensionPoint)
        let deadline = ContinuousClock.now + .seconds(5)
        var candidates: [AppExtensionIdentity]
        repeat {
            candidates = monitor.identities.filter { $0.bundleIdentifier == bundleIdentifier }
            if !candidates.isEmpty { break }
            try await Task.sleep(for: .milliseconds(200))
        } while .now < deadline
        if candidates.isEmpty {
            let state = monitor.state
            guard state.disabledCount > 0 || state.unapprovedCount > 0 else {
                throw ExtensionRuntimeError("macOS has not discovered the service in \(container.path). Retry the reload.")
            }
            try await requestEnablement {
                monitor.identities.contains { $0.bundleIdentifier == bundleIdentifier }
            }
            candidates = monitor.identities.filter { $0.bundleIdentifier == bundleIdentifier }
        }
        try Task.checkCancellation()
        guard let identity = candidates.first else {
            throw ExtensionRuntimeError(
                "macOS has not enabled \(bundleIdentifier). Open Settings → Extensions → Manage Extensions, enable the contributor, then reload it."
            )
        }
        guard candidates.count == 1 else {
            throw ExtensionRuntimeError("Multiple enabled extensions have the identifier \(bundleIdentifier). Disable the duplicate and reload.")
        }

        stopUsage(in: key)
        sessions.removeValue(forKey: key)?.close()
        try await revalidate?()
        let project = appState?.registeredWindows().first(where: { window in
            guard let path = appState?.effectiveCwd(in: window) else { return false }
            return URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path == key.workspace.path
        })?.selectedProject ?? appState?.projects.first(where: { $0.path == key.workspace.path })
        let broker = try manifest.map {
            try ExtensionBroker(manifest: $0, projectRoot: key.workspace, bundleIdentifier: distributed ? $0.id : bundleIdentifier,
                                appState: appState, project: project, verifiedProvider: distributed)
        }
        let session = DevelopmentSession(identity: identity, monitor: monitor, requirement: validation.requirement,
                                         manifest: manifest, broker: broker)
        sessions[key] = session
        session.onClose = { [weak self, weak session] in
            if self?.sessions[key] === session {
                self?.sessions.removeValue(forKey: key)
                self?.stopUsage(in: key)
            }
            self?.panels.removeAll { $0.bundleIdentifier == bundleIdentifier && $0.generation == generation && $0.workspace == key.workspace }
        }
        do {
            try await session.activate(generation: generation)
            try await revalidate?()
            if distributed { session.endIdleConnection() }
            if let manifest, let broker {
                panels.append(ActivatedExtension(identity: identity, permissionIdentity: distributed ? manifest.id : bundleIdentifier, manifest: manifest, generation: generation,
                                                 codeHash: validation.hash, requiresDeveloperID: requiresDeveloperID, workspace: key.workspace, broker: broker, project: project,
                                                 revalidate: distributed ? revalidate : nil))
            }
        } catch {
            session.close()
            throw error
        }
    }

    func test(workspace: URL, bundleIdentifier: String, input: String) async throws -> String {
        let key = Key(workspace, bundleIdentifier)
        try begin(key)
        defer { busy.remove(key) }
        guard let session = sessions[key] else {
            throw ExtensionRuntimeError("Reload this extension successfully before testing it.")
        }
        return try await session.test(input)
    }

    func fetchUsage(_ integration: UsageIntegration, bundleIdentifier: String, workspace: URL, appState: AppState) async throws -> UsagePluginSnapshot {
        let key = Key(workspace, bundleIdentifier)
        guard let panel = panels.first(where: { $0.bundleIdentifier == bundleIdentifier && $0.workspace == key.workspace }),
              let parent = sessions[key], panel.manifest.contributes.usageProviders?.contains(where: { $0.pluginID == integration.pluginID }) == true,
              integration.projectID == nil || integration.projectID == panel.project?.id,
              appState.usageDashboard.integrations.contains(integration) else { throw ExtensionCallError.invalidRequest }
        return try await usageScheduler.fetch(provider: bundleIdentifier, workspace: key.workspace, generation: panel.generation, integration: integration) {
            try await panel.revalidate?()
            try Task.checkCancellation()
            guard self.sessions[key] === parent, appState.usageDashboard.integrations.contains(integration) else { throw ExtensionCallError.extensionBlocked }
            // Only installed, independently verified first-party providers receive the existing host credential slots.
            let ownsSlots = panel.revalidate != nil && panel.manifest.id == "app.rxlab.extensions." + integration.pluginID
            let broker = try ExtensionBroker(manifest: panel.manifest, projectRoot: key.workspace, bundleIdentifier: panel.permissionIdentity,
                                             appState: appState, project: panel.project, integration: integration, verifiedProvider: ownsSlots)
            let child = parent.usageSession(broker: broker)
            let id = UUID()
            self.fetchSessions[key, default: [:]][id] = child
            defer {
                child.close()
                self.fetchSessions[key]?[id] = nil
                if self.fetchSessions[key]?.isEmpty == true { self.fetchSessions[key] = nil }
            }
            try await child.activate(generation: panel.generation)
            let snapshot = try await child.fetchUsage(integration)
            try await panel.revalidate?()
            try Task.checkCancellation()
            guard self.sessions[key] === parent, appState.usageDashboard.integrations.contains(integration),
                  snapshot.id == integration.id, snapshot.pluginID == integration.pluginID, snapshot.projectID == integration.projectID else {
                throw ExtensionCallError.extensionBlocked
            }
            return snapshot
        }
    }

    private func stopUsage(in key: Key) {
        usageScheduler.invalidate(provider: key.bundleIdentifier, workspace: key.workspace)
        guard let children = fetchSessions.removeValue(forKey: key) else { return }
        for child in children.values { child.close() }
    }

    func closeSessions(bundleIdentifier: String) {
        let matching = sessions.keys.filter { $0.bundleIdentifier == bundleIdentifier }
        for key in matching { sessions[key]?.close() }
    }

    private func begin(_ key: Key) throws {
        guard busy.insert(key).inserted else {
            throw ExtensionRuntimeError("Another reload or test is running for this extension. Retry when it finishes.")
        }
    }

    /// Read the product from disk each time; Bundle can cache metadata across rebuilds.
    private nonisolated static func validateBuild(container: URL, bundleIdentifier: String,
                                             generation: String, extensionPoint: String, distributed: Bool, requiresDeveloperID: Bool) throws -> (requirement: XPCPeerRequirement, hash: Data, manifest: ExtensionManifest?) {
        let service = container.appending(path: "Contents/Extensions/Service.appex")
        let infoData = try Data(contentsOf: service.appending(path: "Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        let attributes = info?["EXAppExtensionAttributes"] as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              info?[distributed ? "RxCodeSourceDigest" : "RxCodeDevelopmentGeneration"] as? String == generation, !generation.isEmpty,
              attributes?["EXExtensionPointIdentifier"] as? String == extensionPoint else {
            throw ExtensionRuntimeError("The built extension identifier, extension point, or generation does not match the requested build.")
        }

        var product: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(container as CFURL, [], &product) == errSecSuccess,
              let product, SecStaticCodeCheckValidity(product, flags, nil) == errSecSuccess else {
            throw ExtensionRuntimeError("The contributor app or an embedded component has an invalid code signature.")
        }
        var executable: SecStaticCode?
        guard SecStaticCodeCreateWithPath(service as CFURL, [], &executable) == errSecSuccess, let executable,
              let values = try? ExtensionCompiler.signingInformation(of: executable),
              values[kSecCodeInfoIdentifier as String] as? String == bundleIdentifier,
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
            throw ExtensionRuntimeError("Cannot identify the signed extension executable.")
        }
        var manifest: ExtensionManifest?
        if info?[ExtensionPluginAPI.infoPlistKey] as? String == ExtensionManifest.apiVersion {
            _ = try ExtensionCompiler.codeHashes(of: service)
            let resource = "Contents/Resources/" + ExtensionManifest.resourceName
            let bytes = try Data(contentsOf: service.appending(path: resource))
            guard try Data(contentsOf: container.appending(path: resource)) == bytes else { throw ExtensionCallError.invalidRequest }
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: bytes)
            try manifest?.validate()
        }
        if requiresDeveloperID {
            guard values[kSecCodeInfoTeamIdentifier as String] as? String == "T7GYB573Y6" else {
                throw ExtensionRuntimeError("The distributed extension requires the rxlab Developer ID.")
            }
            return (try .codeRequirement(.allOf {
                CodeDirectoryHash(hash)
                TeamIdentifier("T7GYB573Y6")
            }), hash, manifest)
        }
        return (try .codeRequirement(.allOf { CodeDirectoryHash(hash) }), hash, manifest)
    }
}

@MainActor
private final class DevelopmentSession {
    private let identity: AppExtensionIdentity
    private let monitor: AppExtensionPoint.Monitor
    private var process: AppExtensionProcess?
    private var connection: XPCSession?
    private var cancelPending: ((Error) -> Void)?
    private var closed = false
    private var processID: UUID?
    private var observed = false
    private var activeGeneration: String?
    var onClose: (() -> Void)?

    private let requirement: XPCPeerRequirement
    private let manifest: ExtensionManifest?
    private let broker: ExtensionBroker?

    init(identity: AppExtensionIdentity, monitor: AppExtensionPoint.Monitor, requirement: XPCPeerRequirement, manifest: ExtensionManifest?, broker: ExtensionBroker?) {
        self.manifest = manifest
        self.broker = broker
        self.requirement = requirement
        self.identity = identity
        self.monitor = monitor
    }

    func activate(generation: String) async throws {
        if !observed {
            observed = true
            observeIdentity()
        }
        let processID = UUID()
        self.processID = processID
        let actual: String = try await response { reply in
            Task { @MainActor [self] in
                do {
                    let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: self.identity) { [weak self] in
                        Task { @MainActor [weak self] in
                            if self?.processID == processID { self?.close() }
                        }
                    })
                    guard !self.closed, self.processID == processID else { process.invalidate(); return }
                    self.process = process
                    let session = try process.makeXPCSession()
                    session.setPeerRequirement(self.requirement)
                    if let broker { Self.attach(broker, to: session) }
                    try session.activate()
                    self.connection = session
                    if let manifest {
                        try self.send(ExtensionRequest(.hello, generation), reply: reply) { (hello: ExtensionHello) in
                            try manifest.validate(reportedScenes: Set(hello.scenes))
                            return hello.generation
                        }
                    } else {
                        try self.send(["operation": "generation"], reply: reply)
                    }
                } catch { reply.finish(throwing: error) }
            }
        }
        guard !closed, actual == generation else {
            throw ExtensionRuntimeError("macOS did not activate the requested extension generation. Reload the contributor again.")
        }
        activeGeneration = generation
    }

    // A catalog identity and its scene broker can remain visible without a headless process.
    func endIdleConnection() {
        processID = nil
        connection?.cancel(reason: "Extension request finished.")
        process?.invalidate()
        connection = nil
        process = nil
    }

    func test(_ input: String) async throws -> String {
        let wasIdle = connection == nil
        if wasIdle, let activeGeneration { try await activate(generation: activeGeneration) }
        defer { if wasIdle { endIdleConnection() } }
        guard monitor.identities.contains(identity) else {
            close()
            throw ExtensionRuntimeError("The contributor is no longer enabled. Enable it and reload.")
        }
        return try await response { reply in
            if manifest != nil {
                try send(ExtensionRequest(.test, input), reply: reply) { (text: String) in text }
            } else {
                try send(["operation": "test", "input": input], reply: reply)
            }
        }
    }

    func usageSession(broker: ExtensionBroker) -> DevelopmentSession {
        DevelopmentSession(identity: identity, monitor: monitor, requirement: requirement, manifest: manifest, broker: broker)
    }

    func fetchUsage(_ integration: UsageIntegration) async throws -> UsagePluginSnapshot {
        try await response { reply in
            try send(ExtensionRequest(.fetchUsage, integration), reply: reply) { (snapshot: UsagePluginSnapshot) in snapshot }
        }
    }

    private static func attach(_ broker: ExtensionBroker, to session: XPCSession) {
        let queue = DispatchQueue(label: "app.rxlab.extension-broker", attributes: .concurrent)
        session.setIncomingMessageHandler { (message: XPCReceivedMessage) -> (any Encodable)? in
            guard let request = try? message.decode(as: ExtensionRequest.self) else { return nil }
            return message.handoffReply(to: queue) {
                let result = DispatchSemaphore(value: 0)
                let response = OSAllocatedUnfairLock<ExtensionResponse?>(initialState: nil)
                let task = Task {
                    let value = await broker.handle(request)
                    response.withLock { $0 = value }
                    result.signal()
                }
                _ = result.wait(timeout: .now() + 12)
                task.cancel()
                message.reply(response.withLock { $0 } ?? ExtensionResponse(replyingTo: request, error: .timeout))
            }
        }
    }

    private func send<T: Decodable & Sendable, Output: Sendable>(_ request: ExtensionRequest, reply: AsyncThrowingStream<Output, Error>.Continuation,
                                                                transform: @escaping @Sendable (T) throws -> Output) throws {
        guard let connection else { throw ExtensionCallError.extensionBlocked }
        try connection.send(request) { (result: Result<ExtensionResponse, any Error>) in
            do {
                reply.yield(try transform(result.get().decode(T.self, for: request)))
                reply.finish()
            } catch { reply.finish(throwing: error) }
        }
    }

    private func send(_ message: [String: String], reply: AsyncThrowingStream<String, Error>.Continuation) throws {
        guard let connection else { throw ExtensionRuntimeError("The extension connection is unavailable.") }
        try connection.send(message) { @Sendable (result: Result<[String: String], any Error>) in
            do {
                guard let value = try result.get()["value"] else {
                    throw ExtensionRuntimeError("The extension returned an invalid response.")
                }
                reply.yield(value)
                reply.finish()
            } catch {
                reply.finish(throwing: error)
            }
        }
    }

    private func response<Output: Sendable>(
        _ start: (AsyncThrowingStream<Output, Error>.Continuation) throws -> Void
    ) async throws -> Output {
        guard !closed else { throw ExtensionRuntimeError("The extension is no longer active. Reload it and retry.") }
        try Task.checkCancellation()
        let (stream, reply) = AsyncThrowingStream<Output, Error>.makeStream()
        cancelPending = { reply.finish(throwing: $0) }
        let timeout = Task {
            try await Task.sleep(for: .seconds(12))
            reply.finish(throwing: ExtensionCallError.timeout)
        }
        defer { timeout.cancel(); reply.finish(); cancelPending = nil }
        try start(reply)
        var iterator = stream.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }

    private func observeIdentity() {
        guard !closed else { return }
        let enabled = withObservationTracking {
            monitor.identities.contains(identity)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeIdentity() }
        }
        if !enabled { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        broker?.block()
        cancelPending?(ExtensionCallError.extensionBlocked)
        connection?.cancel(reason: "Extension session closed.")
        process?.invalidate()
        connection = nil
        process = nil
        onClose?()
    }
}
