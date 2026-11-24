#if os(macOS)
import Foundation
import RxCodeCore
import RxCodeExtensionDistribution

public struct InstalledRelease: Sendable {
    public enum Source: String, Codable, Sendable { case bundled, flowcy }
    public let envelope: ExtensionReleaseEnvelope
    public let manifest: ExtensionManifest
    public let container: URL
    public let source: Source
}

/// A Debug build may seed local archives under a separate policy while fetching production updates.
public struct BundledExtensionPolicy: Sendable {
    public let keyIDs: Set<String>
    public let store: ExtensionRevocationStore
    public let useForCatalog: Bool

    public init(keyIDs: Set<String>, store: ExtensionRevocationStore, useForCatalog: Bool) {
        self.keyIDs = keyIDs
        self.store = store
        self.useForCatalog = useForCatalog
    }
}

public actor ExtensionCatalogService {
    public enum InstallError: Error, Equatable {
        case busy, disabled, downgrade, invalidID, missingRelease, versionConflict
    }

    private enum UserChoice: String, Codable { case disabled, uninstalled }
    private let support: URL
    private let keys: [String: Data]
    private let catalogKeys: [String: Data]
    private let developerIDSignedKeys: Set<String>
    private let revocations: ExtensionRevocationStore
    private let bundledPolicy: BundledExtensionPolicy?
    private var catalogPolicy: ExtensionRevocationStore {
        if let bundledPolicy, bundledPolicy.useForCatalog { return bundledPolicy.store }
        return revocations
    }
    private func policy(for envelope: ExtensionReleaseEnvelope) -> ExtensionRevocationStore {
        if let bundledPolicy, bundledPolicy.keyIDs.contains(envelope.keyId) { return bundledPolicy.store }
        return revocations
    }
    private let catalog: any ExtensionCatalog
    private let activate: @Sendable (InstalledRelease) async throws -> Void
    private let deactivate: @Sendable (InstalledRelease) async throws -> Void
    private let blocked: @Sendable (String) async -> Void
    private let fm = FileManager.default
    private var inProgress: Set<String> = []
    private var installingProviders: [String: String] = [:]

    public init(support: URL, keys: [String: Data], revocations: ExtensionRevocationStore, catalog: any ExtensionCatalog,
                developerIDSignedKeys: Set<String> = [], catalogKeys: [String: Data]? = nil, bundledPolicy: BundledExtensionPolicy? = nil,
                activate: @escaping @Sendable (InstalledRelease) async throws -> Void,
                deactivate: @escaping @Sendable (InstalledRelease) async throws -> Void,
                blocked: @escaping @Sendable (String) async -> Void) {
        self.support = support
        self.keys = keys
        self.catalogKeys = catalogKeys ?? keys
        self.developerIDSignedKeys = developerIDSignedKeys
        self.revocations = revocations
        self.bundledPolicy = bundledPolicy
        self.catalog = catalog
        self.activate = activate
        self.deactivate = deactivate
        self.blocked = blocked
    }

    private func signingKeys(_ source: InstalledRelease.Source) -> [String: Data] {
        source == .flowcy ? catalogKeys : keys
    }

    public func available() async throws -> [CatalogExtensionRelease] { try await catalog.releases() }

    public static func validateID(_ id: String) throws {
        guard id.utf8.count <= 253,
              id.range(of: #"\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z"#,
                       options: .regularExpression) != nil else { throw InstallError.invalidID }
    }

    private var extensions: URL { support.appending(path: "Extensions") }
    private var choicesFile: URL { support.appending(path: "extension-install-state.json") }
    private func choices() throws -> [String: UserChoice] {
        do { return try JSONDecoder().decode([String: UserChoice].self, from: Data(contentsOf: choicesFile)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }
    private func record(_ choice: UserChoice?, id: String) throws {
        var all = try choices()
        all[id] = choice
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: choicesFile, options: .atomic)
    }
    public func isDisabled(id: String) throws -> Bool { try choices()[id] == .disabled }
    public func isUninstalled(id: String) throws -> Bool { try choices()[id] == .uninstalled }

    private func begin(_ id: String) throws {
        try Self.validateID(id)
        guard inProgress.insert(id).inserted else { throw InstallError.busy }
    }

    public func installed() throws -> [InstalledRelease] {
        if !fm.fileExists(atPath: extensions.path) { return [] }
        let ids = try fm.contentsOfDirectory(atPath: extensions.path)
        return try ids.sorted().filter { !$0.hasPrefix(".") }.compactMap { id in
            try Self.validateID(id)
            return try release(id: id)
        }
    }

    private func release(id: String) throws -> InstalledRelease? {
        let current = extensions.appending(component: id).appending(path: "current")
        guard fm.fileExists(atPath: current.path) else { return nil }
        let envelope = try JSONDecoder().decode(ExtensionReleaseEnvelope.self, from: Data(contentsOf: current.appending(component: id + ".sig.json")))
        guard envelope.id == id else { throw ExtensionVerificationError.invalidPayload }
        let source = try JSONDecoder().decode(InstalledRelease.Source.self, from: Data(contentsOf: current.appending(path: "source.json")))
        let candidates = try fm.contentsOfDirectory(at: current, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard candidates.count == 1, let app = candidates.first else { throw InstallError.missingRelease }
        let data = try Data(contentsOf: app.appending(path: "Contents/Resources/" + ExtensionManifest.resourceName))
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        return InstalledRelease(envelope: envelope, manifest: manifest, container: app, source: source)
    }

    public func verifiedForActivation(id: String) async throws -> InstalledRelease {
        try await verified(id: id, requireEnabled: true)
    }

    public func verifiedForDisplay(id: String) async throws -> InstalledRelease {
        try await verified(id: id, requireEnabled: false)
    }

    private func verified(id: String, requireEnabled: Bool) async throws -> InstalledRelease {
        try Self.validateID(id)
        guard let envelope = try release(id: id)?.envelope else { throw InstallError.missingRelease }
        let policy = await policy(for: envelope).current
        if requireEnabled, try choices()[id] != nil { throw InstallError.disabled }
        guard let installed = try release(id: id), installed.envelope == envelope else { throw InstallError.missingRelease }
        try installed.envelope.verifySignature(keys: signingKeys(installed.source))
        try policy?.check(installed.envelope)
        try installed.manifest.validate()
        guard installed.manifest.id == id, installed.manifest.version == installed.envelope.version,
              installed.manifest.pluginAPI == installed.envelope.pluginApi else { throw ExtensionVerificationError.invalidPayload }
        let service = installed.container.appending(path: "Contents/Extensions/Service.appex")
        let resource = "Contents/Resources/" + ExtensionManifest.resourceName
        guard try Data(contentsOf: installed.container.appending(path: resource)) == Data(contentsOf: service.appending(path: resource)) else {
            throw ExtensionVerificationError.invalidPayload
        }
        try ExtensionCompiler.verifyContainer(installed.container, requiresDeveloperID: developerIDSignedKeys.contains(installed.envelope.keyId))
        guard try ExtensionCompiler.codeHashes(of: service) == installed.envelope.cdhashes else {
            throw ExtensionVerificationError.codeHashMismatch
        }
        return installed
    }

    public func seedBaseline(data: Data, signature: String) async throws {
        let store = bundledPolicy?.store ?? revocations
        let previous = await store.current
        try await store.loadBaseline(rawPayload: data, signature: signature)
        if let current = await store.current, current != previous { try await apply(current, from: store) }
    }

    public func refreshRevocations() async throws {
        guard !catalogKeys.isEmpty else { throw ExtensionVerificationError.unknownKey }
        let store = catalogPolicy
        let (bytes, response) = try await catalog.revocations()
        if let policy = try await store.refresh(bytes: bytes, response: response) { try await apply(policy, from: store) }
    }

    private func apply(_ policy: ExtensionRevocations, from store: ExtensionRevocationStore) async throws {
        // Invalidation precedes catalog updates, including when the replacement download fails.
        if !fm.fileExists(atPath: extensions.path) { return }
        for id in try fm.contentsOfDirectory(atPath: extensions.path) where (try? Self.validateID(id)) != nil {
            do {
                guard let row = try release(id: id), self.policy(for: row.envelope) === store else { continue }
                try row.envelope.verifySignature(keys: signingKeys(row.source))
                try policy.check(row.envelope)
            } catch { await blocked(id) }
        }
    }

    @discardableResult
    public func install(_ available: CatalogExtensionRelease, explicit: Bool, allowDowngrade: Bool = false) async throws -> InstalledRelease? {
        let envelope = available.envelope
        try begin(envelope.id)
        defer { finish(envelope.id) }
        if !explicit, try choices()[envelope.id] != nil { return nil }
        try envelope.verifySignature(keys: catalogKeys)
        try await self.policy(for: envelope).current?.check(envelope)
        let zip = fm.temporaryDirectory.appending(path: UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: zip) }
        try await catalog.download(available, to: zip)
        return try await installArchive(zip, envelope: envelope, source: .flowcy, explicit: explicit, allowDowngrade: allowDowngrade)
    }

    @discardableResult
    public func install(_ archive: URL, envelope: ExtensionReleaseEnvelope, source: InstalledRelease.Source,
                        explicit: Bool = false, allowDowngrade: Bool = false) async throws -> InstalledRelease? {
        try begin(envelope.id)
        defer { finish(envelope.id) }
        return try await installArchive(archive, envelope: envelope, source: source, explicit: explicit, allowDowngrade: allowDowngrade)
    }

    private func finish(_ id: String) {
        inProgress.remove(id)
        installingProviders = installingProviders.filter { $0.value != id }
    }

    private func installArchive(_ archive: URL, envelope: ExtensionReleaseEnvelope, source: InstalledRelease.Source,
                                explicit: Bool, allowDowngrade: Bool) async throws -> InstalledRelease? {
        let id = envelope.id
        let choice = try choices()[id]
        if choice != nil && !explicit { return nil }
        let policy = await self.policy(for: envelope).current
        try envelope.verifySignature(keys: signingKeys(source))
        try policy?.check(envelope)
        let parent = extensions.appending(component: id)
        let current = parent.appending(path: "current")
        let old = try release(id: id)
        if let old {
            let order = Self.compareVersions(envelope.version, old.envelope.version)
            if order == .orderedAscending && !allowDowngrade {
                if source == .bundled { return old }
                throw InstallError.downgrade
            }
            if envelope.version == old.envelope.version {
                guard envelope.sha256 == old.envelope.sha256 else { throw InstallError.versionConflict }
                if explicit { try record(nil, id: id) }
                do {
                    let verified = try await verifiedForActivation(id: id)
                    if choice != nil { try await activate(verified) }
                    return verified
                } catch {
                    if explicit { try record(choice, id: id) }
                    throw error
                }
            }
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appending(path: ".stage-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        let app = try ExtensionArchive.stage(archive, in: stage, envelope: envelope, keys: signingKeys(source), revocations: policy,
                                             requiresDeveloperID: developerIDSignedKeys.contains(envelope.keyId))
        let data = try Data(contentsOf: app.appending(path: "Contents/Resources/" + ExtensionManifest.resourceName))
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        var providers = installingProviders
        for release in try installed() where release.envelope.id != id {
            for provider in release.manifest.contributes.usageProviders ?? [] { providers[provider.pluginID] = release.envelope.id }
        }
        try manifest.validate(providerOwners: providers)
        for provider in manifest.contributes.usageProviders ?? [] { installingProviders[provider.pluginID] = id }
        try JSONEncoder().encode(envelope).write(to: stage.appending(component: id + ".sig.json"))
        try JSONEncoder().encode(source).write(to: stage.appending(path: "source.json"))

        let previous = parent.appending(path: ".previous")
        if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
        if let old { try await deactivate(old) }
        var swapped = false
        do {
            try await self.policy(for: envelope).current?.check(envelope)
            if old != nil {
                _ = try fm.replaceItemAt(current, withItemAt: stage, backupItemName: ".previous",
                                         options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
            } else {
                try fm.moveItem(at: stage, to: current)
            }
            swapped = true
            if explicit { try record(nil, id: id) }
            let verified = try await verifiedForActivation(id: id)
            try await activate(verified)
            try await self.policy(for: envelope).current?.check(envelope)
            return verified
        } catch {
            var deactivationFailure: Error?
            if swapped {
                do {
                    if let failed = try release(id: id) { try await deactivate(failed) }
                } catch { deactivationFailure = error }
                if old != nil { _ = try fm.replaceItemAt(current, withItemAt: previous, options: .usingNewMetadataOnly) }
                else { try fm.removeItem(at: current) }
            }
            if explicit { try record(choice, id: id) }
            if old != nil, choice == nil, let restored = try? await verifiedForActivation(id: id) { try await activate(restored) }
            if let deactivationFailure { throw deactivationFailure }
            throw error
        }
    }

    public func setEnabled(_ enabled: Bool, id: String) async throws {
        try begin(id)
        defer { inProgress.remove(id) }
        guard let item = try release(id: id) else { throw InstallError.missingRelease }
        let choice = try choices()[id]
        if enabled {
            try record(nil, id: id)
            do { try await activate(verifiedForActivation(id: id)) }
            catch { try record(choice, id: id); throw error }
        } else {
            try record(.disabled, id: id)
            try await deactivate(item)
        }
    }

    public func uninstall(id: String) async throws {
        try begin(id)
        defer { inProgress.remove(id) }
        try record(.uninstalled, id: id)
        if let item = try release(id: id) { try await deactivate(item) }
        let parent = extensions.appending(component: id)
        if fm.fileExists(atPath: parent.path) { try fm.removeItem(at: parent) }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ version: String) -> (String, Substring?) {
            let release = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = release.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? parts[1] : nil)
        }
        let (a, preA) = components(lhs), (b, preB) = components(rhs)
        let core = a.compare(b, options: .numeric)
        if core != .orderedSame { return core }
        switch (preA, preB) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?): return String(a).compare(String(b), options: .numeric)
        }
    }
}
#endif
