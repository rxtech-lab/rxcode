import Foundation

/// Finds or installs stable-diffusion.cpp's `sd-cli`.
///
/// It runs diffusion GGUF models — image and video generators such as
/// MiniMax-H3 — that llama.cpp cannot load. Installing downloads the official
/// macOS release archive from GitHub; there is no build step and no Intel build.
nonisolated enum StableDiffusionRuntimeInstaller {
    typealias Runtime = LlamaRuntimeInstaller.Runtime

    enum InstallError: LocalizedError {
        case unsupportedMac
        case noAsset
        case binaryNotFound
        case extractFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedMac: "stable-diffusion.cpp publishes macOS builds for Apple silicon only."
            case .noAsset: "No stable-diffusion.cpp release for this Mac was found on GitHub."
            case .binaryNotFound: "The downloaded stable-diffusion.cpp archive did not contain sd-cli."
            case .extractFailed(let detail): "Could not extract stable-diffusion.cpp: \(detail)"
            }
        }
    }

    static func managedRoot(_ appSupport: URL) -> URL {
        appSupport.appending(path: "sd.cpp")
    }

    /// The runtime to use, if any is installed.
    static func locate(appSupport: URL) -> Runtime? {
        let root = managedRoot(appSupport)
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for version in versions.sorted(by: { (buildNumber($0) ?? 0) > (buildNumber($1) ?? 0) }) {
                if let binary = findCLI(in: root.appending(path: version)) {
                    return Runtime(path: binary.path, version: version)
                }
            }
        }
        for candidate in ["/opt/homebrew/bin/sd-cli", "/usr/local/bin/sd-cli"]
            where FileManager.default.isExecutableFile(atPath: candidate) {
            return Runtime(path: candidate, version: "homebrew")
        }
        return nil
    }

    /// Downloads and unpacks the latest release.
    static func install(
        appSupport: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Runtime {
        guard LlamaRuntimeInstaller.isAppleSilicon else { throw InstallError.unsupportedMac }
        let (tag, assetURL) = try await latestAsset()
        let root = managedRoot(appSupport)
        let destination = root.appending(path: tag)
        let archive = root.appending(path: "\(tag).zip")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        _ = try await LocalModelDownloader().download(assetURL, to: archive, onProgress: onProgress)
        // Extraction reports no byte progress; (0, 0) marks the switch.
        onProgress(0, 0)
        defer { try? FileManager.default.removeItem(at: archive) }

        try await Task.detached {
            let ditto = Process()
            ditto.executableURL = URL(filePath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", archive.path, destination.path]
            let pipe = Pipe()
            ditto.standardError = pipe
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw InstallError.extractFailed(message)
            }
            let xattr = Process()
            xattr.executableURL = URL(filePath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
            try? xattr.run()
            xattr.waitUntilExit()
        }.value

        guard let binary = findCLI(in: destination) else { throw InstallError.binaryNotFound }
        // Older managed versions are removed so only one copy takes disk space.
        for old in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where old != tag {
            try? FileManager.default.removeItem(at: root.appending(path: old))
        }
        return Runtime(path: binary.path, version: tag)
    }

    /// Whether `runtime` is the copy RxCode installed (and so may update or remove).
    static func isManaged(_ runtime: Runtime, appSupport: URL) -> Bool {
        // The directory enumerator returns symlink-resolved paths.
        let root = managedRoot(appSupport).resolvingSymlinksInPath().path
        return URL(filePath: runtime.path).resolvingSymlinksInPath().path.hasPrefix(root + "/")
    }

    /// Release tag of the newest build for this Mac.
    static func latestVersion() async throws -> String {
        try await latestAsset().tag
    }

    /// Whether release tag `candidate` (`master-1031-abc1234`) is newer than
    /// `installed`. Non-release versions (`homebrew`) never compare as older.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let new = buildNumber(candidate), let old = buildNumber(installed) else { return false }
        return new > old
    }

    /// The build counter in `master-<build>-<commit>`.
    static func buildNumber(_ tag: String) -> Int? {
        let parts = tag.split(separator: "-")
        guard parts.count == 3, parts[0] == "master" else { return nil }
        return Int(parts[1])
    }

    /// Deletes RxCode's managed copy. Homebrew installs are left alone.
    static func removeManaged(appSupport: URL) throws {
        let root = managedRoot(appSupport)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// Release assets are named `sd-master-<commit>-bin-Darwin-macOS-<os>-arm64.zip`.
    static func isMacAsset(_ name: String) -> Bool {
        name.contains("-bin-Darwin-macOS-") && name.hasSuffix("-arm64.zip")
    }

    private static func latestAsset() async throws -> (tag: String, url: URL) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/leejet/stable-diffusion.cpp/releases?per_page=10")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw InstallError.noAsset }
        for release in releases where (release["draft"] as? Bool) != true {
            guard let tag = release["tag_name"] as? String, buildNumber(tag) != nil,
                  let assets = release["assets"] as? [[String: Any]] else { continue }
            for asset in assets {
                if let name = asset["name"] as? String, isMacAsset(name),
                   let link = asset["browser_download_url"] as? String, let url = URL(string: link) {
                    return (tag, url)
                }
            }
        }
        throw InstallError.noAsset
    }

    private static func findCLI(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "sd-cli" {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
