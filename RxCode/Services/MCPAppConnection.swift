import Foundation
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

    init(detail: MCPServerDetail) { self.detail = detail }

    deinit {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
    }

    func load(toolName: String) async throws -> MCPAppResource? {
        _ = try await rpc("initialize", params: .object([
            "protocolVersion": .string("2025-11-25"),
            "capabilities": .object(["extensions": .object([
                "io.modelcontextprotocol/ui": .object(["mimeTypes": .array([.string("text/html;profile=mcp-app")])])
            ])]),
            "clientInfo": .object(["name": .string("RxCode"), "version": .string("1")])
        ]))
        try await notify("notifications/initialized")
        var cursor: JSONValue?
        repeat {
            let page = try await rpc("tools/list", params: cursor.map { .object(["cursor": $0]) } ?? .object([:]))
            tools += page["tools"]?.arrayValue ?? []
            cursor = page["nextCursor"]
        } while cursor?.stringValue != nil && tools.count < 10_000
        guard let tool = tools.first(where: { $0["name"]?.stringValue == toolName }),
              let uri = MCPAppResource.resourceURI(in: tool) else { return nil }
        let read = try await rpc("resources/read", params: .object(["uri": .string(uri)]))
        guard let content = read["contents"]?.arrayValue?.first(where: {
            $0["uri"]?.stringValue == uri && $0["mimeType"]?.stringValue == "text/html;profile=mcp-app"
        }) else { throw failure("The MCP App resource is missing or has an unsupported MIME type.") }
        let html = content["text"]?.stringValue ?? content["blob"]?.stringValue
            .flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        guard let html, html.utf8.count <= 5_000_000 else { throw failure("The MCP App resource is invalid or too large.") }
        // A stricter policy than a listing-level default is permitted. No undeclared access is granted.
        let policy = MCPAppResource.contentSecurityPolicy(meta: content["_meta"]?["ui"])
        let document = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + html
        return MCPAppResource(html: document, tool: tool) { [self] method, params in
            try await appRequest(method, params: params)
        }
    }

    private func appRequest(_ method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "tools/list":
            return .object(["tools": .array(tools.filter(MCPAppResource.permitsAppCall))])
        case "tools/call":
            guard let name = params["name"]?.stringValue,
                  let tool = tools.first(where: { $0["name"]?.stringValue == name }),
                  MCPAppResource.permitsAppCall(tool) else { throw failure("The App cannot call this tool.") }
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
        let data = try JSONEncoder().encode(message)
        if detail.transport == .stdio {
            if process == nil { try startProcess() }
            try input?.write(contentsOf: data + Data([10]))
            if !expectsResponse { return .null }
            guard let output, let process else { throw failure("MCP process is unavailable.") }
            let requestID = message["id"]
            // Bound blocking pipe reads by terminating a non-responsive child.
            let timeout = Task.detached {
                try await Task.sleep(for: .seconds(30))
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
                        guard !chunk.isEmpty, buffer.count < 10_000_000 else { throw failure("MCP App connection closed or timed out.") }
                        buffer.append(chunk)
                    }
                }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        }
        guard let url = detail.url.flatMap(URL.init(string:)) else { throw failure("Missing MCP URL.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        for (key, value) in detail.headers { request.setValue(value, forHTTPHeaderField: key) }
        if let token = try await MCPOAuthService.shared.accessToken(for: url.absoluteString) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = data
        let (bytes, response) = try await MCPOAuthHTTP.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw failure("MCP App request failed. Test the connection or sign in again in Settings.")
        }
        sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
        if !expectsResponse { return .null }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            for try await line in bytes.lines where line.hasPrefix("data:") {
                let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                if let value = try? JSONDecoder().decode(JSONValue.self, from: payload), value["id"] == message["id"] { return value }
            }
            throw failure("The MCP server returned no App response.")
        }
        var responseData = Data()
        for try await byte in bytes {
            guard responseData.count < 10_000_000 else { throw failure("MCP App response is too large.") }
            responseData.append(byte)
        }
        return try JSONDecoder().decode(JSONValue.self, from: responseData)
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
