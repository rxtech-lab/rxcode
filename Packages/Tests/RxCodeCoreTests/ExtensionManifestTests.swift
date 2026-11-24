import Darwin
import Foundation
import XCTest
@testable import RxCodeCore

final class ExtensionManifestTests: XCTestCase {
    private func manifest(
        id: String = "app.rxlab.extensions.example", version: String = "1.2.0",
        api: String = "2.0", permissions: [[String: Any]] = []
    ) throws -> ExtensionManifest {
        let json: [String: Any] = [
            "id": id, "name": "Example", "version": version, "pluginAPI": api, "readme": "README.md",
            "permissions": permissions, "futureKey": 42, "contributes": [
                "usage.provider": [["pluginID": "github-ci", "title": "GitHub CI"]],
                "usage.card": true, "usage.detail": false, "settings": true,
                "inspector.panel": ["title": "Inspector", "symbol": "chart.bar"], "futureSurface": true,
            ] as [String: Any],
        ]
        return try JSONDecoder().decode(ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testUnknownFieldsAndImplicitPermissions() throws {
        let model = try manifest(permissions: [["id": "network", "domains": ["api.example.com"]]])
        try model.validate(reportedScenes: ["usage-card", "inspector", "settings"], providerOwners: ["github-ci": model.id])
        XCTAssertEqual(model.effectivePermissions.map(\.id), [.projectRead, .storage, .network])
        XCTAssertThrowsError(try model.validate(reportedScenes: ["settings"]))
        XCTAssertThrowsError(try model.validate(providerOwners: ["github-ci": "app.other.owner"]))
        XCTAssertEqual(try JSONDecoder().decode(ExtensionManifest.self, from: JSONEncoder().encode(model)), model)
    }

    func testInvalidIDsScopesAndVersions() throws {
        for id in ["simple", ".example", "../example", "com.test.", "app.bad\nline", "app.-bad"] {
            XCTAssertThrowsError(try manifest(id: id).validate(), id)
        }
        XCTAssertThrowsError(try manifest(api: "1.0").validate())
        XCTAssertThrowsError(try manifest(version: "../escape").validate())
        for permissions: [[String: Any]] in [
            [["id": "unknown"]], [["id": "network"]], [["id": "network", "domains": ["*.example.com"]]],
            [["id": "network", "domains": ["host/path"]]], [["id": "network", "domains": [""]]],
            [["id": "storage", "slots": ["wrong"]]], [["id": "credentials.use", "slots": ["a\nb"]]],
            [["id": "vault.read"], ["id": "vault.read"]],
        ] {
            XCTAssertThrowsError(try manifest(permissions: permissions).validate())
        }
    }

    func testPermissionDecisionsSurviveRelaunchAndVersionBumps() throws {
        let slots = ["acp:opencode", "acp:antigravity"]
        let model = try manifest(permissions: [["id": "acp.credentials.use", "slots": slots]])
        let permission = try XCTUnwrap(model.permissions.first)
        var decisions = ExtensionPermissionDecisions()
        XCTAssertEqual(decisions.access(to: .projectRead, in: model, origin: .background), .granted)
        XCTAssertEqual(decisions.access(to: .diskRead, in: model, origin: .userInitiated), .permissionDenied)
        XCTAssertEqual(decisions.access(to: permission.id, in: model, origin: .background), .permissionPending)
        decisions.decide(.skip, permission: permission, extensionID: model.id)
        XCTAssertEqual(decisions.access(to: permission.id, in: model, origin: .background), .permissionPending)
        XCTAssertEqual(decisions.access(to: permission.id, in: model, origin: .userInitiated), .needsPrompt)
        decisions.decide(.reject, permission: permission, extensionID: model.id)
        XCTAssertEqual(decisions.access(to: permission.id, in: model, origin: .userInitiated), .permissionDenied)

        decisions.decide(.confirm, permission: permission, extensionID: model.id)
        decisions = try JSONDecoder().decode(ExtensionPermissionDecisions.self, from: JSONEncoder().encode(decisions))
        let update = try manifest(version: "2.0.0", permissions: [["id": "acp.credentials.use", "slots": Array(slots.reversed())]])
        decisions.reconcile(update)
        XCTAssertEqual(decisions.access(to: permission.id, in: update, origin: .background), .granted)

        let widened = try manifest(permissions: [["id": "acp.credentials.use", "slots": slots + ["acp:new"]]])
        decisions.reconcile(widened)
        XCTAssertEqual(decisions.access(to: permission.id, in: widened, origin: .background), .permissionPending)
        XCTAssertNil(decisions.decision(for: permission, extensionID: model.id))
        decisions.decide(.confirm, permission: permission, extensionID: model.id)
        decisions.reconcile(try manifest())
        XCTAssertEqual(decisions.access(to: permission.id, in: model, origin: .userInitiated), .needsPrompt)
    }

    func testDevelopmentAndDistributionGrantsRemainIndependent() throws {
        let model = try manifest(permissions: [["id": "vault.read"]])
        let permission = try XCTUnwrap(model.permissions.first)
        var decisions = ExtensionPermissionDecisions()
        decisions.decide(.confirm, permission: permission, extensionID: model.id)
        let developmentID = "host.development.local.example.service"
        decisions.reconcile(model, identity: developmentID)
        XCTAssertEqual(decisions.access(to: .vaultRead, in: model, origin: .background, identity: developmentID), .permissionPending)
        XCTAssertEqual(decisions.access(to: .vaultRead, in: model, origin: .background), .granted)
    }

    func testSensitiveNames() {
        for path in [".env", ".ENV.Local", ".SSH/config", ".aws/config", ".gnupg/options", ".GIT/CONFIG",
                     ".RxCode/secrets/a", ".netrc", ".NPMRC", ".pypirc", "private.P12", "private.p8",
                     "key.PEM", "a.key", "id_rsa.pub", "id_ED25519-foo", "db.keychain-db"] {
            XCTAssertTrue(ExtensionFileAccess.isSensitive(path.split(separator: "/").map(String.init)), path)
        }
        for path in [".env.example", ".env.sample", ".env.template", "main.swift"] {
            XCTAssertFalse(ExtensionFileAccess.isSensitive([path]), path)
        }
    }

    func testDirectoryScopedReadAndList() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        let project = dir.appending(path: "project")
        let bytes = Data("example".utf8)
        try fm.createDirectory(at: project.appending(path: "src"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for path in ["project/src/main.swift", "project/.env.example", "project/.env", "outside"] {
            try bytes.write(to: dir.appending(path: path))
        }
        try fm.createSymbolicLink(at: project.appending(path: "alias"), withDestinationURL: dir.appending(path: "outside"))
        try fm.createSymbolicLink(at: project.appending(path: "another"), withDestinationURL: dir)
        try fm.linkItem(at: project.appending(path: ".env"), to: project.appending(path: "hard-link"))
        let access = try ExtensionFileAccess(projectRoot: project)
        XCTAssertEqual(try access.read("src/main.swift"), bytes)
        XCTAssertEqual(try access.read(".env.example"), bytes)
        XCTAssertEqual(try access.list("."), [".env.example", "src"])
        for path in [".env", "../outside", "alias", "another/outside", "hard-link", "src/main.swift\0", dir.appending(path: "outside").path] {
            XCTAssertThrowsError(try access.read(path), path)
        }
        XCTAssertThrowsError(try access.list("another"))
        XCTAssertEqual(try access.read(".env", diskReadGranted: true), bytes)
        let canonicalPath = try XCTUnwrap(realpath(dir.appending(path: "outside").path, nil))
        defer { free(canonicalPath) }
        XCTAssertEqual(try access.read(String(cString: canonicalPath), diskReadGranted: true), bytes)
    }
}
