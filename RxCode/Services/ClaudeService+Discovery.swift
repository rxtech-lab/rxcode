import Foundation
import RxCodeCore
import os

// MARK: - Discovery & Environment

extension ClaudeCodeServer {

    // MARK: - Shell PATH Resolution

    /// Compose a PATH that lets the spawned `claude` CLI find `node` and
    /// related tools regardless of where the user installed them.
    ///
    /// Combines, in priority order:
    ///   1. The user's interactive login shell PATH (captures nvm/asdf/.zshrc init)
    ///   2. Well-known tool directories (Homebrew, npm-global, nvm latest)
    ///   3. The GUI process's existing PATH as a final fallback
    func resolvedShellPath() async -> String {
        if let cached = cachedShellPath { return cached }

        var paths: [String] = []
        var seen = Set<String>()
        func add(_ entry: String) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            paths.append(trimmed)
        }

        if let shellPath = await readUserShellPath() {
            for component in shellPath.split(separator: ":") { add(String(component)) }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
        ] { add(dir) }

        if let nvmBin = latestNvmBinDirectory(home: home) { add(nvmBin) }

        if let existing = ProcessInfo.processInfo.environment["PATH"] {
            for component in existing.split(separator: ":") { add(String(component)) }
        }

        // Double-check after awaits: another reentrant caller may have populated it.
        if let cached = cachedShellPath { return cached }

        let combined = paths.joined(separator: ":")
        cachedShellPath = combined
        logger.info("Resolved shell PATH for subprocess (entries=\(paths.count))")
        return combined
    }

    /// Spawn the user's login shell once to read its `$PATH`.
    /// Uses `-ilc` so `.zshrc` (and the nvm/asdf init it typically sources) runs.
    func readUserShellPath() async -> String? {
        do {
            let output = try await runShellCommand(
                "/bin/zsh",
                arguments: ["-ilc", "print -rn -- $PATH"],
                injectPath: false
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logger.warning("Failed to read user shell PATH: \(error.localizedDescription)")
            return nil
        }
    }

    /// Locate the bin directory of the most recent nvm-installed Node, if any.
    /// Defends against shell readout failure for nvm users.
    func latestNvmBinDirectory(home: String) -> String? {
        let root = "\(home)/.nvm/versions/node"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for entry in entries.sorted(by: >) {
            let bin = "\(root)/\(entry)/bin"
            if fm.isExecutableFile(atPath: "\(bin)/node") { return bin }
        }
        return nil
    }

    /// Build the full environment dictionary for spawned subprocesses,
    /// inheriting the GUI environment but with PATH replaced by ``resolvedShellPath()``.
    func resolvedEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await resolvedShellPath()
        return env
    }

    // MARK: - Binary Discovery

    /// Well-known paths searched in order before falling back to the shell.
    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
    }

    /// Locate the `claude` binary on this machine.
    func findClaudeBinary() async -> String? {
        let fm = FileManager.default

        for path in Self.candidatePaths {
            // Resolve symlinks before checking
            let resolved = (path as NSString).resolvingSymlinksInPath
            if fm.fileExists(atPath: resolved) && fm.isExecutableFile(atPath: path) {
                logger.info("Found claude binary at \(path, privacy: .public) -> \(resolved, privacy: .public)")
                return path
            }
        }

        // Shell fallback
        logger.info("Trying shell fallback to locate claude binary")
        do {
            let result = try await runShellCommand("/bin/zsh", arguments: ["-ilc", "whence -p claude"])
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                logger.info("Found claude binary via shell at \(path, privacy: .public)")
                return path
            }
        } catch {
            logger.warning("Shell fallback failed: \(error, privacy: .public)")
        }

        logger.error("claude binary not found")
        return nil
    }

    // MARK: - Local Command

    /// Run a local slash command (e.g. "/cost", "/usage") and return stdout.
    func runLocalCommand(_ command: String) async throws -> String {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let output = try await runShellCommand(binary, arguments: ["-p", command, "--output-format", "text"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run `/context` for a session and parse the used percentage.
    /// Returns nil if the session has no context info or parsing fails.
    func fetchContextPercentage(sessionId: String, cwd: String) async -> Double? {
        guard let binary = await findClaudeBinary() else { return nil }
        do {
            let output = try await runShellCommand(
                binary,
                arguments: ["-p", "/context", "--output-format", "text", "--resume", sessionId],
                cwd: cwd
            )
            // Parse "Tokens: 24.2k / 200k (12%)" pattern
            guard let match = output.range(of: #"\((\d+(?:\.\d+)?)%\)"#, options: .regularExpression) else {
                return nil
            }
            let captured = output[match].dropFirst(1).dropLast(2) // remove "(" and "%)"
            return Double(captured)
        } catch {
            logger.warning("Failed to fetch context: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Version Check

    /// Run `claude --version` and return the version string.
    func checkVersion() async throws -> String {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let output = try await runShellCommand(binary, arguments: ["--version"])
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\(Claude Code\)"#, with: "", options: .regularExpression)

        guard !version.isEmpty else {
            throw ClaudeError.versionCheckFailed("Empty version output")
        }

        logger.info("Claude CLI version: \(version, privacy: .public)")
        return version
    }

    // MARK: - Shell Command Runner

    /// Run a simple command and return its stdout as a String.
    /// Uses async termination handling to avoid blocking the actor's cooperative thread.
    ///
    /// `injectPath` controls whether the spawned process receives the resolved
    /// shell PATH. Set to `false` when this method is itself used to *resolve*
    /// the shell PATH, to break the chicken-and-egg loop.
    func runShellCommand(
        _ command: String,
        arguments: [String] = [],
        cwd: String? = nil,
        injectPath: Bool = true
    ) async throws -> String {
        let proc = Process()
        let pipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.environment = injectPath
            ? await resolvedEnvironment()
            : ProcessInfo.processInfo.environment
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        try proc.run()

        // Wait for process exit asynchronously instead of blocking
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in
                continuation.resume()
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
