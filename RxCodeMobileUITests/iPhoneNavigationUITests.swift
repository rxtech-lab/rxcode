import XCTest

/// iPhone navigation flows (UI test cases 1 & 3).
///
/// On iPhone the app uses a `TabView` with `NavigationStack` tabs, so each flow
/// pushes a detail screen and navigates back with the navigation-bar back button.
final class iPhoneNavigationUITests: XCTestCase {

    @MainActor
    func testPublishedDocumentAppearsBesideProjectBriefings() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot

        r.tap(r.briefingTab, "Briefing tab")
        r.assertExists(r.anyBriefingCard, "project briefing card")
        r.tap(r.anyBriefingDocumentCard, "published document briefing card")
        r.assertExists(r.briefingDocumentDetail, "published document detail")
    }

    @MainActor
    func testToolGroupsExpandAndShowFullLongResult() throws {
        let session = try UITestRunner.launch(.phone, on: self, additionalLaunchArguments: ["-uitest-tool-activity"])
        let r = session.robot
        let app = session.app
        XCUIDevice.shared.orientation = .portrait
        r.tap(r.anyBriefingCard, "briefing card")
        r.tap(r.anyBriefingThreadRow, "briefing thread")
        let toggle = app.buttons["tool-activity-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "Collapsed tool group")
        toggle.tap()
        let call = app.buttons["tool-activity-fixture-bash"]
        XCTAssertTrue(call.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Failed"].exists)
        XCTAssertLessThanOrEqual(call.frame.maxX, app.frame.maxX)
        attachScreenshot(app, name: "Expanded tool calls")
        call.tap()
        XCTAssertTrue(app.navigationBars["Bash"].waitForExistence(timeout: 5))
        let firstRecord = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Task 1:")).firstMatch
        XCTAssertTrue(firstRecord.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRecord.isHittable, "JSON must draw on the first result page")
        attachScreenshot(app, name: "Visible first JSON result page")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(firstRecord.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRecord.isHittable)
        let pager = app.buttons["tool-detail-page-picker"]
        XCTAssertTrue(pager.exists && pager.isHittable)
        app.buttons["Next page"].tap()
        let nextRecord = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Task 9:")).firstMatch
        XCTAssertTrue(nextRecord.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Visible JSON result in landscape")
        pager.tap()
        app.buttons["Last Page"].tap()
        let end = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "END OF TOOL RESULT")).firstMatch
        for _ in 0..<8 {
            if end.exists && end.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(end.exists && end.isHittable, "The last page must be directly reachable")
        attachScreenshot(app, name: "Last JSON result page")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Parameters"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "build")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Raw Result"].tap()
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Raw result on separate tab")
        app.buttons["Done"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertFalse(call.exists)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Case 1: Briefing tab → briefing detail → thread → messages → back →
    /// briefing detail is shown again.
    @MainActor
    func testBriefingFlowReturnsToDetailAfterBack() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot

        r.tap(r.briefingTab, "Briefing tab")
        r.tap(r.anyBriefingCard, "a briefing card")
        r.assertExists(r.briefingDetailScreen, "briefing detail screen")

        r.tap(r.anyBriefingThreadRow, "a thread row in the briefing detail")
        r.assertMessagesShown()

        r.navigateBack()
        r.assertExists(r.briefingDetailScreen, "briefing detail screen after back")
        r.assertDisappears(r.chatScreen, "chat screen after navigating back")
    }

    /// Briefing tab → briefing detail → New Thread → compose → send → chat for
    /// the new thread is shown and remains shown after the desktop snapshot
    /// settles (the empty-chat-after-creation regression).
    @MainActor
    func testNewThreadFromBriefingDetailOpensChat() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot

        r.tap(r.briefingTab, "Briefing tab")
        r.tap(r.anyBriefingCard, "a briefing card")
        r.assertExists(r.briefingDetailScreen, "briefing detail screen")

        r.tap(r.briefingDetailNewThreadButton, "new thread button in briefing detail")
        r.createNewThread(with: "Help me investigate the empty chat bug.")

        // The chat screen for the freshly-created thread must appear and
        // remain populated — i.e. the briefing navigation stack should hold
        // it, not get reset by the snapshot-driven `activeSessionID` change.
        r.assertMessagesShown()
        // Sustain the assertion a bit so a delayed snapshot can't pop us off.
        Thread.sleep(forTimeInterval: 2.0)
        r.assertExists(r.chatScreen, "chat screen remains after snapshot settles")
        r.assertMessagesShown()
    }

    /// Case 3: Projects tab → project → thread list → thread → messages → back →
    /// thread list is shown again.
    @MainActor
    func testProjectsFlowReturnsToThreadListAfterBack() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot

        r.tap(r.projectsTab, "Projects tab")
        r.tap(r.anyProjectRow, "a project row")
        r.assertExists(r.threadListScreen, "thread list screen")

        r.tap(r.anyThreadRow, "a thread row")
        r.assertMessagesShown()

        r.navigateBack()
        r.assertExists(r.threadListScreen, "thread list screen after back")
        r.assertDisappears(r.chatScreen, "chat screen after navigating back")
    }
}
