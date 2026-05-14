import Foundation
import ClarcCore
import os

// MARK: - MCPService

/// Manages MCP (Model Context Protocol) servers configured for the Claude CLI.
///
/// All persistent state is owned by `claude mcp …` — this service just shells out
/// for add/list/get/remove and runs an in-process JSON-RPC handshake to test
/// connections and enumerate the tools each server exposes.
actor MCPService {

    private let claudeService: ClaudeService
    private let logger = Logger(subsystem: "com.claudework", category: "MCPService")

    init(claudeService: ClaudeService) {
        self.claudeService = claudeService
    }

    // MARK: - Errors

    enum MCPError: LocalizedError {
        case binaryNotFound
        case cliFailed(Int32, String)
        case parseFailure(String)
        case probeTimeout
        case probeFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:           return "Could not find the claude CLI binary."
            case .cliFailed(let s, let m):  return "claude exited with status \(s): \(m)"
            case .parseFailure(let detail): return "Could not parse claude output: \(detail)"
            case .probeTimeout:             return "MCP server did not respond within the timeout."
            case .probeFailed(let detail):  return detail
            }
        }
    }

    // MARK: - List / Get

    /// Run `claude mcp list` and parse the line-oriented output.
    /// Each row reports name, endpoint summary, and a health status.
    /// Scope is *not* present in this output — fill it in via parallel `get` calls.
    func list() async throws -> [MCPServerInfo] {
        let output = try await runClaude(["mcp", "list"])
        let infos = parseListOutput(output)

        guard !infos.isEmpty else { return [] }

        // Hydrate scope in parallel. A single `get` failure should not blank the row,
        // so we fall through with `scope = nil` if it errors.
        return await withTaskGroup(of: (Int, MCPScope?).self) { group in
            for (idx, info) in infos.enumerated() {
                group.addTask {
                    let detail = try? await self.get(name: info.name)
                    return (idx, detail?.scope)
                }
            }
            var hydrated = infos
            for await (idx, scope) in group {
                hydrated[idx].scope = scope
            }
            return hydrated
        }
    }

    /// Fetch one server's full configuration via `claude mcp get <name>`.
    func get(name: String) async throws -> MCPServerDetail {
        let output = try await runClaude(["mcp", "get", name])
        return try parseGetOutput(name: name, raw: output)
    }

    // MARK: - Add / Remove

    /// Build and run `claude mcp add` for the supplied spec.
    /// Falls back to `add-json` for stdio specs that include flag-like args
    /// the parent shell would otherwise mangle.
    func add(spec: MCPServerSpec, scope: MCPScope) async throws {
        var args: [String] = ["mcp", "add", "-s", scope.rawValue]

        switch spec.transport {
        case .http, .sse:
            args += ["-t", spec.transport.rawValue]
            for header in spec.headers where !header.key.isEmpty {
                args += ["-H", "\(header.key): \(header.value)"]
            }
            args += [spec.name, spec.url]

        case .stdio:
            for kv in spec.env where !kv.key.isEmpty {
                args += ["-e", "\(kv.key)=\(kv.value)"]
            }
            args += [spec.name, "--", spec.command]
            args += spec.args
        }

        _ = try await runClaude(args)
    }

    func remove(name: String, scope: MCPScope) async throws {
        _ = try await runClaude(["mcp", "remove", "-s", scope.rawValue, name])
    }

    // MARK: - Probe (test connection + list tools)

    /// Probe an existing server by name. Resolves the configuration via `get` first.
    func probe(name: String) async -> MCPProbeResult {
        do {
            let detail = try await get(name: name)
            return await probe(detail: detail)
        } catch {
            return MCPProbeResult(ok: false, error: error.localizedDescription)
        }
    }

    /// Probe a not-yet-saved spec (used by the editor sheet's Test button).
    func probe(spec: MCPServerSpec) async -> MCPProbeResult {
        let env = Dictionary(uniqueKeysWithValues: spec.env.map { ($0.key, $0.value) })
        let detail = MCPServerDetail(
            name: spec.name.isEmpty ? "(untitled)" : spec.name,
            scope: .local,
            transport: spec.transport,
            url: spec.transport == .stdio ? nil : spec.url,
            command: spec.transport == .stdio ? spec.command : nil,
            args: spec.args,
            env: env
        )
        return await probe(detail: detail)
    }

    private func probe(detail: MCPServerDetail) async -> MCPProbeResult {
        switch detail.transport {
        case .stdio:
            return await probeStdio(detail)
        case .http, .sse:
            return await probeHTTP(detail)
        }
    }

    // MARK: - Internal: claude CLI runner

    private func runClaude(_ args: [String]) async throws -> String {
        guard let binary = await claudeService.findClaudeBinary() else {
            throw MCPError.binaryNotFound
        }
        let env = await claudeService.resolvedEnvironment()
        let result = try await runProcess(
            executable: binary,
            arguments: args,
            environment: env
        )
        guard result.status == 0 else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MCPError.cliFailed(result.status, msg.isEmpty ? result.stdout : msg)
        }
        return result.stdout
    }

    private struct ProcessResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        stdinData: Data? = nil,
        currentDirectory: String? = nil
    ) async throws -> ProcessResult {
        let proc = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe
        if let environment { proc.environment = environment }
        if let currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        try proc.run()

        if let stdinData {
            let handle = stdinPipe.fileHandleForWriting
            try handle.write(contentsOf: stdinData)
            try handle.close()
        } else {
            try stdinPipe.fileHandleForWriting.close()
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Parsing: list

    private func parseListOutput(_ raw: String) -> [MCPServerInfo] {
        var infos: [MCPServerInfo] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.lowercased().hasPrefix("checking mcp") { continue }
            if line.lowercased().hasPrefix("no mcp servers") { continue }

            // Format: "<name>: <endpoint> [- <status>]"
            // The endpoint may itself contain ": " (URLs), so split on the *first*
            // ": ", then on the *last* " - " to peel off the status suffix.
            guard let colonRange = line.range(of: ": ") else { continue }
            let name = String(line[..<colonRange.lowerBound])
            var rest = String(line[colonRange.upperBound...])

            var status: MCPStatus = .unknown
            if let dashRange = rest.range(of: " - ", options: .backwards) {
                let suffix = String(rest[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                rest = String(rest[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                status = parseStatusSuffix(suffix)
            }

            // Strip optional "(HTTP)" / "(SSE)" trailing transport tag.
            var transport: MCPTransport = .stdio
            if let parenRange = rest.range(of: " (", options: .backwards),
               rest.hasSuffix(")") {
                let tag = String(rest[parenRange.upperBound..<rest.index(before: rest.endIndex)]).lowercased()
                switch tag {
                case "http": transport = .http
                case "sse":  transport = .sse
                default:     break
                }
                rest = String(rest[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            } else if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
                transport = .http
            }

            infos.append(MCPServerInfo(
                name: name,
                transport: transport,
                endpoint: rest,
                status: status
            ))
        }
        return infos
    }

    private func parseStatusSuffix(_ suffix: String) -> MCPStatus {
        let lower = suffix.lowercased()
        if lower.contains("connected") { return .connected }
        if lower.contains("needs authentication") || lower.contains("auth") { return .needsAuth }
        if lower.contains("failed") || lower.contains("error") {
            return .failed(suffix)
        }
        return .unknown
    }

    // MARK: - Parsing: get

    private func parseGetOutput(name: String, raw: String) throws -> MCPServerDetail {
        var scope: MCPScope = .user
        var transport: MCPTransport = .stdio
        var url: String?
        var command: String?
        var args: [String] = []
        var env: [String: String] = [:]

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(":") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map { String($0) }
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "Scope":
                let lower = value.lowercased()
                if lower.contains("user")    { scope = .user }
                else if lower.contains("project") { scope = .project }
                else if lower.contains("local")   { scope = .local }
            case "Type":
                switch value.lowercased() {
                case "http": transport = .http
                case "sse":  transport = .sse
                default:     transport = .stdio
                }
            case "URL":
                url = value
            case "Command":
                command = value
            case "Args":
                args = value.split(separator: " ").map(String.init)
            case "Environment":
                if !value.isEmpty {
                    for pair in value.split(separator: " ") {
                        let kv = pair.split(separator: "=", maxSplits: 1)
                        if kv.count == 2 { env[String(kv[0])] = String(kv[1]) }
                    }
                }
            default:
                break
            }
        }

        return MCPServerDetail(
            name: name,
            scope: scope,
            transport: transport,
            url: url,
            command: command,
            args: args,
            env: env
        )
    }

    // MARK: - Probe: stdio

    private func probeStdio(_ detail: MCPServerDetail) async -> MCPProbeResult {
        guard let command = detail.command, !command.isEmpty else {
            return MCPProbeResult(ok: false, error: "No command configured for stdio transport.")
        }

        let env = await claudeService.resolvedEnvironment().merging(detail.env) { _, new in new }
        let resolvedCommand = resolveCommand(command, env: env) ?? command

        let proc = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: resolvedCommand)
        proc.arguments = detail.args
        proc.environment = env
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe

        do {
            try proc.run()
        } catch {
            return MCPProbeResult(ok: false, error: "Failed to spawn: \(error.localizedDescription)")
        }

        let stdinHandle = stdinPipe.fileHandleForWriting
        let stdoutHandle = stdoutPipe.fileHandleForReading

        // Pre-build payloads outside the @Sendable closure so it doesn't need
        // to capture `self`. The closure can then reach back via `self.parse…`.
        let initializeJSON = initializeRequest(id: 1)
        let initializedJSON = initializedNotification()
        let toolsListJSON = toolsListRequest(id: 2)

        let result = await withTimeout(seconds: 10) { [self] () -> MCPProbeResult in
            // 1. initialize
            do {
                try Self.writeJSONRPC(initializeJSON, to: stdinHandle)
            } catch {
                return MCPProbeResult(ok: false, error: "stdin write failed: \(error.localizedDescription)")
            }

            guard let initReply = await Self.readJSONLine(from: stdoutHandle) else {
                return MCPProbeResult(ok: false, error: "No response to initialize.")
            }
            let (serverName, serverVersion) = self.parseInitializeResponse(initReply)

            // 2. notifications/initialized
            do {
                try Self.writeJSONRPC(initializedJSON, to: stdinHandle)
            } catch {
                return MCPProbeResult(ok: false, error: "stdin write failed: \(error.localizedDescription)")
            }

            // 3. tools/list
            do {
                try Self.writeJSONRPC(toolsListJSON, to: stdinHandle)
            } catch {
                return MCPProbeResult(ok: false, error: "stdin write failed: \(error.localizedDescription)")
            }

            guard let toolsReply = await Self.readJSONLine(from: stdoutHandle) else {
                return MCPProbeResult(
                    ok: true,
                    serverName: serverName,
                    serverVersion: serverVersion,
                    tools: [],
                    error: "Server did not return a tools list."
                )
            }
            let tools = self.parseToolsListResponse(toolsReply)
            return MCPProbeResult(
                ok: true,
                serverName: serverName,
                serverVersion: serverVersion,
                tools: tools
            )
        }

        // Tear down — SIGTERM then SIGKILL after 2s.
        if proc.isRunning {
            proc.terminate()
            let pid = proc.processIdentifier
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
        try? stdinHandle.close()
        return result ?? MCPProbeResult(ok: false, error: MCPError.probeTimeout.errorDescription)
    }

    /// Probe a stdio command name (e.g. `npx`) by walking PATH from the resolved env.
    /// Returns the absolute executable path, or nil if not found / already absolute.
    private func resolveCommand(_ command: String, env: [String: String]) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        guard let path = env["PATH"] else { return nil }
        let fm = FileManager.default
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Probe: HTTP / SSE

    private func probeHTTP(_ detail: MCPServerDetail) async -> MCPProbeResult {
        guard let urlString = detail.url, let baseURL = URL(string: urlString) else {
            return MCPProbeResult(ok: false, error: "No URL configured.")
        }

        var sessionID: String?
        do {
            // Headers from `claude mcp get` aren't returned, so probes against
            // servers that need auth headers will likely fail with 401 — surface that.
            let (initData, initResp, sid) = try await postMCP(
                url: baseURL,
                body: initializeRequest(id: 1),
                sessionID: nil
            )
            sessionID = sid
            if let http = initResp as? HTTPURLResponse, http.statusCode == 401 {
                return MCPProbeResult(ok: false, error: "401 Unauthorized — server requires authentication.")
            }
            let (serverName, serverVersion) = parseInitializeResponse(extractJSON(initData))

            _ = try? await postMCP(
                url: baseURL,
                body: initializedNotification(),
                sessionID: sessionID
            )

            let (toolsData, _, _) = try await postMCP(
                url: baseURL,
                body: toolsListRequest(id: 2),
                sessionID: sessionID
            )
            let tools = parseToolsListResponse(extractJSON(toolsData))

            return MCPProbeResult(
                ok: true,
                serverName: serverName,
                serverVersion: serverVersion,
                tools: tools
            )
        } catch {
            return MCPProbeResult(ok: false, error: error.localizedDescription)
        }
    }

    /// One round-trip of MCP-over-HTTP (Streamable HTTP variant).
    /// Returns the raw response body, response, and any new MCP-Session-Id.
    private func postMCP(
        url: URL,
        body: [String: Any],
        sessionID: String?
    ) async throws -> (Data, URLResponse, String?) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let returnedSession = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id")
        return (data, response, returnedSession ?? sessionID)
    }

    /// Pull the JSON-RPC payload out of either a plain JSON body or an SSE stream.
    private func extractJSON(_ data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // SSE: look for lines starting with "data: "
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if let payloadData = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    // MARK: - JSON-RPC payloads

    private nonisolated func initializeRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "Clarc",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                ]
            ]
        ]
    }

    private nonisolated func initializedNotification() -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ]
    }

    private nonisolated func toolsListRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list"
        ]
    }

    private nonisolated func parseInitializeResponse(_ json: [String: Any]?) -> (String?, String?) {
        guard let result = json?["result"] as? [String: Any],
              let info = result["serverInfo"] as? [String: Any] else {
            return (nil, nil)
        }
        return (info["name"] as? String, info["version"] as? String)
    }

    private nonisolated func parseToolsListResponse(_ json: [String: Any]?) -> [MCPTool] {
        guard let result = json?["result"] as? [String: Any],
              let raw = result["tools"] as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return MCPTool(name: name, description: dict["description"] as? String)
        }
    }

    // MARK: - JSON line I/O for stdio probe

    private static func writeJSONRPC(_ obj: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    /// Read one newline-delimited JSON object from the handle.
    /// Returns nil on EOF or parse failure.
    private static func readJSONLine(from handle: FileHandle) async -> [String: Any]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        cont.resume(returning: nil)
                        return
                    }
                    buffer.append(chunk)
                    while let nlIdx = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<nlIdx)
                        buffer.removeSubrange(0...nlIdx)
                        if lineData.isEmpty { continue }
                        if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                            cont.resume(returning: obj)
                            return
                        }
                        // Non-JSON line (some servers print banners) — keep reading.
                    }
                }
            }
        }
    }

    // MARK: - Timeout helper

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
