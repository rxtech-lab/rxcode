import XCTest

@MainActor
final class TaskCardModelMenuTests: XCTestCase {
    private let taskTitle = "Model Menu Task"
    private let details = "Original task details"

    private func openTaskBoard() throws -> (XCUIApplication, String, URL) {
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
        let boardURL = taskBoards.appendingPathComponent("\(projectId).json")
        try JSONSerialization.data(withJSONObject: [["id": projectId, "name": projectName, "path": project.path]])
            .write(to: support.appendingPathComponent("projects.json"))
        try JSONSerialization.data(withJSONObject: ["tasks": [[
            "id": taskId, "projectId": projectId, "title": taskTitle, "details": details, "status": "backlog",
            "agent": ["provider": "claudeCode", "model": "sonnet", "planMode": true]
        ]]]).write(to: boardURL)

        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launchArguments = [
            "-onboardingCompleted", "YES", "-showMenuBarExtra", "NO",
            "-UseAgentSDK", "YES", "-selectedEffort", "auto",
            "-SUEnableAutomaticChecks", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1"]
        app.launch()

        let whatsNew = app.sheets.containing(.staticText, identifier: "New in RxCode").firstMatch
        if whatsNew.waitForExistence(timeout: 5) {
            whatsNew.buttons["Close"].click()
        }
        app.activate()
        let projectsTab = app.buttons["general-route-tasks"]
        XCTAssertTrue(projectsTab.waitForExistence(timeout: 30))
        projectsTab.click()

        let projectMenu = app.menuButtons.matching(identifier: "task-project-section-\(projectId)")
            .matching(NSPredicate(format: "title == %@", "More")).firstMatch
        XCTAssertTrue(projectMenu.waitForExistence(timeout: 10))
        projectMenu.click()
        app.menuItems["Open Project Board"].click()
        XCTAssertTrue(app.scrollViews["task-column-backlog"].waitForExistence(timeout: 10))
        return (app, taskId, boardURL)
    }

    func testModelFooterOpensMenuAndAppliesSelection() throws {
        let (app, taskId, boardURL) = try openTaskBoard()
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
                && agent["planMode"] as? Bool == true && task["details"] as? String == self.details
        }
        wait(for: [XCTNSPredicateExpectation(predicate: savedSelection, object: nil)], timeout: 5)

        XCTAssertFalse(app.buttons["Save"].exists)
        app.staticTexts[taskTitle].firstMatch.click()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
    }

    func testThinkingLevelCanBeCancelledSavedAndResetFromTheCard() throws {
        let (app, taskId, boardURL) = try openTaskBoard()
        let control = app.buttons["task-card-effort-\(taskId)"]
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let defaultTitle = try XCTUnwrap(control.value as? String)
        let sheet = app.sheets.firstMatch
        let save = sheet.buttons["Save"]

        func choose(_ title: String) {
            let option = sheet.radioButtons["Thinking Level, \(title)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            // The native radio indicator sits at the leading edge of the form row.
            option.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: 8, dy: 0)).click()
            XCTAssertTrue(save.isEnabled)
        }

        control.click()
        choose("High")
        sheet.buttons["Cancel"].click()
        XCTAssertEqual(control.value as? String, defaultTitle)

        func expectSavedEffort(_ effort: String?) {
            let matches = NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: boardURL),
                      let board = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let agent = (board["tasks"] as? [[String: Any]])?.first?["agent"] as? [String: Any]
                else { return false }
                return agent["effort"] as? String == effort && agent["model"] as? String == "sonnet"
                    && agent["planMode"] as? Bool == true
            }
            wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5)
        }
        expectSavedEffort(nil)

        control.click()
        choose("High")
        save.click()
        XCTAssertTrue(app.staticTexts["Thinking level updated"].waitForExistence(timeout: 5))
        XCTAssertEqual(control.value as? String, "High")
        expectSavedEffort("high")

        control.click()
        choose(defaultTitle)
        save.click()
        XCTAssertEqual(control.value as? String, defaultTitle)
        expectSavedEffort(nil)

        app.buttons["task-card-model-\(taskId)"].click()
        app.menuItems["Unassigned"].click()
        XCTAssertTrue(control.waitForNonExistence(timeout: 5))
    }
}
