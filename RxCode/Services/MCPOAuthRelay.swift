import Foundation
import Network

/// Keeps OAuth owned by RxCode throughout a CLI session, rather than exporting
/// an expiring bearer token in provider configuration. Each relay is restricted
/// to one upstream origin and an unguessable local route.
actor MCPOAuthRelay {
    private let resource: URL
    private let headers: [String: String]
    private let oauth: MCPOAuthService
    private let prefix = "/" + UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var startups: [CheckedContinuation<URL, Error>] = []
    private var localOrigin: String?
    private var connections: [UUID: NWConnection] = [:]

    init(resource: URL, headers: [String: String], oauth: MCPOAuthService = .shared) {
        self.resource = resource
        self.headers = headers
        self.oauth = oauth
    }

    deinit { listener?.cancel() }

    func start() async throws -> URL {
        if let localOrigin { return localURL(resource, origin: localOrigin) }
        if listener != nil {
            return try await withCheckedThrowingContinuation { startups.append($0) }
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation {
            startups.append($0)
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        localOrigin = nil
        for startup in startups { startup.resume(throwing: CancellationError()) }
        startups.removeAll()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port else { return }
            let origin = "http://127.0.0.1:\(port.rawValue)"
            localOrigin = origin
            for startup in startups { startup.resume(returning: localURL(resource, origin: origin)) }
            startups.removeAll()
        case .failed(let error):
            for startup in startups { startup.resume(throwing: error) }
            startups.removeAll()
            stop()
        case .cancelled:
            for startup in startups { startup.resume(throwing: CancellationError()) }
            startups.removeAll()
        default: break
        }
    }

    private func localURL(_ upstream: URL, origin: String) -> URL {
        let parts = URLComponents(url: upstream, resolvingAgainstBaseURL: false)!
        return URL(string: origin + prefix + (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath)
                   + (parts.percentEncodedQuery.map { "?" + $0 } ?? ""))!
    }

    private func accept(_ connection: NWConnection) async {
        guard connections.count < 128 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global(qos: .userInitiated))
        // Bound incomplete request headers/bodies without limiting live SSE streams.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            connection.cancel()
        }
        defer {
            timeout.cancel()
            connection.cancel()
            connections.removeValue(forKey: id)
        }
        var startedResponse = false
        do {
            let request = try await receiveRequest(connection)
            timeout.cancel()
            let (bytes, response) = try await oauth.bytes(for: request, resource: resource.absoluteString)
            defer {
                connection.stateUpdateHandler = nil
                bytes.task.cancel()
            }
            connection.stateUpdateHandler = { state in
                if case .cancelled = state { bytes.task.cancel() }
                if case .failed = state { bytes.task.cancel() }
            }
            guard let http = response as? HTTPURLResponse else { throw RelayError.invalid }
            var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nConnection: close\r\n"
            // URLSession decodes transfer/content encoding. Close delimits the output.
            let excluded = Self.hopHeaders.union(["content-length", "content-encoding", "set-cookie", "www-authenticate", "location"])
            for (key, value) in http.allHeaderFields {
                let name = String(describing: key)
                let value = String(describing: value)
                if !excluded.contains(name.lowercased()), !value.contains("\r"), !value.contains("\n") {
                    head += "\(name): \(value)\r\n"
                }
            }
            try await send(Data((head + "\r\n").utf8), on: connection)
            startedResponse = true
            if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
                // Legacy SSE announces its POST endpoint in an event. Keep that
                // endpoint behind the relay too, preserving the upstream query.
                var line = Data()
                var endpointEvent = false
                for try await byte in bytes {
                    line.append(byte)
                    guard line.count <= 10_000_000 else { throw RelayError.invalid }
                    if byte == 10 {
                        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
                        if text.hasPrefix("event:") {
                            endpointEvent = text.dropFirst(6).trimmingCharacters(in: .whitespaces) == "endpoint"
                        }
                        if endpointEvent, text.hasPrefix("data:") {
                            let value = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            guard let endpoint = URL(string: value, relativeTo: resource)?.absoluteURL,
                                  endpoint.scheme == resource.scheme, endpoint.host == resource.host,
                                  endpoint.port == resource.port, endpoint.user == nil, endpoint.password == nil,
                                  endpoint.fragment == nil, let origin = localOrigin else { throw RelayError.invalid }
                            line = Data("data: \(localURL(endpoint, origin: origin).absoluteString)\n".utf8)
                        }
                        try await send(line, on: connection)
                        line.removeAll(keepingCapacity: true)
                        if text.isEmpty { endpointEvent = false }
                    }
                }
                if !line.isEmpty { try await send(line, on: connection) }
            } else {
                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 16_384 {
                        try await send(chunk, on: connection)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { try await send(chunk, on: connection) }
            }
        } catch {
            if !startedResponse {
                // Never expose provider bodies or credential errors to a CLI log.
                let status = error is MCPOAuthService.AuthError ? "401 Unauthorized" : "502 Bad Gateway"
                try? await send(Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), on: connection)
            }
        }
    }

    private static let hopHeaders: Set<String> = [
        "host", "connection", "transfer-encoding", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "upgrade"
    ]
    private enum RelayError: Error { case invalid }

    private func receiveRequest(_ connection: NWConnection) async throws -> URLRequest {
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            buffer.append(try await receive(connection))
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            guard (headerEnd?.lowerBound ?? buffer.count) <= 65_536 else { throw RelayError.invalid }
        }
        let end = headerEnd!
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "POST", "DELETE"].contains(String(first[0])),
              first[1].hasPrefix(prefix + "/") else { throw RelayError.invalid }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RelayError.invalid }
            let name = line[..<colon].lowercased()
            guard fields[name] == nil else { throw RelayError.invalid }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Reject browser-origin requests, alternate Host values and ambiguous framing.
        guard fields["origin"] == nil, fields["host"] == localOrigin.map({ String($0.dropFirst(7)) }),
              fields["transfer-encoding"] == nil,
              let length = Int(fields["content-length"] ?? "0"), (0...10_000_000).contains(length) else { throw RelayError.invalid }
        while buffer.count - end.upperBound < length { buffer.append(try await receive(connection)) }
        var upstream = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
        let target = String(first[1].dropFirst(prefix.count))
        guard let path = URLComponents(string: target), path.scheme == nil, path.host == nil,
              path.fragment == nil else { throw RelayError.invalid }
        upstream.percentEncodedPath = path.percentEncodedPath
        upstream.percentEncodedQuery = path.percentEncodedQuery
        guard let url = upstream.url else { throw RelayError.invalid }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = String(first[0])
        for (key, value) in fields where !Self.hopHeaders.contains(key) && !["authorization", "cookie", "content-length"].contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers where !Self.hopHeaders.contains(key.lowercased()) && key.lowercased() != "authorization" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if length > 0 { request.httpBody = Data(buffer[end.upperBound..<(end.upperBound + length)]) }
        return request
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: RelayError.invalid) }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
