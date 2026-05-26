import Foundation
import Network
import RxCodeCore
import os

/// Hosts a local MCP server that polyfills missing editor capabilities for
/// agents whose native toolset lacks them (currently: ACP's `ask_user` /
/// `todos`), and exposes always-IDE-only introspection (running jobs,
/// thread history, usage) to every backend.
///
/// Agents speak to the server by running `nc 127.0.0.1 <port>` as their MCP
/// stdio command. The actor owns one parent `NWListener` per allocated
/// session (each on its own port) so the same agent process can't cross
/// session boundaries; releasing the session shuts that listener down.
actor IDEMCPServer {

    // MARK: - Constants

    private static let basePort: UInt16 = 19847
    private static let maxPort: UInt16 = 19946
    private static let messageMaxLength = 1 << 20  // 1 MiB
    private static let logger = Logger(subsystem: "com.claudework", category: "IDEMCPServer")

    // MARK: - Session State

    /// One allocated listener per RxCode session. Created on
    /// `allocate(sessionKey:capabilities:)`, torn down on `release`.
    private struct Allocation {
        let port: UInt16
        let listener: NWListener
        let sessionKey: String
        let capabilities: CapabilitySet
        var connections: Set<UUID> = []
    }
    private var allocations: [String: Allocation] = [:]
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
    func allocate(sessionKey: String, capabilities: CapabilitySet) async -> UInt16? {
        if let existing = allocations[sessionKey] {
            return existing.port
        }
        for _ in 0..<(Self.maxPort - Self.basePort + 1) {
            let candidate = nextPort
            nextPort = nextPort == Self.maxPort ? Self.basePort : nextPort + 1
            if portIndex[candidate] != nil { continue }
            do {
                let listener = try makeListener(port: candidate)
                var alloc = Allocation(
                    port: candidate,
                    listener: listener,
                    sessionKey: sessionKey,
                    capabilities: capabilities
                )
                _ = alloc
                allocations[sessionKey] = Allocation(
                    port: candidate,
                    listener: listener,
                    sessionKey: sessionKey,
                    capabilities: capabilities
                )
                portIndex[candidate] = sessionKey
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    Task { await self.accept(connection: connection, port: candidate) }
                }
                listener.start(queue: .global(qos: .userInitiated))
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
        guard let alloc = allocations.removeValue(forKey: sessionKey) else { return }
        portIndex.removeValue(forKey: alloc.port)
        alloc.listener.cancel()
        Self.logger.info("[IDE] released port \(alloc.port) for session=\(sessionKey, privacy: .public)")
    }

    // MARK: - Listener

    private func makeListener(port: UInt16) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
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
        let id = UUID()
        allocations[sessionKey]?.connections.insert(id)
        connection.stateUpdateHandler = { state in
            Self.logger.info("[IDE.conn] conn=\(id.uuidString.prefix(8), privacy: .public) session=\(sessionKey, privacy: .public) state=\(String(describing: state), privacy: .public)")
        }
        connection.start(queue: .global(qos: .userInitiated))
        Self.logger.info("[IDE] accepted connection id=\(id.uuidString, privacy: .public) on port \(port) session=\(sessionKey, privacy: .public)")

        await runMCP(
            connection: connection,
            connectionId: id,
            sessionKey: sessionKey,
            capabilities: capabilities
        )

        connection.cancel()
        allocations[sessionKey]?.connections.remove(id)
        Self.logger.info("[IDE] closed connection id=\(id.uuidString, privacy: .public)")
    }

    // MARK: - MCP Protocol Loop

    private func runMCP(
        connection: NWConnection,
        connectionId: UUID,
        sessionKey: String,
        capabilities: CapabilitySet
    ) async {
        var pendingBuffer = Data()
        var chunkCount = 0
        while true {
            // Drain any complete lines already buffered.
            while let newline = pendingBuffer.firstIndex(of: 0x0A) {
                let lineData = pendingBuffer[pendingBuffer.startIndex..<newline]
                pendingBuffer.removeSubrange(pendingBuffer.startIndex...newline)
                if lineData.isEmpty { continue }
                await processLine(
                    data: lineData,
                    connection: connection,
                    sessionKey: sessionKey,
                    capabilities: capabilities,
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
        sessionKey: String,
        capabilities: CapabilitySet,
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
            await reply(
                id: id!,
                result: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [
                        "tools": [String: Any]()
                    ],
                    "serverInfo": [
                        "name": "rxcode-ide",
                        "version": "1"
                    ]
                ],
                on: connection
            )
            Self.logger.info("[IDE.sent] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) reply=initialize")

        case "tools/list":
            let tools = await currentTools(sessionKey: sessionKey, capabilities: capabilities)
            await reply(
                id: id!,
                result: ["tools": tools.map(Self.toolDescriptor)],
                on: connection
            )
            Self.logger.info("[IDE.sent] conn=\(connTag, privacy: .public) session=\(sessionKey, privacy: .public) reply=tools/list count=\(tools.count)")

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let argsValue = JSONValue.fromAny(arguments)
            let callStart = Date()
            do {
                let handler = self.handler
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

    private func currentTools(sessionKey: String, capabilities: CapabilitySet) async -> [IDETool] {
        if let handler {
            return await handler.ideAvailableTools(forSession: sessionKey)
        }
        return IDEToolRegistry.tools(for: capabilities)
    }

    // MARK: - Reply

    private func reply(id: Any, result: Any, on connection: NWConnection) async {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        _ = payload
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

    // MARK: - Helpers

    private static func toolDescriptor(_ tool: IDETool) -> [String: Any] {
        var descriptor: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.inputSchema.toAny() ?? [:]
        ]
        if let annotations = toolAnnotations(for: tool) {
            descriptor["annotations"] = annotations
        }
        return descriptor
    }

    private static func toolAnnotations(for tool: IDETool) -> [String: Any]? {
        let readOnlyTools: Set<String> = [
            "ide__get_running_jobs",
            "ide__get_job_output",
            "ide__get_projects",
            "ide__get_threads",
            "ide__get_thread_messages",
            "ide__get_thread_detail",
            "ide__memory_search",
            "ide__get_usage",
        ]

        guard readOnlyTools.contains(tool.name) else { return nil }
        return [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false,
        ]
    }

    /// Wrap a handler's `JSONValue` result in the MCP tool-call response
    /// envelope: a `content` array with `text` blocks. Handlers may either
    /// pass a string scalar (auto-wrapped) or the full object form.
    private static func wrapToolResult(_ value: JSONValue) -> [String: Any] {
        if case .object(let dict) = value, dict["content"] != nil {
            return value.toAny() as? [String: Any] ?? [:]
        }
        let text: String
        switch value {
        case .string(let s): text = s
        case .null: text = ""
        default:
            if
                let data = try? JSONSerialization.data(
                    withJSONObject: value.toAny() ?? [:],
                    options: [.prettyPrinted, .sortedKeys]
                ),
                let s = String(data: data, encoding: .utf8)
            {
                text = s
            } else {
                text = "\(value)"
            }
        }
        return [
            "content": [
                ["type": "text", "text": text]
            ]
        ]
    }

    private static func errorCode(for error: IDEToolError) -> Int {
        switch error {
        case .unknownTool:        return -32601
        case .invalidArguments:   return -32602
        case .notSupported:       return -32004
        case .handlerFailed:      return -32603
        }
    }

    private static func errorMessage(for error: IDEToolError) -> String {
        switch error {
        case .unknownTool(let n):      return "Unknown tool: \(n)"
        case .invalidArguments(let m): return "Invalid arguments: \(m)"
        case .notSupported(let m):     return "Not supported: \(m)"
        case .handlerFailed(let m):    return m
        }
    }
}

// MARK: - JSONValue <-> Any helpers

private extension JSONValue {
    static func fromAny(_ any: Any) -> JSONValue {
        if let s = any as? String { return .string(s) }
        if let b = any as? Bool { return .bool(b) }
        if let n = any as? NSNumber {
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

    func toAny() -> Any? {
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
