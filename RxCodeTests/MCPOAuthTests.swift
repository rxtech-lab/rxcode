import XCTest
import RxCodeCore
import CryptoKit
@testable import RxCode

@MainActor
final class MCPOAuthTests: XCTestCase {
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
    override func stopLoading() {}
}
