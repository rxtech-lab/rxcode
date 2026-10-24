import XCTest

final class MobileVoiceInputUITests: XCTestCase {
    @MainActor
    func testFlowcyVoiceSheetLanguageAndCancelPreserveDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy"]
        app.launch()
        XCTAssertTrue(app.buttons["Agent"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Agent"].firstMatch.tap()
        let composer = app.textFields["flowcy-agent-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Keep my draft")
        app.buttons["voice-input-button"].tap()
        XCTAssertTrue(app.buttons["voice-input-record"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["voice-input-insert"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Voice input sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["voice-input-language"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("en-US")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'English'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["voice-input-record"].waitForExistence(timeout: 5))
        let selectedLanguage = app.buttons["voice-input-language"].label
        app.navigationBars["Voice Input"].buttons["Cancel"].tap()
        XCTAssertEqual(composer.value as? String, "Keep my draft")
        app.buttons["voice-input-button"].tap()
        XCTAssertTrue(app.buttons["voice-input-language"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["voice-input-language"].label, selectedLanguage)
        app.navigationBars["Voice Input"].buttons["Cancel"].tap()
    }

    @MainActor
    func testConnectedChatOpensVoiceSheet() throws {
        let session = try UITestRunner.launch(.phone, on: self)
        let robot = session.robot
        robot.tap(robot.projectsTab, "Projects tab")
        robot.tap(robot.anyProjectRow, "Project")
        robot.tap(robot.anyThreadRow, "Thread")
        robot.tap(session.app.buttons["voice-input-button"], "Voice input")
        XCTAssertTrue(session.app.buttons["voice-input-record"].waitForExistence(timeout: 5))
        XCTAssertFalse(session.app.buttons["voice-input-insert"].isEnabled)
        session.app.navigationBars["Voice Input"].buttons["Cancel"].tap()
        robot.assertExists(robot.chatScreen, "Chat after closing voice input")
    }
}
