import XCTest

@MainActor
final class InspectorSplitTests: XCTestCase {
    func testDragEachDestinationIntoASplitAndBackToTheTabBar() throws {
        continueAfterFailure = false
        let workspace = "inspector-split-ui-test"
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().string(from: .now)
        let registry: [String: Any] = [
            "activeWorkspaceID": workspace,
            "workspaces": [["id": workspace, "name": "Inspector Test", "createdAt": date, "updatedAt": date]],
        ]
        try JSONSerialization.data(withJSONObject: registry).write(to: support.appendingPathComponent("workspaces.json"))

        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1"]
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-workspace.\(workspace).rightInspectorLayout", "",
            "-workspace.\(workspace).onboardingCompleted", "YES", "-showMenuBarExtra", "NO", "-SUEnableAutomaticChecks", "NO",
            "-workspace.\(workspace).showRightSidebar", "YES", "-workspace.\(workspace).rightInspectorWidth", "600",
        ]
        app.launch()
        app.activate()

        let panes = app.descendants(matching: .any).matching(identifier: "inspector-destination-pane")
        let center = CGVector(dx: 0.5, dy: 0.5)
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 30))
        let whatsNew = app.sheets.containing(.button, identifier: "xmark").firstMatch
        if whatsNew.waitForExistence(timeout: 2) {
            whatsNew.buttons["xmark"].click()
            XCTAssertTrue(whatsNew.waitForNonExistence(timeout: 5))
        }
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
