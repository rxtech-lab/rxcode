import Foundation
import Network

/// A short-lived OAuth receiver bound only to the IPv4 loopback interface.
@MainActor
final class MCPOAuthCallbackServer {
    private var listener: NWListener?
    private var startup: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var authorization: MCPOAuthService.Authorization?
    private var connections: [UUID: NWConnection] = [:]
    private var timeout: Task<Void, Never>?
    private var finished = false

    func start() async throws -> URL {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                switch state {
                case .ready:
                    if let port = self.listener?.port {
                        self.startup?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")!)
                        self.startup = nil
                    }
                case .failed(let error): self.stop(error: error)
                case .cancelled: self.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.stop(error: MCPOAuthService.AuthError.invalid("Sign-in timed out. Please try again."))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                startup = $0
                listener.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func wait(for authorization: MCPOAuthService.Authorization, openBrowser: () -> Bool) async throws -> URL {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        self.authorization = authorization
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                callback = $0
                if !openBrowser() {
                    stop(error: MCPOAuthService.AuthError.invalid("Could not open the sign-in browser."))
                }
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    func stop(error: Error = CancellationError()) {
        finished = true
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        startup?.resume(throwing: error)
        startup = nil
        callback?.resume(throwing: error)
        callback = nil
    }

    private func accept(_ connection: NWConnection) {
        guard !finished, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.finished else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count > 8192 {
                    self.respond(connection, id: id, accepted: nil)
                } else if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(buffer, connection: connection, id: id)
                } else if complete || error != nil {
                    connection.cancel()
                    self.connections.removeValue(forKey: id)
                } else {
                    self.receive(connection, id: id, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        guard let authorization,
              let line = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
            respond(connection, id: id, accepted: nil)
            return
        }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET",
              parts[1].hasPrefix("/oauth/callback?"),
              let base = URLComponents(string: authorization.redirectURI),
              let url = URL(string: "http://127.0.0.1:\(base.port!)\(parts[1])") else {
            respond(connection, id: id, accepted: nil)
            return
        }
        do {
            _ = try MCPOAuthService.callbackCode(authorization, callback: url)
        } catch MCPOAuthService.AuthError.denied {
            // State-validated OAuth errors must reach the sign-in UI too.
        } catch MCPOAuthService.AuthError.authorizationFailed {
        } catch {
            respond(connection, id: id, accepted: nil)
            return
        }
        self.authorization = nil
        respond(connection, id: id, accepted: url)
    }

    private func respond(_ connection: NWConnection, id: UUID, accepted: URL?) {
        let body = accepted == nil
            ? "Invalid OAuth callback."
            : "Authorization response received. Return to RxCode to finish signing in. You can close this tab."
        let status = accepted == nil ? "400 Bad Request" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                guard let self else { return }
                self.connections.removeValue(forKey: id)
                if let accepted {
                    self.callback?.resume(returning: accepted)
                    self.callback = nil
                    self.stop()
                }
            }
        })
    }
}
