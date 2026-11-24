#if os(macOS)
import Foundation
import RxCodeCore
import RxCodeExtensionDistribution

/// Only IDs named by the dashboard are considered for automatic offline installation.
public struct BundledUsageExtensions: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func releaseID(for pluginID: String) -> String { "app.rxlab.extensions." + pluginID }

    public func archivedRelease(for pluginID: String) throws -> (URL, ExtensionReleaseEnvelope)? {
        let id = Self.releaseID(for: pluginID)
        try ExtensionCatalogService.validateID(id)
        let zip = directory.appending(component: id + ".zip")
        guard FileManager.default.fileExists(atPath: zip.path) else { return nil }
        let bytes = try Data(contentsOf: directory.appending(component: id + ".sig.json"))
        let envelope = try JSONDecoder().decode(ExtensionReleaseEnvelope.self, from: bytes)
        guard envelope.id == id else { throw ExtensionVerificationError.invalidPayload }
        return (zip, envelope)
    }
}

extension ExtensionCatalogService {
    public func seedUsageProvider(_ pluginID: String, from resources: BundledUsageExtensions,
                                  explicit: Bool = false) async throws -> InstalledRelease? {
        let id = BundledUsageExtensions.releaseID(for: pluginID)
        if !explicit, try isDisabled(id: id) || isUninstalled(id: id) { return nil }
        guard let (zip, envelope) = try resources.archivedRelease(for: pluginID) else { return nil }
        return try await install(zip, envelope: envelope, source: .bundled, explicit: explicit)
    }
}
#endif
