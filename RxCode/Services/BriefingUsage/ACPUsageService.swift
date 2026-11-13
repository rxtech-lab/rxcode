import Foundation
import SQLite3
import RxCodeCore

/// Credentials stay on this Mac. Only normalized usage snapshots leave this service.
actor ACPUsageService {
    static let shared = ACPUsageService()

    private struct CachedAntigravitySession {
        var accessToken: String
        var expiresAt: Date
        var isBusiness: Bool
        var projectID: String?
        var location: String?
        var userTier: String?
        var endpointBaseURL: URL
    }

    struct StoredAntigravityCredential: Equatable {
        var accessToken: String?
        var expiry: Date?
        var refreshToken: String?
        var clientID: String?
        var clientSecret: String?
        var tokenURI: URL
        var projectID: String?
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private var cachedAntigravitySessions: [String: CachedAntigravitySession] = [:]
    private var cachedBinaryOAuthPairs: [String: [(clientID: String, clientSecret: String)]] = [:]

    func fetch(client: ACPClientSpec, integration: UsageIntegration) async throws -> UsagePluginSnapshot {
        guard client.enabled, let provider = ACPUsageProvider.provider(for: client),
              provider.pluginID == integration.pluginID else { throw ACPUsageError.unavailable }
        let environment = environment(for: client)
        switch provider {
        case .opencode:
            let token = try openCodeCredential(environment: environment)
            return try await ACPUsageAPI.fetch(provider: provider, token: token, integration: integration, session: session)
        case .antigravity:
            return try await fetchAntigravity(client: client, integration: integration, environment: environment)
        }
    }

    private func environment(for client: ACPClientSpec) -> [String: String] {
        let launchEnvironment: [String: String]
        switch client.launch {
        case .binary(_, _, let env), .custom(_, _, let env), .npx(_, _, let env), .uvx(_, _, let env):
            launchEnvironment = env
        }
        return ProcessInfo.processInfo.environment.merging(launchEnvironment) { _, new in new }
            .merging(client.extraEnv) { _, new in new }
    }

    // MARK: - Antigravity

    private func fetchAntigravity(
        client: ACPClientSpec,
        integration: UsageIntegration,
        environment: [String: String]
    ) async throws -> UsagePluginSnapshot {
        if let cached = cachedAntigravitySessions[client.id],
           cached.expiresAt > Date.now.addingTimeInterval(60) {
            do {
                return try await performAntigravityQuotaFetch(sessionInfo: cached, integration: integration)
            } catch ACPUsageFetchError.signIn {
                cachedAntigravitySessions[client.id] = nil
            }
        }

        let resolved = try await resolveAntigravitySession(client: client, environment: environment)
        cachedAntigravitySessions[client.id] = resolved
        do {
            return try await performAntigravityQuotaFetch(sessionInfo: resolved, integration: integration)
        } catch ACPUsageFetchError.signIn {
            cachedAntigravitySessions[client.id] = nil
            throw ACPUsageFetchError.signIn(ACPUsageProvider.antigravity.title)
        }
    }

    private func performAntigravityQuotaFetch(
        sessionInfo: CachedAntigravitySession,
        integration: UsageIntegration
    ) async throws -> UsagePluginSnapshot {
        let request: URLRequest
        if sessionInfo.isBusiness {
            guard let projectID = sessionInfo.projectID,
                  let businessReq = ACPUsageProvider.antigravityBusinessRequest(
                      token: sessionInfo.accessToken,
                      baseURL: sessionInfo.endpointBaseURL,
                      projectID: projectID,
                      location: sessionInfo.location ?? "global",
                      userTier: sessionInfo.userTier
                  ) else {
                throw UsagePluginError.invalidConfiguration
            }
            request = businessReq
        } else {
            let quotaURL = sessionInfo.endpointBaseURL
                .appendingPathComponent("v1internal:retrieveUserQuotaSummary")
            request = ACPUsageProvider.antigravity.request(
                token: sessionInfo.accessToken,
                projectID: sessionInfo.projectID,
                endpointURL: quotaURL
            )
        }
        return try await ACPUsageAPI.fetch(
            request: request,
            provider: .antigravity,
            integration: integration,
            session: session
        )
    }

    private func resolveAntigravitySession(
        client: ACPClientSpec,
        environment: [String: String]
    ) async throws -> CachedAntigravitySession {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let geminiHome = environment["GEMINI_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".gemini")
        let acpDir = geminiHome.appendingPathComponent("antigravity-acp")
        let settings = readJSONDictionary(at: acpDir.appendingPathComponent("settings.json"))
        let authType = clean(environment["AGY_ACP_AUTH_TYPE"])
            ?? clean((settings?["auth"] as? [String: Any])?["type"] as? String)
            ?? "oauth-personal"
        let forceFileStorage = ["1", "true", "yes"].contains(
            (environment["AGY_ACP_FORCE_FILE_STORAGE"] ?? "").lowercased()
        )

        if authType == "oauth-business" {
            let candidates = await loadAntigravityCandidates(
                sources: businessCredentialSources(acpDir: acpDir, forceFileStorage: forceFileStorage),
                environment: environment
            )
            let gcp = settings?["gcp"] as? [String: Any]
            let project = clean(environment["GOOGLE_CLOUD_PROJECT"]) ?? clean(gcp?["project"] as? String)
            let location = clean(environment["GOOGLE_CLOUD_LOCATION"]) ?? clean(gcp?["location"] as? String) ?? "global"
            let userTier = clean(gcp?["userTier"] as? String) ?? clean(gcp?["tier"] as? String)
            let baseURL = cleanHTTPSURL(environment["AGY_ACP_BAIC_HOST"])
                ?? URL(string: "https://cloudaicompanion.googleapis.com")!
            for stored in candidates {
                if let token = try? await resolveAccessToken(from: stored, client: client) {
                    return CachedAntigravitySession(
                        accessToken: token.accessToken,
                        expiresAt: token.expiresAt,
                        isBusiness: true,
                        projectID: project ?? stored.projectID,
                        location: location,
                        userTier: userTier,
                        endpointBaseURL: baseURL
                    )
                }
            }
            throw ACPUsageError.signIn(ACPUsageProvider.antigravity.title)
        }

        let commandName = clientExecutableName(client)
        let sources = personalCredentialSources(
            acpDir: acpDir,
            preferCLIKeychain: commandName == "agy",
            forceFileStorage: forceFileStorage
        )
        let candidates = await loadAntigravityCandidates(sources: sources, environment: environment)
        guard !candidates.isEmpty else {
            throw ACPUsageError.signIn(ACPUsageProvider.antigravity.title)
        }

        for stored in candidates {
            guard let token = try? await resolveAccessToken(from: stored, client: client) else { continue }
            let onboard = await resolveCCPAEndpoint(
                accessToken: token.accessToken,
                storedProjectID: stored.projectID,
                environment: environment
            )
            return CachedAntigravitySession(
                accessToken: token.accessToken,
                expiresAt: token.expiresAt,
                isBusiness: false,
                projectID: onboard.projectID,
                location: nil,
                userTier: nil,
                endpointBaseURL: onboard.baseURL
            )
        }
        throw ACPUsageError.signIn(ACPUsageProvider.antigravity.title)
    }

    private enum CredentialSource: Sendable {
        case keychain(service: String, account: String)
        case file(URL)
    }

    private func businessCredentialSources(acpDir: URL, forceFileStorage: Bool) -> [CredentialSource] {
        let file = CredentialSource.file(acpDir.appendingPathComponent("acp_business_token.json"))
        let keychain = CredentialSource.keychain(service: "gemini", account: "antigravity-acp-business")
        return forceFileStorage ? [file, keychain] : [keychain, file]
    }

    private func personalCredentialSources(
        acpDir: URL,
        preferCLIKeychain: Bool,
        forceFileStorage: Bool
    ) -> [CredentialSource] {
        let acpFile = CredentialSource.file(acpDir.appendingPathComponent("acp_token.json"))
        let acpKeychain = CredentialSource.keychain(service: "gemini", account: "antigravity-acp")
        let cliKeychain = CredentialSource.keychain(service: "gemini", account: "antigravity")
        if preferCLIKeychain {
            return forceFileStorage
                ? [cliKeychain, acpFile, acpKeychain]
                : [cliKeychain, acpKeychain, acpFile]
        }
        return forceFileStorage
            ? [acpFile, acpKeychain, cliKeychain]
            : [acpKeychain, acpFile, cliKeychain]
    }

    private func loadAntigravityCandidates(
        sources: [CredentialSource],
        environment: [String: String]
    ) async -> [StoredAntigravityCredential] {
        let rawPayloads: [Data] = await Task.detached(priority: .utility) {
            var collected: [Data] = []
            for source in sources {
                switch source {
                case .keychain(let service, let account):
                    if let data = KeychainHelper.read(service: service, account: account) {
                        collected.append(data)
                    }
                case .file(let url):
                    if let data = try? Data(contentsOf: url) {
                        collected.append(data)
                    }
                }
            }
            return collected
        }.value

        return rawPayloads.compactMap { Self.parseAntigravityCredential($0, environment: environment) }
    }

    nonisolated static func parseAntigravityCredential(
        _ rawData: Data,
        environment: [String: String] = [:]
    ) -> StoredAntigravityCredential? {
        guard var raw = String(data: rawData, encoding: .utf8) else { return nil }
        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix) {
            guard let decodedData = Data(base64Encoded: String(raw.dropFirst(prefix.count))),
                  let decoded = String(data: decodedData, encoding: .utf8) else { return nil }
            raw = decoded
        }
        guard let jsonData = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        let tokenDict = (root["token"] as? [String: Any]) ?? root
        let access = cleanString(tokenDict["access_token"] as? String) ?? cleanString(tokenDict["token"] as? String)
        let refresh = cleanString(tokenDict["refresh_token"] as? String)
        guard access != nil || refresh != nil else { return nil }

        let expiry = parseISO8601Date(tokenDict["expiry"] as? String)
        let clientID = cleanString(root["client_id"] as? String)
            ?? cleanString(tokenDict["client_id"] as? String)
            ?? cleanString(environment["AGY_ACP_OAUTH_CLIENT_ID"])
            ?? jwtAudience(from: root["id_token"] as? String)
        let clientSecret = cleanString(root["client_secret"] as? String)
            ?? cleanString(tokenDict["client_secret"] as? String)
            ?? cleanString(environment["AGY_ACP_OAUTH_CLIENT_SECRET"])
        let tokenURI = cleanHTTPSURL((root["token_uri"] as? String) ?? (tokenDict["token_uri"] as? String))
            ?? URL(string: "https://oauth2.googleapis.com/token")!
        let projectID = cleanString(root["project_id"] as? String) ?? cleanString(tokenDict["project_id"] as? String)

        return StoredAntigravityCredential(
            accessToken: access,
            expiry: expiry,
            refreshToken: refresh,
            clientID: clientID,
            clientSecret: clientSecret,
            tokenURI: tokenURI,
            projectID: projectID
        )
    }

    private func resolveAccessToken(
        from stored: StoredAntigravityCredential,
        client: ACPClientSpec
    ) async throws -> (accessToken: String, expiresAt: Date) {
        if let access = stored.accessToken {
            if let expiry = stored.expiry {
                if expiry > Date.now.addingTimeInterval(60) {
                    return (access, expiry)
                }
            } else if stored.refreshToken == nil {
                return (access, Date.now.addingTimeInterval(300))
            }
        }

        guard let refreshToken = stored.refreshToken else {
            throw ACPUsageError.signIn(ACPUsageProvider.antigravity.title)
        }

        if let clientID = stored.clientID, let clientSecret = stored.clientSecret {
            return try await exchangeRefreshToken(
                refreshToken: refreshToken,
                clientID: clientID,
                clientSecret: clientSecret,
                tokenURI: stored.tokenURI
            )
        }

        let fallbackPairs = await installedBinaryOAuthPairs(for: client, preferredClientID: stored.clientID)
        for pair in fallbackPairs {
            if let refreshed = try? await exchangeRefreshToken(
                refreshToken: refreshToken,
                clientID: pair.clientID,
                clientSecret: pair.clientSecret,
                tokenURI: stored.tokenURI
            ) {
                return refreshed
            }
        }
        throw ACPUsageError.signIn(ACPUsageProvider.antigravity.title)
    }

    private func exchangeRefreshToken(
        refreshToken: String,
        clientID: String,
        clientSecret: String,
        tokenURI: URL
    ) async throws -> (accessToken: String, expiresAt: Date) {
        var request = URLRequest(url: tokenURI)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret)
        ]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = clean(json["access_token"] as? String) else {
            throw ACPUsageError.signIn(ACPUsageProvider.antigravity.title)
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (accessToken, Date.now.addingTimeInterval(max(60, expiresIn)))
    }

    private func resolveCCPAEndpoint(
        accessToken: String,
        storedProjectID: String?,
        environment: [String: String]
    ) async -> (baseURL: URL, projectID: String?) {
        let customBase = Self.cleanHTTPSURL(environment["AGY_ACP_CCPA_BASE_URL"])
        let onboardBase = customBase ?? URL(string: "https://cloudcode-pa.googleapis.com")!
        let defaultQuotaBase = customBase ?? URL(string: "https://daily-cloudcode-pa.googleapis.com")!

        var request = URLRequest(url: onboardBase.appendingPathComponent("v1internal:loadCodeAssist"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ACPUsageProvider.antigravityUserAgent, forHTTPHeaderField: "User-Agent")

        var metadata: [String: String] = ["ideType": "ANTIGRAVITY"]
        if let storedProjectID, !storedProjectID.isEmpty {
            metadata["duetProject"] = storedProjectID
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": metadata])

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (defaultQuotaBase, storedProjectID)
        }

        let resolvedProject = clean(json["cloudaicompanionProject"] as? String)
            ?? clean((json["cloudaicompanionProject"] as? [String: Any])?["id"] as? String)
            ?? storedProjectID
        let usesGcpTos = (json["paidTier"] as? [String: Any])?["usesGcpTos"] as? Bool ?? false
        let quotaBase = customBase
            ?? (usesGcpTos ? URL(string: "https://cloudcode-pa.googleapis.com")! : defaultQuotaBase)
        return (quotaBase, resolvedProject)
    }

    private func installedBinaryOAuthPairs(
        for client: ACPClientSpec,
        preferredClientID: String?
    ) async -> [(clientID: String, clientSecret: String)] {
        let path: String?
        switch client.launch {
        case .binary(let binaryPath, _, _), .custom(let binaryPath, _, _):
            path = binaryPath
        case .npx, .uvx:
            path = nil
        }
        let cacheKey = "\(path ?? "")|\(preferredClientID ?? "")"
        if let cached = cachedBinaryOAuthPairs[cacheKey] { return cached }

        let candidatePaths: [String] = [
            path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ].compactMap { $0 }

        let extracted = await Task.detached(priority: .utility) { () -> [(String, String)] in
            guard let idRegex = try? NSRegularExpression(pattern: #"[0-9]{10,}-[a-z0-9]+\.apps\.googleusercontent\.com"#),
                  let secretRegex = try? NSRegularExpression(pattern: #"GOCSPX-[A-Za-z0-9_-]{28}"#) else {
                return []
            }
            var clientIDs: [String] = []
            var secrets: [String] = []
            for candidate in candidatePaths where FileManager.default.fileExists(atPath: candidate) {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: candidate),
                      let size = (attrs[.size] as? NSNumber)?.intValue, size <= 120_000_000,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: candidate), options: .mappedIfSafe) else {
                    continue
                }
                let text = String(decoding: data, as: UTF8.self)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in idRegex.matches(in: text, range: range) {
                    if let r = Range(match.range, in: text) {
                        let value = String(text[r])
                        if !clientIDs.contains(value) { clientIDs.append(value) }
                    }
                }
                for match in secretRegex.matches(in: text, range: range) {
                    if let r = Range(match.range, in: text) {
                        let value = String(text[r])
                        if !secrets.contains(value) { secrets.append(value) }
                    }
                }
                if !clientIDs.isEmpty && !secrets.isEmpty { break }
            }
            let orderedIDs: [String]
            if let preferredClientID, !preferredClientID.isEmpty {
                orderedIDs = [preferredClientID] + clientIDs.filter { $0 != preferredClientID }
            } else {
                orderedIDs = clientIDs
            }
            var pairs: [(String, String)] = []
            for id in orderedIDs {
                for secret in secrets {
                    pairs.append((id, secret))
                }
            }
            return pairs
        }.value

        let mapped = extracted.map { (clientID: $0.0, clientSecret: $0.1) }
        cachedBinaryOAuthPairs[cacheKey] = mapped
        return mapped
    }

    // MARK: - OpenCode

    private func openCodeCredential(environment: [String: String]) throws -> String {
        if let token = clean(environment["OPENCODE_API_KEY"]) { return token }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".local/share")
        let directory = dataHome.appendingPathComponent("opencode")
        let filename = environment["OPENCODE_DB"] ?? "opencode.db"
        let database = filename.hasPrefix("/") ? URL(fileURLWithPath: filename) : directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: database.path) {
            let result = try databaseCredential(at: database)
            if result.hasCredentialTable {
                guard let token = result.token else { throw ACPUsageError.signIn("OpenCode Go") }
                return token
            }
        }
        let url = directory.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["opencode-go"] as? [String: Any], account["type"] as? String == "api",
              let token = clean(account["key"] as? String) else { throw ACPUsageError.signIn("OpenCode Go") }
        return token
    }

    private func databaseCredential(at url: URL) throws -> (hasCredentialTable: Bool, token: String?) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw ACPUsageError.signIn("OpenCode Go")
        }
        defer { sqlite3_close(database) }
        var tableQuery: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'credential'", -1, &tableQuery, nil) == SQLITE_OK else {
            throw ACPUsageError.signIn("OpenCode Go")
        }
        let tableStatus = sqlite3_step(tableQuery)
        sqlite3_finalize(tableQuery)
        if tableStatus == SQLITE_DONE { return (false, nil) }
        guard tableStatus == SQLITE_ROW else { throw ACPUsageError.signIn("OpenCode Go") }
        var statement: OpaquePointer?
        let sql = "SELECT integration_id, value FROM credential WHERE active = 1 AND integration_id IN ('opencode-go', 'opencode') ORDER BY CASE integration_id WHEN 'opencode-go' THEN 0 ELSE 1 END"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ACPUsageError.signIn("OpenCode Go") }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return (true, nil) }
        guard status == SQLITE_ROW,
              let id = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else {
            throw ACPUsageError.signIn("OpenCode Go")
        }
        let integration = String(cString: id)
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        // Multiple active credentials for one provider cannot be attributed safely.
        let nextStatus = sqlite3_step(statement)
        guard nextStatus == SQLITE_ROW || nextStatus == SQLITE_DONE else { throw ACPUsageError.signIn("OpenCode Go") }
        if nextStatus == SQLITE_ROW, let next = sqlite3_column_text(statement, 0), String(cString: next) == integration {
            throw ACPUsageError.signIn("OpenCode Go")
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (true, nil) }
        if integration == "opencode-go", value["type"] as? String == "key" { return (true, clean(value["key"] as? String)) }
        if value["type"] as? String == "oauth", let expiry = value["expires"] as? Double,
           expiry / 1000 > Date.now.timeIntervalSince1970 { return (true, clean(value["access"] as? String)) }
        return (true, nil)
    }

    // MARK: - Helpers

    private func clientExecutableName(_ client: ACPClientSpec) -> String {
        switch client.launch {
        case .binary(let path, _, _), .custom(let path, _, _):
            return URL(fileURLWithPath: path).lastPathComponent.lowercased()
        case .npx, .uvx:
            return ""
        }
    }

    private func readJSONDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    nonisolated private static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    nonisolated private static func jwtAudience(from idToken: String?) -> String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return cleanString(payload["aud"] as? String)
    }

    nonisolated private static func cleanHTTPSURL(_ value: String?) -> URL? {
        guard let cleaned = cleanString(value), let url = URL(string: cleaned),
              url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }

    private func cleanHTTPSURL(_ value: String?) -> URL? {
        Self.cleanHTTPSURL(value)
    }

    nonisolated private static func cleanString(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return value
    }

    private func clean(_ value: String?) -> String? {
        Self.cleanString(value)
    }
}

enum ACPUsageError: LocalizedError {
    case unavailable, signIn(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "This ACP client is disabled or no longer installed."
        case .signIn(let title): "Open \(title) and sign in again to refresh usage."
        }
    }
}
