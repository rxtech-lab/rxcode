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

    private struct RunningProcess {
        let process: Process
        let stdin: FileHandle
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "CodexAppServer"
    )
    private var running: [UUID: RunningProcess] = [:]
    private var stderrBuffers: [UUID: String] = [:]
    private var cachedShellPath: String?

    private static var candidatePaths: [String] {
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
        guard let binary = await findCodexBinary() else { return [] }
        do {
            let streamId = UUID()
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: nil)
            defer { finalize(streamId: streamId) }
            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)
            try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
            try Self.writeJSONLine(Self.request(id: 2, method: "model/list", params: [:]), to: handles.stdin)

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard let object = Self.decodeObject(line),
                      Self.idString(object["id"]) == "2",
                      let result = object["result"] else { continue }
                return Self.parseModels(from: result)
            }
        } catch {
            logger.warning("Codex model/list failed: \(error.localizedDescription)")
        }
        return []
    }

    func send(
        streamId: UUID,
        prompt: String,
        cwd: String,
        threadId: String?,
        model: String?,
        permissionMode: PermissionMode,
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

    private func runTurn(
        streamId: UUID,
        prompt: String,
        cwd: String,
        threadId: String?,
        model: String?,
        permissionMode: PermissionMode,
        permissionServer: PermissionServer,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async {
        do {
            guard let binary = await findCodexBinary() else { throw CodexError.binaryNotFound }
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: cwd)
            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)

            var activeThreadId = threadId
            var turnStarted = false
            var turnCompleted = false
            let startedAt = Date()

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard !Task.isCancelled else { break }
                guard let object = Self.decodeObject(line) else { continue }

                if let id = Self.idString(object["id"]), object["method"] == nil {
                    switch id {
                    case "1":
                        try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
                        let method = activeThreadId == nil ? "thread/start" : "thread/resume"
                        try Self.writeJSONLine(Self.request(id: 2, method: method, params: threadParams(threadId: activeThreadId, cwd: cwd)), to: handles.stdin)
                    case "2":
                        if let result = object["result"] {
                            activeThreadId = Self.threadId(from: result) ?? activeThreadId ?? UUID().uuidString
                            continuation.yield(.system(SystemEvent(
                                subtype: "init",
                                sessionId: activeThreadId,
                                tools: nil,
                                model: model,
                                claudeCodeVersion: nil
                            )))
                        }
                        if let activeThreadId, !turnStarted {
                            try Self.writeJSONLine(Self.request(id: 3, method: "turn/start", params: turnParams(threadId: activeThreadId, prompt: prompt, cwd: cwd, model: model)), to: handles.stdin)
                            turnStarted = true
                        }
                    case "3":
                        break
                    default:
                        break
                    }
                    continue
                }

                if let method = object["method"]?.stringValue {
                    if let requestId = Self.idString(object["id"]) {
                        try await handleServerRequest(
                            requestId: requestId,
                            method: method,
                            object: object,
                            activeThreadId: activeThreadId,
                            permissionMode: permissionMode,
                            permissionServer: permissionServer,
                            stdin: handles.stdin
                        )
                    } else {
                        handleNotification(method: method, object: object, activeThreadId: activeThreadId, continuation: continuation)
                        if method == "turn/completed" || method == "turn/failed" {
                            turnCompleted = true
                            break
                        }
                    }
                }
            }

            let sid = activeThreadId ?? threadId ?? UUID().uuidString
            let duration = Date().timeIntervalSince(startedAt) * 1000
            continuation.yield(.result(ResultEvent(
                durationMs: duration,
                totalCostUsd: nil,
                sessionId: sid,
                isError: !turnCompleted,
                totalTurns: 1,
                usage: nil,
                contextWindow: nil
            )))
        } catch {
            stderrBuffers[streamId, default: ""] += "\n\(error.localizedDescription)"
            let sid = threadId ?? "codex-\(streamId.uuidString)"
            continuation.yield(.result(ResultEvent(
                durationMs: nil,
                totalCostUsd: nil,
                sessionId: sid,
                isError: true,
                totalTurns: nil,
                usage: nil,
                contextWindow: nil
            )))
        }
        finalize(streamId: streamId)
        continuation.finish()
    }

    private func handleNotification(
        method: String,
        object: [String: JSONValue],
        activeThreadId: String?,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) {
        let params = object["params"]?.objectValue ?? [:]
        switch method {
        case "thread/started":
            let sid = Self.threadId(from: .object(params)) ?? activeThreadId
            continuation.yield(.system(SystemEvent(subtype: "init", sessionId: sid, tools: nil, model: nil, claudeCodeVersion: nil)))
        case "item/agentMessage/delta", "item/agent_message/delta":
            if let text = Self.firstString(in: params, keys: ["delta", "text", "content"]) {
                continuation.yield(.unknown(Self.claudeTextDelta(text)))
            }
        case "item/started":
            if let item = params["item"]?.objectValue ?? params["itemInfo"]?.objectValue {
                emitToolStart(item: item, continuation: continuation)
            }
        case "item/completed":
            if let item = params["item"]?.objectValue ?? params["itemInfo"]?.objectValue {
                emitToolCompletion(item: item, continuation: continuation)
            }
        case "error", "turn/failed":
            if let message = Self.firstString(in: params, keys: ["message", "error"]) {
                continuation.yield(.unknown(Self.claudeTextDelta(message)))
            }
        default:
            break
        }
    }

    private func emitToolStart(item: [String: JSONValue], continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let name = toolName(from: item), name != "message" else { return }
        let id = Self.firstString(in: item, keys: ["id", "itemId", "callId"]) ?? UUID().uuidString
        let input = item["input"]?.objectValue ?? item["arguments"]?.objectValue ?? item
        continuation.yield(.unknown(Self.claudeToolStart(id: id, name: name)))
        continuation.yield(.unknown(Self.claudeInputDelta(input)))
        continuation.yield(.unknown(Self.claudeContentBlockStop()))
    }

    private func emitToolCompletion(item: [String: JSONValue], continuation: AsyncStream<StreamEvent>.Continuation) {
        let id = Self.firstString(in: item, keys: ["id", "itemId", "callId"]) ?? UUID().uuidString
        let output = Self.firstString(in: item, keys: ["output", "result", "summary", "message"]) ?? ""
        let isError = item["error"] != nil || item["isError"]?.boolValue == true
        continuation.yield(.user(UserMessage(toolUseId: id, content: output, isError: isError)))
    }

    private func handleServerRequest(
        requestId: String,
        method: String,
        object: [String: JSONValue],
        activeThreadId: String?,
        permissionMode: PermissionMode,
        permissionServer: PermissionServer,
        stdin: FileHandle
    ) async throws {
        let params = object["params"]?.objectValue ?? [:]
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "request/approval":
            let toolUseId = Self.firstString(in: params, keys: ["itemId", "callId", "id"]) ?? requestId
            let command = Self.firstString(in: params, keys: ["command", "cmd"])
            let toolName = command == nil ? "Edit" : "Bash"
            var input = params
            if let command { input["command"] = .string(command) }
            let decision = await permissionServer.requestDecision(
                toolUseId: toolUseId,
                sessionId: activeThreadId,
                toolName: toolName,
                toolInput: input,
                mode: permissionMode
            )
            let approved = decision == .allow || {
                if case .allowAlwaysCommand = decision { return true }
                if case .allowSessionTool = decision { return true }
                if case .allowAndSetMode = decision { return true }
                return false
            }()
            try Self.writeJSONLine(Self.response(id: requestId, result: [
                "decision": .string(approved ? "accept" : "reject")
            ]), to: stdin)
        case "userInput/request":
            let toolUseId = Self.firstString(in: params, keys: ["itemId", "callId", "id"]) ?? requestId
            let decision = await permissionServer.requestDecision(
                toolUseId: toolUseId,
                sessionId: activeThreadId,
                toolName: "AskUserQuestion",
                toolInput: params,
                mode: permissionMode
            )
            try Self.writeJSONLine(Self.response(id: requestId, result: [
                "decision": .string(decision == .allow ? "accept" : "reject")
            ]), to: stdin)
        default:
            try Self.writeJSONLine(Self.response(id: requestId, result: [:]), to: stdin)
        }
    }

    private func initializeParams() -> [String: JSONValue] {
        [
            "clientInfo": .object([
                "name": .string("RxCode"),
                "title": .string("RxCode"),
                "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
            ]),
            "capabilities": .object([:])
        ]
    }

    private func threadParams(threadId: String?, cwd: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let threadId { params["threadId"] = .string(threadId) }
        return params
    }

    private func turnParams(threadId: String, prompt: String, cwd: String, model: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "cwd": .string(cwd),
            "input": .array([
                .object(["type": .string("text"), "text": .string(prompt)])
            ])
        ]
        if let model { params["model"] = .string(model) }
        return params
    }

    private func spawnAppServer(binary: String, streamId: UUID, cwd: String?) async throws -> (process: Process, stdin: FileHandle, stdout: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://"]
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

    private func readStderr(_ stderr: Pipe, streamId: UUID) {
        Task.detached { [weak self] in
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            await self?.appendStderr(text, streamId: streamId)
        }
    }

    private func appendStderr(_ text: String, streamId: UUID) {
        stderrBuffers[streamId, default: ""] += text
    }

    private func findNvmCodexBinary(root: String) -> String? {
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

    private func resolvedEnvironment() async -> [String: String] {
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

    private func runShellCommand(_ executable: String, arguments: [String], injectPath: Bool = true) async throws -> String {
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

    private func toolName(from item: [String: JSONValue]) -> String? {
        if let type = Self.firstString(in: item, keys: ["type", "kind"]) {
            if type.contains("command") { return "Bash" }
            if type.contains("file") || type.contains("patch") { return "Edit" }
            if type.contains("message") { return "message" }
            return type
        }
        return Self.firstString(in: item, keys: ["name", "toolName"])
    }

    private static func parseModels(from value: JSONValue) -> [AgentModel] {
        let root = value.objectValue
        let rawModels = root?["models"]?.arrayValue ?? root?["items"]?.arrayValue ?? value.arrayValue ?? []
        return rawModels.compactMap { entry in
            if let id = entry.stringValue {
                return AgentModel(provider: .codex, id: id, displayName: AppStateModelFormatter.codexDisplayName(id), description: "Codex model served by the Codex app-server.")
            }
            guard let object = entry.objectValue,
                  let id = firstString(in: object, keys: ["id", "name", "model"]) else { return nil }
            let displayName = firstString(in: object, keys: ["displayName", "display_name", "name"]) ?? AppStateModelFormatter.codexDisplayName(id)
            let description = firstString(in: object, keys: ["description", "detail"]) ?? "Codex model served by the Codex app-server."
            return AgentModel(provider: .codex, id: id, displayName: displayName, description: description)
        }
    }

    private static func request(id: Int, method: String, params: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)])
    }

    private static func response(id: String, result: [String: JSONValue]) -> JSONValue {
        let idValue = Double(id).map(JSONValue.number) ?? .string(id)
        return .object(["jsonrpc": .string("2.0"), "id": idValue, "result": .object(result)])
    }

    private static func notification(method: String, params: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])
    }

    private static func writeJSONLine(_ value: JSONValue, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private static func decodeObject(_ line: String) -> [String: JSONValue]? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value.objectValue
    }

    private static func idString(_ value: JSONValue?) -> String? {
        if let s = value?.stringValue { return s }
        if let n = value?.numberValue {
            if n.rounded() == n { return String(Int(n)) }
            return String(n)
        }
        return nil
    }

    private static func threadId(from value: JSONValue) -> String? {
        if let object = value.objectValue {
            if let id = firstString(in: object, keys: ["threadId", "thread_id", "id"]) { return id }
            if let nested = object["thread"]?.objectValue {
                return firstString(in: nested, keys: ["threadId", "thread_id", "id"])
            }
        }
        return value.stringValue
    }

    private static func firstString(in object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue { return value }
            if let number = object[key]?.numberValue { return String(number) }
        }
        return nil
    }

    private static func claudeTextDelta(_ text: String) -> String {
        jsonString([
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": text]
        ])
    }

    private static func claudeToolStart(id: String, name: String) -> String {
        jsonString([
            "type": "content_block_start",
            "content_block": ["type": "tool_use", "id": id, "name": name]
        ])
    }

    private static func claudeInputDelta(_ input: [String: JSONValue]) -> String {
        let data = (try? JSONEncoder().encode(JSONValue.object(input))) ?? Data("{}".utf8)
        let inputText = String(data: data, encoding: .utf8) ?? "{}"
        return jsonString([
            "type": "content_block_delta",
            "delta": ["type": "input_json_delta", "partial_json": inputText]
        ])
    }

    private static func claudeContentBlockStop() -> String {
        jsonString(["type": "content_block_stop"])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

private enum AppStateModelFormatter {
    static func codexDisplayName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                part.uppercased().hasPrefix("GPT") ? part.uppercased() : part.capitalized
            }
            .joined(separator: " ")
    }
}
