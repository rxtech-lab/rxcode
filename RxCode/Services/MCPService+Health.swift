import RxCodeCore

extension MCPService {
    func isAvailableToAgents(_ record: MCPServerRecord, projectPath: String?) -> Bool {
        record.isEnabled(for: projectPath)
            && failedConnections[record.name] != makeDetail(record: record, projectPath: nil)
    }

    func makeDetail(record: MCPServerRecord, projectPath: String?) -> MCPServerDetail {
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

    func endpoint(from record: MCPServerRecord) -> String {
        switch record.transport {
        case .http, .sse:
            return record.url ?? ""
        case .stdio:
            let cmd = record.command ?? ""
            return ([cmd] + record.args).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// Keep failures out of every provider config until a successful retest or
    /// configuration change. Draft connection tests must not affect saved servers.
    func recordProbeResult(_ result: MCPProbeResult, for detail: MCPServerDetail) async {
        guard let connection = try? await get(name: detail.name, projectPath: nil) else { return }
        let testedConnection = MCPServerDetail(
            name: detail.name, scope: .user, transport: detail.transport,
            url: detail.url, command: detail.command, args: detail.args,
            env: detail.env, headers: detail.headers
        )
        guard connection == testedConnection else { return }
        if result.ok {
            failedConnections.removeValue(forKey: detail.name)
        } else {
            failedConnections[detail.name] = connection
        }
    }
}
