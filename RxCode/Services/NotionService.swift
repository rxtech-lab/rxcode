import Foundation
import os
import RxCodeCore

/// Minimal Notion REST client for task-board sync: list the databases shared
/// with RxCode, read their pages, and create or update pages.
///
/// Authenticates with a `NotionCredential` from the Keychain — an OAuth grant
/// made through the relay ("Connect with Notion"), or a pasted internal
/// integration token. OAuth access tokens are refreshed through the relay
/// that made the grant, which holds the integration's client secret, when
/// Notion rejects them.
///
/// Uses API version `2025-09-03`, where a database's properties and pages
/// live on its data sources. It is the first version that reports a status
/// property's options and groups, which status sync depends on.
actor NotionService {
    nonisolated static let apiVersion = "2025-09-03"
    nonisolated static let keychainService = "com.rxlab.RxCode.notion"
    /// Holds the JSON credential; a bare string here is a token pasted before
    /// OAuth existed, which `NotionCredential.decode` still reads.
    nonisolated static let keychainAccount = "integration-token"

    private let baseURL = URL(string: "https://api.notion.com/v1/")!
    private let session: URLSession
    private let logger = Logger(subsystem: "com.claudework", category: "Notion")
    /// Read from the Keychain once, then kept current by `refresh`.
    private var cachedCredential: NotionCredential?
    /// Shared by concurrent requests that hit a 401 together, so one refresh
    /// token isn't spent twice.
    private var refreshTask: Task<NotionCredential, Error>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Credential

    nonisolated static func storedCredential() -> NotionCredential? {
        KeychainHelper.read(service: keychainService, account: keychainAccount).flatMap(NotionCredential.decode)
    }

    /// Saves `credential`, or removes the stored one when `nil`.
    nonisolated static func storeCredential(_ credential: NotionCredential?) throws {
        if let credential {
            try KeychainHelper.save(credential.encoded(), service: keychainService, account: keychainAccount)
        } else {
            try KeychainHelper.delete(service: keychainService, account: keychainAccount)
        }
    }

    /// Drops the in-memory copy after the stored credential changes.
    func resetCredential() {
        cachedCredential = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func credential() throws -> NotionCredential {
        if let cachedCredential { return cachedCredential }
        guard let stored = Self.storedCredential() else { throw NotionError.missingToken }
        cachedCredential = stored
        return stored
    }

    /// Exchanges the refresh token through the relay and stores the result.
    private func refresh(_ current: NotionCredential) async throws -> NotionCredential {
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = current.refreshToken,
              let relayURL = current.relayURL.flatMap(URL.init(string:))
        else { throw NotionError.signInExpired }
        let task = Task { [session, logger] () throws -> NotionCredential in
            var request = URLRequest(url: relayURL.appendingPathComponent("notion/oauth/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["refresh_token": refreshToken])
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status),
                  let tokens = try? JSONDecoder().decode(NotionCredential.self, from: data)
            else {
                logger.error("[Notion] token refresh failed with HTTP \(status, privacy: .public)")
                throw NotionError.signInExpired
            }
            let updated = current.refreshed(with: tokens)
            try Self.storeCredential(updated)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        let updated = try await task.value
        cachedCredential = updated
        logger.info("[Notion] refreshed access token")
        return updated
    }

    // MARK: - Relay

    /// Whether `relayBaseURL` serves Notion sign-in, per its `/healthz`.
    /// Relays without Notion credentials (or older builds) report no
    /// `notion` flag.
    func relaySupportsNotion(_ relayBaseURL: URL) async -> Bool {
        var request = URLRequest(url: relayBaseURL.appendingPathComponent("healthz"))
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        return health["notion"]?.boolValue == true
    }

    // MARK: - Endpoints

    /// Every database shared with RxCode, sorted by title.
    func searchDatabases() async throws -> [NotionDatabase] {
        var databases: [NotionDatabase] = []
        var cursor: String?
        repeat {
            var body: [String: JSONValue] = [
                "filter": .object(["property": .string("object"), "value": .string("data_source")]),
                "page_size": .number(100),
            ]
            if let cursor { body["start_cursor"] = .string(cursor) }
            let response = try await request("POST", "search", body: .object(body))
            databases += (response["results"]?.arrayValue ?? []).compactMap(NotionDatabase.init(json:))
            cursor = nextCursor(response)
        } while cursor != nil
        return databases.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The data source `id`. Also accepts a database id — what links made
    /// before data sources were stored — and resolves it to the database's
    /// first data source.
    func database(id: String) async throws -> NotionDatabase {
        let response: JSONValue
        do {
            response = try await request("GET", "data_sources/\(id)")
        } catch let error as NotionError where error.isNotFound || error.isValidationError {
            let database = try await request("GET", "databases/\(id)")
            guard let dataSourceId = database["data_sources"]?[0]?["id"]?.stringValue else { throw error }
            response = try await request("GET", "data_sources/\(dataSourceId)")
        }
        return try Self.dataSource(from: response)
    }

    /// Adds `properties` (name → property schema) to a data source and
    /// returns its updated schema.
    func addProperties(_ properties: [String: JSONValue], toDataSource id: String) async throws -> NotionDatabase {
        let response = try await request("PATCH", "data_sources/\(id)", body: .object(["properties": .object(properties)]))
        return try Self.dataSource(from: response)
    }

    private static func dataSource(from response: JSONValue) throws -> NotionDatabase {
        guard let database = NotionDatabase(json: response) else {
            throw NotionError.api(status: 0, message: String(localized: "Notion returned an unexpected database response."))
        }
        return database
    }

    /// Every page of a database, following pagination.
    func queryPages(databaseId: String) async throws -> [JSONValue] {
        var pages: [JSONValue] = []
        var cursor: String?
        repeat {
            var body: [String: JSONValue] = ["page_size": .number(100)]
            if let cursor { body["start_cursor"] = .string(cursor) }
            let response = try await request("POST", "data_sources/\(databaseId)/query", body: .object(body))
            pages += response["results"]?.arrayValue ?? []
            cursor = nextCursor(response)
        } while cursor != nil
        return pages
    }

    /// Creates a page in `databaseId` and returns its id.
    func createPage(databaseId: String, properties: [String: JSONValue]) async throws -> String {
        let body: JSONValue = .object([
            "parent": .object(["type": .string("data_source_id"), "data_source_id": .string(databaseId)]),
            "properties": .object(properties),
        ])
        let response = try await request("POST", "pages", body: body)
        guard let id = response["id"]?.stringValue else {
            throw NotionError.api(status: 0, message: String(localized: "Notion didn't return the new page's id."))
        }
        return id
    }

    func updatePage(id: String, properties: [String: JSONValue]) async throws {
        _ = try await request("PATCH", "pages/\(id)", body: .object(["properties": .object(properties)]))
    }

    /// Moves a page to the Notion trash.
    func archivePage(id: String) async throws {
        _ = try await request("PATCH", "pages/\(id)", body: .object(["archived": .bool(true)]))
    }

    // MARK: - Transport

    private func nextCursor(_ response: JSONValue) -> String? {
        guard response["has_more"]?.boolValue == true else { return nil }
        return response["next_cursor"]?.stringValue
    }

    /// Sends one request, retrying rate-limited ones after Notion's
    /// `Retry-After` delay and a rejected OAuth token once after a refresh.
    private func request(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = method
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }

        var current = try credential()
        var rateLimitRetries = 0
        var refreshed = false
        while true {
            urlRequest.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            if (200..<300).contains(status) {
                return json
            }
            if status == 401, !refreshed, current.refreshToken != nil {
                refreshed = true
                current = try await refresh(current)
                continue
            }
            if status == 429, rateLimitRetries < 3 {
                rateLimitRetries += 1
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? Double(rateLimitRetries)
                logger.info("[Notion] rate limited on \(path, privacy: .public); retrying in \(retryAfter, privacy: .public)s")
                try await Task.sleep(for: .seconds(retryAfter))
                continue
            }
            let message = json["message"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: status)
            logger.error("[Notion] \(method, privacy: .public) \(path, privacy: .public) failed: \(status, privacy: .public) \(message, privacy: .public)")
            if status == 401 { throw NotionError.signInExpired }
            throw NotionError.api(status: status, message: message)
        }
    }
}

enum NotionError: LocalizedError {
    case missingToken
    case signInExpired
    case notLinked
    case relayUnsupported(String)
    case unsupportedDatabase
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return String(localized: "Connect Notion in Settings → Tasks first.")
        case .signInExpired:
            return String(localized: "Notion rejected the saved sign-in. Connect Notion again.")
        case .notLinked:
            return String(localized: "Choose a Notion database for this project first.")
        case .relayUnsupported(let name):
            return String(localized: "The relay “\(name)” doesn't offer Notion sign-in. Choose another relay or use an integration token.")
        case .unsupportedDatabase:
            return String(localized: "The Notion database has no title property.")
        case .api(_, let message):
            return message
        }
    }

    /// Notion answers a data-source request for a database id with 400 or
    /// 404 depending on the id, so both fall back to the database lookup.
    var isValidationError: Bool {
        guard case .api(let status, _) = self else { return false }
        return status == 400
    }

    var isNotFound: Bool {
        guard case .api(let status, _) = self else { return false }
        return status == 404
    }

    /// The page is gone or in the trash, so it has to be recreated.
    var isMissingPage: Bool {
        guard case .api(let status, let message) = self else { return false }
        return status == 404 || (status == 400 && message.localizedCaseInsensitiveContains("archived"))
    }
}
