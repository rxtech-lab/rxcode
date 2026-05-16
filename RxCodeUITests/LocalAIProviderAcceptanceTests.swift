import XCTest

final class LocalAIProviderAcceptanceTests: XCTestCase {
    enum Provider: String, CaseIterable {
        case codex
        case claudeCode
        case acp

        var modelSeed: String {
            switch self {
            case .codex: return "gpt-5.1-codex"
            case .claudeCode: return "sonnet"
            case .acp: return "default"
            }
        }
    }

    private var app: XCUIApplication!
    private var fixture: Fixture!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CI"] != "true"
                && ProcessInfo.processInfo.environment["RXCODE_SKIP_LOCAL_AI_UI_TESTS"] != "1",
            "Local AI UI acceptance tests are skipped in CI or when RXCODE_SKIP_LOCAL_AI_UI_TESTS=1."
        )
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }
        app = nil
        fixture = nil
    }

    func testCodexAcceptanceWorkflow() throws {
        try runAcceptanceWorkflow(provider: .codex)
    }

    func testClaudeCodeAcceptanceWorkflow() throws {
        try runAcceptanceWorkflow(provider: .claudeCode)
    }

    func testACPAcceptanceWorkflow() throws {
        try XCTSkipUnless(
            Fixture.firstInstalledACPClient() != nil,
            "No installed ACP client found in the local RxCode ACP client store."
        )
        try runAcceptanceWorkflow(provider: .acp)
    }

    private func runAcceptanceWorkflow(provider: Provider) throws {
        fixture = try Fixture.make(provider: provider)
        app = launchApp(provider: provider, fixture: fixture)

        XCTAssertTrue(app.otherElements["rxcode-main-view"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["run-profile-run-button"].waitForExistence(timeout: 10))

        runProfileSmoke()
        sendPlanModeTurn(provider: provider)
        sendIntegratedAITurn(provider: provider)
    }

    private func launchApp(provider: Provider, fixture: Fixture) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingCompleted", "YES",
            "-showMenuBarExtra", "NO",
            "-selectedAgentProvider", provider.rawValue,
            "-selectedModel", fixture.selectedModel(for: provider),
            "-selectedACPClientId", fixture.selectedACPClientId ?? "",
        ]
        app.launchEnvironment = [
            "RXCODE_APP_SUPPORT_DIR": fixture.appSupportURL.path,
            "RXCODE_UI_TESTING": "1",
            "RXCODE_LOCAL_MCP_SERVER": fixture.mcpServerPath,
        ]
        app.launch()
        return app
    }

    private func runProfileSmoke() {
        app.buttons["run-profile-run-button"].click()
        let inspector = app.buttons["toggle-inspector-button"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "RXCODE_UI_TEST_RUN_PROFILE")).element.waitForExistence(timeout: 15))
    }

    private func sendPlanModeTurn(provider: Provider) {
        let input = focusInput()
        app.typeKey(.tab, modifierFlags: [.shift])
        XCTAssertTrue(app.buttons["plan-mode-chip"].waitForExistence(timeout: 5))
        input.typeText("Create a concise implementation plan for adding a local test sentinel. Do not edit files yet.")
        app.buttons["chat-send-button"].click()

        let planCard = app.buttons["plan-card-button"]
        XCTAssertTrue(planCard.waitForExistence(timeout: 120), "Expected a plan card for \(provider.rawValue)")
        planCard.click()

        let acceptAsk = app.buttons["plan-button-accept-ask"]
        XCTAssertTrue(acceptAsk.waitForExistence(timeout: 10))
        acceptAsk.click()
    }

    private func sendIntegratedAITurn(provider: Provider) {
        let input = focusInput()
        input.typeText("""
        Local RxCode UI acceptance test for \(provider.rawValue):
        1. Track exactly three todos: inspect fixture, edit sentinel, verify result.
        2. Edit Sources/Sentinel.txt so it contains RXCODE_UI_TEST_EDITED.
        3. Call the MCP tool rxcode_test_echo with text ui-test.
        4. Use any available IDE job/thread inspection tool if it is available.
        Keep the final response short and include RXCODE_UI_TEST_DONE.
        """)
        app.buttons["chat-send-button"].click()

        XCTAssertTrue(app.buttons["todo-progress-button"].waitForExistence(timeout: 120))
        XCTAssertTrue(waitForFileToContain(fixture.projectURL.appendingPathComponent("Sources/Sentinel.txt"), "RXCODE_UI_TEST_EDITED", timeout: 180))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "RXCODE_UI_TEST_DONE")).element.waitForExistence(timeout: 180))
    }

    private func focusInput() -> XCUIElement {
        let input = app.textViews["chat-input-text-view"].exists
            ? app.textViews["chat-input-text-view"]
            : app.textViews.element(boundBy: 0)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        return input
    }

    private func waitForFileToContain(_ url: URL, _ needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url), contents.contains(needle) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return false
    }
}

private struct Fixture {
    let rootURL: URL
    let appSupportURL: URL
    let projectURL: URL
    let mcpServerPath: String
    let selectedACPClientId: String?
    let selectedACPModel: String?

    func selectedModel(for provider: LocalAIProviderAcceptanceTests.Provider) -> String {
        if provider == .acp, let selectedACPModel {
            return selectedACPModel
        }
        return provider.modelSeed
    }

    static func make(provider: LocalAIProviderAcceptanceTests.Provider) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("RxCodeUITests-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        let project = root.appendingPathComponent("FixtureProject", isDirectory: true)
        let sources = project.appendingPathComponent("Sources", isDirectory: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try "RXCODE_UI_TEST_ORIGINAL\n".write(to: sources.appendingPathComponent("Sentinel.txt"), atomically: true, encoding: .utf8)

        let projectId = "11111111-1111-1111-1111-111111111111"
        let installedACPClient = provider == .acp ? firstInstalledACPClient() : nil
        let selectedACPClientId = installedACPClient.flatMap { $0["id"] as? String }
        let selectedACPModel = installedACPClient.flatMap(Self.firstModelID(in:))
        try writeJSON([
            [
                "id": projectId,
                "name": "RxCode UI Fixture",
                "path": project.path,
                "lastAgentProvider": provider.rawValue,
                "lastModel": selectedACPModel ?? provider.modelSeed,
            ],
        ], to: appSupport.appendingPathComponent("projects.json"))

        try writeJSON([
            [
                "id": "22222222-2222-2222-2222-222222222222",
                "projectId": projectId,
                "name": "UI Test Echo",
                "type": "bash",
                "bash": [
                    "command": "printf 'RXCODE_UI_TEST_RUN_PROFILE\\n'",
                    "workingDirectory": "",
                    "environments": [],
                ],
                "beforeSteps": [],
                "afterSteps": [],
                "createdAt": "2026-05-16T00:00:00Z",
                "updatedAt": "2026-05-16T00:00:00Z",
            ],
        ], to: appSupport.appendingPathComponent("run_profiles/\(projectId).json"))

        let mcpServer = ProcessInfo.processInfo.environment["RXCODE_LOCAL_MCP_SERVER"]
            ?? "\(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path)/scripts/mcp_echo_server.py"
        try writeJSON([
            "version": 1,
            "servers": [[
                "name": "rxcode-ui-test",
                "transport": "stdio",
                "command": mcpServer,
                "args": [],
                "env": [:],
                "headers": [:],
                "isGloballyEnabled": true,
                "projectOverrides": [project.path: "enabled"],
            ]],
        ], to: appSupport.appendingPathComponent("mcp.json"))

        if let installedACPClient {
            var copied = installedACPClient
            copied["enabled"] = true
            try writeJSON([copied], to: appSupport.appendingPathComponent("acp_clients.json"))
        }

        return Fixture(
            rootURL: root,
            appSupportURL: appSupport,
            projectURL: project,
            mcpServerPath: mcpServer,
            selectedACPClientId: selectedACPClientId,
            selectedACPModel: selectedACPModel
        )
    }

    static func firstInstalledACPClient() -> [String: Any]? {
        for url in acpClientStoreCandidates() {
            guard let data = try? Data(contentsOf: url),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !array.isEmpty else {
                continue
            }
            return array.first { ($0["enabled"] as? Bool) != false } ?? array.first
        }
        return nil
    }

    private static func acpClientStoreCandidates() -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["RXCODE_ACP_CLIENTS_FILE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        candidates.append(applicationSupport.appendingPathComponent("RxCode/acp_clients.json"))
        candidates.append(applicationSupport.appendingPathComponent("RxCode.dev/acp_clients.json"))

        if let enumerator = fm.enumerator(
            at: applicationSupport,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard url.lastPathComponent == "acp_clients.json",
                      url.path.contains("/RxCode") else {
                    continue
                }
                candidates.append(url)
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func firstModelID(in client: [String: Any]) -> String? {
        if let models = client["models"] as? [String],
           let first = models.first,
           !first.isEmpty {
            return first
        }
        if let options = client["modelOptions"] as? [[String: Any]],
           let value = options.compactMap({ $0["value"] as? String }).first,
           !value.isEmpty {
            return value
        }
        return nil
    }

    private static func writeJSON(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
