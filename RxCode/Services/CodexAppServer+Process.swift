import Foundation
import RxCodeCore
import os

extension CodexAppServer {
    func fetchRateLimitsUncached() async -> RateLimitUsage? {
        guard let binary = await findCodexBinary() else {
            logger.warning("Skipping Codex rate-limit fetch because no codex binary was found")
            return nil
        }
        do {
            let streamId = UUID()
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: nil)
            defer { finalize(streamId: streamId) }
            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)
            try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
            try Self.writeJSONLine(Self.request(id: 2, method: "account/rateLimits/read", params: .null), to: handles.stdin)

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard let object = Self.decodeObject(line) else { continue }

                if let requestId = Self.idString(object["id"]), object["method"] != nil {
                    try Self.writeJSONLine(Self.response(id: requestId, result: [:]), to: handles.stdin)
                    continue
                }

                if Self.idString(object["id"]) == "2", let result = object["result"] {
                    let usage = Self.parseCodexRateLimits(from: result)
                    if let usage {
                        logger.info("Codex rate limits 5h=\(usage.fiveHourPercent)% 7d=\(usage.sevenDayPercent)%")
                    } else {
                        logger.warning("Codex account/rateLimits/read returned no parseable limits")
                    }
                    return usage
                }

                if object["method"]?.stringValue == "account/rateLimits/updated",
                   let params = object["params"] {
                    return Self.parseCodexRateLimits(from: params)
                }
            }
        } catch {
            logger.warning("Codex rate-limit fetch failed: \(error.localizedDescription)")
        }
        return nil
    }

    func fetchModelsFromDebugCommand(binary: String) async -> [AgentModel] {
        do {
            let output = try await runShellCommand(binary, arguments: ["debug", "models"])
            guard let value = Self.decodeJSONValue(output) else {
                logger.warning("Could not decode codex debug models output as JSON")
                return []
            }
            return Self.parseModels(from: value)
        } catch {
            logger.warning("Codex debug models failed: \(error.localizedDescription)")
            return []
        }
    }

    func spawnAppServer(binary: String, streamId: UUID, cwd: String?, configOverrides: [String] = []) async throws -> (process: Process, stdin: FileHandle, stdout: Pipe) {
        let launchStartedAt = Date()
        logger.info("[CodexAppServer] launch start stream=\(streamId) cwd=\(cwd ?? "<nil>", privacy: .public) overrides=\(configOverrides.count)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let env = await resolvedEnvironment()
        var arguments = ["app-server", "--listen", "stdio://"] + configOverrides
        // Recent Codex routes tool execution (terminal commands, apply_patch)
        // through a separate `codex-code-mode-host` sidecar binary. The Homebrew
        // Cask ships only the main `codex` binary, so the sidecar is missing and
        // every edit/command fails with "code-mode host ... No such file". When we
        // can't locate the sidecar, disable the feature so execution runs directly.
        if !Self.codeModeHostAvailable(binary: binary, path: env["PATH"]) {
            arguments += ["-c", "features.code_mode_host=false"]
            logger.warning("[CodexAppServer] codex-code-mode-host sidecar not found; disabling code_mode_host feature so tool execution runs directly")
        }
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw CodexError.spawnFailed(error.localizedDescription)
        }
        let elapsed = Date().timeIntervalSince(launchStartedAt)
        logger.info("[CodexAppServer] process launched pid=\(process.processIdentifier) stream=\(streamId) after=\(String(format: "%.2f", elapsed), privacy: .public)s binary=\(binary, privacy: .public)")

        let stdinHandle = stdin.fileHandleForWriting
        running[streamId] = RunningProcess(process: process, stdin: stdinHandle)
        readStderr(stderr, streamId: streamId)
        return (process, stdinHandle, stdout)
    }

    func readStderr(_ stderr: Pipe, streamId: UUID) {
        Task.detached { [weak self] in
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            await self?.appendStderr(text, streamId: streamId)
        }
    }

    func appendStderr(_ text: String, streamId: UUID) {
        stderrBuffers[streamId, default: ""] += text
    }

    /// Whether the `codex-code-mode-host` sidecar (spawned by Codex for tool
    /// execution when the `code_mode_host` feature is on) can be located. Mirrors
    /// how Codex resolves it: the `CODEX_CODE_MODE_HOST_PATH` env override, a
    /// sibling of the `codex` binary (and of its symlink target — the Homebrew
    /// symlink dir differs from the Caskroom target dir), or the shell `PATH`.
    static func codeModeHostAvailable(binary: String, path: String?) -> Bool {
        let fm = FileManager.default
        let hostName = "codex-code-mode-host"

        if let explicit = ProcessInfo.processInfo.environment["CODEX_CODE_MODE_HOST_PATH"],
           !explicit.isEmpty, fm.isExecutableFile(atPath: explicit) {
            return true
        }

        let binaryDir = (binary as NSString).deletingLastPathComponent
        let resolvedDir = ((binary as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent
        for dir in [binaryDir, resolvedDir] where !dir.isEmpty {
            if fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(hostName)) {
                return true
            }
        }

        if let path, !path.isEmpty {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                if fm.isExecutableFile(atPath: (String(dir) as NSString).appendingPathComponent(hostName)) {
                    return true
                }
            }
        }

        return false
    }

    func findNvmCodexBinary(root: String) -> String? {
        let fm = FileManager.default
        guard let versions = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for version in versions.sorted(by: >) {
            let candidate = "\(root)/\(version)/bin/codex"
            let resolved = (candidate as NSString).resolvingSymlinksInPath
            if fm.fileExists(atPath: resolved) && fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func resolvedEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let cachedShellPath {
            env["PATH"] = cachedShellPath
            return env
        }
        let rawShellPath = try? await runShellCommand("/bin/zsh", arguments: ["-ilc", "print -rn -- $PATH"], injectPath: false)
        let shellPath = rawShellPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let shellPath, !shellPath.isEmpty {
            cachedShellPath = shellPath
            env["PATH"] = shellPath
        }
        return env
    }

    /// Prime the shell PATH cache so the first user message doesn't pay the
    /// `/bin/zsh -ilc` round trip in its critical path.
    func prewarm() async {
        _ = await resolvedEnvironment()
    }

    func runShellCommand(_ executable: String, arguments: [String], injectPath: Bool = true) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if injectPath {
            process.environment = await resolvedEnvironment()
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CodexError.versionCheckFailed(err.isEmpty ? out : err)
        }
        return out
    }
}
