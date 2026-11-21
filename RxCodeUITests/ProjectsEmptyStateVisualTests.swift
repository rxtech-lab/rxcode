import XCTest

@MainActor
final class ProjectsEmptyStateVisualTests: XCTestCase {
    func testEmptyProjectCardUsesAvailableHeightWithInspectorOpen() throws {
        continueAfterFailure = false
        let (app, projectID) = try launchProjectsOverview()
        let window = app.windows.firstMatch
        let viewport = window.scrollViews["task-overview-projects"]
        let inspector = window.descendants(matching: .any).matching(identifier: "inspector-destination-pane").firstMatch
        let newItemMenu = window.menuButtons["task-board-add"]
        let cardIdentifier = "task-project-section-\(projectID)"
        let cardMenu = window.menuButtons.matching(identifier: cardIdentifier)
            .matching(NSPredicate(format: "title == %@", "More")).firstMatch
        let message = window.staticTexts.matching(identifier: cardIdentifier)
            .matching(NSPredicate(format: "value == %@", "No stories yet.")).firstMatch
        let newStory = window.buttons["New Story"].firstMatch

        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        XCTAssertTrue(inspector.exists)
        XCTAssertTrue(cardMenu.exists)
        XCTAssertTrue(message.exists)
        XCTAssertTrue(newStory.exists)

        func checkLayout(screenshotName: String) {
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = screenshotName
            screenshot.lifetime = .keepAlways
            add(screenshot)

            let bounds = viewport.frame
            XCTAssertLessThan(bounds.width, 360, "The inspector should narrow the Projects pane.")
            XCTAssertLessThan(bounds.minY - window.frame.minY, 160, "The header and filter should stay near the top.")
            XCTAssertEqual(bounds.maxY, window.frame.maxY, accuracy: 2, "The project area should reach the bottom.")
            XCTAssertTrue(newItemMenu.isHittable)
            XCTAssertLessThanOrEqual(newItemMenu.frame.maxX, inspector.frame.minX)

            let emptyState = message.frame.union(newStory.frame)
            XCTAssertEqual(emptyState.midX, bounds.midX, accuracy: 2)
            XCTAssertEqual(emptyState.midY, (cardMenu.frame.maxY + bounds.maxY) / 2, accuracy: 14,
                           "The empty state should be centered in the card body.")
        }

        checkLayout(screenshotName: "Projects empty state")

        let originalHeight = window.frame.height
        let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -2))
        let shorter = bottomEdge.withOffset(CGVector(dx: 0, dy: -140))
        bottomEdge.click(forDuration: 0.2, thenDragTo: shorter, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertLessThan(window.frame.height, originalHeight - 100)
        checkLayout(screenshotName: "Projects empty state after resizing")
    }

    private func launchProjectsOverview() throws -> (XCUIApplication, String) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectsEmptyState-\(UUID())")
        let workspaceID = UUID().uuidString
        let projectID = UUID().uuidString
        let workspace = support.appending(path: "workspaces/\(workspaceID)")
        let project = support.appending(path: "Repository")
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            app.terminate()
            try? FileManager.default.removeItem(at: support)
        }

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().string(from: .now)
        let registry: [String: Any] = [
            "activeWorkspaceID": workspaceID,
            "workspaces": [["id": workspaceID, "name": "Projects Test", "createdAt": date, "updatedAt": date]],
        ]
        try JSONSerialization.data(withJSONObject: registry).write(to: support.appending(path: "workspaces.json"))
        try JSONEncoder().encode([["id": projectID, "name": "Demo App", "path": project.path]])
            .write(to: workspace.appending(path: "projects.json"))

        // The layout only needs local data. Skip agent discovery and system permission prompts at launch.
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UNIT_TESTING": "1"]
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
            "-ApplePersistenceIgnoreState", "YES", "-com.apple.TipKit.HideAllTips", "1",
            "-workspace.\(workspaceID).onboardingCompleted", "YES",
            "-workspace.\(workspaceID).seenWhatsNewSlugs",
            "(code-review-hook, commit-push-hook, custom-context-menus, projects-dashboard, scheduled-tasks, standalone-chat)",
            "-workspace.\(workspaceID).showRightSidebar", "YES",
            "-workspace.\(workspaceID).rightInspectorWidth", "420",
            "-inspectorMode", "Inspector", "-inspectorTab", "Run",
            "-showMenuBarExtra", "NO", "-SUEnableAutomaticChecks", "NO",
        ]
        app.launch()
        app.activate()

        let projects = app.buttons["general-route-tasks"]
        XCTAssertTrue(projects.waitForExistence(timeout: 30))
        let whatsNew = app.sheets.containing(.button, identifier: "xmark").firstMatch
        if whatsNew.waitForExistence(timeout: 3) {
            whatsNew.buttons["xmark"].click()
            XCTAssertTrue(whatsNew.waitForNonExistence(timeout: 5))
        }
        if !projects.isSelected { projects.click() }
        return (app, projectID)
    }
}
