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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://"] + configOverrides
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = await resolvedEnvironment()

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
