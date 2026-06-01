import Foundation
import RxCodeCore
import os

/// Talks to github-pm's CI auto-update API (the "watched repositories" feature,
/// same host as `AutopilotService` / `SecretsService` / `DocsService`,
/// `https://autopilot.rxlab.app`) using the rxauth bearer. Powers the CI
/// Auto-Update management UI in Settings → Autopilot and the setup banner.
/// Transport mirrors `SecretsService` / `DocsService` exactly.
@MainActor
final class CIUpdateService {

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
                return "Received an invalid response from the CI update service."
            case .apiError(let code, let detail):
                return "CI update service error (\(code)): \(detail)"
            case .decodingError(let detail):
                return "Failed to decode CI update response: \(detail)"
            }
        }
    }

    private let rxAuth: RxAuthService
    private let logger = Logger(subsystem: "com.claudework", category: "CIUpdateService")
    private let session: URLSession = .shared

    init(rxAuth: RxAuthService) {
        self.rxAuth = rxAuth
    }

    var baseURL: URL {
        if let override = Bundle.main.object(forInfoDictionaryKey: "CIUpdateBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        if let override = Bundle.main.object(forInfoDictionaryKey: "AutopilotBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        return URL(string: "https://autopilot.rxlab.app")!
    }

    // MARK: - Watched repositories (CRUD)

    func listWatchedRepositories(cursor: String? = nil, pageSize: Int? = nil) async throws -> WatchedRepoPage {
        var items: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty { items.append(.init(name: "cursor", value: cursor)) }
        if let pageSize { items.append(.init(name: "pageSize", value: String(pageSize))) }
        return try await get(url: url("/api/v1/watched-repositories", query: items))
    }

    func addWatchedRepository(_ body: AddWatchedRepoBody) async throws -> CIUpdateIDResponse {
        try await send(method: "POST", url: url("/api/v1/watched-repositories"), body: body)
    }

    func updateScanFrequency(id: String, frequency: CIScanFrequency) async throws {
        let _: Ignored = try await send(
            method: "PATCH",
            url: url("/api/v1/watched-repositories/\(seg(id))"),
            body: UpdateScanFrequencyBody(scanFrequency: frequency)
        )
    }

    func deleteWatchedRepository(id: String) async throws {
        let _: Ignored = try await send(method: "DELETE", url: url("/api/v1/watched-repositories/\(seg(id))"))
    }

    // MARK: - Status (batch, banner gating)

    /// Batch-fetches watch status for `repos` (each `owner/repo`). Returns one
    /// entry per requested repo; unwatched repos report `watchedRepositoryId:
    /// nil`. Used to gate the "set up CI auto-update" banner.
    func statuses(forRepos repos: [String]) async throws -> [CIWatchStatus] {
        guard !repos.isEmpty else { return [] }
        let list: CIWatchStatusList = try await send(
            method: "POST",
            url: url("/api/v1/watched-repositories/status"),
            body: CIWatchStatusRequest(repositories: repos)
        )
        return list.items
    }

    // MARK: - Scan history

    /// Newest-first scan runs for a watched repo. Returns a bare array (the
    /// server does not wrap this one in `{ items: [...] }`).
    func history(id: String, limit: Int? = nil) async throws -> [CIUpdateRunHistory] {
        var items: [URLQueryItem] = []
        if let limit { items.append(.init(name: "limit", value: String(limit))) }
        return try await get(url: url("/api/v1/watched-repositories/\(seg(id))/history", query: items))
    }

    // MARK: - Manual trigger

    func trigger(id: String) async throws -> CITriggerResponse {
        try await send(method: "POST", url: url("/api/v1/watched-repositories/\(seg(id))/trigger"))
    }

    // MARK: - Pull requests

    func pullRequests(id: String) async throws -> [CIPullRequest] {
        try await get(url: url("/api/v1/watched-repositories/\(seg(id))/prs"))
    }

    /// Closes a PR opened by the auto-updater. The PR to close is identified by
    /// number in the request body.
    func closePullRequest(id: String, prNumber: Int) async throws {
        let _: Ignored = try await send(
            method: "DELETE",
            url: url("/api/v1/watched-repositories/\(seg(id))/prs"),
            body: ClosePRBody(prNumber: prNumber)
        )
    }

    // MARK: - URL building

    /// Percent-encodes a single path segment, including any `/` in an
    /// `owner/repo` identifier so it stays one segment.
    private func seg(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = (components.percentEncodedPath) + path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    // MARK: - Transport (mirrors SecretsService / DocsService)

    private struct Ignored: Decodable {}

    private func get<T: Decodable>(url: URL) async throws -> T {
        try await performWithRetry { token in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private func send<Body: Encodable, T: Decodable>(method: String, url: URL, body: Body) async throws -> T {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw ServiceError.decodingError(error.localizedDescription)
        }
        return try await performWithRetry { token in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = payload
            return request
        }
    }

    private func send<T: Decodable>(method: String, url: URL) async throws -> T {
        try await performWithRetry { token in
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private func performWithRetry<T: Decodable>(_ build: (String) -> URLRequest) async throws -> T {
        guard let token = await rxAuth.accessToken() else {
            throw ServiceError.notAuthenticated
        }
        let request = build(token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }

        if http.statusCode == 401 {
            guard let refreshed = await rxAuth.accessToken() else {
                NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
                throw ServiceError.notAuthenticated
            }
            let retried = build(refreshed)
            let (data2, response2) = try await session.data(for: retried)
            guard let http2 = response2 as? HTTPURLResponse else { throw ServiceError.invalidResponse }
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
        if T.self == Ignored.self {
            return Ignored() as! T
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceError.decodingError(error.localizedDescription)
        }
    }
}
