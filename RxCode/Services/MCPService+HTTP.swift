import Foundation
import RxCodeCore

extension MCPService {
    // MARK: - Probe: HTTP / SSE

    func probeHTTP(_ detail: MCPServerDetail) async -> MCPProbeResult {
        guard let urlString = detail.url, let baseURL = URL(string: urlString) else {
            return MCPProbeResult(ok: false, error: "No URL configured.")
        }

        var sessionID: String?
        do {
            let headers = detail.headers
            let (initData, initResp, sid) = try await postMCP(
                url: baseURL,
                body: initializeRequest(id: 1),
                sessionID: nil,
                headers: headers
            )
            sessionID = sid
            if let failure = httpFailure(initResp) { return failure }
            guard let http = initResp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let payload = extractJSON(initData), payload["error"] == nil, payload["result"] != nil else {
                return MCPProbeResult(ok: false, error: "The MCP server did not initialize successfully.")
            }
            let (serverName, serverVersion) = parseInitializeResponse(payload)

            let (_, notificationResponse, _) = try await postMCP(
                url: baseURL,
                body: initializedNotification(),
                sessionID: sessionID,
                headers: headers
            )

            if let failure = httpFailure(notificationResponse) { return failure }

            let (toolsData, toolsResponse, _) = try await postMCP(
                url: baseURL,
                body: toolsListRequest(id: 2),
                sessionID: sessionID,
                headers: headers
            )
            if let failure = httpFailure(toolsResponse) { return failure }
            guard let http = toolsResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let payload = extractJSON(toolsData), payload["error"] == nil,
                  let result = payload["result"] as? [String: Any], result["tools"] is [[String: Any]] else {
                return MCPProbeResult(ok: false, error: "The MCP server did not return a valid tools list.")
            }
            let tools = parseToolsListResponse(payload)

            return MCPProbeResult(
                ok: true,
                serverName: serverName,
                serverVersion: serverVersion,
                tools: tools
            )
        } catch let error as MCPOAuthService.AuthError {
            return MCPProbeResult(ok: false, error: error.localizedDescription, requiresAuthentication: true)
        } catch {
            return MCPProbeResult(ok: false, error: error.localizedDescription)
        }
    }

    func httpFailure(_ response: URLResponse) -> MCPProbeResult? {
        guard let http = response as? HTTPURLResponse else {
            return MCPProbeResult(ok: false, error: "The MCP server did not return an HTTP response.")
        }
        guard !(200..<300).contains(http.statusCode) else { return nil }
        let requiresAuthentication = http.statusCode == 401
            || (http.statusCode == 403 && http.value(forHTTPHeaderField: "WWW-Authenticate") != nil)
        return MCPProbeResult(
            ok: false,
            error: "The MCP server returned HTTP \(http.statusCode) (\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))).",
            requiresAuthentication: requiresAuthentication
        )
    }

    private func postMCP(
        url: URL,
        body: [String: Any],
        sessionID: String?,
        headers: [String: String] = [:]
    ) async throws -> (Data, URLResponse, String?) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in headers where !key.isEmpty {
            req.setValue(value, forHTTPHeaderField: key)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await MCPOAuthService.shared.data(for: req, resource: url.absoluteString)
        let returnedSession = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id")
        return (data, response, returnedSession ?? sessionID)
    }

    private func extractJSON(_ data: Data) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if let payloadData = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

}
