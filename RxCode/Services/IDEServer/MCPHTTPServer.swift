import Foundation
import MCP
import Network
import os

/// Small loopback HTTP/1.1 adapter for the MCP Swift SDK's framework-agnostic
/// stateless Streamable HTTP transport.
actor MCPHTTPServer {
    typealias ToolProvider = @Sendable () async throws -> [MCP.Tool]
    typealias ToolCaller = @Sendable (String, [String: MCP.Value]) async throws -> MCP.CallTool.Result

    private static let headerLimit = 64 * 1024
    private static let bodyLimit = 1 << 20
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let logger = Logger(subsystem: "com.claudework", category: "MCPHTTPServer")

    let port: UInt16

    private let listener: NWListener
    private let transport: StatelessHTTPServerTransport
    private let server: Server
    private let toolProvider: ToolProvider
    private let toolCaller: ToolCaller
    private var connections: [UUID: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?

    init(port: UInt16, toolProvider: @escaping ToolProvider, toolCaller: @escaping ToolCaller) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        self.port = port
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.transport = StatelessHTTPServerTransport()
        self.server = Server(
            name: "rxcode",
            version: "1",
            capabilities: .init(tools: .init(listChanged: false))
        )
        self.toolProvider = toolProvider
        self.toolCaller = toolCaller
    }

    func start() async throws {
        let toolProvider = toolProvider
        let toolCaller = toolCaller

        await server.withMethodHandler(ListTools.self) { _ in
            let tools = try await toolProvider()
            return ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            try await toolCaller(parameters.name, parameters.arguments ?? [:])
        }
        try await server.start(transport: transport)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleListenerState(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection) }
        }
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() async {
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: CancellationError())
        }
        listener.cancel()
        let activeConnections = Array(connections.values)
        connections.removeAll()
        for connection in activeConnections {
            connection.cancel()
        }
        await server.stop()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            Self.logger.info("[RxCode MCP HTTP] ready on http://127.0.0.1:\(self.port)/mcp")
            startContinuation?.resume()
            startContinuation = nil
        case .failed(let error):
            Self.logger.error("[RxCode MCP HTTP] listener failed: \(error.localizedDescription, privacy: .public)")
            startContinuation?.resume(throwing: error)
            startContinuation = nil
        case .cancelled:
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) async {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global(qos: .userInitiated))

        await serve(connection)

        connection.cancel()
        connections.removeValue(forKey: id)
    }

    private func serve(_ connection: NWConnection) async {
        var buffer = Data()

        while true {
            do {
                while let parsed = try Self.parseRequest(from: &buffer) {
                    let response: MCP.HTTPResponse
                    if parsed.request.path != "/mcp" {
                        response = .error(statusCode: 404, .invalidRequest("Not Found"))
                    } else {
                        response = await transport.handleRequest(parsed.request)
                    }

                    try await send(response, closeConnection: parsed.closeConnection, on: connection)
                    if parsed.closeConnection { return }
                }

                let chunk = try await receiveChunk(from: connection)
                if chunk.isEmpty { return }
                buffer.append(chunk)
                if buffer.count > Self.headerLimit + Self.bodyLimit {
                    try await sendError(statusCode: 413, message: "Payload Too Large", on: connection)
                    return
                }
            } catch let error as HTTPParsingError {
                try? await sendError(statusCode: error.statusCode, message: error.message, on: connection)
                return
            } catch {
                Self.logger.debug("[RxCode MCP HTTP] connection ended: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private static func parseRequest(from buffer: inout Data) throws -> ParsedRequest? {
        guard let headerRange = buffer.range(of: headerTerminator) else {
            if buffer.count > headerLimit {
                throw HTTPParsingError(statusCode: 431, message: "Request Header Fields Too Large")
            }
            return nil
        }

        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPParsingError(statusCode: 400, message: "Invalid HTTP headers")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPParsingError(statusCode: 400, message: "Missing request line")
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/") else {
            throw HTTPParsingError(statusCode: 400, message: "Invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPParsingError(statusCode: 400, message: "Invalid HTTP header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if headers.contains(where: { $0.key.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }) {
            throw HTTPParsingError(statusCode: 501, message: "Transfer-Encoding is not supported")
        }
        let contentLengthValue = headers.first {
            $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame
        }?.value
        let contentLength: Int
        if let contentLengthValue {
            guard let parsedLength = Int(contentLengthValue), parsedLength >= 0 else {
                throw HTTPParsingError(statusCode: 400, message: "Invalid Content-Length")
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }
        guard contentLength <= bodyLimit else {
            throw HTTPParsingError(statusCode: 413, message: "Payload Too Large")
        }

        let bodyStart = headerRange.upperBound
        let requestEnd = bodyStart + contentLength
        guard buffer.count >= requestEnd else { return nil }

        let body = contentLength == 0 ? nil : Data(buffer[bodyStart..<requestEnd])
        buffer.removeSubrange(..<requestEnd)

        let method = String(requestParts[0])
        let rawTarget = String(requestParts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget
        let version = String(requestParts[2])
        let connectionHeader = headers.first {
            $0.key.caseInsensitiveCompare("Connection") == .orderedSame
        }?.value
        let closeConnection = connectionHeader?.caseInsensitiveCompare("close") == .orderedSame
            || (version == "HTTP/1.0" && connectionHeader?.caseInsensitiveCompare("keep-alive") != .orderedSame)

        return ParsedRequest(
            request: MCP.HTTPRequest(method: method, headers: headers, body: body, path: path),
            closeConnection: closeConnection
        )
    }

    private func receiveChunk(from connection: NWConnection) async throws -> Data {
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

    private func send(
        _ response: MCP.HTTPResponse,
        closeConnection: Bool,
        on connection: NWConnection
    ) async throws {
        guard case .stream = response else {
            let body = response.bodyData ?? Data()
            var headers = response.headers
            headers["Content-Length"] = String(body.count)
            headers["Connection"] = closeConnection ? "close" : "keep-alive"

            var responseText = "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(for: response.statusCode))\r\n"
            for (name, value) in headers.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                responseText += "\(name): \(value)\r\n"
            }
            responseText += "\r\n"

            var bytes = Data(responseText.utf8)
            bytes.append(body)
            try await send(bytes, on: connection)
            return
        }

        try await sendError(statusCode: 501, message: "Streaming responses are not enabled", on: connection)
    }

    private func sendError(statusCode: Int, message: String, on connection: NWConnection) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["error": message])
        let responseText = """
        HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """
        var bytes = Data(responseText.utf8)
        bytes.append(body)
        try await send(bytes, on: connection)
    }

    private func send(_ bytes: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        default: "Error"
        }
    }

    private struct ParsedRequest {
        let request: MCP.HTTPRequest
        let closeConnection: Bool
    }

    private struct HTTPParsingError: Error {
        let statusCode: Int
        let message: String
    }
}
