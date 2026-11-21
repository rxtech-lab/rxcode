import Foundation

/// A Chrome profile folder that has installed extensions.
nonisolated struct ChromeExtensionProfile: Identifiable, Hashable, Sendable {
    let name: String
    let directory: URL
    var id: String { directory.path }
}

/// An extension installed in Chrome, read from the profile's `Extensions` folder.
nonisolated struct ChromeExtensionCandidate: Identifiable, Hashable, Sendable {
    /// Chrome's 32-character extension ID.
    let chromeID: String
    let name: String
    let version: String
    let manifestVersion: Int
    let directory: URL
    let iconURL: URL?
    var id: String { chromeID }
}

nonisolated enum BrowserExtensionInstallError: LocalizedError, Equatable {
    case invalidArchive
    case missingManifest
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            String(localized: "The file is not a valid Chrome extension (.crx) or ZIP archive.")
        case .missingManifest:
            String(localized: "The extension doesn’t contain a manifest.json file.")
        case .extractionFailed(let message):
            String(localized: "The extension archive couldn’t be extracted: \(message)")
        }
    }
}

/// File work for browser extensions: scanning Chrome, unpacking CRX and ZIP
/// archives, and copying extension folders into RxCode's own storage.
nonisolated enum BrowserExtensionInstaller {
    // MARK: Chrome profiles

    /// Profiles that contain at least one installed extension, default profile first.
    static func chromeProfiles(in root: URL = ChromeCookieImporter.chromeDirectory) throws -> [ChromeExtensionProfile] {
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        let fileManager = FileManager.default
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        let names = ChromeCookieImporter.profileNames(in: root)
        return entries.compactMap { directory -> ChromeExtensionProfile? in
            var isDirectory: ObjCBool = false
            let extensions = directory.appendingPathComponent("Extensions", isDirectory: true)
            guard fileManager.fileExists(atPath: extensions.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let folder = directory.lastPathComponent
            return ChromeExtensionProfile(name: names[folder] ?? folder, directory: directory)
        }
        .sorted { lhs, rhs in
            let lhsDefault = lhs.directory.lastPathComponent == "Default"
            let rhsDefault = rhs.directory.lastPathComponent == "Default"
            if lhsDefault != rhsDefault { return lhsDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The newest installed version of each extension in a Chrome profile.
    static func chromeExtensions(in profile: URL) -> [ChromeExtensionCandidate] {
        let fileManager = FileManager.default
        let root = profile.appendingPathComponent("Extensions", isDirectory: true)
        guard let ids = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return ids.compactMap { idDirectory -> ChromeExtensionCandidate? in
            let chromeID = idDirectory.lastPathComponent
            guard chromeID.count == 32, chromeID.allSatisfy({ ("a"..."p").contains($0) }),
                  let versions = try? fileManager.contentsOfDirectory(at: idDirectory, includingPropertiesForKeys: nil) else { return nil }
            let newest = versions
                .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
                .max { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
            guard let directory = newest, let manifest = manifest(in: directory) else { return nil }
            let name = localized(manifest["name"] as? String, in: directory, manifest: manifest) ?? chromeID
            return ChromeExtensionCandidate(
                chromeID: chromeID,
                name: name,
                version: manifest["version"] as? String ?? "",
                manifestVersion: manifest["manifest_version"] as? Int ?? 0,
                directory: directory,
                iconURL: largestIcon(in: manifest).map { directory.appendingPathComponent($0) }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func manifest(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Resolves `__MSG_key__` placeholders from `_locales/<default_locale>/messages.json`.
    static func localized(_ value: String?, in directory: URL, manifest: [String: Any]) -> String? {
        guard let value, value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
        let key = value.dropFirst(6).dropLast(2).lowercased()
        let locale = manifest["default_locale"] as? String ?? "en"
        let url = directory.appendingPathComponent("_locales/\(locale)/messages.json")
        guard let data = try? Data(contentsOf: url),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let entry = messages.first { $0.key.lowercased() == key }?.value as? [String: Any]
        return entry?["message"] as? String
    }

    private static func largestIcon(in manifest: [String: Any]) -> String? {
        guard let icons = manifest["icons"] as? [String: String] else { return nil }
        return icons.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }?.value
    }

    // MARK: Archives

    /// Returns the ZIP payload of a CRX2 or CRX3 package.
    static func zipPayload(ofCRX data: Data) throws -> Data {
        func uint32(at offset: Int) -> Int? {
            guard data.count >= offset + 4 else { return nil }
            let start = data.startIndex + offset
            return data[start..<start + 4].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        }
        guard data.count > 16, data.prefix(4) == Data("Cr24".utf8), let version = uint32(at: 4) else {
            throw BrowserExtensionInstallError.invalidArchive
        }
        let payloadStart: Int
        switch version {
        case 2:
            guard let keyLength = uint32(at: 8), let signatureLength = uint32(at: 12) else { throw BrowserExtensionInstallError.invalidArchive }
            payloadStart = 16 + keyLength + signatureLength
        case 3:
            guard let headerLength = uint32(at: 8) else { throw BrowserExtensionInstallError.invalidArchive }
            payloadStart = 12 + headerLength
        default:
            throw BrowserExtensionInstallError.invalidArchive
        }
        guard payloadStart < data.count else { throw BrowserExtensionInstallError.invalidArchive }
        let payload = data.suffix(from: data.startIndex + payloadStart)
        guard payload.prefix(2) == Data("PK".utf8) else { throw BrowserExtensionInstallError.invalidArchive }
        return Data(payload)
    }

    // MARK: Installation

    /// Copies a folder, `.crx`, or `.zip` into `destination`, with `manifest.json`
    /// at its top level. Chrome's `_metadata` signature folder is removed.
    @discardableResult
    static func unpack(_ source: URL, into destination: URL) throws -> URL {
        let fileManager = FileManager.default
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        if isDirectory.boolValue {
            try fileManager.copyItem(at: source, to: destination)
        } else {
            let data = try Data(contentsOf: source)
            let zip = data.prefix(4) == Data("Cr24".utf8) ? try zipPayload(ofCRX: data) : data
            guard zip.prefix(2) == Data("PK".utf8) else { throw BrowserExtensionInstallError.invalidArchive }
            let archive = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
            try zip.write(to: archive)
            defer { try? fileManager.removeItem(at: archive) }
            try extract(archive, to: destination)
        }

        guard let root = manifestRoot(in: destination) else {
            try? fileManager.removeItem(at: destination)
            throw BrowserExtensionInstallError.missingManifest
        }
        if root != destination {
            // Archives often wrap the extension in one folder; keep the manifest at the top level.
            let staging = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.moveItem(at: root, to: staging)
            try fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
        }
        try? fileManager.removeItem(at: destination.appendingPathComponent("_metadata"))
        return destination
    }

    /// The folder itself, or its only subfolder, when that holds `manifest.json`.
    static func manifestRoot(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) { return directory }
        let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: .skipsHiddenFiles)) ?? []
        let folders = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && $0.lastPathComponent != "__MACOSX" }
        guard folders.count == 1, fileManager.fileExists(atPath: folders[0].appendingPathComponent("manifest.json").path) else { return nil }
        return folders[0]
    }

    private static func extract(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BrowserExtensionInstallError.extractionFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
