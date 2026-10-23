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
}
