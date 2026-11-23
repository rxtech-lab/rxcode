import XCTest

@MainActor
final class InspectorSplitTests: XCTestCase {
    // The sandboxed UI test runner needs the Git executable behind Apple's xcrun shim.
    private var gitExecutableURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["RXCODE_TEST_GIT"] ?? "/usr/bin/git")
    }

    private func launchInspector(project: URL? = nil, width: Int = 600, additionalProjects: [URL] = []) throws -> XCUIApplication {
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
                + additionalProjects.map { ["id": UUID().uuidString, "name": $0.lastPathComponent, "path": $0.path] }
            try JSONEncoder().encode(projects).write(to: workspaceDirectory.appending(path: "projects.json"))
        }
        // These local window checks do not need background services or notification prompts.
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1", "RXCODE_UNIT_TESTING": "1"]
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES", "-workspace.\(workspace).rightInspectorLayout", "",
            "-workspace.\(workspace).onboardingCompleted", "YES", "-showMenuBarExtra", "NO", "-SUEnableAutomaticChecks", "NO",
            "-workspace.\(workspace).showRightSidebar", "YES", "-workspace.\(workspace).rightInspectorWidth", String(width),
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

    func testSidebarGitChangesCanReturnToTools() throws {
        continueAfterFailure = false
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }

        let gitDirectory = project.appending(path: ".git")
        for directory in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: gitDirectory.appending(path: directory), withIntermediateDirectories: true)
        }
        try "ref: refs/heads/main\n".write(to: gitDirectory.appending(path: "HEAD"), atomically: true, encoding: .utf8)

        let app = try launchInspector(project: project, width: 420)
        let changes = app.buttons["sidebar-git-changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 10))
        changes.click()

        let changesTab = app.buttons["inspector-destination-review"]
        XCTAssertTrue(changesTab.wait(for: \.isSelected, toEqual: true, timeout: 5))
        assertInspectorNavigationIsVisible(in: app)
        app.buttons["inspector-destination-inspector"].click()

        let run = app.descendants(matching: .any).matching(identifier: "inspector-tool-run").firstMatch
        XCTAssertTrue(run.wait(for: \.isSelected, toEqual: true, timeout: 5))
    }

    func testLocalChangesPreviewsAmendFilesAndReportsStaging() throws {
        continueAfterFailure = false
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("GitChanges-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = gitExecutableURL
            process.currentDirectoryURL = project
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        }

        try git(["init", "-q", "-b", "main"])
        try Data("original\n".utf8).write(to: project.appending(path: "original.txt"))
        try Data("pending.txt filter=hold-stage\n".utf8).write(to: project.appending(path: ".gitattributes"))
        try git(["add", "."])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["commit", "-qm", "Original"])
        // Hold git add until the progress overlay is visible, with a timeout if the test stops.
        try git(["config", "filter.hold-stage.clean", "for i in 1 2 3 4 5 6 7 8 9 10; do test -f .git/hold-stage || break; sleep 1; done; cat"])

        let app = try launchInspector(project: project, width: 420)
        let openGit = app.buttons["sidebar-git-window"]
        XCTAssertTrue(openGit.waitForExistence(timeout: 10))
        openGit.click()
        let localChanges = app.staticTexts["Local Changes"].firstMatch
        XCTAssertTrue(localChanges.waitForExistence(timeout: 10))
        localChanges.click()
        let window = app.windows.containing(.checkBox, identifier: "Amend").firstMatch
        let amend = window.checkBoxes["Amend"]
        XCTAssertTrue(amend.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        amend.click()

        func row(_ id: String, in scope: XCUIElement) -> XCUIElement {
            scope.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        let staged = row("git-staged-files", in: window)
        let unstaged = row("git-unstaged-files", in: window)
        XCTAssertTrue(row("git-commit-file-original.txt", in: staged).waitForExistence(timeout: 10))

        let gate = project.appending(path: ".git/hold-stage")
        try Data().write(to: gate)
        try Data("pending\n".utf8).write(to: project.appending(path: "pending.txt"))
        XCTAssertTrue(row("git-file-pending.txt", in: unstaged).waitForExistence(timeout: 10))
        window.buttons["Stage All"].click()
        XCTAssertTrue(window.staticTexts["Staging pending.txt…"].waitForExistence(timeout: 5))
        try FileManager.default.removeItem(at: gate)
        XCTAssertTrue(row("git-file-pending.txt", in: staged).waitForExistence(timeout: 10))
        XCTAssertTrue(row("git-file-pending.txt", in: unstaged).waitForNonExistence(timeout: 5))

        window.buttons["Unstage All"].click()
        XCTAssertTrue(row("git-file-pending.txt", in: unstaged).waitForExistence(timeout: 10))
        amend.click()
        XCTAssertTrue(row("git-commit-file-original.txt", in: window).waitForNonExistence(timeout: 5))

        window.buttons["Stage All"].click()
        XCTAssertTrue(row("git-file-pending.txt", in: staged).waitForExistence(timeout: 10))
        amend.click()
        let openAmend = window.buttons["Amend Commit…"]
        XCTAssertTrue(openAmend.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        openAmend.click()
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(row("git-commit-file-original.txt", in: sheet).waitForExistence(timeout: 5))
        XCTAssertTrue(row("git-file-pending.txt", in: sheet).exists)
        sheet.buttons["Amend"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        try git(["cat-file", "-e", "HEAD:pending.txt"])
    }

    func testGitWindowSwitchesProjectsInPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "First")
        let second = directory.appending(path: "Second Project With a Long Name That Exceeds the Toolbar Width")
        let folder = directory.appending(path: "Plain Folder")
        for project in [first, second, folder] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }

        func initializeRepository(at project: URL, branch: String) throws {
            for arguments in [
                ["init", "-q", "-b", branch],
                ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                 "commit", "--allow-empty", "-qm", branch],
            ] {
                let process = Process()
                process.executableURL = gitExecutableURL
                process.currentDirectoryURL = project
                process.arguments = arguments
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
            }
        }
        try initializeRepository(at: first, branch: "first-branch")
        let longBranch = "feature/second-project-with-a-long-branch-name-for-the-toolbar"
        try initializeRepository(at: second, branch: longBranch)

        let app = try launchInspector(project: first, additionalProjects: [second, folder])
        let toolbar = app.windows.firstMatch.toolbars.firstMatch
        let title = toolbar.descendants(matching: .any)["toolbar-navigation-title"].firstMatch
        let search = toolbar.buttons["toolbar-global-search"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(search.exists)
        XCTAssertLessThan(title.frame.minX - search.frame.maxX, 30)
        let openGit = app.buttons["sidebar-git-window"]
        XCTAssertTrue(openGit.waitForExistence(timeout: 10))
        openGit.click()

        func element(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        let picker = element("git-project-picker")
        let firstBranch = element("git-branch-first-branch")
        let secondBranch = element("git-branch-\(longBranch)")
        XCTAssertTrue(firstBranch.waitForExistence(timeout: 10))
        let gitWindow = app.windows.containing(.any, identifier: "git-project-picker").firstMatch
        if gitWindow.frame.width > 960 {
            let edge = gitWindow.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -1, dy: 0))
            edge.click(forDuration: 0.2, thenDragTo: edge.withOffset(CGVector(dx: 960 - gitWindow.frame.width, dy: 0)))
        }
        XCTAssertLessThanOrEqual(gitWindow.frame.width, 980)
        let branchTitle = element("git-current-branch")
        XCTAssertTrue(branchTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.exists)
        let shortPickerWidth = picker.frame.width
        let shortBranchWidth = branchTitle.frame.width
        let windowCount = app.windows.count

        func choose(_ project: String) {
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.click()
            let option = app.menuItems[project]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.click()
        }
        choose(second.lastPathComponent)
        XCTAssertTrue(secondBranch.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(picker.frame.width, shortPickerWidth)
        XCTAssertGreaterThan(branchTitle.frame.width, shortBranchWidth)
        // Allow native toolbar control margins around the 240-point content cap.
        XCTAssertLessThanOrEqual(picker.frame.width, 280)
        XCTAssertLessThanOrEqual(branchTitle.frame.width, 260)
        XCTAssertFalse(firstBranch.exists)
        XCTAssertEqual(app.windows.count, windowCount)

        choose("Plain Folder")
        XCTAssertTrue(app.staticTexts["No Git repository"].waitForExistence(timeout: 10))
        XCTAssertFalse(secondBranch.exists)

        choose("Branch Test")
        XCTAssertTrue(firstBranch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, windowCount)
    }

    func testGitWindowBranchCheckoutAndRemoteDeletion() throws {
        let project = FileManager.default.temporaryDirectory.appending(path: "GitBranchActions-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        @discardableResult func git(_ arguments: String...) throws -> String {
            let process = Process()
            process.executableURL = gitExecutableURL
            process.arguments = ["-C", project.path] + arguments
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        try git("init", "-b", "main")
        try git("config", "user.name", "Git UI Test")
        try git("config", "user.email", "test@example.com")
        try git("config", "commit.gpgsign", "false")
        try git("commit", "--allow-empty", "-m", "Initial commit")
        try git("init", "--bare", "-b", "main", ".git/server")
        try git("remote", "add", "origin", project.appending(path: ".git/server").path)
        try git("push", "-u", "origin", "main")
        try git("switch", "-c", "topic")
        try git("commit", "--allow-empty", "-m", "Incoming commit")
        try git("push", "-u", "origin", "topic:refs/heads/review")
        try git("-C", ".git/server", "update-ref", "refs/heads/main", "refs/heads/review")
        try git("switch", "main")

        let app = try launchInspector(project: project)
        let openGit = app.buttons["sidebar-git-window"]
        XCTAssertTrue(openGit.waitForExistence(timeout: 10))
        openGit.click()
        let main = app.descendants(matching: .any).matching(identifier: "git-branch-main").firstMatch
        let topic = app.descendants(matching: .any).matching(identifier: "git-branch-topic").firstMatch
        let incoming = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0 ahead, 1 behind"), object: main)
        wait(for: [incoming], timeout: 15)
        topic.click()
        XCTAssertEqual(try git("branch", "--show-current"), "main")
        func switchTo(_ branch: String, using row: XCUIElement) {
            row.doubleClick()
            let head = project.appending(path: ".git/HEAD")
            let switched = NSPredicate { _, _ in (try? String(contentsOf: head, encoding: .utf8)) == "ref: refs/heads/\(branch)\n" }
            wait(for: [XCTNSPredicateExpectation(predicate: switched, object: nil)], timeout: 10)
        }
        switchTo("topic", using: topic)
        switchTo("main", using: main)

        topic.rightClick()
        app.menuItems["Delete…"].click()
        let sheet = app.sheets.containing(.button, identifier: "Delete Local Branch").firstMatch
        let checkbox = sheet.checkBoxes["Also delete “origin/review” from the remote"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        XCTAssertEqual(checkbox.value as? Int, 0)
        checkbox.click()
        app.sheets.buttons["Delete Both Branches"].click()
        XCTAssertTrue(topic.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try git("branch", "--list", "topic"), "")
        XCTAssertEqual(try git("-C", ".git/server", "branch", "--list", "review"), "")
    }

    func testInspectorToolbarShortcutsKeepTheSameSidebarLayout() throws {
        let app = try launchInspector(width: 420)
        let toggle = app.buttons["toggle-inspector-button"]
        let panel = app.descendants(matching: .any).matching(identifier: "inspector-destination-pane").firstMatch
        let tools = app.buttons["inspector-destination-inspector"]

        for (shortcut, tool) in [("open-terminal-button", "terminal"), ("open-views-button", "views")] {
            toggle.click()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
            app.buttons[shortcut].click()
            let selected = app.buttons["inspector-tool-\(tool)"]
            XCTAssertTrue(selected.wait(for: \.isSelected, toEqual: true, timeout: 5))
            assertInspectorNavigationIsVisible(in: app)
            let shortcutFrame = panel.frame
            let shortcutToolsFrame = tools.frame

            toggle.click()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
            toggle.click()
            XCTAssertTrue(selected.wait(for: \.isSelected, toEqual: true, timeout: 5))
            assertInspectorNavigationIsVisible(in: app)
            XCTAssertEqual(panel.frame, shortcutFrame)
            XCTAssertEqual(tools.frame, shortcutToolsFrame)
        }
    }

    private func assertInspectorNavigationIsVisible(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let tools = app.buttons["inspector-destination-inspector"]
        let panel = app.descendants(matching: .any).matching(identifier: "inspector-destination-pane").firstMatch
        XCTAssertGreaterThanOrEqual(tools.frame.minY, app.toolbars.firstMatch.frame.maxY, file: file, line: line)
        XCTAssertEqual(panel.frame.maxX, app.windows.firstMatch.frame.maxX, accuracy: 1, file: file, line: line)
        XCTAssertTrue(tools.isHittable, file: file, line: line)
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
