import Foundation

/// Finds or installs llama.cpp's `llama-server`.
///
/// Prefers a copy RxCode installed itself (pinned, known to work with the
/// flags `LlamaServerManager` passes), then Homebrew's. Installing downloads
/// the official macOS release archive from GitHub — no build step.
nonisolated enum LlamaRuntimeInstaller {
    struct Runtime: Codable, Hashable, Sendable {
        let path: String
        /// Release tag (`b12005`), or `homebrew`.
        let version: String
    }

    enum InstallError: LocalizedError {
        case noAsset
        case binaryNotFound
        case extractFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAsset: "No llama.cpp release for this Mac was found on GitHub."
            case .binaryNotFound: "The downloaded llama.cpp archive did not contain llama-server."
            case .extractFailed(let detail): "Could not extract llama.cpp: \(detail)"
            }
        }
    }

    static func managedRoot(_ appSupport: URL) -> URL {
        appSupport.appending(path: "llama.cpp")
    }

    /// The runtime to use, if any is installed.
    static func locate(appSupport: URL) -> Runtime? {
        let root = managedRoot(appSupport)
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for version in versions.sorted(by: >) {
                if let binary = findServer(in: root.appending(path: version)) {
                    return Runtime(path: binary.path, version: version)
                }
            }
        }
        for candidate in ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
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
        let (tag, assetURL) = try await latestAsset()
        let root = managedRoot(appSupport)
        let destination = root.appending(path: tag)
        let archive = root.appending(path: "\(tag).tar.gz")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        _ = try await LocalModelDownloader().download(assetURL, to: archive, onProgress: onProgress)
        // Extraction reports no byte progress; (0, 0) marks the switch.
        onProgress(0, 0)
        defer { try? FileManager.default.removeItem(at: archive) }

        try await Task.detached {
            let tar = Process()
            tar.executableURL = URL(filePath: "/usr/bin/tar")
            tar.arguments = ["-xzf", archive.path, "-C", destination.path]
            let pipe = Pipe()
            tar.standardError = pipe
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else {
                let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw InstallError.extractFailed(message)
            }
            // Files fetched by URLSession are not quarantined, but clear the
            // attribute anyway in case the archive carried one.
            let xattr = Process()
            xattr.executableURL = URL(filePath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
            try? xattr.run()
            xattr.waitUntilExit()
        }.value

        guard let binary = findServer(in: destination) else { throw InstallError.binaryNotFound }
        // Older managed versions are removed so only one copy takes disk space.
        for old in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where old != tag {
            try? FileManager.default.removeItem(at: root.appending(path: old))
        }
        return Runtime(path: binary.path, version: tag)
    }

    private static func latestAsset() async throws -> (tag: String, url: URL) {
        let suffix = isAppleSilicon ? "bin-macos-arm64.tar.gz" : "bin-macos-x64.tar.gz"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw InstallError.noAsset }
        for release in releases where (release["draft"] as? Bool) != true && (release["prerelease"] as? Bool) != true {
            guard let tag = release["tag_name"] as? String,
                  let assets = release["assets"] as? [[String: Any]] else { continue }
            for asset in assets {
                if let name = asset["name"] as? String, name.hasSuffix(suffix),
                   let link = asset["browser_download_url"] as? String, let url = URL(string: link) {
                    return (tag, url)
                }
            }
        }
        throw InstallError.noAsset
    }

    private static func findServer(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "llama-server" {
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}
