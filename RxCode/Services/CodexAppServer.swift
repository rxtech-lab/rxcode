import Foundation
import RxCodeCore
import os

actor CodexAppServer {
    enum CodexError: LocalizedError {
        case binaryNotFound
        case versionCheckFailed(String)
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find the codex CLI binary."
            case .versionCheckFailed(let detail):
                return "Version check failed: \(detail)"
            case .spawnFailed(let detail):
                return "Failed to spawn codex app-server: \(detail)"
            }
        }
    }

    struct RunningProcess {
        let process: Process
        let stdin: FileHandle
    }

    struct CodexRateLimitWindow {
        let percent: Double
        let resetsAt: Date?
        let durationMinutes: Int?
    }

    let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "CodexAppServer"
    )
    var running: [UUID: RunningProcess] = [:]
    var stderrBuffers: [UUID: String] = [:]
    var cachedShellPath: String?
    var cachedRateLimits: RateLimitUsage?
    var cachedRateLimitsAt: Date?
    var rateLimitsFetchTask: Task<RateLimitUsage?, Never>?
    let rateLimitsCacheTTL: TimeInterval = 300
    var notificationMethodCounts: [String: Int] = [:]
    /// Reference to the permission server for in-band permission requests.
    /// Wired once at app init; the `AgentBackend.send(_:)` adapter pulls it
    /// from here so callers don't have to pass it on every turn.
    weak var permissionServer: PermissionServer?

    func setPermissionServer(_ server: PermissionServer) {
        self.permissionServer = server
    }

    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.nvm/versions/node",
        ]
    }

    func findCodexBinary() async -> String? {
        let fm = FileManager.default
        for path in Self.candidatePaths {
            if path.hasSuffix("/node") {
                if let found = findNvmCodexBinary(root: path) { return found }
                continue
            }
            let resolved = (path as NSString).resolvingSymlinksInPath
            if fm.fileExists(atPath: resolved) && fm.isExecutableFile(atPath: path) {
                logger.info("Found codex binary at \(path, privacy: .public)")
                return path
            }
        }

        do {
            let output = try await runShellCommand("/bin/zsh", arguments: ["-ilc", "whence -p codex"])
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                logger.info("Found codex binary via shell at \(path, privacy: .public)")
                return path
            }
        } catch {
            logger.warning("Shell fallback failed while locating codex: \(error.localizedDescription)")
        }
        return nil
    }

    func checkVersion() async throws -> String {
        guard let binary = await findCodexBinary() else { throw CodexError.binaryNotFound }
        let output = try await runShellCommand(binary, arguments: ["--version"])
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw CodexError.versionCheckFailed("Empty version output") }
        return version
    }

    func fetchModels() async -> [AgentModel] {
        guard let binary = await findCodexBinary() else {
            logger.warning("Skipping Codex model fetch because no codex binary was found")
            return []
        }
        do {
            let streamId = UUID()
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: nil)
            defer { finalize(streamId: streamId) }
            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)
            try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
            try Self.writeJSONLine(Self.request(id: 2, method: "model/list", params: ["includeHidden": .bool(false)]), to: handles.stdin)

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard let object = Self.decodeObject(line),
                      Self.idString(object["id"]) == "2",
                      let result = object["result"] else { continue }
                let models = Self.parseModels(from: result)
                logger.info("Codex app-server model/list returned \(models.count) models")
                if !models.isEmpty { return models }
                logger.warning("Codex app-server model/list returned no parseable models; trying codex debug models")
                break
            }
        } catch {
            logger.warning("Codex model/list failed: \(error.localizedDescription)")
        }
        let debugModels = await fetchModelsFromDebugCommand(binary: binary)
        if !debugModels.isEmpty {
            logger.info("Codex debug models returned \(debugModels.count) models")
        } else {
            logger.warning("Codex debug models returned no parseable models; UI will use built-in fallback models")
        }
        return debugModels
    }

    func fetchRateLimits(forceRefresh: Bool = false) async -> RateLimitUsage? {
        if !forceRefresh,
           let cachedRateLimits,
           let cachedRateLimitsAt,
           Date().timeIntervalSince(cachedRateLimitsAt) < rateLimitsCacheTTL {
            return cachedRateLimits
        }

        if let rateLimitsFetchTask {
            return await rateLimitsFetchTask.value ?? cachedRateLimits
        }

        let task = Task { await self.fetchRateLimitsUncached() }
        rateLimitsFetchTask = task
        let usage = await task.value
        rateLimitsFetchTask = nil

        if let usage {
            cachedRateLimits = usage
            cachedRateLimitsAt = Date()
            return usage
        }
        return cachedRateLimits
    }

    func send(
        streamId: UUID,
        prompt: String,
        cwd: String,
        threadId: String?,
        model: String?,
        permissionMode: PermissionMode,
        planMode: Bool,
        mcpConfigOverrides: [String] = [],
        permissionServer: PermissionServer
    ) -> AsyncStream<StreamEvent> {
        AsyncStream<StreamEvent> { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runTurn(
                    streamId: streamId,
                    prompt: prompt,
                    cwd: cwd,
                    threadId: threadId,
                    model: model,
                    permissionMode: permissionMode,
                    planMode: planMode,
                    mcpConfigOverrides: mcpConfigOverrides,
                    permissionServer: permissionServer,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.finalize(streamId: streamId) }
            }
        }
    }

    func finalize(streamId: UUID) {
        guard let entry = running.removeValue(forKey: streamId) else { return }
        try? entry.stdin.close()
        if entry.process.isRunning {
            entry.process.terminate()
        }
    }

    func cancel(streamId: UUID) {
        finalize(streamId: streamId)
    }

    func consumeStderr(for streamId: UUID) -> String? {
        let value = stderrBuffers.removeValue(forKey: streamId)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum AppStateModelFormatter {
    nonisolated static func codexDisplayName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                part.uppercased().hasPrefix("GPT") ? part.uppercased() : part.capitalized
            }
            .joined(separator: " ")
    }
}

// MARK: - AgentBackend Conformance

extension CodexAppServer: AgentBackend {
    nonisolated var provider: AgentProvider { .codex }
    nonisolated var staticCapabilities: CapabilitySet { AgentProvider.codex.staticCapabilities }

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        guard let permissionServer else {
            logger.error("[Codex] send called before setPermissionServer wired")
            return AsyncStream<StreamEvent> { c in
                c.yield(.user(UserMessage(
                    toolUseId: nil,
                    content: "Codex backend not initialized (missing permission server).",
                    isError: true
                )))
                c.yield(.result(ResultEvent(
                    durationMs: nil, totalCostUsd: nil,
                    sessionId: request.sessionId ?? request.clientSessionKey,
                    isError: true, totalTurns: nil, usage: nil, contextWindow: nil
                )))
                c.finish()
            }
        }
        return send(
            streamId: request.streamId,
            prompt: request.prompt,
            cwd: request.cwd,
            threadId: request.sessionId,
            model: request.model,
            permissionMode: request.permissionMode,
            planMode: request.planMode,
            mcpConfigOverrides: request.mcpCodexOverrides,
            permissionServer: permissionServer
        )
    }
}
