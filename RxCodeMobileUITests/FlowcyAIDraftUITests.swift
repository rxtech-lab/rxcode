import XCTest

final class FlowcyAIDraftUITests: XCTestCase {
    @MainActor
    func testTaskAndStoryDraftReviewBeforeSave() {
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
            let prefix = kind.lowercased()
            XCTAssertTrue(app.buttons["task-board-add"].waitForExistence(timeout: 10))
            app.buttons["task-board-add"].tap()
            app.buttons["New " + kind].tap()
            let ai = app.buttons[prefix + "-form-ai"]
            XCTAssertTrue(ai.waitForExistence(timeout: 5))
            ai.tap()
            let prompt = app.descendants(matching: .any)["ai-draft-prompt"].firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
            prompt.tap()
            prompt.typeText("Support offline work")
            app.buttons["ai-draft-generate"].tap()
            let apply = app.buttons["ai-draft-apply"]
            XCTAssertTrue(apply.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Support offline work"].exists)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = kind + " AI draft review"
            attachment.lifetime = .keepAlways
            add(attachment)
            apply.tap()
            let title = app.textFields[prefix + "-form-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertEqual(title.value as? String, "Support offline work")
            // Cancelling the form demonstrates generation did not save a board item.
            app.buttons["Cancel"].firstMatch.tap()
        }
        XCTAssertFalse(app.staticTexts["Support offline work"].exists)
    }
}
