import Foundation
import RxCodeCore
import os

/// Talks to the autopilot service (deployed at `https://autopilot.rxlab.app`)
/// using the rxauth bearer obtained from `RxAuthService`. autopilot holds the
/// GitHub App installation tokens, so the macOS app never sees a GitHub
/// OAuth token.
@MainActor
final class AutopilotService {

    enum ServiceError: LocalizedError {
        case notAuthenticated
        case invalidResponse
        case apiError(Int, String)
        case decodingError(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not signed in. Please sign in with rxlab."
            case .invalidResponse:
                return "Received an invalid response from autopilot."
            case .apiError(let code, let detail):
                return "autopilot error (\(code)): \(detail)"
            case .decodingError(let detail):
                return "Failed to decode autopilot response: \(detail)"
            }
        }
    }

    private let rxAuth: RxAuthService
    private let logger = Logger(subsystem: "com.claudework", category: "AutopilotService")
    private let session: URLSession = .shared

    init(rxAuth: RxAuthService) {
        self.rxAuth = rxAuth
    }

    var baseURL: URL {
        let override = Bundle.main.object(forInfoDictionaryKey: "AutopilotBaseURL") as? String
        if let override, !override.isEmpty, let url = URL(string: override) {
            return url
        }
        return URL(string: "https://autopilot.rxlab.app")!
    }

    /// `GET /api/v1/repos` — live, paginated list of GitHub repos accessible
    /// via the signed-in user's GitHub App installations. Server caches the
    /// full deduped list for 60s; pagination + search filter happen on top of
    /// that cached snapshot, so passing `search` does not trigger a fresh
    /// fan-out to GitHub.
    func listRepositories(
        search: String? = nil,
        cursor: String? = nil,
        perPage: Int? = nil,
        refresh: Bool = false
    ) async throws -> AutopilotRepoListResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/repos"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if refresh {
            items.append(URLQueryItem(name: "refresh", value: "1"))
        }
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let perPage {
            items.append(URLQueryItem(name: "perPage", value: String(perPage)))
        }
        if let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmed))
        }
        if !items.isEmpty {
            components?.queryItems = items
        }
        guard let url = components?.url else {
            throw ServiceError.invalidResponse
        }
        return try await get(url: url)
    }

    /// `GET /api/v1/installations/precheck` — tiny probe used to decide
    /// whether to surface the "Install GitHub App" CTA before paying the
    /// full installation/repo fetch cost.
    func precheckInstallations() async throws -> AutopilotPrecheckResponse {
        let url = baseURL.appendingPathComponent("/api/v1/installations/precheck")
        return try await get(url: url)
    }

    /// `GET /api/v1/installations` — full list of GitHub App installations
    /// owned by the signed-in user.
    func listInstallations() async throws -> [AutopilotInstallation] {
        let url = baseURL.appendingPathComponent("/api/v1/installations")
        return try await get(url: url)
    }

    /// `GET /api/v1/installations/install-url` — returns a GitHub App
    /// install URL with a signed `state` JWT so the callback can attribute
    /// the new installation back to the rxauth user that initiated it.
    func installUrl() async throws -> AutopilotInstallUrlResponse {
        let url = baseURL.appendingPathComponent("/api/v1/installations/install-url")
        return try await get(url: url)
    }

    /// `POST /api/v1/ci-status/batch` — given a set of repo+branch lookups,
    /// returns the current aggregated GitHub Actions status for each (overall
    /// state, the latest run per workflow, and the failing ones). CI data is
    /// synced into autopilot via GitHub webhooks, so this never touches
    /// api.github.com.
    func batchCIStatus(_ repos: [CIStatusQuery]) async throws -> CIStatusBatchResponse {
        let url = baseURL.appendingPathComponent("/api/v1/ci-status/batch")
        return try await post(url: url, body: CIStatusBatchRequest(repos: repos))
    }

    // MARK: - Internal

    private func get<T: Decodable>(url: URL) async throws -> T {
        try await performWithRetry { token in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private func post<Body: Encodable, T: Decodable>(url: URL, body: Body) async throws -> T {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw ServiceError.decodingError(error.localizedDescription)
        }
        return try await performWithRetry { token in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload
            return request
        }
    }

    /// Sign the request with the current bearer, hit the network, and retry
    /// exactly once after a refresh if the server returned 401. A second 401
    /// posts `.rxAuthSessionExpired` so the UI can re-present sign-in.
    private func performWithRetry<T: Decodable>(_ build: (String) -> URLRequest) async throws -> T {
        guard let token = await rxAuth.accessToken() else {
            throw ServiceError.notAuthenticated
        }

        let request = build(token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        if http.statusCode == 401 {
            // One silent refresh + retry. If that fails too, surface the
            // session-expired notification so the UI re-presents sign-in.
            guard let refreshed = await rxAuth.accessToken() else {
                NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
                throw ServiceError.notAuthenticated
            }
            let retried = build(refreshed)
            let (data2, response2) = try await session.data(for: retried)
            guard let http2 = response2 as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }
            if http2.statusCode == 401 {
                NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
                throw ServiceError.notAuthenticated
            }
            return try decode(data: data2, response: http2)
        }

        return try decode(data: data, response: http)
    }

    private func decode<T: Decodable>(data: Data, response: HTTPURLResponse) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw ServiceError.apiError(response.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceError.decodingError(error.localizedDescription)
        }
    }
}

extension Notification.Name {
    /// Re-export RxAuthSwift's session-expired notification under the same
    /// name so call sites that don't import RxAuthSwift can subscribe.
    static let rxAuthSessionExpired = Notification.Name("rxAuthSessionExpired")
}
