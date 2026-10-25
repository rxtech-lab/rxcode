import XCTest

final class MobileVoiceInputUITests: XCTestCase {
    @MainActor
    func testFlowcyVoiceRecordReviewAndEdit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy", "-uitest-voice-input"]
        app.launch()
        XCTAssertTrue(app.buttons["Agent"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Agent"].firstMatch.tap()
        let composer = app.textFields["flowcy-agent-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // iMessage layout: Mic and Send share the trailing slot.
        XCTAssertFalse(app.buttons["flowcy-agent-send"].exists)
        app.buttons["voice-input-button"].tap()
        XCTAssertTrue(app.buttons["voice-input-stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voice-input-cancel"].exists)
        XCTAssertFalse(composer.exists)
        XCTAssertTrue(app.otherElements["voice-input-recording-bar"].exists)
        let recording = XCTAttachment(screenshot: app.screenshot())
        recording.name = "iMessage-style voice recording"
        recording.lifetime = .keepAlways
        add(recording)
        app.buttons["voice-input-settings"].tap()
        XCTAssertTrue(app.navigationBars["Recognition Language"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("en-US")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'English'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["voice-input-stop"].waitForExistence(timeout: 5))
        app.buttons["voice-input-stop"].tap()
        let transcript = app.buttons["voice-input-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voice-input-send"].exists)
        XCTAssertTrue(transcript.label.contains("Dictated test message"))
        let review = XCTAttachment(screenshot: app.screenshot())
        review.name = "Voice review with transcript"
        review.lifetime = .keepAlways
        add(review)
        transcript.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Dictated test message")
        XCTAssertTrue(app.buttons["flowcy-agent-send"].exists)
    }

    @MainActor
    func testConnectedChatVoiceReviewSends() throws {
        let session = try UITestRunner.launch(.phone, on: self, additionalLaunchArguments: ["-uitest-voice-input"])
        let robot = session.robot
        robot.tap(robot.projectsTab, "Projects tab")
        robot.tap(robot.anyProjectRow, "Project")
        robot.tap(robot.anyThreadRow, "Thread")
        XCTAssertFalse(session.app.buttons["send-button"].exists)
        robot.tap(session.app.buttons["voice-input-button"], "Voice input")
        let stop = session.app.buttons["voice-input-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(session.app.textFields["chat-input"].exists)
        XCTAssertTrue(session.app.otherElements["voice-input-recording-bar"].exists)
        XCTAssertTrue(session.app.buttons["voice-input-settings"].exists)
        stop.tap()
        let voiceSend = session.app.buttons["voice-input-send"]
        XCTAssertTrue(voiceSend.waitForExistence(timeout: 5))
        XCTAssertTrue(session.app.buttons["voice-input-transcript"].exists)
        voiceSend.tap()
        XCTAssertTrue(session.app.buttons["voice-input-button"].waitForExistence(timeout: 5))
        XCTAssertEqual(session.app.textFields["chat-input"].value as? String, "Message…")
        robot.assertExists(robot.chatScreen, "Chat after voice send")
    }
}
