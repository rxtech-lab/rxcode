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
            case .npmMissing: "npm was not found. Install Node.js first, then try again."
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

    func install(
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
        let manifest = await Self.packageManifest(runtime.package, version: requested)
        let resolvedVersion = manifest?.version ?? (requested == "latest" ? nil : requested)

        let shellPath = await ShellPathResolver.shared.refresh() ?? ""
        let path = [shellPath, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", ProcessInfo.processInfo.environment["PATH"] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ":")
        guard let npm = path.split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("npm").path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw InstallError.npmMissing }

        let root = URL(fileURLWithPath: Self.executablePath(for: runtime))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("\(runtime.rawValue)-staging-\(UUID().uuidString)")
        let backup = root.deletingLastPathComponent()
            .appendingPathComponent("\(runtime.rawValue)-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

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
        progress?(Progress(phase: .downloading, resolvedVersion: resolvedVersion, expectedBytes: manifest?.unpackedSize))
        let monitor = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { break }
                progress?(Progress(
                    phase: .downloading,
                    resolvedVersion: resolvedVersion,
                    downloadedBytes: Self.directorySize(staging),
                    expectedBytes: manifest?.unpackedSize
                ))
            }
        }
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        for await _ in completion { break }
        monitor.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "npm exited with status \(process.terminationStatus)"
            throw InstallError.failed(String(message.suffix(500)))
        }
        let installedBinary = staging.appendingPathComponent("node_modules/.bin/\(runtime.rawValue)").path
        guard FileManager.default.isExecutableFile(atPath: installedBinary) else {
            throw InstallError.executableMissing
        }
        progress?(Progress(
            phase: .finalizing,
            resolvedVersion: resolvedVersion,
            downloadedBytes: Self.directorySize(staging),
            expectedBytes: manifest?.unpackedSize
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

    private struct PackageManifest: Sendable {
        let version: String?
        let unpackedSize: Int64?
    }

    /// Best-effort registry lookup used only for progress display. Both CLIs
    /// ship a thin wrapper plus a per-platform binary package, so the expected
    /// size includes the optional dependency matching this Mac.
    private static func packageManifest(_ package: String, version: String) async -> PackageManifest? {
        guard let root = await registryDocument(package, version: version) else { return nil }
        var size = (root.dist?["unpackedSize"] as? NSNumber)?.int64Value
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin-x64"
        #endif
        if let optional = root.object["optionalDependencies"] as? [String: String],
           let (name, spec) = optional.first(where: { $0.key.hasSuffix(platform) }),
           let target = aliasTarget(name: name, spec: spec),
           let binary = await registryDocument(target.name, version: target.version),
           let binarySize = (binary.dist?["unpackedSize"] as? NSNumber)?.int64Value {
            size = (size ?? 0) + binarySize
        }
        return PackageManifest(version: root.object["version"] as? String, unpackedSize: size)
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
