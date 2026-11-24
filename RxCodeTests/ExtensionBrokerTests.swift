import Foundation
import RxCodeCore
import RxCodeExtensionSDK
import XCTest
@testable import RxCode

@MainActor
final class ExtensionBrokerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: root.appending(path: "main.swift"))
        try Data("fixture".utf8).write(to: root.appending(path: ".env"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func manifest(_ permissions: [[String: Any]]) throws -> ExtensionManifest {
        let json: [String: Any] = [
            "id": "app.rxlab.extensions.test", "name": "Test", "version": "1.0", "pluginAPI": "2.0",
            "readme": "README.md", "permissions": permissions, "contributes": [:] as [String: Any],
        ]
        return try JSONDecoder().decode(ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testDefaultFileAccessAndBlockedSession() async throws {
        let broker = try ExtensionBroker(manifest: manifest([]), projectRoot: root, bundleIdentifier: UUID().uuidString)
        let allowed = try ExtensionRequest(.filesRead, ["path": "main.swift"])
        let data = try await broker.handle(allowed).decode(Data.self, for: allowed)
        XCTAssertEqual(data, Data("source".utf8))
        let restricted = try ExtensionRequest(.filesRead, ["path": ".env"])
        let denied = await broker.handle(restricted)
        XCTAssertThrowsError(try denied.decode(Data.self, for: restricted)) {
            XCTAssertEqual($0 as? ExtensionCallError, .permissionDenied)
        }
        broker.block()
        let blocked = await broker.handle(allowed)
        XCTAssertThrowsError(try blocked.decode(Data.self, for: allowed)) {
            XCTAssertEqual($0 as? ExtensionCallError, .extensionBlocked)
        }
    }

    func testSensitiveReadFromBackgroundDoesNotPrompt() async throws {
        let broker = try ExtensionBroker(manifest: manifest([["id": "disk.read"]]), projectRoot: root,
                                         bundleIdentifier: UUID().uuidString)
        let read = try ExtensionRequest(.filesRead, ["path": ".env"])
        let result = await broker.handle(read)
        XCTAssertThrowsError(try result.decode(Data.self, for: read)) {
            XCTAssertEqual($0 as? ExtensionCallError, .permissionPending)
        }
    }

    func testStorageIsScopedToHostIdentityAndSurvivesNewSession() async throws {
        let identity = UUID().uuidString
        let manifest = try manifest([])
        let broker = try ExtensionBroker(manifest: manifest, projectRoot: root, bundleIdentifier: identity)
        let put = try ExtensionRequest(.storageSet, ["key": "choice", "value": "dark"])
        _ = try await broker.handle(put).decode(String.self, for: put)
        let get = try ExtensionRequest(.storageGet, ["key": "choice"])
        let reloaded = try ExtensionBroker(manifest: manifest, projectRoot: root, bundleIdentifier: identity)
        let restored = try await reloaded.handle(get).decode(String.self, for: get)
        XCTAssertEqual(restored, "dark")
        let other = try ExtensionBroker(manifest: manifest, projectRoot: root, bundleIdentifier: UUID().uuidString)
        let isolated = try await other.handle(get).decode(String?.self, for: get)
        XCTAssertNil(isolated)
    }

    func testBlockingAConnectionDiscardsAnInFlightNetworkReply() async throws {
        let started = expectation(description: "Entered broker transport")
        let release = AsyncStream<Void>.makeStream()
        let broker = try ExtensionBroker(manifest: manifest([["id": "network", "domains": ["example.test"]]]),
                                         projectRoot: root, bundleIdentifier: UUID().uuidString) { _, _ in
            started.fulfill()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
            return ExtensionNetworkResponse(status: 200, body: Data("late usage".utf8))
        }
        let fetch = try ExtensionRequest(.netFetch, ["url": "https://example.test/usage"])
        let pending = Task { await broker.handle(fetch) }
        await fulfillment(of: [started], timeout: 3)
        broker.block()
        release.continuation.yield(())
        release.continuation.finish()
        let reply = await pending.value
        XCTAssertThrowsError(try reply.decode(Data.self, for: fetch)) {
            XCTAssertEqual($0 as? ExtensionCallError, .extensionBlocked)
        }
    }

    func testNetworkOriginAndCredentialBinding() async throws {
        let domains: Set<String> = ["api.example.com"]
        for raw in ["http://api.example.com/", "https://api.example.com:8443/", "https://test.api.example.com/",
                    "https://api.example.com.invalid/", "https://name@api.example.com/"] {
            XCTAssertFalse(ExtensionRedirectPolicy.permits(try XCTUnwrap(URL(string: raw)), domains: domains), raw)
        }
        XCTAssertTrue(ExtensionRedirectPolicy.permits(try XCTUnwrap(URL(string: "https://api.example.com/data")), domains: domains))
        let broker = try ExtensionBroker(manifest: manifest([
            ["id": "network", "domains": ["api.example.com"]], ["id": "credentials.use", "slots": ["primary"]],
        ]), projectRoot: root, bundleIdentifier: UUID().uuidString)
        let fetch = try ExtensionRequest(.netFetch, ["url": "https://api.example.com/me", "credentialSlot": "primary"])
        let reply = await broker.handle(fetch)
        XCTAssertThrowsError(try reply.decode(Data.self, for: fetch)) {
            XCTAssertEqual($0 as? ExtensionCallError, .permissionDenied)
        }
    }
}
