import AppKit
import ExtensionFoundation
import Foundation
import LightweightCodeRequirements
import Observation
import Security
import XPC

private struct ExtensionRuntimeError: LocalizedError {
    let errorDescription: String?
    nonisolated init(_ message: String) { errorDescription = message }
}

typealias ExtensionEnablementHandler = @MainActor @Sendable (_ isEnabled: @MainActor () -> Bool) async throws -> Void

@MainActor
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

    private var sessions: [Key: DevelopmentSession] = [:]
    private var busy: Set<Key> = []

    func reload(workspace: URL, bundleIdentifier: String, container: URL, generation: String,
                requestEnablement: ExtensionEnablementHandler) async throws {
        let key = Key(workspace, bundleIdentifier)
        try begin(key)
        defer { busy.remove(key) }
        let point = AppExtensionPoint.workspaceServices.id
        let requirement = try await Task.detached(priority: .userInitiated) {
            try Self.validateBuild(container: container, bundleIdentifier: bundleIdentifier,
                              generation: generation, extensionPoint: point)
        }.value
        try Task.checkCancellation()

        // Launch Services can record an unopened app without publishing its embedded extensions.
        // Open the generated, windowless container before querying the system extension browser.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: container, configuration: configuration)
        try Task.checkCancellation()

        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .workspaceServices)
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

        sessions.removeValue(forKey: key)?.close()
        let session = DevelopmentSession(identity: identity, monitor: monitor, requirement: requirement)
        sessions[key] = session
        session.onClose = { [weak self, weak session] in
            if self?.sessions[key] === session { self?.sessions.removeValue(forKey: key) }
        }
        do {
            try await session.activate(generation: generation)
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

    private func begin(_ key: Key) throws {
        guard busy.insert(key).inserted else {
            throw ExtensionRuntimeError("Another reload or test is running for this extension. Retry when it finishes.")
        }
    }

    /// Read the product from disk each time; Bundle can cache metadata across rebuilds.
    private nonisolated static func validateBuild(container: URL, bundleIdentifier: String,
                                             generation: String, extensionPoint: String) throws -> XPCPeerRequirement {
        let service = container.appending(path: "Contents/Extensions/Service.appex")
        let infoData = try Data(contentsOf: service.appending(path: "Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        let attributes = info?["EXAppExtensionAttributes"] as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              info?["RxCodeDevelopmentGeneration"] as? String == generation, !generation.isEmpty,
              attributes?["EXExtensionPointIdentifier"] as? String == extensionPoint else {
            throw ExtensionRuntimeError("The built extension identifier, extension point, or generation does not match the requested build.")
        }

        var product: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(container as CFURL, [], &product) == errSecSuccess,
              let product, SecStaticCodeCheckValidity(product, flags, nil) == errSecSuccess else {
            throw ExtensionRuntimeError("The contributor app or an embedded component has an invalid code signature.")
        }
        var executable: SecStaticCode?
        var signingInfo: CFDictionary?
        guard SecStaticCodeCreateWithPath(service as CFURL, [], &executable) == errSecSuccess, let executable,
              SecCodeCopySigningInformation(executable, [], &signingInfo) == errSecSuccess,
              let values = signingInfo as? [String: Any],
              values[kSecCodeInfoIdentifier as String] as? String == bundleIdentifier,
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
            throw ExtensionRuntimeError("Cannot identify the signed extension executable.")
        }
        return try .codeRequirement(.allOf { CodeDirectoryHash(hash) })
    }
}

@MainActor
private final class DevelopmentSession {
    private let identity: AppExtensionIdentity
    private let monitor: AppExtensionPoint.Monitor
    private var process: AppExtensionProcess?
    private var connection: XPCSession?
    private var pending: AsyncThrowingStream<String, Error>.Continuation?
    private var closed = false
    var onClose: (() -> Void)?

    private let requirement: XPCPeerRequirement

    init(identity: AppExtensionIdentity, monitor: AppExtensionPoint.Monitor, requirement: XPCPeerRequirement) {
        self.requirement = requirement
        self.identity = identity
        self.monitor = monitor
    }

    func activate(generation: String) async throws {
        observeIdentity()
        let actual = try await response { reply in
            Task { @MainActor [self] in
                do {
                    let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: self.identity) { [weak self] in
                        Task { @MainActor [weak self] in self?.close() }
                    })
                    guard !self.closed else { process.invalidate(); return }
                    self.process = process
                    let session = try process.makeXPCSession()
                    session.setPeerRequirement(self.requirement)
                    try session.activate()
                    self.connection = session
                    try self.send(["operation": "generation"], reply: reply)
                } catch { reply.finish(throwing: error) }
            }
        }
        guard !closed, actual == generation else {
            throw ExtensionRuntimeError("macOS did not activate the requested extension generation. Reload the contributor again.")
        }
    }

    func test(_ input: String) async throws -> String {
        guard monitor.identities.contains(identity) else {
            close()
            throw ExtensionRuntimeError("The contributor is no longer enabled. Enable it and reload.")
        }
        return try await response { reply in
            try send(["operation": "test", "input": input], reply: reply)
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

    private func response(
        _ start: (AsyncThrowingStream<String, Error>.Continuation) throws -> Void
    ) async throws -> String {
        guard !closed else { throw ExtensionRuntimeError("The extension is no longer active. Reload it and retry.") }
        try Task.checkCancellation()
        let (stream, reply) = AsyncThrowingStream<String, Error>.makeStream()
        pending = reply
        let timeout = Task {
            try await Task.sleep(for: .seconds(12))
            reply.finish(throwing: ExtensionRuntimeError("Timed out waiting for the extension to respond."))
        }
        defer { timeout.cancel(); reply.finish(); pending = nil }
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
        pending?.finish(throwing: ExtensionRuntimeError("The extension was disabled or disconnected. Reload it and retry."))
        connection?.cancel(reason: "Extension session closed.")
        process?.invalidate()
        connection = nil
        process = nil
        onClose?()
    }
}
