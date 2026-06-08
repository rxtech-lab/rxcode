import Foundation
import RxCodeCore
import os

// MARK: - MCPService

/// Manages RxCode-owned MCP server definitions and per-project activation.
///
/// RxCode is the source of truth. Provider-specific config is generated at
/// launch time for Claude Code and Codex instead of treating either CLI's
/// native config as authoritative.
actor MCPService {

    private let baseURL: URL
    private let claudeService: ClaudeService
    private let logger = Logger(subsystem: "com.claudework", category: "MCPService")

    init(baseURL: URL = AppSupport.bundleScopedURL, claudeService: ClaudeService) {
        self.baseURL = baseURL
        self.claudeService = claudeService
    }

    // MARK: - Errors

    enum MCPError: LocalizedError {
        case parseFailure(String)
        case probeTimeout
        case probeFailed(String)

        var errorDescription: String? {
            switch self {
            case .parseFailure(let detail): return "Could not parse MCP config: \(detail)"
            case .probeTimeout:             return "MCP server did not respond within the timeout."
            case .probeFailed(let detail):  return detail
            }
        }
    }

    // MARK: - List / Get

    func list(projectPath: String?) async throws -> [MCPServerInfo] {
        let config = try loadConfig()
        return config.servers
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { makeInfo(record: $0, projectPath: projectPath) }
    }

    /// Full server records sorted by name. Unlike `list`, this exposes the
    /// command/args/env/headers needed to render an editable form (e.g. on the
    /// mobile MCP screen).
    func globalRecords() async throws -> [MCPServerRecord] {
        try loadConfig().servers
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func get(name: String, projectPath: String?) async throws -> MCPServerDetail {
        guard let record = try loadConfig().servers.first(where: { $0.name == name }) else {
            throw MCPError.parseFailure("MCP server '\(name)' not found")
        }
        return makeDetail(record: record, projectPath: projectPath)
    }

    func get(name: String, scope: MCPScope?, projectPath: String?) async throws -> MCPServerDetail {
        try await get(name: name, projectPath: projectPath)
    }

    // MARK: - Mutations

    func add(spec: MCPServerSpec, scope: MCPScope, projectPath: String?) async throws {
        var config = try loadConfig()
        let name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MCPError.parseFailure("Server name is required.") }

        let env = Dictionary(uniqueKeysWithValues: spec.env.compactMap { kv -> (String, String)? in
            let key = kv.key.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : (key, kv.value)
        })
        let headers = Dictionary(uniqueKeysWithValues: spec.headers.compactMap { kv -> (String, String)? in
            let key = kv.key.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : (key, kv.value)
        })

        var record = MCPServerRecord(
            name: name,
            transport: spec.transport,
            url: spec.transport == .stdio ? nil : spec.url.trimmingCharacters(in: .whitespacesAndNewlines),
            command: spec.transport == .stdio ? spec.command.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            args: spec.args,
            env: env,
            headers: headers,
            isGloballyEnabled: true
        )

        if scope != .user, let projectPath, !projectPath.isEmpty {
            record.isGloballyEnabled = false
            record.projectOverrides[projectPath] = .enabled
        }

        if let index = config.servers.firstIndex(where: { $0.name == name }) {
            let existing = config.servers[index]
            record.projectOverrides = existing.projectOverrides.merging(record.projectOverrides) { _, new in new }
            if scope == .user {
                record.isGloballyEnabled = existing.isGloballyEnabled
            }
            config.servers[index] = record
        } else {
            config.servers.append(record)
        }

        try saveConfig(config)
    }

    func remove(name: String, scope: MCPScope) async throws {
        var config = try loadConfig()
        config.servers.removeAll { $0.name == name }
        try saveConfig(config)
    }

    func setGlobalEnabled(name: String, enabled: Bool) async throws {
        var config = try loadConfig()
        guard let index = config.servers.firstIndex(where: { $0.name == name }) else {
            throw MCPError.parseFailure("MCP server '\(name)' not found")
        }
        config.servers[index].isGloballyEnabled = enabled
        try saveConfig(config)
    }

    func setProjectOverride(name: String, projectPath: String, override: MCPProjectOverride) async throws {
        var config = try loadConfig()
        guard let index = config.servers.firstIndex(where: { $0.name == name }) else {
            throw MCPError.parseFailure("MCP server '\(name)' not found")
        }
        if override == .inherit {
            config.servers[index].projectOverrides.removeValue(forKey: projectPath)
        } else {
            config.servers[index].projectOverrides[projectPath] = override
        }
        try saveConfig(config)
    }

    // MARK: - Provider Config

    /// Write the `--mcp-config` JSON handed to the Claude CLI. If
    /// `bridgeCommand` is non-nil an extra `rxcode-ide` stdio server is added —
    /// the local MCP polyfill / introspection server that exposes IDE-only
    /// tools (cross-project chat, thread history, running jobs, usage).
    func writeClaudeConfig(
        projectPath: String?,
        bridgeCommand: (command: String, args: [String])? = nil
    ) async -> String? {
        do {
            let records = try enabledRecords(projectPath: projectPath)
            var servers = dictionaryForClaude(records)
            if let bridge = bridgeCommand {
                servers["rxcode-ide"] = [
                    "type": "stdio",
                    "command": bridge.command,
                    "args": bridge.args,
                ]
            }
            let data = try JSONSerialization.data(
                withJSONObject: ["mcpServers": servers],
                options: [.prettyPrinted, .sortedKeys]
            )
            return try writeGeneratedConfig(data: data, filename: "claude-mcp.json")
        } catch {
            logger.warning("Failed to write Claude MCP config: \(error.localizedDescription)")
            return nil
        }
    }

    /// Build the `mcpServers` array passed to ACP's `session/new` RPC.
    /// Disabled servers are filtered out. If `bridgeCommand` is non-nil an
    /// additional entry `rxcode-ide` is prepended — that's the local MCP
    /// polyfill server. HTTP/SSE entries are emitted using ACP's discriminated
    /// union shape and are later filtered against the agent's advertised MCP
    /// capabilities after `initialize`.
    func acpMCPServers(
        projectPath: String?,
        bridgeCommand: (command: String, args: [String])? = nil
    ) async -> [JSONValue] {
        var entries: [JSONValue] = []
        if let bridge = bridgeCommand {
            entries.append(.object([
                "name": .string("rxcode-ide"),
                "command": .string(bridge.command),
                "args": .array(bridge.args.map { .string($0) }),
                "env": .array([])
            ]))
        }
        do {
            let records = try enabledRecords(projectPath: projectPath)
            let userEntries: [JSONValue] = records
                .sorted { $0.name < $1.name }
                .compactMap { record -> JSONValue? in
                    acpMCPServerEntry(for: record)
                }
            entries.append(contentsOf: userEntries)
        } catch {
            logger.warning("Failed to build ACP MCP servers: \(error.localizedDescription)")
        }
        let names = entries.compactMap { $0["name"]?.stringValue }.joined(separator: ", ")
        logger.info("[ACP-MCP] built \(entries.count, privacy: .public) mcpServers entries for project=\(projectPath ?? "<nil>", privacy: .public) [\(names, privacy: .public)]")
        // Dump the full JSON payload so a comparison against a known-good
        // Python repro is one log line away.
        if let data = try? JSONEncoder().encode(JSONValue.array(entries)),
           let json = String(data: data, encoding: .utf8) {
            logger.info("[ACP-MCP] payload=\(json, privacy: .public)")
        }
        return entries
    }

    private func acpMCPServerEntry(for record: MCPServerRecord) -> JSONValue? {
        let headers: [JSONValue] = record.headers
            .sorted { $0.key < $1.key }
            .map { key, value in
                .object([
                    "name": .string(key),
                    "value": .string(value),
                ])
            }

        switch record.transport {
        case .stdio:
            let envPairs: [JSONValue] = record.env
                .sorted { $0.key < $1.key }
                .map { key, value in
                    .object([
                        "name": .string(key),
                        "value": .string(value),
                    ])
                }
            // IMPORTANT: do NOT add a `"type": "stdio"` field. Stdio is the
            // default ACP union member; `type` is only the discriminator for
            // HTTP and SSE entries.
            return .object([
                "name": .string(record.name),
                "command": .string(record.command ?? ""),
                "args": .array(record.args.map { .string($0) }),
                "env": .array(envPairs),
            ])
        case .http:
            guard let url = record.url, !url.isEmpty else { return nil }
            return .object([
                "name": .string(record.name),
                "type": .string("http"),
                "url": .string(url),
                "headers": .array(headers),
            ])
        case .sse:
            guard let url = record.url, !url.isEmpty else { return nil }
            return .object([
                "name": .string(record.name),
                "type": .string("sse"),
                "url": .string(url),
                "headers": .array(headers),
            ])
        }
    }

    /// Build the `-c` overrides handed to the Codex app-server child. If
    /// `bridgeCommand` is non-nil an extra `rxcode-ide` stdio MCP server is
    /// emitted — the local MCP polyfill / introspection server that exposes
    /// IDE-only tools (cross-project chat, thread history, running jobs,
    /// usage, durable memory).
    func codexConfigOverrides(
        projectPath: String?,
        bridgeCommand: (command: String, args: [String])? = nil
    ) async -> [String] {
        do {
            let config = try loadConfig()
            var pairs: [String] = []
            if let bridge = bridgeCommand {
                // Emit the full inline table — a partial override fails codex's
                // validation when the server isn't already defined in
                // ~/.codex/config.toml.
                let table = "{enabled=true,command=\(tomlString(bridge.command)),args=\(tomlArray(bridge.args))}"
                pairs += ["-c", "mcp_servers.rxcode-ide=\(table)"]
            }
            for record in config.servers.sorted(by: { $0.name < $1.name }) {
                // Always emit the full inline table. A bare `enabled=false`
                // override fails codex's validation ("invalid transport") when
                // the server isn't already defined in ~/.codex/config.toml.
                let key = "mcp_servers.\(tomlKey(record.name))"
                let enabled = record.isEnabled(for: projectPath)
                pairs += ["-c", "\(key)=\(tomlInlineTable(for: record, enabled: enabled))"]
            }
            return pairs
        } catch {
            logger.warning("Failed to build Codex MCP overrides: \(error.localizedDescription)")
            return []
        }
    }

    private func enabledRecords(projectPath: String?) throws -> [MCPServerRecord] {
        try loadConfig().servers.filter { $0.isEnabled(for: projectPath) }
    }

    // MARK: - Probe

    func probe(name: String, projectPath: String?) async -> MCPProbeResult {
        do {
            let detail = try await get(name: name, projectPath: projectPath)
            return await probe(detail: detail)
        } catch {
            return MCPProbeResult(ok: false, error: error.localizedDescription)
        }
    }

    func probe(info: MCPServerInfo) async -> MCPProbeResult {
        do {
            let detail = try await get(name: info.name, projectPath: info.projectPath)
            return await probe(detail: detail)
        } catch {
            return MCPProbeResult(ok: false, error: error.localizedDescription)
        }
    }

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

    // MARK: - RxCode Config

    private func configURL() -> URL {
        baseURL.appendingPathComponent("mcp.json")
    }

    private func generatedConfigDirectory() -> URL {
        baseURL.appendingPathComponent("GeneratedMCP", isDirectory: true)
    }

    private func loadConfig() throws -> MCPConfiguration {
        let url = configURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(MCPConfiguration.self, from: data)
        }
        let imported = importExistingConfigs()
        try saveConfig(imported)
        return imported
    }

    private func saveConfig(_ config: MCPConfiguration) throws {
        let url = configURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    private func writeGeneratedConfig(data: Data, filename: String) throws -> String {
        let dir = generatedConfigDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(filename)
        try data.write(to: path, options: .atomic)
        return path.path
    }

    private func makeInfo(record: MCPServerRecord, projectPath: String?) -> MCPServerInfo {
        MCPServerInfo(
            name: record.name,
            transport: record.transport,
            endpoint: endpoint(from: record),
            status: .unknown,
            scope: .user,
            projectPath: projectPath,
            isGloballyEnabled: record.isGloballyEnabled,
            projectOverride: record.projectOverride(for: projectPath),
            effectiveEnabled: record.isEnabled(for: projectPath)
        )
    }

    private func makeDetail(record: MCPServerRecord, projectPath: String?) -> MCPServerDetail {
        MCPServerDetail(
            name: record.name,
            scope: .user,
            transport: record.transport,
            url: record.transport == .stdio ? nil : record.url,
            command: record.transport == .stdio ? record.command : nil,
            args: record.args,
            env: record.env,
            headers: record.headers,
            projectPath: projectPath
        )
    }

    private func endpoint(from record: MCPServerRecord) -> String {
        switch record.transport {
        case .http, .sse:
            return record.url ?? ""
        case .stdio:
            let cmd = record.command ?? ""
            return ([cmd] + record.args).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    // MARK: - Imports

    private struct ClaudeRootConfig: Decodable {
        var mcpServers: [String: ServerEntry]?
        var projects: [String: ClaudeProjectEntry]?
    }

    private struct ClaudeProjectEntry: Decodable {
        var mcpServers: [String: ServerEntry]?
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

    private func importExistingConfigs() -> MCPConfiguration {
        var recordsByName: [String: MCPServerRecord] = [:]
        for record in importClaudeConfigs() + importCodexConfig() {
            recordsByName[record.name] = merge(recordsByName[record.name], with: record)
        }
        return MCPConfiguration(servers: recordsByName.values.sorted { $0.name < $1.name })
    }

    private func merge(_ existing: MCPServerRecord?, with incoming: MCPServerRecord) -> MCPServerRecord {
        guard var existing else { return incoming }
        existing.transport = incoming.transport
        existing.url = incoming.url
        existing.command = incoming.command
        existing.args = incoming.args
        existing.env = incoming.env
        existing.headers = incoming.headers
        existing.cwd = incoming.cwd
        existing.bearerTokenEnvVar = incoming.bearerTokenEnvVar
        existing.isGloballyEnabled = existing.isGloballyEnabled || incoming.isGloballyEnabled
        existing.projectOverrides.merge(incoming.projectOverrides) { _, new in new }
        return existing
    }

    private func importClaudeConfigs() -> [MCPServerRecord] {
        guard let root = readJSON(ClaudeRootConfig.self, from: claudeRootPath()) else { return [] }
        var records: [MCPServerRecord] = []

        for (name, entry) in root.mcpServers ?? [:] {
            records.append(record(name: name, entry: entry, isGloballyEnabled: true))
        }

        for (projectPath, project) in root.projects ?? [:] {
            for (name, entry) in project.mcpServers ?? [:] {
                var record = record(name: name, entry: entry, isGloballyEnabled: false)
                record.projectOverrides[projectPath] = .enabled
                records.append(record)
            }

            if let projectFile = readJSON(ProjectMCPFile.self, from: projectMCPPath(projectPath)) {
                let disabled = Set(project.disabledMcpjsonServers ?? [])
                for (name, entry) in projectFile.mcpServers ?? [:] {
                    var record = record(name: name, entry: entry, isGloballyEnabled: false)
                    record.projectOverrides[projectPath] = disabled.contains(name) ? .disabled : .enabled
                    records.append(record)
                }
            }
        }

        return records
    }

    private func importCodexConfig() -> [MCPServerRecord] {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var records: [MCPServerRecord] = []
        var currentName: String?
        var fields: [String: String] = [:]

        func flush() {
            guard let name = currentName else { return }
            let enabled = fields["enabled"].map { $0.trimmingCharacters(in: .whitespaces) != "false" } ?? true
            if let url = fields["url"]?.tomlUnquoted {
                records.append(MCPServerRecord(name: name, transport: .http, url: url, isGloballyEnabled: enabled))
            } else if let command = fields["command"]?.tomlUnquoted {
                let args = fields["args"]?.tomlArrayValues ?? []
                let cwd = fields["cwd"]?.tomlUnquoted
                records.append(MCPServerRecord(name: name, transport: .stdio, command: command, args: args, cwd: cwd, isGloballyEnabled: enabled))
            }
        }

        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[mcp_servers."), line.hasSuffix("]") {
                flush()
                let name = String(line.dropFirst("[mcp_servers.".count).dropLast())
                currentName = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                fields = [:]
            } else if currentName != nil, let equal = line.firstIndex(of: "=") {
                let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
                fields[key] = value
            }
        }
        flush()
        return records
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func claudeRootPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
    }

    private func projectMCPPath(_ projectRoot: String) -> String {
        (projectRoot as NSString).appendingPathComponent(".mcp.json")
    }

    private func record(name: String, entry: ServerEntry, isGloballyEnabled: Bool) -> MCPServerRecord {
        let transport = transport(from: entry)
        return MCPServerRecord(
            name: name,
            transport: transport,
            url: transport == .stdio ? nil : entry.url,
            command: transport == .stdio ? entry.command : nil,
            args: entry.args ?? [],
            env: entry.env ?? [:],
            headers: entry.headers ?? [:],
            isGloballyEnabled: isGloballyEnabled
        )
    }

    private func transport(from entry: ServerEntry) -> MCPTransport {
        switch entry.type?.lowercased() {
        case "http", "streamable_http": return .http
        case "sse": return .sse
        default: return .stdio
        }
    }

    // MARK: - Provider Serialization

    private func dictionaryForClaude(_ records: [MCPServerRecord]) -> [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: records.map { record in
            var entry: [String: Any] = ["type": record.transport.rawValue]
            switch record.transport {
            case .stdio:
                entry["command"] = record.command ?? ""
                if !record.args.isEmpty { entry["args"] = record.args }
                if !record.env.isEmpty { entry["env"] = record.env }
            case .http, .sse:
                entry["url"] = record.url ?? ""
                if !record.headers.isEmpty { entry["headers"] = record.headers }
            }
            return (record.name, entry)
        })
    }

    private func tomlInlineTable(for record: MCPServerRecord, enabled: Bool = true) -> String {
        var parts = ["enabled=\(enabled ? "true" : "false")"]
        switch record.transport {
        case .stdio:
            parts.append("command=\(tomlString(record.command ?? ""))")
            if !record.args.isEmpty {
                parts.append("args=\(tomlArray(record.args))")
            }
            if !record.env.isEmpty {
                parts.append("env=\(tomlDictionary(record.env))")
            }
            if let cwd = record.cwd, !cwd.isEmpty {
                parts.append("cwd=\(tomlString(cwd))")
            }
        case .http, .sse:
            parts.append("url=\(tomlString(record.url ?? ""))")
            if let bearer = record.bearerTokenEnvVar, !bearer.isEmpty {
                parts.append("bearer_token_env_var=\(tomlString(bearer))")
            }
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private func tomlKey(_ key: String) -> String {
        if key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            return key
        }
        return tomlString(key)
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func tomlArray(_ values: [String]) -> String {
        "[\(values.map(tomlString).joined(separator: ","))]"
    }

    private func tomlDictionary(_ values: [String: String]) -> String {
        let parts = values.keys.sorted().map { key in
            "\(tomlKey(key))=\(tomlString(values[key] ?? ""))"
        }
        return "{\(parts.joined(separator: ","))}"
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

        let initializeJSON = initializeRequest(id: 1)
        let initializedJSON = initializedNotification()
        let toolsListJSON = toolsListRequest(id: 2)

        let result = await withTimeout(seconds: 10) { [self] () -> MCPProbeResult in
            do {
                try Self.writeJSONRPC(initializeJSON, to: stdinHandle)
            } catch {
                return MCPProbeResult(ok: false, error: "stdin write failed: \(error.localizedDescription)")
            }

            guard let initReply = await Self.readJSONLine(from: stdoutHandle) else {
                return MCPProbeResult(ok: false, error: "No response to initialize.")
            }
            let (serverName, serverVersion) = self.parseInitializeResponse(initReply)

            do {
                try Self.writeJSONRPC(initializedJSON, to: stdinHandle)
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

    private func extractJSON(_ data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
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
                    "name": "RxCode",
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
              let tools = result["tools"] as? [[String: Any]] else {
            return []
        }
        return tools.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return MCPTool(name: name, description: dict["description"] as? String)
        }
    }

    private nonisolated static func writeJSONRPC(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    private nonisolated static func readJSONLine(from handle: FileHandle) async -> [String: Any]? {
        await Task.detached {
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first else {
                return nil
            }
            let lineData = Data(String(line).utf8)
            return (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
        }.value
    }

    private func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

private extension String {
    nonisolated var tomlUnquoted: String {
        var value = trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    nonisolated var tomlArrayValues: [String]? {
        let value = trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        let body = value.dropFirst().dropLast()
        return body
            .split(separator: ",")
            .map { String($0).tomlUnquoted }
            .filter { !$0.isEmpty }
    }
}
