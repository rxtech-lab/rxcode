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

    /// Read MCP server configs straight from disk:
    ///   User scope    -> ~/.claude.json :: mcpServers
    ///   Local scope   -> ~/.claude.json :: projects[<projectPath>].mcpServers
    ///   Project scope -> <projectPath>/.mcp.json :: mcpServers
    /// Servers listed in `projects[<projectPath>].disabledMcpjsonServers` are filtered out
    /// of the Project section, matching what Claude Code actually loads.
    /// Status is always `.unknown` from the file read alone — connection state comes from a probe.
    ///
    /// When `projectPath` is nil, aggregate Local/Project rows across every project in
    /// `~/.claude.json`. This is what the (window-less) Settings sheet uses so the list
    /// matches the union of `claude mcp list` run from each project directory.
    func list(projectPath: String?) async throws -> [MCPServerInfo] {
        let root = readClaudeRoot()
        var rows: [MCPServerInfo] = []

        for (name, entry) in (root?.mcpServers ?? [:]).sorted(by: { $0.key < $1.key }) {
            rows.append(makeInfo(name: name, entry: entry, scope: .user, projectPath: nil))
        }

        let projectPaths: [String]
        if let projectPath, !projectPath.isEmpty {
            projectPaths = [projectPath]
        } else {
            projectPaths = (root?.projects?.keys.sorted() ?? [])
        }

        for path in projectPaths {
            let projectEntry = root?.projects?[path]
            for (name, entry) in (projectEntry?.mcpServers ?? [:]).sorted(by: { $0.key < $1.key }) {
                rows.append(makeInfo(name: name, entry: entry, scope: .local, projectPath: path))
            }

            let disabled = Set(projectEntry?.disabledMcpjsonServers ?? [])
            let projectFile = readProjectMCPFile(projectRoot: path)
            for (name, entry) in (projectFile?.mcpServers ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard !disabled.contains(name) else { continue }
                rows.append(makeInfo(name: name, entry: entry, scope: .project, projectPath: path))
            }
        }

        return rows
    }

    /// Resolve one server by name. Precedence matches the CLI: Local > Project > User.
    /// When `projectPath` is nil, scan every project in `~/.claude.json` for a match.
    func get(name: String, projectPath: String?) async throws -> MCPServerDetail {
        let root = readClaudeRoot()

        let candidatePaths: [String]
        if let projectPath, !projectPath.isEmpty {
            candidatePaths = [projectPath]
        } else {
            candidatePaths = (root?.projects?.keys.sorted() ?? [])
        }

        for path in candidatePaths {
            if let entry = root?.projects?[path]?.mcpServers?[name] {
                return makeDetail(name: name, entry: entry, scope: .local, projectPath: path)
            }
            let disabled = Set(root?.projects?[path]?.disabledMcpjsonServers ?? [])
            if !disabled.contains(name),
               let entry = readProjectMCPFile(projectRoot: path)?.mcpServers?[name] {
                return makeDetail(name: name, entry: entry, scope: .project, projectPath: path)
            }
        }

        if let entry = root?.mcpServers?[name] {
            return makeDetail(name: name, entry: entry, scope: .user, projectPath: nil)
        }

        throw MCPError.parseFailure("MCP server '\(name)' not found in any scope")
    }

    /// Lookup using known scope + project hints (from an existing `MCPServerInfo` row).
    /// Falls back to the precedence-based `get` when hints don't resolve.
    func get(name: String, scope: MCPScope?, projectPath: String?) async throws -> MCPServerDetail {
        let root = readClaudeRoot()
        switch scope {
        case .user:
            if let entry = root?.mcpServers?[name] {
                return makeDetail(name: name, entry: entry, scope: .user, projectPath: nil)
            }
        case .local:
            if let projectPath, let entry = root?.projects?[projectPath]?.mcpServers?[name] {
                return makeDetail(name: name, entry: entry, scope: .local, projectPath: projectPath)
            }
        case .project:
            if let projectPath,
               let entry = readProjectMCPFile(projectRoot: projectPath)?.mcpServers?[name] {
                return makeDetail(name: name, entry: entry, scope: .project, projectPath: projectPath)
            }
        case .none:
            break
        }
        return try await get(name: name, projectPath: projectPath)
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
    func probe(name: String, projectPath: String?) async -> MCPProbeResult {
        do {
            let detail = try await get(name: name, projectPath: projectPath)
            return await probe(detail: detail)
        } catch {
            return MCPProbeResult(ok: false, error: error.localizedDescription)
        }
    }

    /// Probe an existing server identified by `MCPServerInfo` (carries scope + projectPath).
    /// Preferred over `probe(name:projectPath:)` when the row's origin is known.
    func probe(info: MCPServerInfo) async -> MCPProbeResult {
        do {
            let detail = try await get(name: info.name, scope: info.scope, projectPath: info.projectPath)
            return await probe(detail: detail)
        } catch {
            return MCPProbeResult(ok: false, error: error.localizedDescription)
        }
    }

    /// Probe a not-yet-saved spec (used during auto-probe on Save).
    func probe(spec: MCPServerSpec) async -> MCPProbeResult {
        let env = Dictionary(uniqueKeysWithValues: spec.env.map { ($0.key, $0.value) })
        let headers = Dictionary(uniqueKeysWithValues: spec.headers.map { ($0.key, $0.value) })
        let detail = MCPServerDetail(
            name: spec.name.isEmpty ? "(untitled)" : spec.name,
            scope: .local,
            transport: spec.transport,
            url: spec.transport == .stdio ? nil : spec.url,
            command: spec.transport == .stdio ? spec.command : nil,
            args: spec.args,
            env: env,
            headers: headers
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

    // MARK: - On-disk config

    /// Minimal mirror of the `~/.claude.json` shape we care about. Anything
    /// missing or malformed degrades to `nil` and is treated as "no servers".
    private struct ClaudeRootConfig: Decodable {
        var mcpServers: [String: ServerEntry]?
        var projects: [String: ProjectEntry]?
    }

    private struct ProjectEntry: Decodable {
        var mcpServers: [String: ServerEntry]?
        var enabledMcpjsonServers: [String]?
        var disabledMcpjsonServers: [String]?
    }

    private struct ProjectMCPFile: Decodable {
        var mcpServers: [String: ServerEntry]?
    }

    private struct ServerEntry: Decodable {
        var type: String?
        var url: String?
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var headers: [String: String]?
    }

    private func claudeRootPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
    }

    private func projectMCPPath(_ projectRoot: String) -> String {
        (projectRoot as NSString).appendingPathComponent(".mcp.json")
    }

    private func readClaudeRoot() -> ClaudeRootConfig? {
        guard let data = FileManager.default.contents(atPath: claudeRootPath()) else { return nil }
        return try? JSONDecoder().decode(ClaudeRootConfig.self, from: data)
    }

    private func readProjectMCPFile(projectRoot: String) -> ProjectMCPFile? {
        guard let data = FileManager.default.contents(atPath: projectMCPPath(projectRoot)) else {
            return nil
        }
        return try? JSONDecoder().decode(ProjectMCPFile.self, from: data)
    }

    private func transport(from entry: ServerEntry) -> MCPTransport {
        switch entry.type?.lowercased() {
        case "http": return .http
        case "sse":  return .sse
        default:     return .stdio
        }
    }

    private func endpoint(from entry: ServerEntry) -> String {
        switch transport(from: entry) {
        case .http, .sse:
            return entry.url ?? ""
        case .stdio:
            let cmd = entry.command ?? ""
            let args = entry.args ?? []
            return ([cmd] + args).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private func makeInfo(name: String, entry: ServerEntry, scope: MCPScope, projectPath: String?) -> MCPServerInfo {
        MCPServerInfo(
            name: name,
            transport: transport(from: entry),
            endpoint: endpoint(from: entry),
            status: .unknown,
            scope: scope,
            projectPath: projectPath
        )
    }

    private func makeDetail(name: String, entry: ServerEntry, scope: MCPScope, projectPath: String?) -> MCPServerDetail {
        let t = transport(from: entry)
        return MCPServerDetail(
            name: name,
            scope: scope,
            transport: t,
            url: (t == .stdio) ? nil : entry.url,
            command: (t == .stdio) ? entry.command : nil,
            args: entry.args ?? [],
            env: entry.env ?? [:],
            headers: entry.headers ?? [:],
            projectPath: projectPath
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
            let (initData, initResp, sid) = try await postMCP(
                url: baseURL,
                body: initializeRequest(id: 1),
                sessionID: nil,
                headers: detail.headers
            )
            sessionID = sid
            if let http = initResp as? HTTPURLResponse, http.statusCode == 401 {
                return MCPProbeResult(ok: false, error: "401 Unauthorized — server requires authentication.")
            }
            let (serverName, serverVersion) = parseInitializeResponse(extractJSON(initData))

            _ = try? await postMCP(
                url: baseURL,
                body: initializedNotification(),
                sessionID: sessionID,
                headers: detail.headers
            )

            let (toolsData, _, _) = try await postMCP(
                url: baseURL,
                body: toolsListRequest(id: 2),
                sessionID: sessionID,
                headers: detail.headers
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
        sessionID: String?,
        headers: [String: String] = [:]
    ) async throws -> (Data, URLResponse, String?) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in headers where !key.isEmpty {
            req.setValue(value, forHTTPHeaderField: key)
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
