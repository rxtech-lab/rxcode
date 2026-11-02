import XCTest

final class MobileNativeReorderingUITests: XCTestCase {
    @MainActor
    func testNativeBoardReordersColumnsAndCards() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Uses two fully visible columns.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy", "-uitest-reset-column-order"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
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
        let backlog = app.otherElements["task-kanban-column-backlog"].firstMatch
        let pending = app.otherElements["task-kanban-column-pending"].firstMatch
        XCTAssertTrue(backlog.exists)
        XCTAssertTrue(pending.exists)
        let backlogOrigin = backlog.frame.origin
        let pendingOrigin = pending.frame.origin
        let pendingIsRight = pending.frame.minX > backlog.frame.minX
        let upper = first.frame.minY < second.frame.minY ? first : second
        let lower = first.frame.minY < second.frame.minY ? second : first
        // Drop inside the first card instead of beyond the last insertion target.
        lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 1.2,
            thenDragTo: upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
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
            thenDragTo: pending.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 100)),
            withVelocity: .slow,
            thenHoldForDuration: 2
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
        lowerColumn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 1.2,
            thenDragTo: upperColumn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
            withVelocity: .slow,
            thenHoldForDuration: 2
        )
        let columnsMoved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            upperColumn.frame.minY > lowerColumn.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [columnsMoved], timeout: 10), .completed)
        app.buttons["Done"].tap()
        XCTAssertTrue(backlogWasFirst ? backlog.frame.minX > pending.frame.minX : pending.frame.minX > backlog.frame.minX)
    }

    /// Resting a thumb before scrolling must not lift a card, and a drag that
    /// never lifted must not open it. Tapping and a deliberate hold still work.
    @MainActor
    func testOnlyDeliberateHoldLiftsTaskCard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy", "-uitest-reset-column-order"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
            .matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        if deny.waitForExistence(timeout: 3) { deny.tap() }
        let project = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Cloud Project'")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()

        for title in ["First hold card", "Second hold card"] {
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

        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'First hold card'")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Second hold card'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        let upper = first.frame.minY < second.frame.minY ? first : second
        let lower = first.frame.minY < second.frame.minY ? second : first
        let detailDone = app.buttons["task-detail-done"]

        func dragLowerOntoUpper(holding duration: TimeInterval) {
            lower.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: duration,
                thenDragTo: upper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
                withVelocity: .slow,
                thenHoldForDuration: 1
            )
        }

        // 0.4s is past the system's default lift delay of 0.325s.
        for duration in [0.05, 0.2, 0.4] {
            dragLowerOntoUpper(holding: duration)
            XCTAssertFalse(detailDone.waitForExistence(timeout: 2), "A \(duration)s drag must not open the card")
            XCTAssertLessThan(upper.frame.minY, lower.frame.minY, "A \(duration)s hold must not lift the card")
        }

        lower.tap()
        XCTAssertTrue(detailDone.waitForExistence(timeout: 5), "A tap must still open the card")
        detailDone.tap()
        XCTAssertFalse(detailDone.waitForExistence(timeout: 2))

        dragLowerOntoUpper(holding: 1.2)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            upper.frame.minY > lower.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed, "A deliberate hold must still lift the card")
    }
}
