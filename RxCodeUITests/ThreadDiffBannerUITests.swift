import XCTest

@MainActor
final class ThreadDiffBannerUITests: XCTestCase {
    func testFirstFileEditShowsBannerAboveInputAndOpensDiff() throws {
        let (app, project) = try launchProjectChat()
        let holdTurn = project.appending(path: "hold-turn")
        try Data().write(to: holdTurn)
        let banner = app.buttons["thread-diff-banner"]
        let input = app.textViews["chat-input-text-view"]
        XCTAssertFalse(banner.exists)

        send("Edit greeting", in: app)
        XCTAssertTrue(app.buttons["chat-stop-button"].waitForExistence(timeout: 10))
        let file = project.appending(path: "Greeting.txt")
        let wroteFile = NSPredicate { _, _ in FileManager.default.fileExists(atPath: file.path) }
        wait(for: [XCTNSPredicateExpectation(predicate: wroteFile, object: nil)], timeout: 10)
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "The first recorded edit should reveal the banner during the turn")
        XCTAssertTrue(banner.isHittable)
        XCTAssertLessThanOrEqual(banner.frame.maxY, input.frame.minY)
        XCTAssertTrue(banner.label.contains("1 file changed"), banner.debugDescription)
        XCTAssertTrue(banner.label.contains("View Diff"), banner.debugDescription)

        banner.click()
        let sheet = app.sheets.firstMatch
        let fileRow = sheet.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Greeting.txt")).firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 5))
        fileRow.click()
        XCTAssertTrue(sheet.staticTexts["Greeting.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Diff"].exists)
        try FileManager.default.removeItem(at: holdTurn)
    }

    func testReopeningEditedThreadRestoresBannerAndCleanThreadHasNone() throws {
        let (app, _) = try launchProjectChat()
        send("Edit greeting", in: app)
        XCTAssertTrue(app.staticTexts["Greeting updated."].firstMatch.waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["What should we build in Diff Fixture?"].waitForExistence(timeout: 5))
        send("Read greeting", in: app)
        XCTAssertTrue(app.staticTexts["Greeting read."].firstMatch.waitForExistence(timeout: 10))
        let banner = app.buttons["thread-diff-banner"]
        XCTAssertFalse(banner.exists)

        let edited = app.staticTexts["Edit greeting"].firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10))
        edited.click()
        XCTAssertTrue(app.staticTexts["Greeting updated."].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        app.staticTexts["Read greeting"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Greeting read."].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
    }

    private func launchProjectChat() throws -> (XCUIApplication, URL) {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(path: "ThreadDiff-\(UUID())")
        let support = root.appending(path: "Support")
        let project = root.appending(path: "Project")
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let clientID = "diff-fixture"
        let projects = [[
            "id": UUID().uuidString, "name": "Diff Fixture", "path": project.path,
            "lastAgentProvider": "acp", "lastModel": "\(clientID)::fixture-model",
        ]]
        try JSONEncoder().encode(projects).write(to: support.appending(path: "projects.json"))
        let clients: [[String: Any]] = [[
            "id": clientID, "displayName": "Diff Fixture Agent", "enabled": true,
            "launch": ["binary": ["path": "/usr/bin/python3", "args": ["-u", "-c", Self.agent, project.path], "env": [:]]],
            "models": ["fixture-model"], "extraArgs": [], "extraEnv": [:],
        ]]
        try JSONSerialization.data(withJSONObject: clients).write(to: support.appending(path: "acp_clients.json"))
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1"]
        app.launchArguments = [
            "-onboardingCompleted", "YES", "-showMenuBarExtra", "NO", "-SUEnableAutomaticChecks", "NO",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES",
            "-com.apple.TipKit.HideAllTips", "1", "-summarizationProvider", "selectedClient",
            "-selectedAgentProvider", "acp", "-selectedModel", "\(clientID)::fixture-model", "-selectedACPClientId", clientID,
            "-resolvedLoginShellPath", "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        app.launch()
        app.activate()
        let whatsNew = app.sheets.containing(.staticText, identifier: "New in RxCode").firstMatch
        if whatsNew.waitForExistence(timeout: 3) { whatsNew.buttons["xmark"].click() }
        openNewChat(in: app)
        return (app, project)
    }

    private func openNewChat(in app: XCUIApplication) {
        let sidebar = app.scrollViews.containing(.button, identifier: "Show all chats").firstMatch
        let disclosure = sidebar.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "chats in Diff Fixture")).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 15))
        disclosure.hover()
        let newChat = sidebar.buttons["square.and.pencil"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.click()
        XCTAssertTrue(app.textViews["chat-input-text-view"].waitForExistence(timeout: 5))
    }

    private func send(_ prompt: String, in app: XCUIApplication) {
        let input = app.textViews["chat-input-text-view"]
        input.click()
        app.typeText(prompt)
        XCTAssertEqual(input.value as? String, prompt)
        let sendButton = app.buttons["chat-send-button"]
        XCTAssertTrue(sendButton.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        sendButton.click()
    }

    /// A local ACP client sends ordinary tool events through the same change tracker as a real agent.
    private static let agent = #"""
    import json, pathlib, sys, time, uuid

    project = pathlib.Path(sys.argv[1])
    def emit(**message):
        print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)

    for line in sys.stdin:
        call = json.loads(line)
        method = call.get("method")
        result = {}
        if method == "initialize":
            result = {"protocolVersion": 1, "agentCapabilities": {}}
        elif method == "session/new":
            result = {"sessionId": str(uuid.uuid4())}
        elif method == "session/prompt":
            params = call["params"]
            def update(**event):
                emit(method="session/update", params={"sessionId": params["sessionId"], "update": event})
            if any("Edit greeting" in part.get("text", "") for part in params["prompt"]):
                target = project / "Greeting.txt"
                diff = {"type": "diff", "path": str(target), "newText": "Hello"}
                update(sessionUpdate="tool_call", toolCallId="write", kind="edit", title="Write greeting", content=[diff])
                target.write_text(diff["newText"])
                update(sessionUpdate="tool_call_update", toolCallId="write", status="completed")
                deadline = time.monotonic() + 60
                while (project / "hold-turn").exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                answer = "Greeting updated."
            else:
                answer = "Greeting read."
            update(sessionUpdate="agent_message_chunk", content={"type": "text", "text": answer})
            result = {"stopReason": "end_turn"}
        if "id" in call:
            emit(id=call["id"], result=result)
    """#
}
