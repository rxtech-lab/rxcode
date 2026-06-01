import Foundation
import RxCodeCore
import os

/// Talks to github-pm's end-to-end-encrypted secrets API (same host as
/// `AutopilotService`, `https://autopilot.rxlab.app`) using the rxauth bearer.
/// All ciphertext is produced/consumed by `SecretsCrypto`; this layer only
/// moves opaque blobs.
@MainActor
final class SecretsService {

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
                return "Received an invalid response from the secrets service."
            case .apiError(let code, let detail):
                return "Secrets service error (\(code)): \(detail)"
            case .decodingError(let detail):
                return "Failed to decode secrets response: \(detail)"
            }
        }
    }

    private let rxAuth: RxAuthService
    private let logger = Logger(subsystem: "com.claudework", category: "SecretsService")
    private let session: URLSession = .shared

    init(rxAuth: RxAuthService) {
        self.rxAuth = rxAuth
    }

    var baseURL: URL {
        if let override = Bundle.main.object(forInfoDictionaryKey: "SecretsBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        if let override = Bundle.main.object(forInfoDictionaryKey: "AutopilotBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        return URL(string: "https://autopilot.rxlab.app")!
    }

    // MARK: - Enrollment

    func getUserKey() async throws -> SecretsUserKey {
        try await get(url: url("/api/v1/secrets/users/me/key"))
    }

    func putUserKey(_ body: EnrollKeyBody) async throws {
        let _: Ignored = try await send(method: "PUT", url: url("/api/v1/secrets/users/me/key"), body: body)
    }

    // MARK: - Repositories

    func listManagedRepositories(
        currentRepo: String? = nil,
        search: String? = nil,
        cursor: String? = nil,
        pageSize: Int? = nil
    ) async throws -> SecretsManagedRepoPage {
        var items: [URLQueryItem] = []
        if let currentRepo, !currentRepo.isEmpty { items.append(.init(name: "currentRepo", value: currentRepo)) }
        if let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            items.append(.init(name: "search", value: trimmed))
        }
        if let cursor, !cursor.isEmpty { items.append(.init(name: "cursor", value: cursor)) }
        if let pageSize { items.append(.init(name: "pageSize", value: String(pageSize))) }
        return try await get(url: url("/api/v1/secrets/repositories/all", query: items))
    }

    func addRepository(_ body: AddSecretsRepoBody) async throws -> SecretsIDResponse {
        try await send(method: "POST", url: url("/api/v1/secrets/repositories"), body: body)
    }

    /// Batch-fetches secrets-management status for `repos` (each `owner/repo`).
    /// Returns one entry per requested repo; unmanaged repos report `isManaged:
    /// false`. Used to gate per-project "Download Secret" affordances.
    func statuses(forRepos repos: [String]) async throws -> [SecretsRepoStatus] {
        guard !repos.isEmpty else { return [] }
        let list: SecretsRepoStatusList = try await send(
            method: "POST",
            url: url("/api/v1/secrets/repositories/status"),
            body: SecretsRepoStatusRequest(repositories: repos)
        )
        return list.items
    }

    // MARK: - Environments

    func listEnvironments(repo: String) async throws -> SecretsEnvironmentList {
        try await get(url: url("/api/v1/secrets/repositories/\(seg(repo))/environments"))
    }

    func createEnvironment(repo: String, body: CreateEnvironmentBody) async throws -> SecretsIDResponse {
        try await send(method: "POST", url: url("/api/v1/secrets/repositories/\(seg(repo))/environments"), body: body)
    }

    func deleteEnvironment(repo: String, envId: String) async throws {
        let _: Ignored = try await send(
            method: "DELETE",
            url: url("/api/v1/secrets/repositories/\(seg(repo))/environments/\(seg(envId))")
        )
    }

    // MARK: - Files

    func listFiles(repo: String, envId: String) async throws -> SecretsFileList {
        try await get(url: url("/api/v1/secrets/repositories/\(seg(repo))/environments/\(seg(envId))/files"))
    }

    func upsertFile(repo: String, envId: String, body: UpsertFileBody) async throws -> SecretsIDResponse {
        try await send(
            method: "POST",
            url: url("/api/v1/secrets/repositories/\(seg(repo))/environments/\(seg(envId))/files"),
            body: body
        )
    }

    /// Searches every environment of `repo` for files matching `filenames`,
    /// in a single request. Returns one result per requested filename, each
    /// listing the environments that contain it (`exists` = found anywhere).
    func searchFiles(repo: String, filenames: [String]) async throws -> SecretsFileSearchList {
        let query = filenames.map { URLQueryItem(name: "filename", value: $0) }
        return try await get(url: url("/api/v1/secrets/repositories/\(seg(repo))/files", query: query))
    }

    func deleteFile(repo: String, envId: String, fileId: String) async throws {
        let _: Ignored = try await send(
            method: "DELETE",
            url: url("/api/v1/secrets/repositories/\(seg(repo))/environments/\(seg(envId))/files/\(seg(fileId))")
        )
    }

    // MARK: - Download bundle

    /// `env` may be an environment name or UUID.
    func bundle(repo: String, env: String) async throws -> SecretsBundle {
        try await get(url: url("/api/v1/secrets/repositories/\(seg(repo))/environments/\(seg(env))/bundle"))
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

    // MARK: - Transport (mirrors AutopilotService)

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
