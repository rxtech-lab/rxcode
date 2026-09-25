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

    func install(_ runtime: Runtime, version: String) async throws {
        let requested = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requested == "latest" || requested.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#,
            options: .regularExpression
        ) != nil else { throw InstallError.invalidVersion }

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
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        for await _ in completion { break }
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "npm exited with status \(process.terminationStatus)"
            throw InstallError.failed(String(message.suffix(500)))
        }
        let installedBinary = staging.appendingPathComponent("node_modules/.bin/\(runtime.rawValue)").path
        guard FileManager.default.isExecutableFile(atPath: installedBinary) else {
            throw InstallError.executableMissing
        }
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
}
