import CoreFoundation
import Foundation
import MCP
import Network
import RxCodeCore
import os

nonisolated enum MCPServerTool: String, CaseIterable, Identifiable, Sendable {
    case memorySearch = "memory_search"
    case memoryCreate = "memory_create"
    case memoryUpdate = "memory_update"
    case memoryDelete = "memory_delete"

    var id: String { rawValue }

    var internalName: String {
        switch self {
        case .memorySearch: "ide__memory_search"
        case .memoryCreate: "ide__memory_add"
        case .memoryUpdate: "ide__memory_update"
        case .memoryDelete: "ide__memory_delete"
        }
    }

    var title: String {
        switch self {
        case .memorySearch: "Memory Search"
        case .memoryCreate: "Memory Create"
        case .memoryUpdate: "Memory Update"
        case .memoryDelete: "Memory Delete"
        }
    }

    var summary: String {
        switch self {
        case .memorySearch: "Search saved memories and retrieve matching preferences, facts, and decisions."
        case .memoryCreate: "Create new durable memories."
        case .memoryUpdate: "Update existing durable memories."
        case .memoryDelete: "Delete durable memories."
        }
    }
}

/// Hosts a local MCP server that polyfills missing editor capabilities for
/// agents whose native toolset lacks them (such as ACP's `todos`), and
/// exposes IDE questions and introspection (running jobs, thread history,
/// usage) to every backend.
///
/// Agents speak to the server by running `nc 127.0.0.1 <port>` as their MCP
/// stdio command. The actor owns one parent `NWListener` per allocated
/// session (each on its own port) so the same agent process can't cross
/// session boundaries; releasing the session shuts that listener down.
actor IDEMCPServer {

    // MARK: - Constants

    private static let basePort: UInt16 = 19847
    private static let maxPort: UInt16 = 19946
    static let memoryAPIDefaultPort = 19846
    static let memoryAPIEnabledDefaultsKey = "memoryMCPServerEnabled"
    static let memoryAPIPortDefaultsKey = "memoryMCPServerPort"
    static let exposedToolsDefaultsKey = "memoryMCPServerExposedTools"
    static let defaultExposedToolsValue = MCPServerTool.allCases.map(\.rawValue).joined(separator: ",")
    private static let messageMaxLength = 1 << 20  // 1 MiB
    private static let logger = Logger(subsystem: "com.claudework", category: "IDEMCPServer")
    private static let memoryAPISessionKey = "rxcode-mcp-server"

    private struct ToolExposure: Equatable, Sendable {
        let publicName: String
        let internalName: String
    }

    private struct SettingsHTTPServer {
        let port: UInt16
        let toolExposures: [ToolExposure]
        let server: MCPHTTPServer
    }

    // MARK: - Session State

    /// One allocated listener per RxCode session. Created on
    /// `allocate(sessionKey:capabilities:)`, torn down on `release`.
    private struct Allocation {
        let port: UInt16
        let listener: NWListener
        let sessionKey: String
        let capabilities: CapabilitySet
        let sessionHandler: (any IDEToolHandling)?
        var toolExposures: [ToolExposure]?
        var connections: [UUID: NWConnection] = [:]
    }
    private var allocations: [String: Allocation] = [:]
    private var startingListeners: [String: Task<UInt16?, Never>] = [:]
    private var settingsHTTPServer: SettingsHTTPServer?
    /// Port → sessionKey, so connection accept can resolve back.
    private var portIndex: [UInt16: String] = [:]
    private var nextPort: UInt16 = IDEMCPServer.basePort

    private weak var handler: (any IDEToolHandling)?

    init() {}

    func setHandler(_ handler: any IDEToolHandling) {
        self.handler = handler
    }

    // MARK: - Bridge Command

    /// Build the `(command, args)` an ACP agent should run as its MCP
    /// server child. The child is a perl one-liner that pipes its stdin to
    /// our TCP listener and our reply stream back to its stdout — perl is
    /// always at `/usr/bin/perl` on macOS and is far more reliable than
    /// BSD `nc` for bidirectional line-buffered forwarding (some `nc`
    /// builds close the write side on stdin EOF detection, which kills
    /// long-lived MCP sessions).
    static func bridgeCommand(forPort port: UInt16) -> (command: String, args: [String]) {
        let script = """
        use IO::Socket::INET;use IO::Select;$|=1;\
        my($h,$p)=@ARGV;my $s=IO::Socket::INET->new(PeerAddr=>$h,PeerPort=>$p,Proto=>"tcp")or die $!;\
        $s->autoflush(1);binmode STDIN;binmode STDOUT;binmode $s;\
        my $sel=IO::Select->new($s,\\*STDIN);\
        while(my @r=$sel->can_read){for my $fh(@r){my $buf;my $n=sysread($fh,$buf,4096);exit 0 unless $n;\
        if($fh==$s){syswrite(STDOUT,$buf);}else{syswrite($s,$buf);}}}
        """
        return ("/usr/bin/perl", ["-e", script, "127.0.0.1", String(port)])
    }

    // MARK: - Allocate / Release

    /// Reserve a port + listener for `sessionKey`. Returns the port that
    /// should be embedded in the MCP server `args` (`["127.0.0.1", "<port>"]`).
    /// If the session is already allocated, returns the existing port.
    func allocate(sessionKey: String, capabilities: CapabilitySet, handler: (any IDEToolHandling)? = nil) async -> UInt16? {
        if let existing = allocations[sessionKey] { return existing.port }
        if let starting = startingListeners[sessionKey] { return await starting.value }
        let starting = Task {
            defer { if !Task.isCancelled { startingListeners.removeValue(forKey: sessionKey) } }
            return await startListener(sessionKey: sessionKey, capabilities: capabilities, handler: handler)
        }
        startingListeners[sessionKey] = starting
        return await starting.value
    }

    private func startListener(sessionKey: String, capabilities: CapabilitySet, handler: (any IDEToolHandling)?) async -> UInt16? {
        for _ in 0..<(Self.maxPort - Self.basePort + 1) {
            guard !Task.isCancelled else { return nil }
            let candidate = nextPort
            nextPort = nextPort == Self.maxPort ? Self.basePort : nextPort + 1
            if portIndex[candidate] != nil { continue }
            do {
                let listener = try makeListener(port: candidate)
                portIndex[candidate] = sessionKey
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    Task { await self.accept(connection: connection, port: candidate) }
                }
                // Network.framework reports a busy port after start(), even when
                // creating the listener succeeded. Only hand out a bound port.
                let (readiness, signal) = AsyncStream<Bool>.makeStream()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: signal.yield(true)
                    case .failed, .waiting, .cancelled: signal.yield(false)
                    default: return
                    }
                    signal.finish()
                }
                listener.start(queue: .global(qos: .userInitiated))
                var events = readiness.makeAsyncIterator()
                guard await events.next() == true, !Task.isCancelled else {
                    listener.cancel()
                    portIndex.removeValue(forKey: candidate)
                    continue
                }
                allocations[sessionKey] = Allocation(
                    port: candidate,
                    listener: listener,
                    sessionKey: sessionKey,
                    capabilities: capabilities,
                    sessionHandler: handler,
                    toolExposures: nil
                )
                Self.logger.info("[IDE] allocated port \(candidate) for session=\(sessionKey, privacy: .public)")
                return candidate
            } catch {
                Self.logger.warning("[IDE] port \(candidate) unavailable: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        Self.logger.error("[IDE] no available port for session=\(sessionKey, privacy: .public)")
        return nil
    }

    func release(sessionKey: String) async {
        startingListeners.removeValue(forKey: sessionKey)?.cancel()
        guard let alloc = allocations.removeValue(forKey: sessionKey) else { return }
        portIndex.removeValue(forKey: alloc.port)
        alloc.listener.cancel()
        for connection in alloc.connections.values {
            connection.cancel()
        }
        Self.logger.info("[IDE] released port \(alloc.port) for session=\(sessionKey, privacy: .public) connections=\(alloc.connections.count)")
    }

    // MARK: - Settings-Managed MCP Server

    /// Starts or stops the process-wide MCP listener configured in Settings.
    /// It is bound to loopback and intentionally sits outside the ephemeral
    /// per-chat port range used by agent sessions.
    func configureMemoryAPI(enabled: Bool, port: Int, exposedTools: Set<MCPServerTool>) async throws {
        guard enabled else {
            await stopSettingsHTTPServer()
            return
        }
        guard Self.isValidMemoryAPIPort(port) else {
            throw MemoryAPIError.invalidPort(port)
        }
        let requestedPort = UInt16(port)
        let requestedToolExposures = Self.toolExposures(for: exposedTools)
        if let settingsHTTPServer,
           settingsHTTPServer.port == requestedPort,
           settingsHTTPServer.toolExposures == requestedToolExposures
        {
            return
        }
        await stopSettingsHTTPServer()
        guard portIndex[requestedPort] == nil else {
            throw MemoryAPIError.portUnavailable(port)
        }

        do {
            let httpServer = try MCPHTTPServer(
                port: requestedPort,
                toolProvider: { [weak self] in
                    guard let self else { return [] }
                    return try await self.mcpTools(exposedBy: requestedToolExposures)
                },
                toolCaller: { [weak self] name, arguments in
                    guard let self else {
                        throw MCPError.internalError("IDE handler is unavailable")
                    }
                    return try await self.callMCPTool(
                        name: name,
                        arguments: arguments,
                        exposedBy: requestedToolExposures
                    )
                }
            )
            do {
                try await httpServer.start()
            } catch {
                await httpServer.stop()
                throw error
            }
            settingsHTTPServer = SettingsHTTPServer(
                port: requestedPort,
                toolExposures: requestedToolExposures,
                server: httpServer
            )
            Self.logger.info("[RxCode MCP] Streamable HTTP listening on http://127.0.0.1:\(requestedPort)/mcp tools=\(requestedToolExposures.count)")
        } catch {
            await stopSettingsHTTPServer()
            throw MemoryAPIError.listenerFailed(port, error.localizedDescription)
        }
    }

    private func stopSettingsHTTPServer() async {
        guard let settingsHTTPServer else { return }
        self.settingsHTTPServer = nil
        await settingsHTTPServer.server.stop()
        Self.logger.info("[RxCode MCP] stopped Streamable HTTP server on port \(settingsHTTPServer.port)")
    }

    static func isValidMemoryAPIPort(_ port: Int) -> Bool {
        (1024...65_535).contains(port)
            && !(Int(basePort)...Int(maxPort)).contains(port)
    }

    static func exposedTools(from storedValue: String?) -> Set<MCPServerTool> {
        guard let storedValue else { return Set(MCPServerTool.allCases) }
        return Set(storedValue.split(separator: ",").compactMap { MCPServerTool(rawValue: String($0)) })
    }

    static func storedValue(for exposedTools: Set<MCPServerTool>) -> String {
        MCPServerTool.allCases
            .filter { exposedTools.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private static func toolExposures(for tools: Set<MCPServerTool>) -> [ToolExposure] {
        MCPServerTool.allCases.compactMap { tool in
            guard tools.contains(tool) else { return nil }
            return ToolExposure(publicName: tool.rawValue, internalName: tool.internalName)
        }
    }

    static func memoryAPIConfiguration(port: Int) -> String? {
        guard let endpoint = memoryAPIEndpoint(port: port) else { return nil }
        let value: [String: Any] = [
            "mcpServers": [
                "rxcode": [
                    "url": endpoint.absoluteString,
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func memoryAPIEndpoint(port: Int) -> URL? {
        guard isValidMemoryAPIPort(port) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/mcp")
    }

    // MARK: - Listener

    private func makeListener(port: UInt16) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        return try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    private func accept(connection: NWConnection, port: UInt16) async {
        guard let sessionKey = portIndex[port] else {
            connection.cancel()
            return
        }
        guard let capabilities = allocations[sessionKey]?.capabilities else {
            connection.cancel()
            return
        }
        let toolExposures = allocations[sessionKey]?.toolExposures
        let id = UUID()
        allocations[sessionKey]?.connections[id] = connection
        connection.stateUpdateHandler = { state in
            Self.logger.info("[IDE.conn] conn=\(id.uuidString.prefix(8), privacy: .public) session=\(sessionKey, privacy: .public) state=\(String(describing: state), privacy: .public)")
        }
        connection.start(queue: .global(qos: .userInitiated))
        Self.logger.info("[IDE] accepted connection id=\(id.uuidString, privacy: .public) on port \(port) session=\(sessionKey, privacy: .public)")

        await runMCP(
            connection: connection,
            connectionId: id,
            sessionKey: sessionKey,
            capabilities: capabilities,
            toolExposures: toolExposures
        )

        connection.cancel()
        allocations[sessionKey]?.connections.removeValue(forKey: id)
        Self.logger.info("[IDE] closed connection id=\(id.uuidString, privacy: .public)")
    }

    // MARK: - MCP Protocol Loop

    private func runMCP(
        connection: NWConnection,
        connectionId: UUID,
        sessionKey: String,
        capabilities: CapabilitySet,
        toolExposures: [ToolExposure]?
    ) async {
        var pendingBuffer = Data()
        var chunkCount = 0
        while true {
            // Drain any complete lines already buffered.
            while let newline = pendingBuffer.firstIndex(of: 0x0A) {
                let lineData = pendingBuffer[pendingBuffer.startIndex..<newline]
                pendingBuffer.removeSubrange(pendingBuffer.startIndex...newline)
                if lineData.isEmpty { continue }
                guard let allocation = allocations[sessionKey], allocation.connections[connectionId] != nil else {
                    Self.logger.info("[IDE.runMCP] revoked conn=\(connectionId.uuidString.prefix(8), privacy: .public) session=\(sessionKey, privacy: .public)")
                    return
                }
                await processLine(
                    data: lineData,
                    connection: connection,
                    handler: allocation.sessionHandler ?? handler,
                    sessionKey: sessionKey,
                    capabilities: capabilities,
                    toolExposures: toolExposures,
                    connectionId: connectionId
                )
            }
            // Read more bytes; bail when the peer half-closes.
            do {
                let chunk = try await readChunk(connection: connection)
                if chunk.isEmpty {
                    Self.logger.info("[IDE.runMCP] eof conn=\(connectionId.uuidString.prefix(8), privacy: .public) session=\(sessionKey, privacy: .public) chunks=\(chunkCount)")
                    return
                }
                chunkCount += 1
                pendingBuffer.append(chunk)
                if pendingBuffer.count > Self.messageMaxLength {
                    Self.logger.error("[IDE] message exceeded limit, closing connection id=\(connectionId.uuidString, privacy: .public)")
                    return
                }
            } catch {
                Self.logger.info("[IDE.runMCP] err conn=\(connectionId.uuidString.prefix(8), privacy: .public) session=\(sessionKey, privacy: .public) chunks=\(chunkCount): \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private func readChunk(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - Per-Message Dispatch

    private func processLine(
        data: Data.SubSequence,
        connection: NWConnection,
        handler: (any IDEToolHandling)?,
        sessionKey: String,
        capabilities: CapabilitySet,
        toolExposures: [ToolExposure]?,
        connectionId: UUID
    ) async {
        let bytes = Data(data)
        guard
            let raw = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]),
            let dict = raw as? [String: Any]
        else {
            Self.logger.warning("[IDE] malformed JSON-RPC line, dropping")
            return
        }
        let id = dict["id"]
        let method = dict["method"] as? String
        let params = dict["params"] as? [String: Any] ?? [:]

        // Notifications (no id) — we only care about `notifications/initialized`
        if id == nil {
            Self.logger.info("[IDE.recv] conn=\(connectionId.uuidString.prefix(8), privacy: .public) session=\(sessionKey, privacy: .public) notif=\(method ?? "<nil>", privacy: .public)")
            return
        }

        let connTag = connectionId.uuidString.prefix(8)
        let toolName = (params["name"] as? String) ?? ""
        Self.logger.info("[IDE.recv] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) method=\(method ?? "<nil>", privacy: .public) tool=\(toolName, privacy: .public)")

        switch method {
        case "initialize":
            let requestedVersion = params["protocolVersion"] as? String
            let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            let protocolVersion = requestedVersion.flatMap { supportedVersions.contains($0) ? $0 : nil }
                ?? "2024-11-05"
            await reply(
                id: id!,
                result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": [
                        "tools": [String: Any]()
                    ],
                    "serverInfo": [
                        "name": toolExposures == nil ? "rxcode-ide" : "rxcode",
                        "version": "1"
                    ]
                ],
                on: connection
            )
            Self.logger.info("[IDE.sent] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) reply=initialize")

        case "tools/list":
            let tools = await currentTools(
                sessionKey: sessionKey,
                capabilities: capabilities,
                toolExposures: toolExposures,
                handler: handler
            )
            await reply(
                id: id!,
                result: ["tools": tools.map(Self.toolDescriptor)],
                on: connection
            )
            Self.logger.info("[IDE.sent] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) reply=tools/list count=\(tools.count)")

        case "tools/call":
            let publicName = params["name"] as? String ?? ""
            let name: String
            if let toolExposures {
                guard let exposure = toolExposures.first(where: { $0.publicName == publicName }) else {
                    await replyError(id: id!, code: -32601, message: "Unknown tool: \(publicName)", on: connection)
                    return
                }
                name = exposure.internalName
            } else {
                name = publicName
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let argsValue = JSONValue.fromAny(arguments)
            let callStart = Date()
            do {
                guard let handler else {
                    throw IDEToolError.handlerFailed("IDE handler not attached")
                }
                Self.logger.info("[IDE.call→] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) tool=\(name, privacy: .public)")
                let result = try await handler.ideHandleToolCall(
                    name: name,
                    arguments: argsValue,
                    sessionKey: sessionKey
                )
                let elapsed = Date().timeIntervalSince(callStart)
                Self.logger.info("[IDE.call←] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) tool=\(name, privacy: .public) elapsed=\(String(format: "%.1f", elapsed))s")
                let payload = Self.wrapToolResult(result)
                await reply(id: id!, result: payload, on: connection)
                Self.logger.info("[IDE.sent] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) reply=tools/call tool=\(name, privacy: .public)")
            } catch let error as IDEToolError {
                let elapsed = Date().timeIntervalSince(callStart)
                Self.logger.warning("[IDE.call✗] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) tool=\(name, privacy: .public) elapsed=\(String(format: "%.1f", elapsed))s err=\(Self.errorMessage(for: error), privacy: .public)")
                await replyError(id: id!, code: Self.errorCode(for: error), message: Self.errorMessage(for: error), on: connection)
            } catch {
                let elapsed = Date().timeIntervalSince(callStart)
                Self.logger.warning("[IDE.call✗] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) tool=\(name, privacy: .public) elapsed=\(String(format: "%.1f", elapsed))s err=\(error.localizedDescription, privacy: .public)")
                await replyError(id: id!, code: -32603, message: error.localizedDescription, on: connection)
            }

        default:
            await replyError(id: id!, code: -32601, message: "Method not found: \(method ?? "<nil>")", on: connection)
        }
    }

    private func currentTools(
        sessionKey: String,
        capabilities: CapabilitySet,
        toolExposures: [ToolExposure]?,
        handler: (any IDEToolHandling)?
    ) async -> [IDETool] {
        let available: [IDETool]
        if let handler {
            available = await handler.ideAvailableTools(forSession: sessionKey)
        } else {
            available = IDEToolRegistry.tools(for: capabilities)
        }
        guard let toolExposures else { return available }
        let byName = Dictionary(uniqueKeysWithValues: available.map { ($0.name, $0) })
        return toolExposures.compactMap { exposure in
            guard let tool = byName[exposure.internalName] else { return nil }
            return IDETool(
                name: exposure.publicName,
                description: tool.description,
                visibility: tool.visibility,
                inputSchema: tool.inputSchema
            )
        }
    }

    private func mcpTools(exposedBy toolExposures: [ToolExposure]) async throws -> [MCP.Tool] {
        let tools = await currentTools(
            sessionKey: Self.memoryAPISessionKey,
            capabilities: [],
            toolExposures: toolExposures,
            handler: handler
        )
        return try tools.map(Self.mcpTool)
    }

    private func callMCPTool(
        name: String,
        arguments: [String: MCP.Value],
        exposedBy toolExposures: [ToolExposure]
    ) async throws -> MCP.CallTool.Result {
        guard let exposure = toolExposures.first(where: { $0.publicName == name }) else {
            throw MCPError.methodNotFound("Unknown tool: \(name)")
        }
        guard let handler else {
            throw MCPError.internalError("IDE handler is unavailable")
        }

        let encodedArguments = try JSONEncoder().encode(arguments)
        let decodedArguments = try JSONDecoder().decode([String: JSONValue].self, from: encodedArguments)
        do {
            let result = try await handler.ideHandleToolCall(
                name: exposure.internalName,
                arguments: .object(decodedArguments),
                sessionKey: Self.memoryAPISessionKey
            )
            return try Self.mcpCallResult(result)
        } catch let error as IDEToolError {
            switch error {
            case .unknownTool:
                throw MCPError.methodNotFound(Self.errorMessage(for: error))
            case .invalidArguments:
                throw MCPError.invalidParams(Self.errorMessage(for: error))
            case .notSupported:
                throw MCPError.serverError(code: -32004, message: Self.errorMessage(for: error))
            case .handlerFailed:
                throw MCPError.internalError(Self.errorMessage(for: error))
            }
        }
    }

    // MARK: - Reply

    private func reply(id: Any, result: Any, on connection: NWConnection) async {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        await send(json: body, on: connection)
    }

    private func replyError(id: Any, code: Int, message: String, on connection: NWConnection) async {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
        await send(json: body, on: connection)
    }

    private func send(json: [String: Any], on connection: NWConnection) async {
        guard
            JSONSerialization.isValidJSONObject(json),
            var bytes = try? JSONSerialization.data(withJSONObject: json, options: [])
        else {
            Self.logger.error("[IDE] failed to encode response, dropping")
            return
        }
        bytes.append(0x0A)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: bytes, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

private enum MemoryAPIError: LocalizedError {
    case invalidPort(Int)
    case portUnavailable(Int)
    case listenerFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Port \(port) is invalid. Use 1024–65535, excluding 19847–19946."
        case .portUnavailable(let port):
            return "Port \(port) is already in use by RxCode."
        case .listenerFailed(let port, let message):
            return "Could not start the memory MCP server on port \(port): \(message)"
        }
    }
}

// MARK: - JSONValue <-> Any helpers

extension JSONValue {
    nonisolated static func fromAny(_ any: Any) -> JSONValue {
        if let s = any as? String { return .string(s) }
        // Foundation also bridges numeric 0/1 to Bool. Only CFBoolean is a JSON Boolean.
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let arr = any as? [Any] {
            return .array(arr.map { Self.fromAny($0) })
        }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = Self.fromAny(v) }
            return .object(out)
        }
        return .null
    }

    nonisolated func toAny() -> Any? {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.toAny() ?? NSNull() }
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = v.toAny() ?? NSNull() }
            return out
        }
    }
}
