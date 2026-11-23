import Foundation
import JSONSchemaValidator
import RxCodeCore

/// A dedicated connection for an open App. It never re-executes the original chat tool.
actor MCPAppConnection {
    private let detail: MCPServerDetail
    private var sessionID: String?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var tools: [JSONValue] = []
    private var busy = false

    typealias Approval = @Sendable (MCPJSONUIActionContext) async throws -> Bool

    private let oauth: MCPOAuthService
    private let validateOrigin: @Sendable () async throws -> Void
    private let timeoutSeconds: Int
    private var initialized = false
    private var pendingActions = Set<String>()

    init(detail: MCPServerDetail, timeoutSeconds: Int = 30, oauth: MCPOAuthService = .shared,
         validateOrigin: @escaping @Sendable () async throws -> Void = {}) {
        self.detail = detail
        self.oauth = oauth
        self.validateOrigin = validateOrigin
        self.timeoutSeconds = timeoutSeconds
    }

    func nativeToolDescriptors() async throws -> [JSONValue] {
        try await connect()
        return tools
    }

    /// This entry point is for native clients such as the Xcode preview inspector.
    /// Embedded HTML continues through the visibility checks in appRequest.
    func callNativeTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        try await connect()
        guard tools.contains(where: { $0["name"]?.stringValue == name }) else { throw failure("MCP tool \(name) is unavailable.") }
        return try await rpc("tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)]))
    }

    deinit {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
    }

    /// Names of the server's tools that advertise an MCP App resource.
    func appToolNames() async throws -> Set<String> {
        try await connect()
        return Set(tools.compactMap { tool in
            MCPAppResource.resourceURI(in: tool) == nil ? nil : tool["name"]?.stringValue
        })
    }

    private func connect() async throws {
        guard !initialized else { return }
        _ = try await rpc("initialize", params: .object([
            "protocolVersion": .string("2025-11-25"),
            "capabilities": .object(["extensions": .object([
                "io.modelcontextprotocol/ui": .object(["mimeTypes": .array([.string(MCPJSONUIResource.mimeType), .string("text/html;profile=mcp-app")])])
            ])]),
            "clientInfo": .object(["name": .string("RxCode"), "version": .string("1")])
        ]))
        try await notify("notifications/initialized")
        tools = try await listTools()
        initialized = true
    }

    private func listTools() async throws -> [JSONValue] {
        var cursor: String?
        var seen = Set<String>()
        var result: [JSONValue] = []
        repeat {
            let page = try await rpc("tools/list", params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:]))
            guard let items = page["tools"]?.arrayValue, result.count + items.count <= 10_000 else {
                throw failure("Invalid MCP tool listing.")
            }
            result += items
            cursor = page["nextCursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted || seen.count > 1_000 { throw failure("Invalid MCP tool cursor.") }
        } while cursor != nil
        return result
    }

    func load(toolName: String, approve: @escaping Approval = { _ in false }) async throws -> MCPAppResource? {
        try await connect()
        guard let tool = tools.first(where: { $0["name"]?.stringValue == toolName }),
              let uri = MCPAppResource.resourceURI(in: tool) else { return nil }
        let read = try await rpc("resources/read", params: .object(["uri": .string(uri)]))
        let matches = read["contents"]?.arrayValue?.filter { $0["uri"]?.stringValue?.utf8.elementsEqual(uri.utf8) == true } ?? []
        if let content = matches.first(where: { $0["mimeType"]?.stringValue == MCPJSONUIResource.mimeType }) {
            let data = try resourceData(content, limit: MCPJSONUIResource.maxBytes)
            let document = try MCPJSONUIResource(data: data)
            return MCPAppResource(jsonUI: document, tool: tool) { [self] action in
                try await submit(action, owner: toolName, uri: uri, approve: approve)
            }
        }
        guard let content = matches.first(where: { $0["mimeType"]?.stringValue == "text/html;profile=mcp-app" }) else {
            throw failure("The MCP App resource is missing or has an unsupported MIME type.")
        }
        guard let html = String(data: try resourceData(content, limit: 5_000_000), encoding: .utf8) else {
            throw failure("Invalid MCP App HTML.")
        }
        let policy = MCPAppResource.contentSecurityPolicy(meta: content["_meta"]?["ui"])
        let document = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + html
        return MCPAppResource(html: document, tool: tool) { [self] method, params in
            try await appRequest(method, params: params, owner: toolName, uri: uri)
        }
    }

    private func resourceData(_ content: JSONValue, limit: Int) throws -> Data {
        if let text = content["text"]?.stringValue, text.utf8.count <= limit {
            return Data(text.utf8)
        }
        if content["text"] == nil, let blob = content["blob"]?.stringValue,
           blob.utf8.count <= ((limit + 2) / 3) * 4,
           let data = Data(base64Encoded: blob), data.count <= limit { return data }
        throw failure("The MCP App resource is invalid or too large.")
    }

    private func visibleTools(owner: String, uri: String) async throws -> [JSONValue] {
        let current = try await listTools()
        guard current.contains(where: { $0["name"]?.stringValue == owner && MCPAppResource.resourceURI(in: $0) == uri }) else {
            throw failure("This tool no longer provides the open MCP App.")
        }
        return current.filter(MCPAppResource.permitsAppCall)
    }

    private func checkedTool(name: String, arguments: [String: JSONValue], owner: String, uri: String) async throws -> JSONValue {
        let visible = try await visibleTools(owner: owner, uri: uri)
        guard !name.hasPrefix("mcp__"), let tool = visible.first(where: { $0["name"]?.stringValue == name }) else {
            throw failure("The App cannot call this tool.")
        }
        guard let schema = tool["inputSchema"]?.objectValue else { throw failure("Missing tool input schema.") }
        do {
            try JSONSchemaValidator.validate(arguments.mapValues(\.foundationObject), schema: schema.mapValues(\.foundationObject))
        } catch {
            throw failure("The App arguments do not match the tool’s current input schema.")
        }
        return tool
    }

    private func submit(_ action: MCPJSONUIActionContext, owner: String, uri: String, approve: Approval) async throws -> JSONValue {
        guard pendingActions.insert(action.actionID).inserted else { throw failure("This action is already pending.") }
        defer { pendingActions.remove(action.actionID) }
        let descriptor = try await checkedTool(name: action.toolName, arguments: action.arguments, owner: owner, uri: uri)
        guard try await approve(action) else { throw failure("The user declined this App action.") }
        try Task.checkCancellation()
        guard try await checkedTool(name: action.toolName, arguments: action.arguments, owner: owner, uri: uri) == descriptor else {
            throw failure("The tool changed while awaiting approval. Submit the form again.")
        }
        return try await rpc("tools/call", params: .object(["name": .string(action.toolName), "arguments": .object(action.arguments)]))
    }

    private func appRequest(_ method: String, params: JSONValue, owner: String, uri: String) async throws -> JSONValue {
        switch method {
        case "tools/list":
            return .object(["tools": .array(try await visibleTools(owner: owner, uri: uri))])
        case "tools/call":
            guard let name = params["name"]?.stringValue, params["arguments"] == nil || params["arguments"]?.objectValue != nil else {
                throw failure("Invalid App tool call.")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            _ = try await checkedTool(name: name, arguments: arguments, owner: owner, uri: uri)
            return try await rpc(method, params: params)
        default:
            throw failure("Unsupported MCP App request.")
        }
    }

    private func failure(_ text: String) -> MCPService.MCPError { .probeFailed(text) }

    private func rpc(_ method: String, params: JSONValue) async throws -> JSONValue {
        guard !busy else { throw failure("Another MCP App request is still running.") }
        busy = true
        defer { busy = false }
        nextID += 1
        let id = nextID
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "method": .string(method), "params": params
        ])
        let response = try await transport(message, expectsResponse: true)
        guard response["id"] == .number(Double(id)), response["error"] == nil,
              let result = response["result"] else { throw failure("The MCP server rejected the App request.") }
        return result
    }

    private func notify(_ method: String) async throws {
        _ = try await transport(.object(["jsonrpc": .string("2.0"), "method": .string(method)]), expectsResponse: false)
    }

    private func transport(_ message: JSONValue, expectsResponse: Bool) async throws -> JSONValue {
        try Task.checkCancellation()
        try await validateOrigin()
        let data = try JSONEncoder().encode(message)
        if detail.transport == .stdio {
            if process == nil { try startProcess() }
            try input?.write(contentsOf: data + Data([10]))
            if !expectsResponse { return .null }
            guard let output, let process else { throw failure("MCP process is unavailable.") }
            let requestID = message["id"]
            // Bound blocking pipe reads by terminating a non-responsive child.
            let timeout = Task.detached { [timeoutSeconds] in
                try await Task.sleep(for: .seconds(timeoutSeconds))
                if process.isRunning { process.terminate() }
            }
            defer { timeout.cancel() }
            return try await withTaskCancellationHandler {
                while true {
                    if let newline = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: newline)
                        buffer.removeSubrange(...newline)
                        if let value = try? JSONDecoder().decode(JSONValue.self, from: line), value["id"] == requestID {
                            return value
                        }
                    } else {
                        let chunk = await Task.detached { output.availableData }.value
                        guard !chunk.isEmpty, chunk.count <= 10_000_000 - buffer.count else { throw failure("MCP App connection closed or timed out.") }
                        buffer.append(chunk)
                    }
                }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        }
        guard let url = detail.url.flatMap(URL.init(string:)) else { throw failure("Missing MCP URL.") }
        try MCPOAuthService.validate(url)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        for (key, value) in detail.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = data
        let (bytes, response) = try await oauth.bytes(for: request, resource: url.absoluteString, beforeSend: validateOrigin)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw failure("MCP App request failed. Test the connection or sign in again in Settings.")
        }
        sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
        if !expectsResponse { return .null }
        if http.mimeType == "text/event-stream" {
            return try await eventResponse(bytes: bytes, requestID: message["id"])
        }
        var responseData = Data()
        for try await byte in bytes {
            guard responseData.count < 10_000_000 else { throw failure("MCP App response is too large.") }
            responseData.append(byte)
        }
        return try JSONDecoder().decode(JSONValue.self, from: responseData)
    }

    private func eventResponse(bytes: URLSession.AsyncBytes, requestID: JSONValue?) async throws -> JSONValue {
        var line = Data()
        var payload = Data()
        var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= 10_000_000 else { throw failure("MCP App response is too large.") }
            if byte != 10 {
                line.append(byte)
                continue
            }
            if line.last == 13 { line.removeLast() }
            if line.isEmpty {
                if let value = try? JSONDecoder().decode(JSONValue.self, from: payload), value["id"] == requestID { return value }
                payload.removeAll(keepingCapacity: true)
            } else if line.starts(with: "data:".utf8) {
                if !payload.isEmpty { payload.append(10) }
                payload.append(contentsOf: line.dropFirst(5))
            }
            line.removeAll(keepingCapacity: true)
        }
        throw failure("The MCP server returned no App response.")
    }

    private func startProcess() throws {
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = [detail.command ?? ""] + detail.args
        child.environment = ProcessInfo.processInfo.environment.merging(detail.env) { _, value in value }
        child.currentDirectoryURL = detail.projectPath.map { URL(fileURLWithPath: $0) }
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }
}
