import Darwin
import Foundation
import Network
import os.log
import RxCodeSync

actor LocalWebProxyServer {
    private static let basePort: UInt16 = 19920
    private static let maxPort: UInt16 = 19930
    private static let reverseBootstrapPath = "/__rxcode_browser"
    private static let reverseCookieName = "rxcode_proxy_target"

    private var listener: NWListener?
    private var port: UInt16 = LocalWebProxyServer.basePort
    private let username = "rxcode"
    private let password = UUID().uuidString
    private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "LocalWebProxy")

    func proxyInfo() async -> MobileWebProxyInfo? {
        if listener == nil {
            do {
                try await start()
            } catch {
                logger.error("[WebBrowserSync] failed to start local web proxy: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guard let host = Self.localIPv4Address() else {
            logger.error("[WebBrowserSync] failed to find a LAN IPv4 address for local web proxy")
            return nil
        }
        logger.info("[WebBrowserSync] proxy info host=\(host, privacy: .public) port=\(self.port, privacy: .public)")
        return MobileWebProxyInfo(host: host, port: Int(port), username: username, password: password)
    }

    private func start() async throws {
        for candidatePort in Self.basePort...Self.maxPort {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidatePort)!)
                listener.stateUpdateHandler = { [logger] state in
                    switch state {
                    case .ready:
                        logger.info("[WebBrowserSync] local web proxy listening on port \(candidatePort)")
                    case .failed(let error):
                        logger.error("[WebBrowserSync] local web proxy failed: \(error.localizedDescription, privacy: .public)")
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    Task { await self.handleConnection(connection) }
                }
                listener.start(queue: .global(qos: .userInitiated))
                self.listener = listener
                self.port = candidatePort
                return
            } catch {
                logger.warning("[WebBrowserSync] local web proxy port \(candidatePort) unavailable")
            }
        }
        throw LocalWebProxyError.noAvailablePort
    }

    private func handleConnection(_ client: NWConnection) async {
        client.start(queue: .global(qos: .userInitiated))
        do {
            let raw = try await Self.readHTTPRequest(client)
            let request = try Self.parseHTTPRequest(raw)
            logger.info("[WebBrowserSync] proxy request method=\(request.method, privacy: .public) target=\(request.target, privacy: .public)")
            if let bootstrap = Self.reverseBootstrap(from: request, password: password) {
                logger.info("[WebBrowserSync] reverse bootstrap target=\(bootstrap.target.absoluteString, privacy: .public)")
                await Self.sendReverseBootstrap(client, bootstrap: bootstrap, password: password)
                return
            }
            if let targetOrigin = Self.reverseTargetOrigin(from: request, password: password) {
                try await handleReverseHTTP(request, targetOrigin: targetOrigin, client: client)
                return
            }
            guard Self.isAuthorized(request.headers, username: username, password: password) else {
                logger.warning("[WebBrowserSync] proxy request unauthorized target=\(request.target, privacy: .public)")
                await Self.sendProxyAuthRequired(client)
                return
            }

            if request.method.uppercased() == "CONNECT" {
                try await handleConnect(request, client: client)
            } else {
                try await handlePlainHTTP(request, client: client)
            }
        } catch {
            logger.error("[WebBrowserSync] proxy request failed: \(error.localizedDescription, privacy: .public)")
            await Self.sendError(client, status: "502 Bad Gateway", message: error.localizedDescription)
        }
    }

    private func handleConnect(_ request: ProxyHTTPRequest, client: NWConnection) async throws {
        let hostPort = request.target.split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = hostPort.first, !host.isEmpty else { throw LocalWebProxyError.badRequest }
        let port = UInt16(hostPort.count > 1 ? hostPort[1] : "443") ?? 443
        logger.info("[WebBrowserSync] proxy CONNECT host=\(host, privacy: .public) port=\(port, privacy: .public)")
        let upstream = try await Self.connect(host: host, port: port)
        await Self.sendRaw(client, data: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), close: false)
        Self.pipe(client, upstream)
        Self.pipe(upstream, client)
    }

    private func handlePlainHTTP(_ request: ProxyHTTPRequest, client: NWConnection) async throws {
        guard let target = request.resolvedURL else { throw LocalWebProxyError.badRequest }
        guard let host = target.host, !host.isEmpty else { throw LocalWebProxyError.badRequest }
        let port = UInt16(target.port ?? (target.scheme == "https" ? 443 : 80))
        logger.info("[WebBrowserSync] proxy HTTP target=\(target.absoluteString, privacy: .public) host=\(host, privacy: .public) port=\(port, privacy: .public)")
        let upstream = try await Self.connect(host: host, port: port)
        let rewritten = request.rewrittenForOriginServer(targetURL: target)
        await Self.sendRaw(upstream, data: rewritten, close: false)
        Self.pipe(client, upstream)
        Self.pipe(upstream, client)
    }

    private func handleReverseHTTP(_ request: ProxyHTTPRequest, targetOrigin: URL, client: NWConnection) async throws {
        let target = try Self.reverseTargetURL(origin: targetOrigin, request: request)
        guard let host = target.host, !host.isEmpty else { throw LocalWebProxyError.badRequest }
        let port = UInt16(target.port ?? 80)
        logger.info("[WebBrowserSync] reverse HTTP target=\(target.absoluteString, privacy: .public) host=\(host, privacy: .public) port=\(port, privacy: .public)")
        let upstream = try await Self.connect(host: host, port: port)
        let rewritten = request.rewrittenForReverseProxy(
            targetURL: target,
            targetHostHeader: Self.hostHeader(for: targetOrigin),
            targetOrigin: Self.originString(for: targetOrigin),
            reverseCookieName: Self.reverseCookieName
        )
        await Self.sendRaw(upstream, data: rewritten, close: false)
        Self.pipe(client, upstream)
        Self.pipe(upstream, client)
    }

    private nonisolated static func connect(host: String, port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        return try await withCheckedThrowingContinuation { continuation in
            let resumeGate = ProxyConnectResumeGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeGate.markResumed() else { return }
                    continuation.resume(returning: connection)
                case .failed(let error):
                    guard resumeGate.markResumed() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private nonisolated static func readHTTPRequest(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let headerEnd = Data("\r\n\r\n".utf8)
        while !buffer.contains(headerEnd) {
            let chunk = try await readChunk(connection, maxLength: 8192)
            guard !chunk.isEmpty else { throw LocalWebProxyError.connectionClosed }
            buffer.append(chunk)
        }

        guard let headerRange = buffer.range(of: headerEnd) else {
            throw LocalWebProxyError.badRequest
        }
        let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
        let headerString = String(data: headerData, encoding: .utf8) ?? ""
        let contentLength = contentLength(from: headerString)
        if contentLength > 0 {
            let bodyStart = headerRange.upperBound
            let bodyBytesRead = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
            var remaining = contentLength - bodyBytesRead
            while remaining > 0 {
                let chunk = try await readChunk(connection, maxLength: min(remaining, 8192))
                guard !chunk.isEmpty else { throw LocalWebProxyError.connectionClosed }
                buffer.append(chunk)
                remaining -= chunk.count
            }
        }
        return buffer
    }

    private nonisolated static func readChunk(_ connection: NWConnection, maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private nonisolated static func parseHTTPRequest(_ data: Data) throws -> ProxyHTTPRequest {
        let headerEnd = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: headerEnd),
              let headerString = String(data: data[data.startIndex..<headerRange.lowerBound], encoding: .utf8)
        else {
            throw LocalWebProxyError.badRequest
        }
        let body = data[headerRange.upperBound...]
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw LocalWebProxyError.badRequest }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw LocalWebProxyError.badRequest }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        return ProxyHTTPRequest(
            method: parts[0],
            target: parts[1],
            version: parts[2],
            headers: headers,
            body: Data(body)
        )
    }

    private nonisolated static func isAuthorized(
        _ headers: [(String, String)],
        username: String,
        password: String
    ) -> Bool {
        guard let value = headers.first(where: { $0.0.lowercased() == "proxy-authorization" })?.1,
              value.lowercased().hasPrefix("basic ")
        else {
            return false
        }
        let encoded = String(value.dropFirst("Basic ".count))
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return decoded == "\(username):\(password)"
    }

    private nonisolated static func reverseBootstrap(
        from request: ProxyHTTPRequest,
        password: String
    ) -> ReverseBootstrap? {
        guard request.method.uppercased() == "GET",
              let components = request.originFormComponents,
              components.path == reverseBootstrapPath,
              let items = components.queryItems,
              items.first(where: { $0.name == "token" })?.value == password,
              let targetValue = items.first(where: { $0.name == "target" })?.value,
              let target = URL(string: targetValue),
              isAllowedReverseTarget(target),
              let origin = originURL(for: target)
        else {
            return nil
        }

        var location = target.path.isEmpty ? "/" : target.path
        if let query = target.query, !query.isEmpty {
            location += "?\(query)"
        }
        return ReverseBootstrap(target: target, origin: origin, location: location)
    }

    private nonisolated static func reverseTargetOrigin(
        from request: ProxyHTTPRequest,
        password: String
    ) -> URL? {
        guard request.originFormComponents?.path != reverseBootstrapPath,
              let cookie = request.headers.first(where: { $0.0.lowercased() == "cookie" })?.1,
              let value = cookieValue(named: reverseCookieName, in: cookie),
              let decoded = decodeBase64URL(value),
              let payload = String(data: decoded, encoding: .utf8)
        else {
            return nil
        }
        let parts = payload.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0] == password,
              let origin = URL(string: parts[1]),
              isAllowedReverseTarget(origin)
        else {
            return nil
        }
        return origin
    }

    private nonisolated static func reverseTargetURL(origin: URL, request: ProxyHTTPRequest) throws -> URL {
        guard let requestComponents = request.originFormComponents else {
            throw LocalWebProxyError.badRequest
        }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = requestComponents.percentEncodedPath.isEmpty ? "/" : requestComponents.percentEncodedPath
        components?.percentEncodedQuery = requestComponents.percentEncodedQuery
        guard let url = components?.url else {
            throw LocalWebProxyError.badRequest
        }
        return url
    }

    private nonisolated static func sendReverseBootstrap(
        _ connection: NWConnection,
        bootstrap: ReverseBootstrap,
        password: String
    ) async {
        let payload = Data("\(password)\n\(bootstrap.origin.absoluteString)".utf8)
        let cookie = encodeBase64URL(payload)
        let response = [
            "HTTP/1.1 302 Found",
            "Location: \(sanitizeHeaderValue(bootstrap.location))",
            "Set-Cookie: \(reverseCookieName)=\(cookie); Path=/; HttpOnly; SameSite=Lax",
            "Content-Length: 0",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        await sendRaw(connection, data: Data(response.utf8), close: true)
    }

    private nonisolated static func isAllowedReverseTarget(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    private nonisolated static func originURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }

    private nonisolated static func hostHeader(for url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    private nonisolated static func originString(for url: URL) -> String {
        guard let scheme = url.scheme else { return "" }
        return "\(scheme)://\(hostHeader(for: url))"
    }

    private nonisolated static func cookieValue(named name: String, in cookieHeader: String) -> String? {
        for part in cookieHeader.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let pair = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0] == name {
                return pair[1]
            }
        }
        return nil
    }

    private nonisolated static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }

    private nonisolated static func sanitizeHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private nonisolated static func contentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private nonisolated static func pipe(_ source: NWConnection, _ destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in
                    if isComplete || error != nil {
                        source.cancel()
                        destination.cancel()
                    } else {
                        pipe(source, destination)
                    }
                })
            } else {
                source.cancel()
                destination.cancel()
            }
        }
    }

    private nonisolated static func sendProxyAuthRequired(_ connection: NWConnection) async {
        let response = [
            "HTTP/1.1 407 Proxy Authentication Required",
            #"Proxy-Authenticate: Basic realm="RxCode""#,
            "Content-Length: 0",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        await sendRaw(connection, data: Data(response.utf8), close: true)
    }

    private nonisolated static func sendError(_ connection: NWConnection, status: String, message: String) async {
        let body = Data(message.utf8)
        let response = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var data = Data(response.utf8)
        data.append(body)
        await sendRaw(connection, data: data, close: true)
    }

    private nonisolated static func sendRaw(_ connection: NWConnection, data: Data, close: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                if close { connection.cancel() }
                continuation.resume()
            })
        }
    }

    private nonisolated static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  item.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }
            let address = item.pointee.ifa_addr!
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: item.pointee.ifa_name)
            if name == "en0" { return ip }
            fallback = fallback ?? ip
        }
        return fallback
    }
}

private struct ReverseBootstrap {
    let target: URL
    let origin: URL
    let location: String
}

private final class ProxyConnectResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var didResume = false

    nonisolated init() {}

    nonisolated func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private struct ProxyHTTPRequest {
    let method: String
    let target: String
    let version: String
    let headers: [(String, String)]
    let body: Data

    nonisolated var originFormComponents: URLComponents? {
        if let absolute = URLComponents(string: target), absolute.scheme != nil {
            var components = URLComponents()
            components.percentEncodedPath = absolute.percentEncodedPath.isEmpty ? "/" : absolute.percentEncodedPath
            components.percentEncodedQuery = absolute.percentEncodedQuery
            return components
        }
        return URLComponents(string: target)
    }

    nonisolated var resolvedURL: URL? {
        if let url = URL(string: target), url.scheme != nil {
            return url
        }
        guard let host = headers.first(where: { $0.0.lowercased() == "host" })?.1 else {
            return nil
        }
        return URL(string: "http://\(host)\(target)")
    }

    nonisolated func rewrittenForOriginServer(targetURL: URL) -> Data {
        let components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? targetURL.path
        if path.isEmpty { path = "/" }
        if let query = components?.percentEncodedQuery ?? targetURL.query {
            path += "?\(query)"
        }
        var lines = ["\(method) \(path) \(version)"]
        for (name, value) in headers {
            let lower = name.lowercased()
            guard lower != "proxy-authorization", lower != "proxy-connection" else { continue }
            lines.append("\(name): \(value)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    nonisolated func rewrittenForReverseProxy(
        targetURL: URL,
        targetHostHeader: String,
        targetOrigin: String,
        reverseCookieName: String
    ) -> Data {
        let components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? targetURL.path
        if path.isEmpty { path = "/" }
        if let query = components?.percentEncodedQuery ?? targetURL.query {
            path += "?\(query)"
        }

        var sawHost = false
        var lines = ["\(method) \(path) \(version)"]
        for (name, value) in headers {
            let lower = name.lowercased()
            switch lower {
            case "host":
                sawHost = true
                lines.append("Host: \(targetHostHeader)")
            case "proxy-authorization", "proxy-connection":
                continue
            case "origin":
                lines.append("\(name): \(targetOrigin)")
            case "referer":
                lines.append("\(name): \(targetURL.absoluteString)")
            case "cookie":
                if let stripped = strippingCookie(named: reverseCookieName, from: value), !stripped.isEmpty {
                    lines.append("\(name): \(stripped)")
                }
            default:
                lines.append("\(name): \(value)")
            }
        }
        if !sawHost {
            lines.append("Host: \(targetHostHeader)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    private nonisolated func strippingCookie(named name: String, from value: String) -> String? {
        let cookies = value
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { cookie in
                !cookie.hasPrefix("\(name)=")
            }
        return cookies.joined(separator: "; ")
    }
}

private enum LocalWebProxyError: LocalizedError {
    case noAvailablePort
    case badRequest
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .noAvailablePort:
            return "No local web proxy port is available."
        case .badRequest:
            return "Malformed proxy request."
        case .connectionClosed:
            return "Connection closed."
        }
    }
}
