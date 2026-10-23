import Foundation
import RxCodeCore

nonisolated struct FlowcyTool: Codable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String?
    let inputSchema: JSONValue
    let annotations: JSONValue?
    var isReadOnly: Bool { annotations?["readOnlyHint"]?.boolValue == true || ["list_tasks", "query_issues", "query_pull_requests", "query_actions", "search_document", "get_document"].contains(name) }
}

enum FlowcyError: LocalizedError {
    case signIn, denied, transport(Int), protocolError, toolFailed, message(String)
    var errorDescription: String? {
        switch self {
        case .signIn: "Your account session is unavailable. Sign in to Flowcy again."
        case .denied: "Your account does not have permission for this operation."
        case .transport(let status): "Flowcy returned HTTP \(status). Try again."
        case .protocolError: "Flowcy returned an invalid protocol response."
        case .toolFailed: "The tool reported an error. Review its result before retrying."
        case .message(let message): message
        }
    }
}

/// Serialized Streamable HTTP connection. A connection is ready only after initialize and tools/list succeed.
actor FlowcyMCPClient {
    static let endpoint = URL(string: "https://www.flowcy.dev/api/v1/agent/tools")!
    /// Normalize the legacy apex host without forwarding credentials through a redirect.
    nonisolated static func transportURL(_ url: URL) -> URL {
        guard url.scheme == "https", url.host == "flowcy.dev", url.port == nil else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.host = "www.flowcy.dev"
        return parts.url!
    }
    private let endpoint: URL
    private let session: URLSession
    private let token: @Sendable (Bool) async throws -> String?
    private var sessionID: String?
    private var protocolVersion = "2025-11-25"
    private var initialized = false

    init(endpoint: URL = FlowcyMCPClient.endpoint, session: URLSession = .shared,
         token: @escaping @Sendable (Bool) async throws -> String? = { await RxAuthService.shared.accessToken(forceRefresh: $0) }) {
        self.endpoint = endpoint
        self.session = session
        self.token = token
    }

    func reset() { initialized = false; sessionID = nil }

    func discover() async throws -> [FlowcyTool] {
        initialized = false
        sessionID = nil
        let result = try await rpc("initialize", params: .object([
            "protocolVersion": .string(protocolVersion), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Flowcy iOS"), "version": .string("1")])
        ]))
        guard let version = result["protocolVersion"]?.stringValue,
              ["2025-11-25", "2025-06-18", "2025-03-26"].contains(version), result["capabilities"] != nil else { throw FlowcyError.protocolError }
        protocolVersion = version
        _ = try await rpc("notifications/initialized", params: .object([:]), notification: true)
        var tools: [FlowcyTool] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await rpc("tools/list", params: .object(cursor.map { ["cursor": .string($0)] } ?? [:]))
            guard let values = page["tools"]?.arrayValue else { throw FlowcyError.protocolError }
            tools += try values.map { try JSONDecoder().decode(FlowcyTool.self, from: JSONEncoder().encode($0)) }
            cursor = page["nextCursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted { throw FlowcyError.protocolError }
        } while cursor != nil
        initialized = true
        return tools
    }

    func call(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        guard initialized else { throw FlowcyError.message("Connect Flowcy Tools before sending a prompt.") }
        return try await rpc("tools/call", params: .object(["name": .string(name), "arguments": arguments]))
    }

    private func rpc(_ method: String, params: JSONValue, notification: Bool = false, refresh: Bool = false) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let bearer = try await token(refresh) else { throw FlowcyError.signIn }
        let id = UUID().uuidString
        var payload: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
        if !notification { payload["id"] = .string(id) }
        var request = URLRequest(url: Self.transportURL(endpoint), timeoutInterval: 65)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(JSONValue.object(payload))
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if method != "initialize" { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FlowcyError.protocolError }
        switch http.statusCode {
        case 401:
            if !refresh { return try await rpc(method, params: params, notification: notification, refresh: true) }
            initialized = false
            throw FlowcyError.signIn
        case 403: throw FlowcyError.denied
        case 404 where sessionID != nil: initialized = false; sessionID = nil; throw FlowcyError.message("The tools session expired. Reconnect and try again.")
        case 200..<300: break
        default: throw FlowcyError.transport(http.statusCode)
        }
        if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = value }
        if notification { return .null }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            var event = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.isEmpty {
                    if let result = try Self.response(event, id: id) { return result }
                    event = ""
                } else if line.hasPrefix("data:") {
                    event += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) + "\n"
                    if event.utf8.count > 4_000_000 { throw FlowcyError.protocolError }
                }
            }
            if let result = try Self.response(event, id: id) { return result }
        } else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 4_000_000 { throw FlowcyError.protocolError }
            }
            if let result = try Self.response(String(decoding: data, as: UTF8.self), id: id) { return result }
        }
        throw FlowcyError.protocolError
    }

    nonisolated static func response(_ text: String, id: String) throws -> JSONValue? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard value["id"]?.stringValue == id else { return nil }
        if value["error"] != nil { throw FlowcyError.protocolError }
        guard let result = value["result"] else { throw FlowcyError.protocolError }
        return result
    }
}

