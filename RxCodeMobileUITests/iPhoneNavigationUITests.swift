import RxCodeCore
import RxCodeSync
import XCTest

/// iPhone navigation flows (UI test cases 1 & 3).
///
/// On iPhone the app uses a `TabView` with `NavigationStack` tabs, so each flow
/// pushes a detail screen and navigates back with the navigation-bar back button.
final class iPhoneNavigationUITests: XCTestCase {

    @MainActor
    func testComputerUseConfirmationSendsBothDecisionsToTheMac() throws {
        let session = try UITestRunner.launch(.phone, on: self)
        let r = session.robot
        r.tap(r.projectsTab, "Projects tab")
        r.tap(r.app.buttons["project-row-A0000000-0000-0000-0000-000000000001"], "Project Alpha")
        r.tap(r.app.buttons["thread-row-sess-alpha-1"].firstMatch, "Alpha Thread One")
        r.assertExists(r.chatScreen, "chat screen")

        let alert = r.app.alerts["Confirm computer use"]
        let banner = r.app.buttons["Confirmation needed: Confirm computer use. Tap to review."]
        for confirmed in [true, false] {
            let prompt = PendingConfirmationPayload(
                id: UUID().uuidString, sessionID: "sess-alpha-1", projectID: nil,
                title: "Confirm computer use", message: "Allow the agent to control your Mac for the rest of this session?",
                confirmLabel: "Confirm for This Session", cancelLabel: "Reject", isDestructive: false
            )
            session.server.sendConfirmations([prompt])
            r.assertExists(alert, "computer-use confirmation")
            r.tap(alert.buttons[confirmed ? prompt.confirmLabel : prompt.cancelLabel], "permission decision")
            r.assertDisappears(banner, "resolved permission")
            XCTAssertEqual(session.server.confirmationDecision(for: prompt.id), confirmed)
        }
    }

    @MainActor
    func testPublishedDocumentAppearsBesideProjectBriefings() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot

        r.tap(r.briefingTab, "Briefing tab")
        r.assertExists(r.anyBriefingCard, "project briefing card")
        r.assertExists(r.app.descendants(matching: .any)["briefing-day-header"].firstMatch, "timeline day header")
        attachScreenshot(r.app, name: "Briefing timeline")
        r.tap(r.anyBriefingDocumentCard, "published document briefing card")
        r.assertExists(r.briefingDocumentDetail, "published document detail")
    }

    @MainActor
    func testToolGroupsExpandAndShowFullLongParameters() throws {
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
        XCTAssertTrue(app.navigationBars["Tool Call"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "build")).firstMatch.waitForExistence(timeout: 5))
        let firstRecord = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Task 1:")).firstMatch
        XCTAssertTrue(firstRecord.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRecord.isHittable, "JSON must draw on the first parameters page")
        attachScreenshot(app, name: "Visible first JSON parameters page")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(firstRecord.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRecord.isHittable)
        let pager = app.buttons["tool-detail-page-picker"]
        XCTAssertTrue(pager.exists && pager.isHittable)
        app.buttons["Next page"].tap()
        let nextRecord = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Task 9:")).firstMatch
        XCTAssertTrue(nextRecord.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Visible JSON parameters in landscape")
        pager.tap()
        app.buttons["Last Page"].tap()
        let end = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "END OF TOOL RESULT")).firstMatch
        for _ in 0..<8 {
            if end.exists && end.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(end.exists && end.isHittable, "The last page must be directly reachable")
        attachScreenshot(app, name: "Last JSON parameters page")
        XCUIDevice.shared.orientation = .portrait
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

    @MainActor
    func testSyncedCodingPlanShowsVersionAndImplementationState() throws {
        let r = try UITestRunner.launch(.phone, on: self, includePlan: true).robot
        r.tap(r.briefingTab, "Briefing")
        let card = r.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "briefing-card-A0000000-0000-0000-0000-000000000001"))
            .firstMatch
        r.tap(card, "Project Alpha briefing")
        let row = r.app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Plugin discovery plan")).firstMatch
        r.tap(row, "Coding plan")
        r.assertExists(r.app.staticTexts["Plugin discovery plan"], "plan title")
        r.assertExists(r.app.staticTexts["Implementation, Unimplemented"], "implementation status")
        r.assertExists(r.app.staticTexts["Plan, Ready"], "planning status")
        r.assertExists(r.app.staticTexts["Version, v3 · Plugin manifest"], "current version")
        r.assertExists(r.app.staticTexts["Discover installed plugins"], "planned feature")
        r.assertExists(r.app.staticTexts["Implementation has not started."], "implementation evidence")
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

    @MainActor
    func testNewThreadRemembersModelAndThinkingLevel() throws {
        let model = AgentModel(provider: .codex, id: "test-codex", displayName: "Test Codex")
        let settings = MobileSettingsSnapshot(
            selectedAgentProvider: .claudeCode, selectedModel: "test-claude", selectedACPClientId: "",
            selectedEffort: "low", permissionMode: .default, summarizationProvider: "",
            summarizationProviderDisplayName: "", openAISummarizationEndpoint: "", openAISummarizationModel: "",
            notificationsEnabled: true, focusMode: false, autoArchiveEnabled: false, archiveRetentionDays: 7,
            autoPreviewSettings: .init(), availableEfforts: ["low", "high"],
            reasoningLevelsByModel: [model.key: .levels(["low", "high"])],
            availableModels: [.init(provider: .claudeCode, id: "test-claude", displayName: "Test Claude"), model]
        )
        let session = try UITestRunner.launch(.phone, on: self, settings: settings)
        let r = session.robot
        r.tap(r.briefingTab, "Briefing")
        r.tap(r.anyBriefingCard, "project briefing")
        r.tap(r.briefingDetailNewThreadButton, "new thread")

        let modelPicker = r.app.buttons["new-thread-model-picker"]
        let thinkingLevel = r.app.buttons["new-thread-thinking-level"]
        r.app.scrollViews.firstMatch.swipeUp()
        r.tap(modelPicker, "model picker")
        r.tap(r.app.buttons["Test Codex"], "Codex model")
        r.tap(thinkingLevel, "thinking level")
        r.tap(r.app.buttons["High"], "High")
        r.tap(r.app.navigationBars["New Thread"].buttons["Cancel"], "close new thread")

        r.tap(r.briefingDetailNewThreadButton, "reopen new thread")
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(modelPicker.label.contains("Test Codex"))
        XCTAssertTrue(thinkingLevel.label.contains("High"))
        r.createNewThread(with: "Use the saved model and thinking level.")
        r.assertMessagesShown()
        let request = try XCTUnwrap(session.server.latestNewSessionRequest)
        XCTAssertEqual(request.selectedAgentProvider, .codex)
        XCTAssertEqual(request.selectedModel, model.id)
        XCTAssertEqual(request.selectedEffort, "high")
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

    /// Sideways and diagonal thumb movement across a row must not open it, while
    /// a tap with ordinary finger wobble still does.
    @MainActor
    func testDraggingAcrossRowsDoesNotOpenThem() throws {
        let r = try UITestRunner.launch(.phone, on: self).robot
        r.tap(r.projectsTab, "Projects tab")

        assertDragsOnlyOpenOnWobble(row: r.anyProjectRow, opened: r.threadListScreen, r)
        r.tap(r.anyProjectRow, "a project row")
        r.assertExists(r.threadListScreen, "thread list screen")
        assertDragsOnlyOpenOnWobble(row: r.anyThreadRow, opened: r.chatScreen, r) {
            // A rightward drag can invoke the system's full-screen back gesture.
            // Restore the thread list only after verifying that exact destination.
            r.assertExists(r.anyProjectRow, "Projects after the system back gesture")
            r.tap(r.anyProjectRow, "project after the system back gesture")
            r.assertExists(r.threadListScreen, "restored thread list")
        }
    }

    @MainActor
    private func assertDragsOnlyOpenOnWobble(
        row: XCUIElement,
        opened: XCUIElement,
        _ r: MobileAppRobot,
        restoreAfterBackGesture: (() -> Void)? = nil
    ) {
        let drags: [(CGVector, XCUIGestureVelocity)] = [
            (CGVector(dx: 16, dy: 0), .slow),
            (CGVector(dx: 40, dy: 0), .slow),
            (CGVector(dx: 120, dy: 0), .fast),
            (CGVector(dx: -40, dy: 0), .slow),
            (CGVector(dx: 24, dy: -24), .slow),
            (CGVector(dx: 0, dy: -40), .slow),
        ]
        for (offset, velocity) in drags {
            drag(row, by: offset, velocity: velocity, r)
            XCTAssertFalse(opened.waitForExistence(timeout: 1.5), "A drag of \(offset) must not open the row")
            if offset.dx > 0, !row.exists, let restoreAfterBackGesture {
                restoreAfterBackGesture()
            }
            r.assertExists(row, "row remains available for the next gesture")
        }
        drag(row, by: CGVector(dx: 4, dy: 0), velocity: .slow, r)
        r.assertExists(opened, "row opened by a tap with slight wobble")
        r.navigateBack()
        r.assertDisappears(opened, "opened screen after navigating back")
    }

    @MainActor
    private func drag(_ row: XCUIElement, by offset: CGVector, velocity: XCUIGestureVelocity, _ r: MobileAppRobot) {
        XCTAssertTrue(row.waitForExistence(timeout: r.timeout))
        r.waitForHittable(row, timeout: 5)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(offset), withVelocity: velocity, thenHoldForDuration: 0)
    }

    /// Open Duo: threads and chat side by side, with a collapsible sidebar.
    @MainActor
    func testOpenDuoShowsThreadsBesideChatWithCollapsibleSidebar() throws {
        let session = try UITestRunner.launch(.phone, on: self)
        let r = session.robot
        let app = session.app
        try XCTSkipUnless(app.frame.width >= 600, "Open iPhone Duo only: unfold the simulator to run this.")

        // Open Duo may draw its tabs as a side rail, outside `app.tabBars`.
        r.tap(app.buttons["Projects"].firstMatch, "Projects tab")
        r.tap(r.anyProjectRow, "a project row")
        r.assertExists(r.threadListScreen, "thread list screen")
        XCTAssertTrue(app.staticTexts["Select a Thread"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Duo threads with empty detail")
        // The side tab rail's safe area must not squeeze the sidebar's rows.
        XCTAssertEqual(r.anyThreadRow.frame.width, r.threadListScreen.frame.width - 32, accuracy: 1)

        let threadRow = r.anyThreadRow
        r.tap(threadRow, "a thread row")
        r.assertMessagesShown()
        attachScreenshot(app, name: "Duo threads beside chat")
        XCTAssertTrue(threadRow.isHittable, "The thread list stays beside the chat")
        XCTAssertLessThanOrEqual(threadRow.frame.maxX, r.chatScreen.frame.minX)

        let toggle = app.buttons["duo-sidebar-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let expandedWidth = r.chatScreen.frame.width
        toggle.tap()
        r.assertDisappears(threadRow, "thread list after collapsing the sidebar")
        r.assertMessagesShown()
        XCTAssertGreaterThan(r.chatScreen.frame.width, expandedWidth, "The chat takes over the sidebar's space")
        attachScreenshot(app, name: "Duo sidebar collapsed")

        toggle.tap()
        r.assertExists(threadRow, "thread list after expanding the sidebar")
        XCTAssertTrue(r.waitForHittable(threadRow, timeout: 5), "Expanding restores the sidebar")
        r.assertMessagesShown()
    }
}
