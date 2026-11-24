import Foundation
import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class ExtensionPermissionStoreTests: XCTestCase {
    func testConcurrentInteractiveCallsShareOnePromptAndBackgroundCallsNeverPrompt() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = parent.appending(path: "extension-permissions.json")
        defer { try? FileManager.default.removeItem(at: parent) }
        let payload = """
        {"id":"app.rxlab.extensions.demo","name":"Demo","version":"1.0","pluginAPI":"2.0","readme":"README.md",
        "permissions":[{"id":"contacts.read"}],"contributes":{}}
        """
        let model = try JSONDecoder().decode(ExtensionManifest.self, from: Data(payload.utf8))
        var count = 0
        let store = ExtensionPermissionStore(url: url) { _, _, _ in
            count += 1
            try? await Task.sleep(for: .milliseconds(100))
            return .skip
        }
        let before = try await store.authorize(.contactsRead, manifest: model, identity: model.id, origin: .background)
        XCTAssertEqual(before, .permissionPending)
        XCTAssertEqual(count, 0)
        async let a = store.authorize(.contactsRead, manifest: model, identity: model.id, origin: .userInitiated)
        async let b = store.authorize(.contactsRead, manifest: model, identity: model.id, origin: .userInitiated)
        let results = try await [a, b]
        XCTAssertEqual(results, [.permissionPending, .permissionPending])
        XCTAssertEqual(count, 1)

        let reopened = ExtensionPermissionStore(url: url) { _, _, _ in
            XCTFail("A background call or a rejected permission must not prompt.")
            return .skip
        }
        let after = try await reopened.authorize(.contactsRead, manifest: model, identity: model.id, origin: .background)
        XCTAssertEqual(after, .permissionPending)
        try await reopened.set(.reject, permission: model.permissions[0], identity: model.id)
        let rejected = try await reopened.authorize(.contactsRead, manifest: model, identity: model.id, origin: .userInitiated)
        XCTAssertEqual(rejected, .permissionDenied)
    }

    func testUnattendedUpdateDropsAnOldGrantBeforePermissionReturns() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = parent.appending(path: "extension-permissions.json")
        defer { try? FileManager.default.removeItem(at: parent) }
        func manifest(version: Int, contacts: Bool) throws -> ExtensionManifest {
            let permissions = contacts ? #"[{"id":"contacts.read"}]"# : "[]"
            return try JSONDecoder().decode(ExtensionManifest.self, from: Data("""
            {"id":"app.rxlab.extensions.example","name":"Example","version":"\(version)","pluginAPI":"2.0",
             "readme":"README.md","permissions":\(permissions),"contributes":{}}
            """.utf8))
        }
        let first = try manifest(version: 1, contacts: true)
        let store = ExtensionPermissionStore(url: url) { _, _, _ in
            XCTFail("A background update requested permission.")
            return .skip
        }
        try await store.set(.confirm, permission: first.permissions[0], identity: first.id)
        try await store.review(manifest: manifest(version: 2, contacts: false), identity: first.id, interactive: false)
        let restored = try manifest(version: 3, contacts: true)
        try await store.review(manifest: restored, identity: first.id, interactive: false)
        let access = try await store.authorize(.contactsRead, manifest: restored, identity: first.id, origin: .background)
        XCTAssertEqual(access, .permissionPending)
    }
}
