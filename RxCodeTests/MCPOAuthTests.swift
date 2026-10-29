import XCTest
import RxCodeCore
import CryptoKit
import Synchronization
@testable import RxCode

@MainActor
final class MCPOAuthTests: XCTestCase {
    func testCloudflareDefaultScopesReachAuthorizationRequest() throws {
        for saved in [nil, UsageOAuthConfiguration(),
                      UsageOAuthConfiguration(clientID: CloudflareUsageOAuth.clientID, scopes: " \n"),
                      UsageOAuthConfiguration(clientID: CloudflareUsageOAuth.clientID,
                                              scopes: "account-analytics.read workers-r2.read zone.read")] {
            let config = CloudflareUsageOAuth.configuration(saved)
            let request = UsageOAuthSignIn.authorizeURL("https://dash.cloudflare.com/oauth2/auth", config: config)
            let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first { $0.name == "scope" }?.value,
                           "account-analytics.read workers-r2.read zone.read memberships.read")
        }
    }

    func testCloudflarePreservesExplicitScopesAndCustomClients() {
        let custom = UsageOAuthConfiguration(clientID: "custom", callbackURL: CloudflareUsageOAuth.callbackURL)
        XCTAssertEqual(CloudflareUsageOAuth.configuration(custom), custom)
        let explicit = UsageOAuthConfiguration(clientID: CloudflareUsageOAuth.clientID,
                                              callbackURL: CloudflareUsageOAuth.callbackURL, scopes: "zone.read")
        XCTAssertEqual(CloudflareUsageOAuth.configuration(explicit), explicit)
    }

    func testCloudflareMigratesLegacyCallbackWithoutChangingClientOrScopes() {
        var saved = UsageOAuthConfiguration(clientID: "client", scopes: "account:read")
        let migrated = CloudflareUsageOAuth.configuration(saved)
        XCTAssertEqual(migrated.callbackURL, "http://localhost:47616/oauth/callback")
        XCTAssertEqual(migrated.clientID, saved.clientID)
        XCTAssertEqual(migrated.scopes, saved.scopes)
        saved.callbackURL = "http://127.0.0.1:49152/oauth/callback"
        XCTAssertEqual(CloudflareUsageOAuth.configuration(saved), saved)
    }

    func testCloudflareOnlyAcceptsExplicitHTTPCallbackPortsOnLoopback() {
        XCTAssertEqual(CloudflareUsageOAuth.callbackPort(CloudflareUsageOAuth.callbackURL), 47616)
        XCTAssertEqual(CloudflareUsageOAuth.callbackPort("http://127.0.0.1:49152/oauth/callback"), 49152)
        for invalid in ["rxcode://usage-oauth", "https://localhost:47616/oauth/callback",
                        "http://example.com:47616/oauth/callback", "http://localhost/oauth/callback",
                        "http://localhost:0/oauth/callback", "http://localhost:47616/other",
                        "http://user@localhost:47616/oauth/callback",
                        "http://localhost:47616/oauth/callback?code=forged",
                        "http://localhost:47616/oauth/callback#fragment"] {
            XCTAssertNil(CloudflareUsageOAuth.callbackPort(invalid), invalid)
        }
    }

    private let resource = "https://refresh-fixture.example/mcp"

    private func refreshFixture(expiry: Date? = nil, refreshToken: String? = "refresh-original") -> (MCPOAuthService, OAuthMemoryStorage) {
        let saved = MCPOAuthService.Credential(
            accessToken: "original", refreshToken: refreshToken, expiresAt: expiry,
            clientID: "rxcode", tokenEndpoint: URL(string: "https://refresh-fixture.example/token")!, resource: resource
        )
        let storage = OAuthMemoryStorage(saved)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthFixtureProtocol.self]
        return (MCPOAuthService(session: URLSession(configuration: configuration), storage: storage.storage), storage)
    }

    func testExpiredTokenRefreshesAndPersistsRotation() async throws {
        let (service, storage) = refreshFixture(expiry: .distantPast)
        let token = try await service.accessToken(for: resource)
        XCTAssertEqual(token, "renewed")
        XCTAssertEqual(storage.credential?.refreshToken, "refresh-rotated")
        XCTAssertEqual(storage.writes, 1)
        XCTAssertGreaterThan(try XCTUnwrap(storage.credential?.expiresAt).timeIntervalSinceNow, 3500)
    }

    func testConcurrentRefreshesShareOneRotationAndLateRejectionUsesCurrentToken() async throws {
        let (service, storage) = refreshFixture(expiry: .distantPast)
        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<20 { group.addTask { try await service.accessToken(for: "https://refresh-fixture.example/mcp") } }
            var tokens: [String?] = []
            for try await token in group { tokens.append(token) }
            return tokens
        }
        XCTAssertTrue(tokens.allSatisfy { $0 == "renewed" })
        let current = try await service.accessToken(for: resource, rejecting: "original")
        XCTAssertEqual(current, "renewed")
        XCTAssertEqual(storage.writes, 1)
    }

    func test401RefreshesTokenWithoutExpiryAndRetriesOriginalRequest() async throws {
        let (service, storage) = refreshFixture()
        var request = URLRequest(url: URL(string: resource)!)
        request.httpMethod = "POST"
        request.httpBody = Data("original-request".utf8)
        request.setValue("session-123", forHTTPHeaderField: "Mcp-Session-Id")
        let (data, response) = try await service.data(for: request, resource: resource)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"accepted\":true}")
        XCTAssertEqual(storage.writes, 1)
    }

    func testDoesNotRetry403OrRepeated401() async throws {
        for path in ["/forbidden", "/always-unauthorized"] {
            let (service, storage) = refreshFixture()
            let request = URLRequest(url: URL(string: "https://refresh-fixture.example" + path)!)
            let (_, response) = try await service.data(for: request, resource: resource)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, path == "/forbidden" ? 403 : 401)
            XCTAssertEqual(storage.writes, path == "/forbidden" ? 0 : 1)
        }
    }

    func testRefreshResponseWithoutRefreshTokenPreservesExistingOne() async throws {
        let (service, storage) = refreshFixture(expiry: .distantPast, refreshToken: "keep-existing")
        _ = try await service.accessToken(for: resource)
        XCTAssertEqual(storage.credential?.refreshToken, "keep-existing")
    }

    func testTokenWithoutRefreshCredentialRemainsUsableUntilExpiry() async throws {
        let (service, storage) = refreshFixture(expiry: Date().addingTimeInterval(30), refreshToken: nil)
        let token = try await service.accessToken(for: resource)
        XCTAssertEqual(token, "original")
        XCTAssertEqual(storage.writes, 0)
        do {
            _ = try await service.accessToken(for: resource, rejecting: "original")
            XCTFail("A rejected token without refresh credentials requires sign-in")
        } catch is MCPOAuthService.AuthError {}
    }

    func testFailedRefreshKeepsCredentialsForLaterRetry() async throws {
        let (service, storage) = refreshFixture(expiry: .distantPast, refreshToken: "fail-refresh")
        for _ in 0..<2 {
            do {
                _ = try await service.accessToken(for: resource)
                XCTFail("Refresh should fail")
            } catch is MCPOAuthService.AuthError {}
        }
        XCTAssertEqual(storage.credential?.accessToken, "original")
        XCTAssertEqual(storage.writes, 0)
    }

    func testSignOutCancelsRefreshWithoutRestoringCredentials() async throws {
        let (service, storage) = refreshFixture(expiry: .distantPast, refreshToken: "slow-refresh")
        let pending = Task { try await service.accessToken(for: resource) }
        try await Task.sleep(for: .milliseconds(30))
        try await service.signOut(resource: resource)
        do {
            _ = try await pending.value
            XCTFail("Signed-out credentials must not be restored")
        } catch {}
        XCTAssertNil(storage.credential)
        XCTAssertEqual(storage.writes, 0)
    }

    /// Run the repository's Postman simulation on port 49491 to enable this check.
    func testRelayRefreshesOverHTTPAndPreservesSSEAndProviderRouting() async throws {
        let origin = ProcessInfo.processInfo.environment["MCP_OAUTH_SIMULATION_URL"] ?? "http://127.0.0.1:49491/oauth"
        let base = try XCTUnwrap(URL(string: origin))
        var reset = URLRequest(url: base.appendingPathComponent("reset"), timeoutInterval: 2)
        reset.httpMethod = "POST"
        let session = URLSession(configuration: .ephemeral)
        do {
            let (_, response) = try await session.data(for: reset)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        } catch {
            if ProcessInfo.processInfo.environment["MCP_OAUTH_SIMULATION_URL"] != nil { throw error }
            throw XCTSkip("Start postman/simulations/mcp-oauth.sim.yaml on port 49491 for the HTTP integration test.")
        }
        let resource = base.appendingPathComponent("mcp")
        let saved = MCPOAuthService.Credential(accessToken: "fixture-expired", refreshToken: "fixture-refresh",
            expiresAt: .distantPast, clientID: "rxcode-fixture", tokenEndpoint: base.appendingPathComponent("token"),
            resource: resource.absoluteString)
        let storage = OAuthMemoryStorage(saved)
        let oauth = MCPOAuthService(storage: storage.storage)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(MCPConfiguration()).write(to: root.appendingPathComponent("mcp.json"))
        let mcp = MCPService(baseURL: root, claudeService: ClaudeService(cliStore: CLISessionStore(metaStore: SessionMetaStore())), oauth: oauth)
        var spec = MCPServerSpec(name: "oauth", transport: .http, url: resource.absoluteString)
        spec.headers = [MCPKeyValue(key: "X-Fixture-Header", value: "preserved")]
        try await mcp.add(spec: spec, scope: .user, projectPath: nil)
        let records = await mcp.enabledServerRecords(projectPath: nil)
        let record = try XCTUnwrap(records.first)
        let local = try XCTUnwrap(record.url.flatMap(URL.init(string:)))
        XCTAssertEqual(local.host, "127.0.0.1")
        XCTAssertNotEqual(local, resource)
        XCTAssertTrue(record.headers.isEmpty)
        let acp = await mcp.acpMCPServers(projectPath: nil)
        guard case .string(let acpURL) = acp.first?["url"] else { return XCTFail("Missing ACP relay URL") }
        XCTAssertEqual(acpURL, local.absoluteString)
        let codex = await mcp.codexConfigOverrides(projectPath: nil)
        XCTAssertTrue(codex.contains { $0.contains(local.absoluteString) })
        let generatedPath = await mcp.writeClaudeConfig(projectPath: nil)
        let claudePath = try XCTUnwrap(generatedPath)
        let claude = try String(contentsOfFile: claudePath, encoding: .utf8)
        XCTAssertTrue(claude.contains(String(local.port!)))
        XCTAssertFalse(claude.contains("fixture-access"))
        var request = URLRequest(url: local)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("accepted"))
        XCTAssertEqual(storage.writes, 2, "Early invalidation must trigger one refresh after the initial expiry refresh")
        let (events, eventResponse) = try await session.data(from: local)
        XCTAssertEqual((eventResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id"), "fixture-session")
        let text = String(decoding: events, as: UTF8.self)
        XCTAssertTrue(text.contains("event: message"))
        let endpoint = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("data: http://") })
        let endpointURL = try XCTUnwrap(URL(string: String(endpoint.dropFirst(6))))
        XCTAssertEqual(endpointURL.host, "127.0.0.1")
        XCTAssertEqual(endpointURL.port, local.port)
        XCTAssertEqual(endpointURL.query, "session=fixture-session")
        request.url = endpointURL
        let (_, posted) = try await session.data(for: request)
        XCTAssertEqual((posted as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(storage.writes, 2)
        // Browser requests and routes without the capability never reach upstream.
        request.setValue("https://untrusted.example", forHTTPHeaderField: "Origin")
        let (_, browser) = try await session.data(for: request)
        XCTAssertEqual((browser as? HTTPURLResponse)?.statusCode, 502)
        request.setValue(nil, forHTTPHeaderField: "Origin")
        request.url = URL(string: "http://127.0.0.1:\(local.port!)/mcp")!
        let (_, unknownRoute) = try await session.data(for: request)
        XCTAssertEqual((unknownRoute as? HTTPURLResponse)?.statusCode, 502)
        try await mcp.remove(name: "oauth", scope: .user)
    }

    private func authorization(redirect: String) -> MCPOAuthService.Authorization {
        MCPOAuthService.Authorization(
            url: URL(string: "https://auth.example/authorize")!, state: "expected-state", verifier: "verifier",
            clientID: "rxcode", tokenEndpoint: URL(string: "https://auth.example/token")!,
            resource: "https://mcp.example/mcp", redirectURI: redirect
        )
    }

    func testAuthorizationUsesSelectedLoopbackRedirect() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthFixtureProtocol.self]
        let service = MCPOAuthService(session: URLSession(configuration: configuration))
        let redirect = "http://127.0.0.1:54321/oauth/callback"
        let authorization = try await service.begin(
            resource: URL(string: "https://oauth-fixture.example/mcp")!, clientID: nil, redirectURI: redirect
        )
        XCTAssertEqual(authorization.redirectURI, redirect)
        let items = URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "redirect_uri" })?.value, redirect)
    }

    func testLoopbackCallbackValidation() throws {
        let authorization = authorization(redirect: "http://127.0.0.1:54321/oauth/callback")
        let valid = "http://127.0.0.1:54321/oauth/callback?state=expected-state&code=secret"
        XCTAssertEqual(try MCPOAuthService.callbackCode(authorization, callback: URL(string: valid)!), "secret")
        for invalid in [
            valid.replacingOccurrences(of: "54321", with: "54322"),
            valid.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
            valid.replacingOccurrences(of: "/oauth/callback", with: "/other"),
            valid + "&state=expected-state", valid + "&code=other", valid + "#fragment",
            valid.replacingOccurrences(of: "expected-state", with: "wrong")
        ] {
            XCTAssertThrowsError(try MCPOAuthService.callbackCode(authorization, callback: URL(string: invalid)!))
        }
        let denied = URL(string: "http://127.0.0.1:54321/oauth/callback?state=expected-state&error=access_denied")!
        XCTAssertThrowsError(try MCPOAuthService.callbackCode(authorization, callback: denied)) {
            guard case MCPOAuthService.AuthError.denied = $0 else { return XCTFail("Expected explicit denial") }
        }
    }

    func testLoopbackReceiverRejectsForgedStateThenAcceptsCallback() async throws {
        let server = MCPOAuthCallbackServer()
        defer { server.stop() }
        let redirect = try await server.start()
        XCTAssertEqual(redirect.host, "127.0.0.1")
        let authorization = authorization(redirect: redirect.absoluteString)
        let callback = URL(string: redirect.absoluteString + "?state=expected-state&code=secret")!
        let delivery = Task {
            try await server.wait(for: authorization) { true }
        }
        await Task.yield()
        let session = URLSession(configuration: .ephemeral)
        let (_, rejected) = try await session.data(from: URL(string: redirect.absoluteString + "?state=wrong&code=secret")!)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        let (_, accepted) = try await session.data(from: callback)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let received = try await delivery.value
        XCTAssertEqual(received, callback)
    }

    func testFixedPortReceiverServesRegisteredLocalhostRedirect() async throws {
        let server = MCPOAuthCallbackServer()
        defer { server.stop() }
        let redirect = try await server.start(port: 47_616)
        XCTAssertEqual(redirect.absoluteString, "http://localhost:47616/oauth/callback")
        let callback = URL(string: redirect.absoluteString + "?state=expected&code=secret")!
        let delivery = Task {
            try await server.wait(redirectURI: redirect.absoluteString, accepts: {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value == "expected"
            }) { true }
        }
        await Task.yield()
        let session = URLSession(configuration: .ephemeral)
        let (_, rejected) = try await session.data(from: URL(string: redirect.absoluteString + "?state=wrong&code=secret")!)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        let (_, accepted) = try await session.data(from: callback)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let received = try await delivery.value
        XCTAssertEqual(received, callback)
    }

    func testLoopbackReceiverCancellation() async throws {
        let server = MCPOAuthCallbackServer()
        defer { server.stop() }
        let redirect = try await server.start()
        let authorization = authorization(redirect: redirect.absoluteString)
        let delivery = Task { try await server.wait(for: authorization) { true } }
        await Task.yield()
        delivery.cancel()
        do {
            _ = try await delivery.value
            XCTFail("Cancellation must stop waiting for the browser")
        } catch is CancellationError {}
    }

    func testRejectsInsecureOrCredentialBearingEndpoints() throws {
        for text in ["http://example.com/mcp", "file:///etc/passwd", "https://user:pass@example.com/mcp", "https://example.com/mcp#fragment"] {
            XCTAssertThrowsError(try MCPOAuthService.validate(XCTUnwrap(URL(string: text)) as URL))
        }
        try MCPOAuthService.validate(XCTUnwrap(URL(string: "https://example.com/mcp")))
        try MCPOAuthService.validate(XCTUnwrap(URL(string: "http://127.0.0.1:3000/mcp")))
    }

    func testDiscoveryRegistrationAndPKCE() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthFixtureProtocol.self]
        let service = MCPOAuthService(session: URLSession(configuration: configuration))
        let authorization = try await service.begin(resource: URL(string: "https://oauth-fixture.example/mcp")!, clientID: nil)
        let items = try XCTUnwrap(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems)
        func item(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        XCTAssertEqual(item("client_id"), "registered-client")
        XCTAssertEqual(item("redirect_uri"), MCPOAuthService.redirectURI)
        XCTAssertEqual(item("resource"), "https://oauth-fixture.example/mcp")
        XCTAssertEqual(item("code_challenge_method"), "S256")
        XCTAssertEqual(item("state"), authorization.state)
        XCTAssertEqual(item("scope"), "mcp:read")
        XCTAssertGreaterThanOrEqual(authorization.verifier.count, 43)
        let expected = Data(SHA256.hash(data: Data(authorization.verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(item("code_challenge"), expected)
    }

    func testFallsBackToRootResourceMetadataAndOpenIDDiscovery() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthFixtureProtocol.self]
        let service = MCPOAuthService(session: URLSession(configuration: configuration))
        let authorization = try await service.begin(resource: URL(string: "https://oidc-fixture.example/mcp")!, clientID: "native-client")
        XCTAssertEqual(authorization.url.host, "oidc-fixture.example")
        XCTAssertEqual(authorization.url.path, "/authorize")
    }

    func testRejectsMetadataWithoutPKCE() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthFixtureProtocol.self]
        let service = MCPOAuthService(session: URLSession(configuration: configuration))
        do {
            _ = try await service.begin(resource: URL(string: "https://no-pkce.example/mcp")!, clientID: "registered")
            XCTFail("Authorization must fail when PKCE S256 is not advertised")
        } catch { XCTAssertTrue(error.localizedDescription.contains("PKCE S256")) }
    }

    func testRejectsForgedCallbackBeforeTokenExchange() async throws {
        let authorization = MCPOAuthService.Authorization(
            url: URL(string: "https://auth.example/authorize")!, state: "expected-state", verifier: "verifier",
            clientID: "rxcode", tokenEndpoint: URL(string: "https://auth.example/token")!, resource: "https://mcp.example/mcp"
        )
        let service = MCPOAuthService()
        for callback in ["rxcode://mcp/oauth/callback?state=wrong&code=secret", "rxcode://other/oauth/callback?state=expected-state&code=secret"] {
            do {
                try await service.complete(authorization, callback: URL(string: callback)!)
                XCTFail("A forged OAuth callback must not reach the token endpoint")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("state validation"))
            }
        }
    }
}

nonisolated private final class OAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let origin = "https://" + url.host!
        let body: [String: Any]
        let status: Int
        var headers = ["Content-Type": "application/json"]
        if url.host == "refresh-fixture.example" {
            let formData = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                return data
            } ?? Data()
            let form = String(decoding: formData, as: UTF8.self)
            if url.path == "/token" {
                guard form.contains("grant_type=refresh_token"), form.contains("client_id=rxcode"),
                      form.contains("resource=https%3A%2F%2Frefresh-fixture.example%2Fmcp") else {
                    respond(status: 400, body: ["error": "invalid_request"]); return
                }
                if form.contains("fail-refresh") {
                    respond(status: 503, body: ["error": "temporarily_unavailable"]); return
                }
                var token: [String: Any] = ["access_token": "renewed", "token_type": "Bearer", "expires_in": 3600]
                if !form.contains("keep-existing") { token["refresh_token"] = "refresh-rotated" }
                let response = try! JSONSerialization.data(withJSONObject: token)
                DispatchQueue.global().asyncAfter(deadline: .now() + (form.contains("slow-refresh") ? 0.3 : 0.02)) { [self] in
                    respond(status: 200, data: response)
                }
                return
            }
            if url.path == "/forbidden" { respond(status: 403, body: [:]); return }
            let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed"
            let accepted = authorized && url.path != "/always-unauthorized"
            if accepted {
                guard request.httpMethod == "POST", form == "original-request",
                      request.value(forHTTPHeaderField: "Mcp-Session-Id") == "session-123" else {
                    respond(status: 400, body: [:]); return
                }
            }
            respond(status: accepted ? 200 : 401, body: ["accepted": accepted])
            return
        }
        switch url.path {
        case "/mcp":
            body = [:]
            status = 401
            headers["WWW-Authenticate"] = url.host == "oidc-fixture.example"
                ? "Bearer scope=\"mcp:read\""
                : "Bearer resource_metadata=\"\(origin)/resource-metadata\", scope=\"mcp:read\""
        case "/resource-metadata", "/.well-known/oauth-protected-resource":
            body = ["resource": origin + "/mcp", "authorization_servers": [origin], "scopes_supported": ["all:permissions"]]
            status = 200
        case "/.well-known/oauth-authorization-server" where url.host == "oidc-fixture.example":
            body = [:]
            status = 404
        case "/.well-known/oauth-authorization-server", "/.well-known/openid-configuration":
            body = ["issuer": origin, "authorization_endpoint": origin + "/authorize", "token_endpoint": origin + "/token",
                    "registration_endpoint": origin + "/register",
                    "code_challenge_methods_supported": url.host == "no-pkce.example" ? [] : ["S256"]]
            status = 200
        case "/register":
            body = ["client_id": "registered-client"]
            status = 201
        default:
            body = [:]
            status = 400
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    private func respond(status: Int, body: [String: Any]) {
        respond(status: status, data: try! JSONSerialization.data(withJSONObject: body, options: .sortedKeys))
    }
    private let stopped = Mutex(false)
    private func respond(status: Int, data: Data) {
        guard !stopped.withLock({ $0 }) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                           headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}

nonisolated private final class OAuthMemoryStorage: Sendable {
    private struct State {
        var credential: MCPOAuthService.Credential?
        var writes = 0
    }
    private let state: Mutex<State>
    init(_ credential: MCPOAuthService.Credential) { state = Mutex(State(credential: credential)) }
    var credential: MCPOAuthService.Credential? { state.withLock { $0.credential } }
    var writes: Int { state.withLock { $0.writes } }
    var storage: MCPOAuthService.CredentialStorage {
        .init(read: { [self] resource in state.withLock { $0.credential?.resource == resource ? $0.credential : nil } },
              write: { [self] credential in state.withLock { $0.credential = credential; $0.writes += 1 } },
              delete: { [self] _ in state.withLock { $0.credential = nil } })
    }
}
