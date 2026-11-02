import XCTest

final class TaskDetailSheetUITests: XCTestCase {
    @MainActor
    func testTaskAndStoryCardsOpenDismissibleDetailSheets() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy"]
        app.launch()
        let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
            .matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        if deny.waitForExistence(timeout: 3) { deny.tap() }
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cloud Project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()

        for kind in ["Task", "Story"] {
            let title = "Sheet regression " + kind
            XCTAssertTrue(app.buttons["task-board-add"].waitForExistence(timeout: 10))
            app.buttons["task-board-add"].tap()
            app.buttons["New " + kind].tap()
            let field = app.textFields[kind.lowercased() + "-form-title"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(title)
            app.buttons[kind.lowercased() + "-form-save"].tap()
            XCTAssertTrue(app.buttons["task-board-add"].waitForExistence(timeout: 10))
            if kind == "Story" {
                app.segmentedControls.buttons["Stories"].tap()
            }
            let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            card.tap()
            XCTAssertTrue(app.navigationBars[kind].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[title].exists)
            let done = app.buttons["task-detail-done"]
            XCTAssertTrue(done.exists)
            done.tap()
            XCTAssertTrue(app.buttons["task-board-add"].waitForExistence(timeout: 5))
            XCTAssertTrue(card.exists)
        }
    }

    /// Actions live in each card's dropdown menu; swiping reveals nothing.
    @MainActor
    func testCardActionsAreInDropdownMenuAndNotSwipeable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy"]
        app.launch()
        let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
            .matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        if deny.waitForExistence(timeout: 3) { deny.tap() }

        func assertSwipeRevealsNothing(_ card: XCUIElement, hidden: String, swipesRight: Bool = true) {
            card.swipeLeft()
            XCTAssertFalse(app.buttons[hidden].waitForExistence(timeout: 1.5), "Swiping left must not reveal \(hidden)")
            guard swipesRight else { return }
            // On the kanban board the swipe scrolls the card away, so return to it.
            (card.isHittable ? card : app).swipeRight()
            XCTAssertFalse(app.buttons[hidden].waitForExistence(timeout: 1.5), "Swiping right must not reveal \(hidden)")
            XCTAssertTrue(card.isHittable)
        }

        func assertMenu(_ menu: XCUIElement, offers actions: [String], screenshot name: String) {
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            menu.tap()
            for action in actions {
                XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "Menu must offer \(action)")
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            // Dismiss without choosing an action.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
            XCTAssertFalse(app.buttons[actions[0]].waitForExistence(timeout: 2))
        }

        let projects = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-dashboard-project-'"))
        let projectRow = projects.firstMatch
        XCTAssertTrue(projectRow.waitForExistence(timeout: 15))
        assertSwipeRevealsNothing(projectRow, hidden: "Hide Project Card")
        assertMenu(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tasks-project-actions-'")).firstMatch,
            offers: ["Open Project Board", "Hide Project Card"],
            screenshot: "Project card menu"
        )

        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cloud Project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()

        for kind in ["Task", "Story"] {
            let title = "Menu regression " + kind
            XCTAssertTrue(app.buttons["task-board-add"].waitForExistence(timeout: 10))
            app.buttons["task-board-add"].tap()
            app.buttons["New " + kind].tap()
            let field = app.textFields[kind.lowercased() + "-form-title"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(title)
            app.buttons[kind.lowercased() + "-form-save"].tap()
            XCTAssertTrue(app.buttons["task-board-add"].waitForExistence(timeout: 10))
            if kind == "Story" {
                app.segmentedControls.buttons["Stories"].tap()
            }
            let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            // Swiping right on the story list is the system's back gesture.
            assertSwipeRevealsNothing(card, hidden: "Delete", swipesRight: kind == "Task")
            assertMenu(
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", kind.lowercased() + "-actions-")).firstMatch,
                offers: kind == "Task" ? ["Edit", "Move To", "Delete"] : ["Edit", "Delete"],
                screenshot: kind + " card menu"
            )
        }
    }
}
