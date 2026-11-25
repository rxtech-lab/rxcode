import XCTest

final class AgentHubUITests: XCTestCase {
    @MainActor
    func testCreateAgentAndOpenMemory() throws {
        continueAfterFailure = false
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1"]
        app.launchArguments = ["-onboardingCompleted", "YES", "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let releaseNotes = app.sheets.containing(.staticText, identifier: "New in RxCode").firstMatch
        if releaseNotes.waitForExistence(timeout: 3) { releaseNotes.buttons["xmark"].click() }
        let agents = app.buttons["general-route-agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 30))
        agents.click()
        app.buttons["New Agent"].firstMatch.click()
        let name = app.sheets.textFields["agent-profile-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Studio Assistant")
        app.sheets.buttons["Save"].click()
        let profile = app.descendants(matching: .any)["agent-profile-Studio Assistant"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.click()
        app.descendants(matching: .any)["agent-memory"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No Memory Yet"].firstMatch.waitForExistence(timeout: 5))
    }
}
