import Foundation
import RxCodeCore
import os

extension MCPService {
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

    func importExistingConfigs() -> MCPConfiguration {
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

    func dictionaryForClaude(_ records: [MCPServerRecord]) -> [String: [String: Any]] {
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

    func tomlInlineTable(for record: MCPServerRecord, enabled: Bool = true) -> String {
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
            if !record.headers.isEmpty {
                parts.append("http_headers=\(tomlDictionary(record.headers))")
            }
            if record.headers["Authorization"] == nil, let bearer = record.bearerTokenEnvVar, !bearer.isEmpty {
                parts.append("bearer_token_env_var=\(tomlString(bearer))")
            }
        }
        return "{\(parts.joined(separator: ","))}"
    }

    func tomlKey(_ key: String) -> String {
        if key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            return key
        }
        return tomlString(key)
    }

    func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    func tomlArray(_ values: [String]) -> String {
        "[\(values.map(tomlString).joined(separator: ","))]"
    }

    private func tomlDictionary(_ values: [String: String]) -> String {
        let parts = values.keys.sorted().map { key in
            "\(tomlKey(key))=\(tomlString(values[key] ?? ""))"
        }
        return "{\(parts.joined(separator: ","))}"
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
