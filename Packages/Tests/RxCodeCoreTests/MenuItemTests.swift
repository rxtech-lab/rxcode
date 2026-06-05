import XCTest
@testable import RxCodeCore

/// The whole premise of the cross-platform menu is that the desktop's
/// `[MenuItem]` survives a JSON round trip so mobile can render the identical
/// items. These tests pin that contract plus the deep-link helper.
final class MenuItemTests: XCTestCase {
    func testMenuTreeRoundTripsThroughJSON() throws {
        let projectId = UUID()
        let items: [MenuItem] = [
            MenuItem(
                id: "a",
                title: "Code Review",
                systemImage: "checklist",
                action: .command(MenuActionCommand(kind: .projectCodeReview, projectId: projectId, branch: "fix"))
            ),
            .separator(id: "sep"),
            MenuItem(
                id: "b",
                title: "Set Up Secrets",
                systemImage: "key.fill",
                action: .deepLink(MenuDeepLink.url(action: MenuDeepLink.secretsSetup, projectId: projectId))
            ),
            MenuItem(
                id: "c",
                title: "More",
                children: [
                    MenuItem(
                        id: "c1",
                        title: "Commit Files",
                        role: .destructive,
                        action: .command(MenuActionCommand(kind: .threadCommitFiles, sessionId: "sess-1"))
                    ),
                ]
            ),
        ]

        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([MenuItem].self, from: data)
        XCTAssertEqual(decoded, items)
    }

    func testAsyncCommandRoundTripsAndDefaultsWhenAbsent() throws {
        // The flag survives a JSON round trip…
        let async = MenuActionCommand(kind: .projectCreatePullRequest, projectId: UUID(), isAsync: true)
        let data = try JSONEncoder().encode(async)
        XCTAssertTrue(try JSONDecoder().decode(MenuActionCommand.self, from: data).isAsync)

        // …and decoding a payload from a peer that predates the field (no
        // `isAsync` key) defaults to a synchronous command rather than failing.
        let legacy = Data(#"{"kind":"projectCreatePullRequest"}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuActionCommand.self, from: legacy)
        XCTAssertEqual(decoded.kind, .projectCreatePullRequest)
        XCTAssertFalse(decoded.isAsync)
    }

    func testCustomCommandRoundTripsAndDefaultsWhenAbsent() throws {
        // A fully-resolved custom API command survives a JSON round trip, config
        // and all, and is marked async so both platforms show the loading dialog.
        let config = CustomMenuActionConfig(
            kind: .callAPI,
            httpMethod: "POST",
            url: "https://api.example.com/notify",
            headers: ["Authorization": "Bearer x"],
            body: #"{"branch":"main"}"#
        )
        let command = MenuActionCommand(kind: .custom, projectId: UUID(), isAsync: true, custom: config)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(MenuActionCommand.self, from: data)
        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.custom?.kind, .callAPI)
        XCTAssertEqual(decoded.custom?.headers?["Authorization"], "Bearer x")
        XCTAssertTrue(decoded.isAsync)

        // A built-in command serialized by a peer that predates `custom` still
        // decodes, with `custom` defaulting to nil.
        let legacy = Data(#"{"kind":"projectCommitAll"}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(MenuActionCommand.self, from: legacy)
        XCTAssertEqual(legacyDecoded.kind, .projectCommitAll)
        XCTAssertNil(legacyDecoded.custom)
    }

    func testDeepLinkBuildAndParse() throws {
        let projectId = UUID()
        let url = MenuDeepLink.url(action: MenuDeepLink.releaseCreate, projectId: projectId, sessionId: "s1")
        let parsed = try XCTUnwrap(MenuDeepLink.parse(url))
        XCTAssertEqual(parsed.action, MenuDeepLink.releaseCreate)
        XCTAssertEqual(parsed.projectId, projectId)
        XCTAssertEqual(parsed.sessionId, "s1")
    }

    func testParseRejectsUnrelatedURL() {
        XCTAssertNil(MenuDeepLink.parse(URL(string: "rxcode://secrets/add?repo=a/b")!))
        XCTAssertNil(MenuDeepLink.parse(URL(string: "https://example.com/menu/x")!))
    }
}
