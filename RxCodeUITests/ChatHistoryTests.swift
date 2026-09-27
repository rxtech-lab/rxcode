import XCTest

final class ChatHistoryTests: XCTestCase {
    func testBrowseHistoryInsideChatTab() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatHistory-\(UUID())")
        let project = root.appendingPathComponent("Repository")
        let support = root.appendingPathComponent("AppSupport")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let projectID = UUID().uuidString
        let globalID = "28D14445-94B0-4474-BA4D-BFAD56F93B01"
        let date = ISO8601DateFormatter().string(from: Date())

        func write(_ value: Any, to path: String) throws {
            let url = support.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }

        try write([["id": projectID, "name": "History Repository", "path": project.path]], to: "projects.json")
        for (id, owner, title, message, archived) in [
            ("project-chat", projectID, "Saved repository chat", "Repository transcript content", false),
            ("global-chat", globalID, "Saved global chat", "Global transcript content", false),
            ("archived-chat", globalID, "Archived conversation", "Archived transcript content", true),
        ] {
            try write([
                "id": id, "projectId": owner, "title": title,
                "createdAt": date, "updatedAt": date, "origin": "legacyRxCode",
                "isArchived": archived,
                "messages": [["id": UUID().uuidString, "role": "user", "content": message, "timestamp": date]],
            ], to: "sessions/\(id).json")
        }

        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launchArguments = [
            "-onboardingCompleted", "YES", "-showMenuBarExtra", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-historyShowAllProjects", "NO", "-historyShowArchived", "NO",
            "-autoArchiveEnabled", "NO",
        ]
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1"]
        app.launch()

        let chatTab = app.buttons["general-route-chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 30))
        chatTab.click()

        // History lives in a sheet opened from the welcome page, not a sidebar.
        let history = app.descendants(matching: .any)["global-chat-history"].firstMatch
        XCTAssertFalse(history.exists)
        let welcomeHistory = app.buttons["global-chat-welcome-history"]
        XCTAssertTrue(welcomeHistory.waitForExistence(timeout: 10))
        welcomeHistory.click()

        XCTAssertTrue(history.waitForExistence(timeout: 10))
        let repositoryChat = history.staticTexts["Saved repository chat"].firstMatch
        XCTAssertTrue(repositoryChat.waitForExistence(timeout: 10))
        XCTAssertTrue(history.staticTexts["Saved global chat"].firstMatch.exists)
        XCTAssertFalse(history.staticTexts["Archived conversation"].firstMatch.exists)

        // Picking a thread opens it and dismisses the sheet.
        repositoryChat.click()
        XCTAssertTrue(app.staticTexts["Repository transcript content"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(history.exists)
        XCTAssertFalse(welcomeHistory.exists)

        // The header button reopens history mid-conversation.
        app.buttons["global-chat-history-toggle"].click()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.staticTexts["Saved global chat"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Global transcript content"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(history.exists)

        app.buttons["global-new-chat"].click()
        XCTAssertFalse(app.staticTexts["Global transcript content"].firstMatch.exists)
        XCTAssertTrue(welcomeHistory.waitForExistence(timeout: 5))
    }
}

@MainActor
final class BriefingNavigationTests: XCTestCase {
    func testSelectedProjectsCurrentBranchBriefingOpensInTimeline() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BriefingNavigation-\(UUID())")
        let project = root.appendingPathComponent("Repository")
        let support = root.appendingPathComponent("AppSupport")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-b", "main", project.path]
        git.standardOutput = Pipe()
        git.standardError = Pipe()
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        let projects = [["id": UUID().uuidString, "name": "Briefing Repository", "path": project.path]]
        try JSONSerialization.data(withJSONObject: projects)
            .write(to: support.appendingPathComponent("projects.json"))

        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launchArguments = ["-onboardingCompleted", "YES", "-showMenuBarExtra", "NO"]
        app.launchEnvironment = [
            "RXCODE_APP_SUPPORT_DIR": support.path,
            "RXCODE_UI_TESTING": "1",
            "RXCODE_UI_TEST_SEED_BRIEFING": "1",
        ]
        app.launch()

        let projectRow = app.staticTexts["Briefing Repository"].firstMatch
        XCTAssertTrue(projectRow.waitForExistence(timeout: 30))
        projectRow.click()
        let briefingTab = app.buttons["general-route-briefing"]
        XCTAssertTrue(briefingTab.waitForExistence(timeout: 10))
        briefingTab.click()

        // The briefing tab opens the all-projects timeline, which includes
        // the selected project's current-branch briefing as a folded card.
        XCTAssertTrue(app.staticTexts["Seeded briefing for the local UI acceptance test."].waitForExistence(timeout: 10))
    }
}
