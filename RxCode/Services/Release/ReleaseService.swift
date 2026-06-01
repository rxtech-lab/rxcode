import Foundation
import RxCodeCore
import os

/// Talks to github-pm's release API (same host as `DocsService` /
/// `SecretsService`, `https://autopilot.rxlab.app`) using the rxauth bearer.
/// Powers the release-setup hook, the release management UI, the
/// `ide__setup_release` MCP tool, and the "Create Release" dispatch dialog.
/// Transport mirrors `DocsService` / `SecretsService` exactly.
@MainActor
final class ReleaseService {

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
                return "Received an invalid response from the release service."
            case .apiError(let code, let detail):
                return "Release service error (\(code)): \(detail)"
            case .decodingError(let detail):
                return "Failed to decode release response: \(detail)"
            }
        }
    }

    private let rxAuth: RxAuthService
    private let logger = Logger(subsystem: "com.claudework", category: "ReleaseService")
    private let session: URLSession = .shared

    init(rxAuth: RxAuthService) {
        self.rxAuth = rxAuth
    }

    var baseURL: URL {
        if let override = Bundle.main.object(forInfoDictionaryKey: "ReleaseBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        if let override = Bundle.main.object(forInfoDictionaryKey: "AutopilotBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        return URL(string: "https://autopilot.rxlab.app")!
    }

    // MARK: - Repositories

    func listRepositories(cursor: String? = nil, pageSize: Int? = nil) async throws -> ReleaseRepoListResponse {
        var items: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty { items.append(.init(name: "cursor", value: cursor)) }
        if let pageSize { items.append(.init(name: "pageSize", value: String(pageSize))) }
        return try await get(url: url("/api/v1/release-repositories", query: items))
    }

    func addRepository(_ body: AddReleaseRepoBody) async throws -> ReleaseIDResponse {
        try await send(method: "POST", url: url("/api/v1/release-repositories"), body: body)
    }

    func deleteRepository(id: String) async throws {
        let _: Ignored = try await send(method: "DELETE", url: url("/api/v1/release-repositories/\(seg(id))"))
    }

    /// Resolves release status for `repos` (each `owner/repo`) via the batch
    /// status endpoint. Returns one entry per requested repo; repos that aren't
    /// set up report `isManaged: false`. Used by the release hook + sidebar /
    /// briefing affordances.
    func statuses(forRepos repos: [String]) async throws -> [ReleaseRepoStatus] {
        guard !repos.isEmpty else { return [] }
        return try await send(
            method: "POST",
            url: url("/api/v1/release-repositories/status"),
            body: ReleaseRepoStatusRequest(repositories: repos)
        )
    }

    /// Pages through every release-managed repository the signed-in user can
    /// read. The managed set is small (one row per set-up repo).
    func allManagedRepositories() async throws -> [ReleaseRepo] {
        var all: [ReleaseRepo] = []
        var cursor: String?
        repeat {
            let page = try await listRepositories(cursor: cursor, pageSize: 100)
            all.append(contentsOf: page.items)
            cursor = (page.pagination?.hasMore == true) ? page.pagination?.nextCursor : nil
        } while cursor != nil
        return all
    }

    // MARK: - Workflows

    /// Lists the scanned workflows for a repo. `repoId` may be the internal
    /// release-repo UUID or an `owner/repo` full name.
    func listWorkflows(repoId: String) async throws -> [ReleaseWorkflow] {
        try await get(url: url("/api/v1/release-repositories/\(seg(repoId))/workflows"))
    }

    // MARK: - Dispatch

    /// Triggers a `workflow_dispatch` on the given workflow. `repoId` may be the
    /// UUID or `owner/repo`.
    @discardableResult
    func dispatch(repoId: String, body: ReleaseDispatchRequest) async throws -> ReleaseDispatchResult {
        try await send(
            method: "POST",
            url: url("/api/v1/release-repositories/\(seg(repoId))/dispatch"),
            body: body
        )
    }

    // MARK: - GitHub secret (RELEASE_TOKEN)

    /// Installs the user-supplied `value` as the repo's `RELEASE_TOKEN` GitHub
    /// Actions secret in one step (encrypted server-side). `repoId` may be the
    /// UUID or `owner/repo`. Powers the release-repo UI button and the
    /// `ide__setup_release` MCP tool.
    @discardableResult
    func installReleaseToken(repoId: String, value: String) async throws -> ReleaseGithubSecretResult {
        try await send(
            method: "POST",
            url: url("/api/v1/release-repositories/\(seg(repoId))/github-secret"),
            body: InstallReleaseTokenBody(value: value)
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

    // MARK: - Transport (mirrors DocsService / SecretsService)

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
            guard let refreshed = await rxAuth.accessToken(forceRefresh: true) else {
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
