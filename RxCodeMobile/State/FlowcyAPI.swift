import Foundation
import RxCodeCore

/// Shared account authentication for feature reads and backend model turns.
@MainActor
final class FlowcyAPI {
    private let session: URLSession
    private let baseURL: URL
    private let notifySessionExpiry: Bool
    private let token: (Bool) async -> String?

    init(session: URLSession = .shared, baseURL: URL = URL(string: "https://www.flowcy.dev")!,
         notifySessionExpiry: Bool = true, token: @escaping (Bool) async -> String? = { await RxAuthService.shared.accessToken(forceRefresh: $0) }) {
        self.notifySessionExpiry = notifySessionExpiry
        self.session = session
        self.baseURL = baseURL
        self.token = token
    }

    func request(path: String, body: JSONValue? = nil, method: String? = nil) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        guard !path.contains(".."), !path.hasPrefix("/"),
              let url = URL(string: baseURL.appendingPathComponent("api/v1").absoluteString + "/" + path)?.absoluteURL else { throw FlowcyError.protocolError }
        for refresh in [false, true] {
            guard let bearer = await token(refresh) else {
                if notifySessionExpiry { NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil) }
                throw FlowcyError.signIn
            }
            var request = URLRequest(url: url, timeoutInterval: 90)
            request.httpMethod = method ?? (body == nil ? "GET" : "POST")
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                request.httpBody = try JSONEncoder().encode(body)
            }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw FlowcyError.protocolError }
            if http.statusCode == 401 {
                if !refresh { continue }
                // A feature rejecting a freshly renewed identity token is not evidence
                // that the account session expired (for example, an older deployment).
                throw FlowcyError.message("This feature could not accept your account session. Try again after the Flowcy service is updated.")
            }
            if http.statusCode == 403 { throw FlowcyError.denied }
            guard (200..<300).contains(http.statusCode) else { throw FlowcyError.transport(http.statusCode) }
            return (bytes, http)
        }
        throw FlowcyError.signIn
    }

    func read(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        let (bytes, _) = try await request(path: path, body: body, method: method)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 4_000_000 { throw FlowcyError.protocolError }
        }
        return data.isEmpty ? .null : try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
