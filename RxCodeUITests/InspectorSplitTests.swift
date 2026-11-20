import XCTest

@MainActor
final class InspectorSplitTests: XCTestCase {
    private func launchInspector(project: URL? = nil) throws -> XCUIApplication {
        continueAfterFailure = false
        let workspace = "inspector-split-ui-test"
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        let date = ISO8601DateFormatter().string(from: .now)
        let registry: [String: Any] = [
            "activeWorkspaceID": workspace,
            "workspaces": [["id": workspace, "name": "Inspector Test", "createdAt": date, "updatedAt": date]],
        ]
        try JSONSerialization.data(withJSONObject: registry).write(to: support.appendingPathComponent("workspaces.json"))

        if let project {
            let workspaceDirectory = support.appending(path: "workspaces/\(workspace)")
            try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
            let projects = [["id": UUID().uuidString, "name": "Branch Test", "path": project.path]]
            try JSONEncoder().encode(projects).write(to: workspaceDirectory.appending(path: "projects.json"))
        }
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1"]
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES", "-workspace.\(workspace).rightInspectorLayout", "",
            "-workspace.\(workspace).onboardingCompleted", "YES", "-showMenuBarExtra", "NO", "-SUEnableAutomaticChecks", "NO",
            "-workspace.\(workspace).showRightSidebar", "YES", "-workspace.\(workspace).rightInspectorWidth", "600",
            "-inspectorMode", "Inspector", "-inspectorTab", "Run",
        ]
        app.launch()
        app.activate()

        let panes = app.descendants(matching: .any).matching(identifier: "inspector-destination-pane")
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 30))
        let whatsNew = app.sheets.containing(.button, identifier: "xmark").firstMatch
        if whatsNew.waitForExistence(timeout: 2) {
            whatsNew.buttons["xmark"].click()
            XCTAssertTrue(whatsNew.waitForNonExistence(timeout: 5))
        }
        return app
    }

    func testSidebarBranchesDismissWithTheInspectorShownAndHidden() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let app = try launchInspector(project: project)
        let setup = app.buttons["Set up Git…"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.click()
        let sheet = app.sheets.containing(.textField, identifier: "Filter branches").firstMatch
        app.sheets.buttons["Initialize Git"].click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        sheet.buttons["Close"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))

        let run = app.descendants(matching: .any).matching(identifier: "inspector-tool-run").firstMatch
        XCTAssertTrue(run.wait(for: \.isSelected, toEqual: true, timeout: 5))

        let branches = app.buttons["sidebar-git-branches"]
        XCTAssertTrue(branches.waitForExistence(timeout: 10))
        branches.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Close"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(run.isSelected)

        app.buttons["toggle-inspector-button"].click()
        let panel = app.descendants(matching: .any).matching(identifier: "inspector-destination-pane").firstMatch
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        branches.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertFalse(panel.exists)
        XCTAssertTrue(branches.isHittable)
    }

    func testDragEachDestinationIntoASplitAndBackToTheTabBar() throws {
        let app = try launchInspector()
        let panes = app.descendants(matching: .any).matching(identifier: "inspector-destination-pane")
        let center = CGVector(dx: 0.5, dy: 0.5)
        for (index, mode) in ["preview", "inspector", "review", "browser"].enumerated() {
            let tab = app.buttons["inspector-destination-\(mode)"]
            let companion = app.buttons[mode == "browser" ? "inspector-destination-preview" : "inspector-destination-browser"]
            companion.click()
            XCTAssertTrue(companion.wait(for: \.isSelected, toEqual: true, timeout: 5))
            let above = index.isMultiple(of: 2)
            let target = panes.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.4 : 0.8))
            tab.coordinate(withNormalizedOffset: center)
                .click(forDuration: 0.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.3)

            let secondPane = panes.element(boundBy: 1)
            XCTAssertTrue(secondPane.waitForExistence(timeout: 5), "Splitting \(mode)")
            XCTAssertEqual(tab.frame.midY < companion.frame.midY, above)
            tab.coordinate(withNormalizedOffset: center)
                .click(forDuration: 0.2, thenDragTo: companion.coordinate(withNormalizedOffset: center),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(secondPane.waitForNonExistence(timeout: 5), "Rejoining \(mode)")
            XCTAssertEqual(tab.frame.midY, companion.frame.midY, accuracy: 1)
        }
    }
}
