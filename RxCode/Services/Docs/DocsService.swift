import Foundation
import RxCodeCore
import os

/// Talks to github-pm's docs API (same host as `AutopilotService` /
/// `SecretsService`, `https://autopilot.rxlab.app`) using the rxauth bearer.
/// Powers docs search (⌘K + the `ide__search_docs` tool), the docs management
/// UI, and the docs-setup hook. Transport mirrors `SecretsService` exactly.
@MainActor
final class DocsService {

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
                return "Received an invalid response from the docs service."
            case .apiError(let code, let detail):
                return "Docs service error (\(code)): \(detail)"
            case .decodingError(let detail):
                return "Failed to decode docs response: \(detail)"
            }
        }
    }

    private let rxAuth: RxAuthService
    private let logger = Logger(subsystem: "com.claudework", category: "DocsService")
    private let session: URLSession = .shared

    init(rxAuth: RxAuthService) {
        self.rxAuth = rxAuth
    }

    var baseURL: URL {
        if let override = Bundle.main.object(forInfoDictionaryKey: "DocsBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        if let override = Bundle.main.object(forInfoDictionaryKey: "AutopilotBaseURL") as? String,
           !override.isEmpty, let url = URL(string: override) {
            return url
        }
        return URL(string: "https://autopilot.rxlab.app")!
    }

    // MARK: - Search

    /// Semantic docs search. `repo` (an `owner/repo` full name) is optional —
    /// omit it to search across every docs repo the user can read.
    func search(query: String, repo: String? = nil, limit: Int? = nil) async throws -> [DocsSearchHit] {
        var items: [URLQueryItem] = [.init(name: "q", value: query)]
        if let repo, !repo.isEmpty { items.append(.init(name: "repo", value: repo)) }
        if let limit { items.append(.init(name: "limit", value: String(limit))) }
        let result: DocsSearchResult = try await get(url: url("/api/v1/docs/search", query: items))
        return result.items
    }

    // MARK: - Repositories

    func listRepositories(search: String? = nil, cursor: String? = nil, pageSize: Int? = nil) async throws -> DocsRepoListResponse {
        var items: [URLQueryItem] = []
        if let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            items.append(.init(name: "search", value: trimmed))
        }
        if let cursor, !cursor.isEmpty { items.append(.init(name: "cursor", value: cursor)) }
        if let pageSize { items.append(.init(name: "pageSize", value: String(pageSize))) }
        return try await get(url: url("/api/v1/docs/repositories", query: items))
    }

    func addRepository(_ body: AddDocsRepoBody) async throws -> DocsIDResponse {
        try await send(method: "POST", url: url("/api/v1/docs/repositories"), body: body)
    }

    func deleteRepository(id: String) async throws {
        let _: Ignored = try await send(method: "DELETE", url: url("/api/v1/docs/repositories/\(seg(id))"))
    }

    /// Resolves docs status for `repos` (each `owner/repo`). Returns one entry
    /// per requested repo; repos without docs report `hasDocs: false`. Used by
    /// the docs hook + sidebar affordances.
    ///
    /// There is no batch-status endpoint server-side, so status is derived from
    /// the managed-repositories listing (`GET /api/v1/docs/repositories`), which
    /// is the source of truth for which repos have docs set up. A repo present
    /// in that listing has docs; one that isn't does not.
    func statuses(forRepos repos: [String]) async throws -> [DocsRepoStatus] {
        guard !repos.isEmpty else { return [] }
        let managed = try await allManagedRepositories()
        let byName = Dictionary(
            managed.map { ($0.repositoryFullName.lowercased(), $0) },
            uniquingKeysWith: { _, last in last }
        )
        return repos.map { repo in
            let match = byName[repo.lowercased()]
            return DocsRepoStatus(
                repository: repo,
                hasDocs: match != nil,
                documentsCount: match?.documentsCount,
                docsRepositoryId: match?.id
            )
        }
    }

    /// Pages through every docs-managed repository the signed-in user can read.
    /// The managed set is small (one row per set-up repo), so the full walk is
    /// cheap and avoids relying on server-side `search` filtering.
    private func allManagedRepositories() async throws -> [DocsRepo] {
        var all: [DocsRepo] = []
        var cursor: String?
        repeat {
            let page = try await listRepositories(cursor: cursor, pageSize: 100)
            all.append(contentsOf: page.items)
            cursor = (page.pagination?.hasMore == true) ? page.pagination?.nextCursor : nil
        } while cursor != nil
        return all
    }

    // MARK: - Documents

    func listDocuments(repoId: String, cursor: String? = nil) async throws -> DocsDocumentList {
        var items: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty { items.append(.init(name: "cursor", value: cursor)) }
        return try await get(url: url("/api/v1/docs/repositories/\(seg(repoId))/documents", query: items))
    }

    /// Uploads (creates/updates) one or more documents. `repoId` may be the
    /// internal docs-repo UUID or an `owner/repo` full name. Returns 202 with a
    /// job id — embedding completes asynchronously.
    @discardableResult
    func uploadDocuments(repoId: String, documents: [DocsDocumentUpload]) async throws -> DocsUploadResult {
        try await send(
            method: "POST",
            url: url("/api/v1/docs/repositories/\(seg(repoId))/documents"),
            body: UploadDocumentsBody(documents: documents)
        )
    }

    /// Deletes a single document by its logical `docId` (the slug it was
    /// uploaded as). `repoId` may be the internal UUID or `owner/repo`.
    func deleteDocument(repoId: String, docId: String) async throws {
        let _: Ignored = try await send(
            method: "DELETE",
            url: url("/api/v1/docs/repositories/\(seg(repoId))/documents/\(seg(docId))")
        )
    }

    /// Fetches a single document with its current version (full markdown lives
    /// on `currentVersion.content`). `repoId` may be the UUID or `owner/repo`.
    func getDocument(repoId: String, docId: String) async throws -> DocsDocumentDetail {
        try await get(url: url("/api/v1/docs/repositories/\(seg(repoId))/documents/\(seg(docId))"))
    }

    /// Lists a document's version history, newest-first. Each item omits the
    /// markdown `content`; fetch a specific version for its body.
    func listDocumentVersions(repoId: String, docId: String) async throws -> [DocsDocumentVersion] {
        let list: DocsDocumentVersionList = try await get(
            url: url("/api/v1/docs/repositories/\(seg(repoId))/documents/\(seg(docId))/versions")
        )
        return list.items
    }

    /// Fetches a single historical version (includes its full `content`).
    func getDocumentVersion(repoId: String, docId: String, version: Int) async throws -> DocsDocumentVersion {
        try await get(
            url: url("/api/v1/docs/repositories/\(seg(repoId))/documents/\(seg(docId))/versions/\(version)")
        )
    }

    // MARK: - Upload tokens

    func createUploadToken(repoId: String, name: String? = nil) async throws -> DocsUploadToken {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenName = (trimmed?.isEmpty == false) ? trimmed! : "RxCode CI token"
        return try await send(
            method: "POST",
            url: url("/api/v1/docs/repositories/\(seg(repoId))/upload-tokens"),
            body: CreateDocsUploadTokenBody(name: tokenName)
        )
    }

    /// Mints a `DOCS_UPLOAD_TOKEN` and installs it as the repo's GitHub Actions
    /// secret in one server-side step — the plaintext never reaches the client.
    /// `repoId` may be the internal docs-repo UUID or an `owner/repo` full name.
    /// Powers both the docs-repo UI button and the `ide__setup_docs_secret`
    /// MCP tool. The repo must already be registered with the docs service.
    @discardableResult
    func installGithubSecret(repoId: String) async throws -> DocsGithubSecretResult {
        try await send(
            method: "POST",
            url: url("/api/v1/docs/repositories/\(seg(repoId))/github-secret")
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

    // MARK: - Transport (mirrors SecretsService / AutopilotService)

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
