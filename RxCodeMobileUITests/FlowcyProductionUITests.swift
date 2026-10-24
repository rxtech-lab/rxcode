import XCTest

final class FlowcyProductionUITests: XCTestCase {
    @MainActor
    func testDashboardWithoutPairingAndRootNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy"]
        app.launch()
        XCTAssertTrue(app.buttons["flowcy-remote-menu"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["view-tasks-offline"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cloud Project'")).firstMatch.waitForExistence(timeout: 15))
        capture("Flowcy Projects")
        app.buttons["Projects"].firstMatch.tap()
        let project = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'flowcy-project-' ")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Select a Feature"].exists)
        capture("Flowcy Project Directory")
        project.tap()
        XCTAssertTrue(app.scrollViews["flowcy-project-overview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Task Progress"].waitForExistence(timeout: 10))
        let newTask = app.buttons["New Task"]
        XCTAssertTrue(newTask.isEnabled)
        newTask.tap()
        XCTAssertTrue(app.textFields["task-form-title"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.scrollViews["flowcy-project-overview"].waitForExistence(timeout: 5))
        capture("Flowcy Project Overview")
        let closeProject = app.buttons["flowcy-close-project"]
        if !closeProject.isHittable {
            // Compact layouts first pop the overview to the workspace's feature list.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(closeProject.waitForExistence(timeout: 5))
        closeProject.tap()
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Projects"].exists)
        project.tap()
        XCTAssertTrue(app.scrollViews["flowcy-project-overview"].waitForExistence(timeout: 5))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Integrations"].waitForExistence(timeout: 5))
        capture("Flowcy Settings")
        app.buttons["Integrations"].tap()
        XCTAssertTrue(app.buttons["Notifications"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Webhooks"].exists)
        XCTAssertTrue(app.buttons["Repository Setup"].exists)
        if !app.buttons["flowcy-settings-account"].isHittable {
            app.navigationBars["Integrations"].buttons.element(boundBy: 0).tap()
        }
        app.buttons["flowcy-settings-account"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sign Out"].exists)
        capture("Flowcy Settings Detail")
        app.buttons["Agent"].firstMatch.tap()
        XCTAssertTrue(app.textFields["flowcy-agent-composer"].waitForExistence(timeout: 5))
        capture("Flowcy Agent")
        app.buttons["Flowcy Tools"].tap()
        XCTAssertTrue(app.navigationBars["Flowcy Tools"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Disconnected"].exists)
        capture("Flowcy Tools Disconnected")
        app.buttons["Done"].tap()
        app.buttons["flowcy-remote-menu"].firstMatch.tap()
        app.buttons["Connect New Remote"].tap()
        XCTAssertTrue(app.navigationBars["Connect New Remote"].waitForExistence(timeout: 5))
        capture("Flowcy Pairing Sheet")
    }

    @MainActor
    func testProjectCardsDragHideRestoreAndPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy", "-uitest-project-cards"]
        app.launch()
        let denyNotifications = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
            .matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        if denyNotifications.waitForExistence(timeout: 5) { denyNotifications.tap() }
        let controls = app.buttons["tasks-project-cards"]
        XCTAssertTrue(controls.waitForExistence(timeout: 15))
        controls.tap()
        XCTAssertTrue(app.buttons["tasks-project-visibility-A0000000-0000-0000-0000-000000000001"].waitForExistence(timeout: 10))
        for name in ["Alpha Project", "Beta Project"] {
            let show = app.buttons["Show " + name]
            if show.exists { show.tap() }
        }
        app.buttons["Done"].tap()

        let alpha = app.descendants(matching: .any)["tasks-dashboard-project-A0000000-0000-0000-0000-000000000001"].firstMatch
        let beta = app.descendants(matching: .any)["tasks-dashboard-project-B0000000-0000-0000-0000-000000000002"].firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(beta.exists)
        let wide = app.descendants(matching: .any)["tasks-ipad-overview"].firstMatch.exists
        let alphaFirst = wide ? alpha.frame.minX < beta.frame.minX : alpha.frame.minY < beta.frame.minY
        let first = alphaFirst ? alpha : beta
        let second = alphaFirst ? beta : alpha
        // Move upward on iPhone so the drop stays inside the section as rows shift.
        let source = (wide ? first : second).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = (wide ? second : first).coordinate(withNormalizedOffset: CGVector(dx: wide ? 0.95 : 0.5, dy: wide ? 0.5 : 0.05))
        source.press(forDuration: 1.2, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 2)
        // The status overlay can expire while XCTest waits for the drag to settle.
        // Verify the resulting order, then verify it again from persisted state.
        let reordered = NSPredicate { _, _ in
            guard first.exists, second.exists else { return false }
            return wide ? first.frame.minX > second.frame.minX : first.frame.minY > second.frame.minY
        }
        let moved = XCTNSPredicateExpectation(predicate: reordered, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed,
                       "Dragging a project should swap the project order.")
        // This sheet reads the saved model rather than the List's drag preview.
        controls.tap()
        let firstControl = app.buttons[alphaFirst ? "Hide Alpha Project" : "Hide Beta Project"]
        let secondControl = app.buttons[alphaFirst ? "Hide Beta Project" : "Hide Alpha Project"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            firstControl.exists && secondControl.exists && firstControl.frame.minY > secondControl.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed,
                       "The project controls should reflect the saved order after dragging.")
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        let persisted = XCTNSPredicateExpectation(predicate: reordered, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 15), .completed,
                       "The reordered projects should keep their order after relaunching.")

        controls.tap()
        app.buttons["Hide Alpha Project"].tap()
        app.buttons["Hide Beta Project"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["All Project Cards Hidden"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["All Project Cards Hidden"].waitForExistence(timeout: 15))
        controls.tap()
        app.buttons["Show Alpha Project"].tap()
        app.buttons["Show Beta Project"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        XCTAssertTrue(beta.exists)
        alpha.tap()
        XCTAssertTrue(app.buttons["task-board-add"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCIAndReleaseProjectNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-cloud", "-uitest-flowcy", "-uitest-feature-navigation"]
        app.launch()
        app.buttons["Projects"].firstMatch.tap()
        let project = app.buttons["flowcy-project-project"]
        XCTAssertTrue(project.waitForExistence(timeout: 15))
        project.tap()
        XCTAssertTrue(app.scrollViews["flowcy-project-overview"].waitForExistence(timeout: 10))

        selectFeature("Dependency & CI Updates", in: app)
        let history = app.buttons.matching(NSPredicate(format: "label CONTAINS 'CI History'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["Could Not Complete Request"].exists)
        history.tap()
        XCTAssertTrue(app.navigationBars["CI History"].waitForExistence(timeout: 5))
        app.navigationBars["CI History"].buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Dependencies & Security'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Scans Unavailable"].waitForExistence(timeout: 5))
        app.navigationBars["Dependencies & Security"].buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Automation'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Automation Unavailable"].waitForExistence(timeout: 5))
        app.navigationBars["Automation"].buttons.element(boundBy: 0).tap()

        selectFeature("Releases", in: app)
        let workflow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Publish App'")).firstMatch
        XCTAssertTrue(workflow.waitForExistence(timeout: 10))
        workflow.tap()
        XCTAssertTrue(app.navigationBars["release.yml"].waitForExistence(timeout: 5))
        app.buttons["Release"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["release.yml"].waitForExistence(timeout: 5))
        capture("Project CI and Release Navigation")
    }

    @MainActor
    private func selectFeature(_ title: String, in app: XCUIApplication) {
        let item = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        if !item.isHittable {
            // Compact iPhone navigation returns to the feature list; wide layouts retain it.
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
