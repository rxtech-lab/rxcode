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

    /// Self-contained markup: no remote assets or callback values leave this page.
    nonisolated static func callbackPage(received: Bool, hasError: Bool) -> String {
        let isSuccess = received && !hasError
        let title = isSuccess ? "Continue in RxCode" : "Let’s try that again"
        let message = isSuccess
            ? "Your authorization response has been received. Return to RxCode to finish connecting your MCP server."
            : "Sign-in could not be completed. Return to RxCode to review the message and start a new sign-in."
        let label = isSuccess ? "AUTHORIZATION RECEIVED" : "SIGN-IN NEEDS ATTENTION"
        let symbol = isSuccess ? "<path d=\"m8 16 5 5 11-11\"/>" : "<path d=\"M16 9v9m0 5h.01\"/>"
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <title>\(title) · RxCode</title>
          <style>
            :root { color-scheme: light dark; --bg: #f5f6fa; --card: #ffffff;
              --text: #202332; --muted: #62697a; --line: #e5e7ef; --accent: #5652d9;
              --tint: #efefff; --shadow: 0 24px 80px #2023320d; }
            * { box-sizing: border-box; }
            body { margin: 0; min-height: 100vh; min-height: 100svh; display: grid;
              place-items: center; padding: 32px 20px; background: var(--bg);
              background-image: radial-gradient(ellipse at 50% 0%, #7770ef12, transparent 65%);
              color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            .shell { width: 100%; max-width: 480px; }
            .brand { display: flex; align-items: center; justify-content: center; gap: 10px;
              margin-bottom: 28px; font-size: 18px; font-weight: 650; letter-spacing: -.5px; }
            .brand-mark { display: grid; place-items: center; width: 32px; height: 32px;
              border-radius: 9px; color: white; background: #5652d9; font-size: 16px; font-weight: 700; }
            main { padding: 44px 36px 32px; text-align: center; border: 1px solid var(--line);
              border-radius: 24px; background: var(--card); box-shadow: var(--shadow); }
            .icon { width: 64px; height: 64px; display: grid; place-items: center; margin: 0 auto 26px;
              border-radius: 50%; background: var(--tint); color: var(--accent); }
            .attention { --accent: #a56313; --tint: #fff3df; }
            .eyebrow { margin: 0 0 12px; font-size: 10px; font-weight: 700; letter-spacing: 1.6px; color: var(--accent); }
            h1 { margin: 0 0 16px; font-size: clamp(26px, 5vw, 32px); line-height: 1.2; letter-spacing: -1px; }
            .description { margin: 0 auto 28px; max-width: 350px; font-size: 15px; line-height: 1.7; color: var(--muted); }
            .button { display: flex; align-items: center; justify-content: center; gap: 10px;
              min-height: 48px; padding: 12px 20px; border-radius: 12px; background: #5652d9;
              color: white; text-decoration: none; font-size: 14px; font-weight: 600; }
            .button:hover { background: #4540c5; }
            .button:focus-visible { outline: 3px solid var(--accent); outline-offset: 4px; }
            .hint { margin: 24px 0 0; padding-top: 24px; border-top: 1px solid var(--line);
              font-size: 12px; line-height: 1.6; color: var(--muted); }
            footer { margin-top: 24px; text-align: center; font-size: 12px; color: var(--muted); }
            @media (prefers-color-scheme: dark) {
              :root { --bg: #111219; --card: #1b1d27; --text: #f0f1f8; --muted: #a2a8bb;
                --line: #303341; --accent: #b0acff; --tint: #2b2947; --shadow: 0 24px 80px #0003; }
              .attention { --accent: #f0bf77; --tint: #3b3022; }
            }
            @media (max-width: 400px) { main { padding: 32px 24px 26px; } }
          </style>
        </head>
        <body>
          <div class="shell">
            <div class="brand"><span class="brand-mark" aria-hidden="true">&lt;/&gt;</span>RxCode</div>
            <main class="\(isSuccess ? "received" : "attention")">
              <div class="icon" aria-hidden="true">
                <svg width="32" height="32" viewBox="0 0 32 32" fill="none" stroke="currentColor"
                  stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">\(symbol)</svg>
              </div>
              <p class="eyebrow">\(label)</p>
              <h1>\(title)</h1>
              <p class="description">\(message)</p>
              <a class="button" href="rxcode://">Return to RxCode <span aria-hidden="true">↗</span></a>
              <p class="hint">If the app doesn’t open, switch to RxCode from your Dock.</p>
            </main>
            <footer>You can safely close this tab.</footer>
          </div>
        </body>
        </html>
        """
    }

    private func respond(_ connection: NWConnection, id: UUID, accepted: URL?) {
        let hasError = accepted.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
            .contains(where: { $0.name == "error" }) == true
        let body = Self.callbackPage(received: accepted != nil, hasError: hasError)
        let status = accepted == nil ? "400 Bad Request" : "200 OK"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n\(body)"
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
