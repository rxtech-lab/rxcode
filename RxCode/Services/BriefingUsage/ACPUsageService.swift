import Foundation
import SQLite3
import RxCodeCore

/// Credentials stay on this Mac. Only normalized usage snapshots leave this service.
actor ACPUsageService {
    static let shared = ACPUsageService()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    func fetch(client: ACPClientSpec, integration: UsageIntegration) async throws -> UsagePluginSnapshot {
        guard client.enabled, let provider = ACPUsageProvider.provider(for: client),
              provider.pluginID == integration.pluginID else { throw ACPUsageError.unavailable }
        let environment = environment(for: client)
        let token = try credential(provider: provider, environment: environment)
        return try await ACPUsageAPI.fetch(provider: provider, token: token, integration: integration, session: session)
    }

    private func environment(for client: ACPClientSpec) -> [String: String] {
        let launchEnvironment: [String: String]
        switch client.launch {
        case .binary(_, _, let env), .custom(_, _, let env), .npx(_, _, let env), .uvx(_, _, let env):
            launchEnvironment = env
        }
        return ProcessInfo.processInfo.environment.merging(launchEnvironment) { _, new in new }
            .merging(client.extraEnv) { _, new in new }
    }

    private func credential(provider: ACPUsageProvider, environment: [String: String]) throws -> String {
        switch provider {
        case .opencode:
            if let token = clean(environment["OPENCODE_API_KEY"]) { return token }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? home.appendingPathComponent(".local/share")
            let directory = dataHome.appendingPathComponent("opencode")
            let filename = environment["OPENCODE_DB"] ?? "opencode.db"
            let database = filename.hasPrefix("/") ? URL(fileURLWithPath: filename) : directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: database.path) {
                let result = try databaseCredential(at: database)
                if result.hasCredentialTable {
                    guard let token = result.token else { throw ACPUsageError.signIn(provider.title) }
                    return token
                }
            }
            let url = directory.appendingPathComponent("auth.json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = root["opencode-go"] as? [String: Any], account["type"] as? String == "api",
                  let token = clean(account["key"] as? String) else { throw ACPUsageError.signIn(provider.title) }
            return token
        case .antigravity:
            guard let stored = KeychainHelper.read(service: "gemini", account: "antigravity"),
                  var raw = String(data: stored, encoding: .utf8) else {
                throw ACPUsageError.signIn(provider.title)
            }
            let prefix = "go-keyring-base64:"
            if raw.hasPrefix(prefix) {
                guard let data = Data(base64Encoded: String(raw.dropFirst(prefix.count))),
                      let decoded = String(data: data, encoding: .utf8) else { throw ACPUsageError.signIn(provider.title) }
                raw = decoded
            }
            guard let data = raw.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ACPUsageError.signIn(provider.title)
            }
            let token = root["token"] as? [String: Any] ?? root
            guard let access = clean(token["access_token"] as? String) else { throw ACPUsageError.signIn(provider.title) }
            // The client owns refresh-token rotation. Re-read its login on each poll.
            if let expiry = token["expiry"] as? String,
               let date = ISO8601DateFormatter().date(from: expiry), date <= .now {
                throw ACPUsageError.signIn(provider.title)
            }
            return access
        }
    }

    private func databaseCredential(at url: URL) throws -> (hasCredentialTable: Bool, token: String?) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw ACPUsageError.signIn("OpenCode Go")
        }
        defer { sqlite3_close(database) }
        var tableQuery: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'credential'", -1, &tableQuery, nil) == SQLITE_OK else {
            throw ACPUsageError.signIn("OpenCode Go")
        }
        let tableStatus = sqlite3_step(tableQuery)
        sqlite3_finalize(tableQuery)
        if tableStatus == SQLITE_DONE { return (false, nil) }
        guard tableStatus == SQLITE_ROW else { throw ACPUsageError.signIn("OpenCode Go") }
        var statement: OpaquePointer?
        let sql = "SELECT integration_id, value FROM credential WHERE active = 1 AND integration_id IN ('opencode-go', 'opencode') ORDER BY CASE integration_id WHEN 'opencode-go' THEN 0 ELSE 1 END"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ACPUsageError.signIn("OpenCode Go") }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return (true, nil) }
        guard status == SQLITE_ROW,
              let id = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else {
            throw ACPUsageError.signIn("OpenCode Go")
        }
        let integration = String(cString: id)
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        // Multiple active credentials for one provider cannot be attributed safely.
        let nextStatus = sqlite3_step(statement)
        guard nextStatus == SQLITE_ROW || nextStatus == SQLITE_DONE else { throw ACPUsageError.signIn("OpenCode Go") }
        if nextStatus == SQLITE_ROW, let next = sqlite3_column_text(statement, 0), String(cString: next) == integration {
            throw ACPUsageError.signIn("OpenCode Go")
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (true, nil) }
        if integration == "opencode-go", value["type"] as? String == "key" { return (true, clean(value["key"] as? String)) }
        if value["type"] as? String == "oauth", let expiry = value["expires"] as? Double,
           expiry / 1000 > Date.now.timeIntervalSince1970 { return (true, clean(value["access"] as? String)) }
        return (true, nil)
    }

    private func clean(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return value
    }
}

enum ACPUsageError: LocalizedError {
    case unavailable, signIn(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "This ACP client is disabled or no longer installed."
        case .signIn(let title): "Open \(title) and sign in again to refresh usage."
        }
    }
}
