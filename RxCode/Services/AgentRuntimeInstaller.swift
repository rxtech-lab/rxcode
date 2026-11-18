import CryptoKit
import Foundation

/// Installs the npm distributions in an RxCode-owned prefix, leaving system
/// package-manager installations untouched.
actor AgentRuntimeInstaller {
    enum Runtime: String, Sendable {
        case claude
        case codex

        var package: String {
            switch self {
            case .claude: "@anthropic-ai/claude-code"
            case .codex: "@openai/codex"
            }
        }
    }

    enum InstallError: LocalizedError {
        case npmMissing
        case invalidVersion
        case failed(String)
        case executableMissing

        var errorDescription: String? {
            switch self {
            case .npmMissing: "This version requires npm. Choose a version with a native macOS download or install Node.js."
            case .invalidVersion: "Enter a version such as 1.2.3, or use latest."
            case .failed(let message): "Installation failed: \(message)"
            case .executableMissing: "The package installed, but its executable was not found."
            }
        }
    }

    /// Snapshot of an in-flight install. `expectedBytes` comes from the npm
    /// registry's `dist.unpackedSize`, so the fraction is an estimate.
    struct Progress: Sendable, Equatable {
        enum Phase: Sendable, Equatable {
            case resolving
            case downloading
            case finalizing
        }

        var phase: Phase
        var resolvedVersion: String?
        var downloadedBytes: Int64 = 0
        var expectedBytes: Int64?

        var fraction: Double? {
            switch phase {
            case .resolving: return nil
            case .finalizing: return 1
            case .downloading:
                guard let expectedBytes, expectedBytes > 0 else { return nil }
                return min(Double(downloadedBytes) / Double(expectedBytes), 0.95)
            }
        }
    }

    static let shared = AgentRuntimeInstaller()

    nonisolated static func executablePath(for runtime: Runtime) -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("RxCode/agent-runtimes/\(runtime.rawValue)/node_modules/.bin/\(runtime.rawValue)").path
    }

    func uninstall(_ runtime: Runtime) throws {
        let root = URL(fileURLWithPath: Self.executablePath(for: runtime))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// Installs in flight, so a second request for the same runtime waits for
    /// the first instead of racing it into the same folder.
    private var inFlight: [Runtime: Task<Void, Error>] = [:]

    /// Installs `runtime` as a tracked, cancellable item in the Downloads window.
    func install(
        _ runtime: Runtime,
        version: String,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        if let running = inFlight[runtime] {
            try await running.value
            return
        }
        let title = "\(runtime.displayName)\(version == "latest" ? "" : " \(version)")"
        let task = Task {
            try await DownloadCenter.track(title, kind: .agentRuntime) { item in
                try await self.performInstall(runtime, version: version) { update in
                    let phase: DownloadCenter.Phase = switch update.phase {
                    case .resolving: .preparing
                    case .downloading: .downloading
                    case .finalizing: .installing
                    }
                    DownloadCenter.update(item, phase: phase, receivedBytes: update.downloadedBytes, totalBytes: update.expectedBytes)
                    progress?(update)
                }
            }
        }
        inFlight[runtime] = task
        defer { inFlight[runtime] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performInstall(
        _ runtime: Runtime,
        version: String,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let requested = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requested == "latest" || requested.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil else { throw InstallError.invalidVersion }

        progress?(Progress(phase: .resolving))
        let manifest = try await Self.packageManifest(runtime.package, version: requested)
        let resolvedVersion = manifest.version ?? (requested == "latest" ? nil : requested)

        let root = URL(fileURLWithPath: Self.executablePath(for: runtime))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("\(runtime.rawValue)-staging-\(UUID().uuidString)")
        let backup = root.deletingLastPathComponent()
            .appendingPathComponent("\(runtime.rawValue)-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        if let archive = manifest.archive {
            try await installNative(runtime, archive: archive, staging: staging, version: resolvedVersion, progress: progress)
        } else {
            try await installLegacy(runtime, requested: resolvedVersion ?? requested, staging: staging, manifest: manifest, progress: progress)
        }
        try Task.checkCancellation()
        let installedBinary = staging.appendingPathComponent("node_modules/.bin/\(runtime.rawValue)").path
        guard FileManager.default.isExecutableFile(atPath: installedBinary) else {
            throw InstallError.executableMissing
        }
        progress?(Progress(
            phase: .finalizing,
            resolvedVersion: resolvedVersion,
            downloadedBytes: Self.directorySize(staging),
            expectedBytes: manifest.unpackedSize
        ))
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.moveItem(at: root, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: root)
            try? FileManager.default.removeItem(at: backup)
        } catch {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: root)
            }
            throw error
        }
    }

    private func installNative(
        _ runtime: Runtime, archive: Archive, staging: URL, version: String?,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws {
        let delegate = RuntimeDownloadDelegate { received, expected in
            progress?(Progress(phase: .downloading, resolvedVersion: version, downloadedBytes: received, expectedBytes: expected))
        }
        let (file, response) = try await URLSession.shared.download(from: archive.url, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError.failed("Could not download the macOS package.")
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard "sha512-" + Data(SHA512.hash(data: data)).base64EncodedString() == archive.integrity else {
            throw InstallError.failed("The package checksum did not match.")
        }
        try Task.checkCancellation()
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", file.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw InstallError.failed("Could not unpack the macOS package.") }
        #if arch(arm64)
        let triple = "aarch64-apple-darwin"
        #else
        let triple = "x86_64-apple-darwin"
        #endif
        let vendor = "package/vendor/\(triple)"
        let candidates = runtime == .claude ? ["package/claude"] : ["\(vendor)/bin/codex", "\(vendor)/codex/codex"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent($0).path) }) else {
            throw InstallError.executableMissing
        }
        let bin = staging.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent(runtime.rawValue).path,
                                                  withDestinationPath: "../../\(binary)")
    }

    private func installLegacy(
        _ runtime: Runtime, requested: String, staging: URL, manifest: PackageManifest,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws {
        let resolvedVersion = manifest.version
        let shellPath = await ShellPathResolver.shared.refresh() ?? ""
        let path = [shellPath, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", ProcessInfo.processInfo.environment["PATH"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ":")
        guard let npm = path.split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("npm").path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw InstallError.npmMissing }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = ["install", "--prefix", staging.path, "--no-audit", "--no-fund", "\(runtime.package)@\(requested)"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let (completion, continuation) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            continuation.yield()
            continuation.finish()
        }
        try process.run()
        progress?(Progress(phase: .downloading, resolvedVersion: resolvedVersion, expectedBytes: manifest.unpackedSize))
        let monitor = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { break }
                progress?(Progress(
                    phase: .downloading,
                    resolvedVersion: resolvedVersion,
                    downloadedBytes: Self.directorySize(staging),
                    expectedBytes: manifest.unpackedSize
                ))
            }
        }
        // Cancelling ends npm, which closes its output and ends the wait.
        let running = process
        let data = await withTaskCancellationHandler {
            let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            for await _ in completion { break }
            return data
        } onCancel: {
            if running.isRunning { running.terminate() }
        }
        monitor.cancel()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "npm exited with status \(process.terminationStatus)"
            throw InstallError.failed(String(message.suffix(500)))
        }
    }

    private struct Archive {
        let url: URL
        let integrity: String
    }

    private struct PackageManifest: Sendable {
        let version: String?
        let unpackedSize: Int64?
        let archive: Archive?
    }

    /// Older releases lack a platform package and use the legacy installer.
    private static func packageManifest(_ package: String, version: String) async throws -> PackageManifest {
        guard let root = await registryDocument(package, version: version) else {
            throw InstallError.failed("Could not load the release metadata for \(package)@\(version).")
        }
        var archive: Archive?
        var size = (root.dist?["unpackedSize"] as? NSNumber)?.int64Value
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin-x64"
        #endif
        if let optional = root.object["optionalDependencies"] as? [String: String],
           let (name, spec) = optional.first(where: { $0.key.hasSuffix(platform) }) {
            guard let target = aliasTarget(name: name, spec: spec),
                  let binary = await registryDocument(target.name, version: target.version),
                  let address = binary.dist?["tarball"] as? String, let url = URL(string: address),
                  url.scheme == "https", url.host == "registry.npmjs.org",
                  let integrity = binary.dist?["integrity"] as? String else {
                throw InstallError.failed("Could not resolve the native macOS download.")
            }
            size = (binary.dist?["unpackedSize"] as? NSNumber)?.int64Value
            archive = Archive(url: url, integrity: integrity)
        }
        return PackageManifest(version: root.object["version"] as? String, unpackedSize: size, archive: archive)
    }

    /// Resolves `npm:@scope/pkg@1.2.3` aliases (used by Codex) to name/version.
    private static func aliasTarget(name: String, spec: String) -> (name: String, version: String)? {
        guard spec.hasPrefix("npm:") else { return (name, spec) }
        let target = spec.dropFirst(4)
        guard let at = target.lastIndex(of: "@"), at != target.startIndex else { return nil }
        return (String(target[..<at]), String(target[target.index(after: at)...]))
    }

    private static func registryDocument(
        _ package: String,
        version: String
    ) async -> (object: [String: Any], dist: [String: Any]?)? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let name = package.addingPercentEncoding(withAllowedCharacters: allowed),
              let tag = version.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://registry.npmjs.org/\(name)/\(tag)")
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object, object["dist"] as? [String: Any])
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

private final class RuntimeDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Int64, Int64?) -> Void

    nonisolated init(report: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.report = report
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {}
}
