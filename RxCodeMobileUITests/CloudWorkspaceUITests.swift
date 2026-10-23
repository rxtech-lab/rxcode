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
    func testPairedButUnreachableMacOffersRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest-cloud",
            "-uitest-relay-url", "ws://127.0.0.1:9/ws",
            "-uitest-desktop-pubkey", String(repeating: "2", count: 64),
        ]
        app.launch()
        XCTAssertTrue(app.buttons["sync-retry"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["Connection Timed Out"].exists)
        XCTAssertFalse(app.buttons["view-tasks-offline"].exists)
    }

    @MainActor
    func testIPadSyncFailureOffersRetry() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only test.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest-cloud",
            "-uitest-relay-url", "ws://127.0.0.1:9/ws",
            "-uitest-desktop-pubkey", String(repeating: "2", count: 64),
        ]
        app.launch()

        let retry = app.buttons["sync-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 25))
        XCTAssertTrue(retry.isEnabled)
        XCTAssertTrue(app.staticTexts["Connection Timed Out"].exists)
        XCTAssertFalse(app.buttons["view-tasks-offline"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["tasks-ipad-overview"].firstMatch.exists)
    }

    @MainActor
    func testIPadUnpairedTasksOpenFullScreenEmptyBoard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only test.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud"]
        app.launch()
        let viewTasks = app.buttons["view-tasks-offline"]
        XCTAssertTrue(viewTasks.waitForExistence(timeout: 15))
        viewTasks.tap()

        let overview = app.descendants(matching: .any)["tasks-ipad-overview"].firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(overview.frame.width, app.frame.width * 0.85)
        let projectContent = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-ipad-project-content-'")).firstMatch
        XCTAssertTrue(projectContent.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(projectContent.frame.height, overview.frame.height * 0.65)

        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-dashboard-project-'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        let emptyState = app.descendants(matching: .any)["task-board-empty-state"].firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Tasks"].exists)
        XCTAssertGreaterThan(emptyState.frame.width, app.frame.width * 0.85)
        XCTAssertGreaterThan(emptyState.frame.height, app.frame.height * 0.65)
        XCTAssertFalse(app.descendants(matching: .any)["tasks-ipad-kanban"].firstMatch.exists)
        XCTAssertTrue(app.buttons["task-board-add"].exists)
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
