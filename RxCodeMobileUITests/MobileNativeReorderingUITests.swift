import XCTest

final class MobileNativeReorderingUITests: XCTestCase {
    @MainActor
    func testNativeBoardReordersColumnsAndCards() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Uses two fully visible columns.")
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

        for title in ["First reorder card", "Second reorder card"] {
            let add = app.buttons["task-board-add"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
            app.buttons["New Task"].tap()
            let field = app.textFields["task-form-title"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(title)
            app.buttons["task-form-save"].tap()
        }

        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'First reorder card'")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Second reorder card'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        let backlog = app.descendants(matching: .any)["task-column-backlog"].firstMatch
        let pending = app.descendants(matching: .any)["task-column-pending"].firstMatch
        XCTAssertTrue(backlog.exists)
        XCTAssertTrue(pending.exists)
        let backlogOrigin = backlog.frame.origin
        let pendingOrigin = pending.frame.origin
        let pendingIsRight = pending.frame.minX > backlog.frame.minX
        let upper = first.frame.minY < second.frame.minY ? first : second
        let lower = first.frame.minY < second.frame.minY ? second : first
        upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 1.2,
            thenDragTo: lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.1)),
            withVelocity: .slow,
            thenHoldForDuration: 2
        )
        let cardMoved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            upper.frame.minY > lower.frame.minY
        }, object: nil)
        let result = XCTWaiter.wait(for: [cardMoved], timeout: 10)
        if result != .completed {
            print(app.debugDescription)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed)

        XCTAssertEqual(backlog.frame.minX, backlogOrigin.x, accuracy: 1)
        XCTAssertEqual(backlog.frame.minY, backlogOrigin.y, accuracy: 1)
        XCTAssertEqual(pending.frame.minX, pendingOrigin.x, accuracy: 1)
        XCTAssertEqual(pending.frame.minY, pendingOrigin.y, accuracy: 1)
        upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 1.2,
            thenDragTo: pending.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: 100))
        )
        let changedColumn = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pendingIsRight ? upper.frame.minX > lower.frame.minX : upper.frame.minX < lower.frame.minX
        }, object: nil)
        let crossColumnResult = XCTWaiter.wait(for: [changedColumn], timeout: 10)
        if crossColumnResult != .completed { print(app.debugDescription) }
        XCTAssertEqual(crossColumnResult, .completed)
        XCTAssertEqual(backlog.frame.minX, backlogOrigin.x, accuracy: 1)
        XCTAssertEqual(pending.frame.minX, pendingOrigin.x, accuracy: 1)

        app.buttons["task-board-views"].tap()
        app.buttons["Reorder Columns"].tap()
        let firstColumn = app.descendants(matching: .any)["reorder-column-backlog"].firstMatch
        let secondColumn = app.descendants(matching: .any)["reorder-column-pending"].firstMatch
        XCTAssertTrue(firstColumn.waitForExistence(timeout: 5))
        XCTAssertTrue(secondColumn.exists)
        let backlogWasFirst = firstColumn.frame.minY < secondColumn.frame.minY
        let upperColumn = backlogWasFirst ? firstColumn : secondColumn
        let lowerColumn = backlogWasFirst ? secondColumn : firstColumn
        upperColumn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 1.2,
            thenDragTo: lowerColumn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: 24))
        )
        XCTAssertTrue(app.staticTexts["Column order saved"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(upperColumn.frame.minY, lowerColumn.frame.minY)
        app.buttons["Done"].tap()
        XCTAssertTrue(backlogWasFirst ? backlog.frame.minX > pending.frame.minX : pending.frame.minX > backlog.frame.minX)
    }
}
