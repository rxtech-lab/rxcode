import XCTest

/// iPad task ordering and navigation flows.
///
/// On iPad the app uses a three-column `NavigationSplitView`. Opening a thread
/// swaps in the chat without unwinding navigation, so the list column the user
/// came from stays visible — that persistence is what these tests assert,
/// instead of navigating back as the iPhone tests do.
final class iPadNavigationUITests: XCTestCase {

    @MainActor
    func testTaskProjectsCanBeDraggedAndKeepTheirOrder() throws {
        let session = try UITestRunner.launch(.pad, on: self)
        let app = session.app
        let alpha = app.buttons["tasks-dashboard-project-A0000000-0000-0000-0000-000000000001"]
        let beta = app.buttons["tasks-dashboard-project-B0000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 15))
        XCTAssertTrue(beta.exists)
        let overview = app.descendants(matching: .any)["tasks-ipad-overview"].firstMatch
        let cardContent = app.scrollViews["tasks-ipad-project-content-A0000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(overview.exists)
        XCTAssertTrue(cardContent.exists)
        XCTAssertGreaterThan(cardContent.frame.height, overview.frame.height * 0.65)
        XCTAssertLessThan(abs(alpha.frame.minY - beta.frame.minY), 10)

        let first = isBefore(alpha, beta) ? alpha : beta
        let second = isBefore(alpha, beta) ? beta : alpha
        first.press(forDuration: 1, thenDragTo: second)
        XCTAssertFalse(isBefore(first, second), "Dragging a project should change its place in the row.")

        app.terminate()
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        XCTAssertTrue(second.exists)
        XCTAssertFalse(isBefore(first, second), "The project order should survive a relaunch.")
    }

    @MainActor
    private func isBefore(_ first: XCUIElement, _ second: XCUIElement) -> Bool {
        let left = first.frame
        let right = second.frame
        return abs(left.minY - right.minY) < 10 ? left.minX < right.minX : left.minY < right.minY
    }

    @MainActor
    func testSettingsOpensRemoteTasksFullScreen() throws {
        let session = try UITestRunner.launch(.pad, on: self, additionalLaunchArguments: ["-uitest-cloud"])
        let app = session.app
        session.robot.tap(app.buttons["open-settings"], "Settings toolbar button")
        session.robot.tap(app.buttons["settings-view-remote-tasks"], "View Remote Tasks")

        let tasksBar = app.navigationBars["Tasks"].firstMatch
        XCTAssertTrue(tasksBar.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(tasksBar.frame.width, app.frame.width * 0.85)
        XCTAssertTrue(app.staticTexts["Cloud Project"].firstMatch.waitForExistence(timeout: 15))

        app.buttons["settings-remote-tasks-done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Case 2: Briefing → briefing detail → thread → messages, and the briefing
    /// list column remains visible (split view keeps context).
    @MainActor
    func testBriefingSplitKeepsListVisible() throws {
        let r = try UITestRunner.launch(.pad, on: self).robot

        // The app opens on Tasks; switch the sidebar to Briefing.
        r.tap(r.sidebarBriefingItem, "Briefing item in the sidebar")
        r.tap(r.anyBriefingListCard, "a briefing card in the list column")
        r.assertExists(r.briefingDetailScreen, "briefing detail screen")

        r.tap(r.anyBriefingThreadRow, "a thread row in the briefing detail")
        r.assertMessagesShown()

        // The chat is pushed inside the detail column; the briefing list column
        // stays on screen — the split view never lost the briefing context.
        r.assertExists(r.briefingListScreen, "briefing list column still visible")
    }

    /// Briefing split → briefing detail → New Thread → compose → send → chat
    /// for the new thread is shown in the detail column, the briefing list
    /// column stays visible, and the chat keeps its content after the desktop
    /// snapshot settles (the empty-chat-after-creation regression).
    @MainActor
    func testNewThreadFromBriefingSplitOpensChat() throws {
        let r = try UITestRunner.launch(.pad, on: self).robot

        r.tap(r.sidebarBriefingItem, "Briefing item in the sidebar")
        r.tap(r.anyBriefingListCard, "a briefing card in the list column")
        r.assertExists(r.briefingDetailScreen, "briefing detail screen")

        r.tap(r.briefingDetailNewThreadButton, "new thread button in briefing detail")
        r.createNewThread(with: "Help me investigate the empty chat bug.")

        // The chat appears in the detail column and the briefing list column
        // stays alongside it — the split view never lost the briefing context.
        r.assertMessagesShown()
        r.assertExists(r.briefingListScreen, "briefing list column still visible")
        // Sustain the chat for a beat so a delayed snapshot can't quietly
        // navigate us into the projects split.
        Thread.sleep(forTimeInterval: 2.0)
        r.assertExists(r.chatScreen, "chat screen remains after snapshot settles")
        r.assertMessagesShown()
        r.assertExists(r.briefingListScreen, "briefing list column still visible after settle")
    }

    /// Case 4: Projects → project → thread list → thread → messages, and the
    /// thread list column remains visible (split view keeps context).
    @MainActor
    func testProjectsSplitKeepsThreadListVisible() throws {
        let r = try UITestRunner.launch(.pad, on: self).robot

        // Selecting a project in the sidebar switches to the projects split view.
        r.tap(r.anyProjectRow, "a project row in the sidebar")
        r.assertExists(r.threadListScreen, "thread list column")

        r.tap(r.anyThreadRow, "a thread row")
        r.assertMessagesShown()

        // The chat fills the detail column; the thread list column stays visible.
        r.assertExists(r.threadListScreen, "thread list column still visible")
    }
}
