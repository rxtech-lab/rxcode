import XCTest

@MainActor
final class TaskCardModelMenuTests: XCTestCase {
    func testModelFooterOpensMenuAndAppliesSelection() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TaskCardModelMenu-\(UUID())")
        let project = root.appendingPathComponent("Repository")
        let support = root.appendingPathComponent("AppSupport")
        let taskBoards = support.appendingPathComponent("task_board")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: taskBoards, withIntermediateDirectories: true)

        let projectId = UUID().uuidString
        let taskId = UUID().uuidString
        let projectName = "Model Menu Project"
        let taskTitle = "Model Menu Task"
        let details = "Original task details"
        let boardURL = taskBoards.appendingPathComponent("\(projectId).json")
        try JSONSerialization.data(withJSONObject: [["id": projectId, "name": projectName, "path": project.path]])
            .write(to: support.appendingPathComponent("projects.json"))
        try JSONSerialization.data(withJSONObject: ["tasks": [[
            "id": taskId, "projectId": projectId, "title": taskTitle, "details": details, "status": "backlog",
            "agent": ["provider": "claudeCode", "model": "sonnet", "planMode": true]
        ]]]).write(to: boardURL)

        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launchArguments = [
            "-onboardingCompleted", "YES", "-showMenuBarExtra", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1"]
        app.launch()

        let projectsTab = app.buttons["general-route-tasks"]
        XCTAssertTrue(projectsTab.waitForExistence(timeout: 30))
        projectsTab.click()

        let projectTitle = app.buttons.matching(identifier: "task-project-section-\(projectId)")
            .matching(NSPredicate(format: "label == %@", projectName)).firstMatch
        XCTAssertTrue(projectTitle.waitForExistence(timeout: 10))
        projectTitle.click()

        let modelFooter = app.buttons["task-card-model-\(taskId)"]
        XCTAssertTrue(modelFooter.waitForExistence(timeout: 10))
        let codexModel = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH[c] %@", "GPT")).firstMatch

        modelFooter.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)).click()
        XCTAssertTrue(codexModel.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        let column = app.scrollViews["task-column-backlog"]
        XCTAssertTrue(column.exists)
        let footer = modelFooter.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        footer.withOffset(CGVector(dx: column.frame.maxX - modelFooter.frame.minX - 20, dy: 0)).click()
        XCTAssertTrue(codexModel.waitForExistence(timeout: 5))
        codexModel.click()
        XCTAssertTrue(app.staticTexts["Task model updated"].waitForExistence(timeout: 5))
        XCTAssertTrue(modelFooter.label.hasPrefix("GPT"))

        let savedSelection = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: boardURL),
                  let board = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let task = (board["tasks"] as? [[String: Any]])?.first,
                  let agent = task["agent"] as? [String: Any] else { return false }
            return agent["provider"] as? String == "codex" && (agent["model"] as? String)?.hasPrefix("gpt-") == true
                && agent["planMode"] as? Bool == true && task["details"] as? String == details
        }
        wait(for: [XCTNSPredicateExpectation(predicate: savedSelection, object: nil)], timeout: 5)

        XCTAssertFalse(app.buttons["Save"].exists)
        app.staticTexts[taskTitle].firstMatch.click()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
    }
}
