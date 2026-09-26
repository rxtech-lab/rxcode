import XCTest

final class CloudWorkspaceUITests: XCTestCase {
    @MainActor
    func testOfflineTasksReuseBoardAndForms() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud"]
        app.launch()
        let viewTasks = app.buttons["view-tasks-offline"]
        XCTAssertTrue(viewTasks.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Open Paired Macs"].exists)
        viewTasks.tap()
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cloud Project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        let add = app.buttons["task-board-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["task-board-views"].exists)
        add.tap()
        XCTAssertFalse(app.buttons["Quick Add Task"].exists)
        app.buttons["New Story"].tap()
        let storyTitle = app.textFields["story-form-title"]
        XCTAssertTrue(storyTitle.waitForExistence(timeout: 5))
        storyTitle.tap()
        storyTitle.typeText("Cloud Story")
        app.buttons["story-form-save"].tap()
        add.tap()
        app.buttons["New Task"].tap()
        let title = app.textFields["task-form-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Offline Laptop Task")
        app.swipeUp()
        app.swipeUp()
        let laptop = app.buttons["task-assigned-mac"]
        XCTAssertTrue(laptop.waitForExistence(timeout: 5))
        laptop.tap()
        app.buttons["Offline Work Mac"].tap()
        app.buttons["task-form-save"].tap()
        let task = app.staticTexts["Offline Laptop Task"]
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        XCTAssertTrue(app.staticTexts["Offline Work Mac"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Run with Agent"].exists)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textFields["task-form-title"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPairedButUnreachableMacOffersTasks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest-cloud",
            "-uitest-relay-url", "ws://127.0.0.1:9/ws",
            "-uitest-desktop-pubkey", String(repeating: "2", count: 64),
        ]
        app.launch()
        let viewTasks = app.buttons["view-tasks-offline"]
        XCTAssertTrue(viewTasks.waitForExistence(timeout: 15))
        viewTasks.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cloud Project'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Open Paired Macs"].exists)
    }

    @MainActor
    func testIPadSyncFailureOpensFullScreenKanbanTasks() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only test.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest-cloud",
            "-uitest-relay-url", "ws://127.0.0.1:9/ws",
            "-uitest-desktop-pubkey", String(repeating: "2", count: 64),
        ]
        app.launch()

        XCTAssertTrue(app.buttons["sync-retry"].waitForExistence(timeout: 25))
        app.buttons["view-tasks-offline"].tap()

        let overview = app.descendants(matching: .any)["tasks-ipad-overview"].firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(overview.frame.width, app.frame.width * 0.85)
        let projectContent = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-ipad-project-content-'")).firstMatch
        XCTAssertTrue(projectContent.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(projectContent.frame.height, overview.frame.height * 0.65)

        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-dashboard-project-'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tasks-ipad-kanban"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testConnectedMacKeepsRegularTasksWorkspace() throws {
        let app = try UITestRunner.launch(.phone, on: self).app
        XCTAssertTrue(app.tabBars.buttons["Tasks"].exists)
        XCTAssertFalse(app.buttons["view-tasks-offline"].exists)
        XCTAssertFalse(app.buttons["Back to Autopilot"].exists)
        XCTAssertFalse(app.buttons["Open Paired Macs"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-dashboard-project-'")).firstMatch.exists)
    }
}
