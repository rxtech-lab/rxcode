import AppKit
import Foundation
import RxCodeCore

nonisolated struct ExtensionVerificationDetails: Hashable, Sendable {
    let keyId: String
    let fingerprint: String
    let sha256: String
    let blocked: Bool
    let source: String
}

/// Presentation metadata read from an installed extension bundle on disk.
nonisolated struct InstalledExtensionMetadata: Identifiable, Hashable, Sendable {
    enum Icon: Hashable, Sendable {
        /// A packaged `Icon.png`.
        case image(URL)
        /// The containing application's own icon.
        case application(URL)
        case none
    }

    let bundleIdentifier: String
    let name: String
    let version: String?
    let pluginAPIVersion: String?
    let readme: String?
    let readmeBaseURL: URL?
    let icon: Icon
    let containerURL: URL?
    let isDevelopment: Bool
    var manifest: ExtensionManifest? = nil
    var verification: ExtensionVerificationDetails? = nil

    var id: String { bundleIdentifier }
    var compatibility: ExtensionPluginAPI.Compatibility { ExtensionPluginAPI.compatibility(of: pluginAPIVersion) }

    static let readmeFileName = "README.md"
    static let iconFileName = "Icon.png"

    static func load(bundleIdentifier: String, localizedName: String) -> InstalledExtensionMetadata {
        let located = locate(bundleIdentifier: bundleIdentifier)
        let info = located.service.flatMap { infoDictionary(of: $0) } ?? [:]
        let containerInfo = located.container.flatMap { infoDictionary(of: $0) } ?? [:]
        let resourceRoots = [located.service, located.container].compactMap { $0?.appending(path: "Contents/Resources") }

        let readmeURL = resourceRoots.map { $0.appending(path: readmeFileName) }.first { isRegularFile($0) }
        let readme = readmeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let icon: Icon
        if let packaged = resourceRoots.map({ $0.appending(path: iconFileName) }).first(where: { isRegularFile($0) }) {
            icon = .image(packaged)
        } else if let container = located.container,
                  containerInfo["CFBundleIconFile"] != nil || containerInfo["CFBundleIconName"] != nil {
            icon = .application(container)
        } else {
            icon = .none
        }
        let version = (info["CFBundleShortVersionString"] as? String).map { short in
            (info["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
        }
        let manifest = resourceRoots.lazy.compactMap { root -> ExtensionManifest? in
            let url = root.appending(path: ExtensionManifest.resourceName)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let bytes = values.fileSize, bytes <= 256 * 1024,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ExtensionManifest.self, from: data)
        }.first
        return InstalledExtensionMetadata(
            bundleIdentifier: bundleIdentifier,
            name: manifest?.name ?? localizedName,
            version: version,
            pluginAPIVersion: (info[ExtensionPluginAPI.infoPlistKey] ?? containerInfo[ExtensionPluginAPI.infoPlistKey]) as? String,
            readme: readme,
            readmeBaseURL: readmeURL?.deletingLastPathComponent(),
            icon: icon,
            containerURL: located.container,
            isDevelopment: AgentExtensionBuilder.developmentContainer(forServiceIdentifier: bundleIdentifier) != nil,
            manifest: manifest
        )
    }

    // MARK: - Bundle lookup

    private static func locate(bundleIdentifier: String) -> (container: URL?, service: URL?) {
        if let container = AgentExtensionBuilder.developmentContainer(forServiceIdentifier: bundleIdentifier) {
            let service = container.appending(path: "Contents/Extensions/Service.appex")
            return (container, isDirectory(service) ? service : nil)
        }
        // Third-party contributors conventionally nest the extension identifier under the app's identifier.
        var components = bundleIdentifier.split(separator: ".").map(String.init)
        while components.count > 1 {
            components.removeLast()
            guard let container = NSWorkspace.shared.urlForApplication(withBundleIdentifier: components.joined(separator: ".")) else { continue }
            if let service = embeddedExtension(in: container, bundleIdentifier: bundleIdentifier) {
                return (container, service)
            }
        }
        return (nil, nil)
    }

    private static func embeddedExtension(in container: URL, bundleIdentifier: String) -> URL? {
        let fm = FileManager.default
        for folder in ["Contents/Extensions", "Contents/PlugIns"] {
            let directory = container.appending(path: folder)
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension == "appex" {
                if infoDictionary(of: entry)?["CFBundleIdentifier"] as? String == bundleIdentifier { return entry }
            }
        }
        return nil
    }

    /// Read Info.plist from disk; `Bundle` caches metadata across development rebuilds.
    private static func infoDictionary(of bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
