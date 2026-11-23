import AppKit
import XCTest

@MainActor
final class CodingPlanUITests: XCTestCase {
    /// A real ACP subprocess with deterministic answers, so this exercises
    /// streaming, native controls and session rollover without an account.
    func testPlanDebateRevisionImplementationAndChatConversions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        func control(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        func text(_ text: String, in pane: XCUIElement) -> XCUIElement {
            let matches = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
            return pane.descendants(matching: .any).matching(matches).firstMatch
        }
        func paste(_ item: NSPasteboardWriting, in field: XCUIElement? = nil, matching predicate: NSPredicate? = nil) {
            let pasteboard = NSPasteboard.general
            let saved = (pasteboard.pasteboardItems ?? []).map { original in
                let copy = NSPasteboardItem()
                for type in original.types {
                    if let data = original.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            let changeCount = pasteboard.changeCount
            defer {
                if pasteboard.changeCount == changeCount {
                    pasteboard.clearContents()
                    pasteboard.writeObjects(saved)
                }
            }
            app.typeKey("v", modifierFlags: .command)
            if let field, let predicate {
                let pasted = XCTNSPredicateExpectation(predicate: predicate, object: field)
                XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 4), .completed, field.debugDescription)
            }
        }
        // Paste fixture text verbatim even when the Mac has a composing input method selected.
        func enterText(_ text: String, in field: XCUIElement? = nil) {
            paste(text as NSString, in: field, matching: NSPredicate(format: "value == %@", text))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanDebateUI-\(UUID())")
        let support = root.appendingPathComponent("Support")
        let repo = root.appendingPathComponent("Repository")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let requirements = repo.appendingPathComponent("Plan requirements.md")
        try "Support reopening.".write(to: requirements, atomically: true, encoding: .utf8)
        let chatNotes = repo.appendingPathComponent("Chat notes.md")
        try "Preserve draft files.".write(to: chatNotes, atomically: true, encoding: .utf8)
        let finishDraft = root.appendingPathComponent("finish-draft")
        let projectID = UUID().uuidString
        let config: [[String: Any]] = [[
            "id": "plan-fixture", "displayName": "Fixture Client", "enabled": true,
            "launch": ["binary": ["path": "/usr/bin/python3", "args": ["-u", "-c", Self.acpClient, finishDraft.path], "env": [:]]],
            "models": ["fixture-model"], "extraArgs": [], "extraEnv": [:]
        ]]
        try JSONSerialization.data(withJSONObject: config).write(to: support.appendingPathComponent("acp_clients.json"))
        try JSONSerialization.data(withJSONObject: [["id": projectID, "name": "Test Repository", "path": repo.path]])
            .write(to: support.appendingPathComponent("projects.json"))
        let model = "plan-fixture::fixture-model"
        app.launchArguments = [
            "-onboardingCompleted", "YES", "-showMenuBarExtra", "NO", "-UseAgentSDK", "NO",
            "-resolvedLoginShellPath", "/usr/bin:/bin:/usr/sbin:/sbin",
            "-selectedAgentProvider", "acp", "-selectedModel", model, "-selectedACPClientId", "plan-fixture",
            "-globalChatLastAgentProvider", "acp", "-globalChatLastModel", model,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES",
            "-com.apple.TipKit.HideAllTips", "1", "-SUEnableAutomaticChecks", "NO",
            "-summarizationProvider", "openAI", "-openAISummarizationModel", ""
        ]
        app.launchEnvironment = ["RXCODE_APP_SUPPORT_DIR": support.path, "RXCODE_UI_TESTING": "1", "RXCODE_UNIT_TESTING": "1"]
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        app.launch()
        app.activate()
        let whatsNew = app.sheets.containing(.staticText, identifier: "New in RxCode").firstMatch
        if whatsNew.waitForExistence(timeout: 3) { whatsNew.buttons["xmark"].click() }
        let chat = app.buttons["general-route-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 25))
        chat.click()
        let addMenu = control("composer-add-menu")
        XCTAssertTrue(addMenu.waitForExistence(timeout: 10), app.windows.firstMatch.debugDescription)
        addMenu.click()
        control("composer-plan-mode").click()
        let start = app.buttons["coding-plan-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(start.isEnabled)
        app.buttons["Cancel"].click()
        let chatInput = app.textViews["chat-input-text-view"].firstMatch
        XCTAssertTrue(chatInput.waitForExistence(timeout: 5))
        chatInput.click()
        paste(chatNotes as NSURL)
        let chatFile = app.buttons["attachment-preview-Chat notes.md"].firstMatch
        XCTAssertTrue(chatFile.waitForExistence(timeout: 5))
        chatFile.click()
        let closeNotes = app.sheets.buttons["Close"].firstMatch
        XCTAssertTrue(closeNotes.waitForExistence(timeout: 5))
        XCTAssertTrue(text("Preserve draft files.", in: app).waitForExistence(timeout: 5))
        closeNotes.click()
        addMenu.click()
        control("composer-plan-mode").click()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(app.sheets.buttons["attachment-preview-Chat notes.md"].firstMatch.exists)
        let goal = app.descendants(matching: .any).matching(identifier: "coding-plan-goal").firstMatch
        control("coding-plan-goal-add-files").click()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        enterText(requirements.path)
        app.typeKey(.return, modifierFlags: [])
        open.click()
        let hasFile = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "[File: Plan requirements.md]"), object: goal)
        XCTAssertEqual(XCTWaiter.wait(for: [hasFile], timeout: 5), .completed)
        XCTAssertTrue(start.isEnabled)
        let filePreview = app.buttons["attachment-preview-Plan requirements.md"]
        XCTAssertTrue(filePreview.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(filePreview.frame.maxY, goal.frame.minY)
        filePreview.click()
        let closeFile = app.sheets.buttons["Close"].firstMatch
        XCTAssertTrue(closeFile.waitForExistence(timeout: 5))
        XCTAssertTrue(text("Support reopening.", in: app).waitForExistence(timeout: 5))
        closeFile.click()
        goal.click()
        app.typeKey(.downArrow, modifierFlags: .command)
        enterText("Persist the workspace settings.")
        let setupForm = app.sheets.scrollViews.firstMatch
        setupForm.scroll(byDeltaX: 0, deltaY: -360)
        let picker = control("coding-plan-planner")
        XCTAssertTrue(picker.exists)
        picker.click()
        XCTAssertTrue(app.menuItems["fixture-model"].firstMatch.waitForExistence(timeout: 8))
        app.menuItems["fixture-model"].firstMatch.click()
        app.buttons["coding-plan-reviewer-0"].click()
        control("coding-plan-reviewer-model").click()
        app.menuItems["fixture-model"].firstMatch.click()
        app.buttons["Save Reviewer"].click()
        setupForm.scroll(byDeltaX: 0, deltaY: -240)
        app.buttons["coding-plan-add-reviewer"].click()
        let instructions = app.descendants(matching: .any).matching(identifier: "coding-plan-review-prompt").firstMatch
        instructions.click()
        enterText("Review acceptance criteria.")
        app.buttons["Save Reviewer"].click()
        XCTAssertTrue(app.buttons["coding-plan-reviewer-1"].waitForExistence(timeout: 5))
        start.click()
        let debate = control("coding-plan-debate"), document = control("coding-plan-document")
        XCTAssertTrue(control("coding-plan-streaming-dots").waitForExistence(timeout: 10))
        XCTAssertTrue(debate.exists && document.exists)
        XCTAssertTrue(text("Persist stable keys.", in: document).waitForExistence(timeout: 8))
        XCTAssertFalse(text("Persist stable keys.", in: debate).exists)
        let toolActivity = debate.buttons["tool-activity-toggle"].firstMatch
        XCTAssertTrue(toolActivity.waitForExistence(timeout: 5))
        XCTAssertTrue(toolActivity.label.localizedCaseInsensitiveContains("running"), toolActivity.debugDescription)
        toolActivity.click()
        XCTAssertTrue(debate.buttons["tool-activity-read-brief"].firstMatch.waitForExistence(timeout: 5))
        toolActivity.click()
        let draftPrompt = try String(contentsOf: root.appendingPathComponent("draft-prompt"), encoding: .utf8)
        XCTAssertTrue(draftPrompt.contains(chatNotes.absoluteString) || draftPrompt.contains(chatNotes.resolvingSymlinksInPath().absoluteString), draftPrompt)
        XCTAssertTrue(draftPrompt.contains(requirements.absoluteString) || draftPrompt.contains(requirements.resolvingSymlinksInPath().absoluteString), draftPrompt)
        let liveScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        liveScreenshot.name = "Streaming planner with a live plan chip"
        liveScreenshot.lifetime = .keepAlways
        add(liveScreenshot)
        XCTAssertTrue(control("coding-plan-workspace").frame.contains(control("coding-plan-chip-live").frame))
        control("coding-plan-chip-live").click()
        let composer = control("coding-plan-message"), send = app.buttons["coding-plan-send"]
        let messageList = debate.scrollViews["coding-plan-messages"].firstMatch
        let restingInput = composer.frame
        let restingSend = send.frame
        func enterMultilineDraft(_ text: String) {
            composer.click()
            enterText(text, in: composer)
            let expanded = NSPredicate { _, _ in composer.frame.height > restingInput.height + 8 }
            let layout = XCTNSPredicateExpectation(predicate: expanded, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [layout], timeout: 4), .completed, composer.debugDescription)
            XCTAssertEqual(send.frame.midY, restingSend.midY, accuracy: 2)
        }
        XCTAssertTrue(messageList.frame.contains(restingInput.union(restingSend)))
        XCTAssertGreaterThan(messageList.frame.maxY - restingSend.maxY, 12)
        XCTAssertFalse(send.isEnabled)
        enterMultilineDraft("Keep a local backup.\nVerify recovery.\nTest reopening.")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPQr/8EAAKBAaEd3mrZAAAAAElFTkSuQmCC"))
        let image = NSPasteboardItem()
        image.setData(png, forType: .png)
        paste(image, in: composer, matching: NSPredicate(format: "value CONTAINS %@", "[Image1]"))
        let pastedPreview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachment-preview-pasted-")).firstMatch
        XCTAssertTrue(pastedPreview.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(pastedPreview.frame.maxY, composer.frame.minY)
        let attachmentDraft = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachmentDraft.name = "Debate draft with a pasted image"
        attachmentDraft.lifetime = .keepAlways
        add(attachmentDraft)
        pastedPreview.click()
        XCTAssertTrue(app.sheets.staticTexts["100%"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Image unavailable"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(send.isEnabled)
        send.click()
        XCTAssertTrue(text("Keep a local backup.", in: debate).waitForExistence(timeout: 5))
        XCTAssertTrue(control("coding-plan-user-bubble").exists)
        XCTAssertFalse(send.isEnabled)
        try Data().write(to: finishDraft)
        let implement = app.buttons["coding-plan-implement"]
        XCTAssertTrue(implement.waitForExistence(timeout: 45))
        XCTAssertFalse(control("coding-plan-streaming-dots").exists)
        composer.click()
        enterText("Why keep a backup?")
        app.typeKey(.return, modifierFlags: [])
        let reply = text("A backup lets you recover settings.", in: debate)
        XCTAssertTrue(reply.waitForExistence(timeout: 12))
        let replyPrompt = try String(contentsOf: root.appendingPathComponent("reply-prompt"), encoding: .utf8)
        let images = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("attachments"), includingPropertiesForKeys: nil)
        let savedImage = try XCTUnwrap(images.first { $0.pathExtension == "png" })
        XCTAssertEqual(try Data(contentsOf: savedImage), png)
        XCTAssertTrue(replyPrompt.contains(savedImage.absoluteString), replyPrompt)
        XCTAssertFalse(replyPrompt.contains("[Image1]"))
        XCTAssertTrue(implement.waitForExistence(timeout: 5))
        XCTAssertTrue(control("coding-plan-agent-bubble").exists)
        XCTAssertLessThan(reply.frame.maxY, composer.frame.minY - 10)
        enterMultilineDraft("First line\nSecond line\nThird line")
        XCTAssertLessThan(reply.frame.maxY, composer.frame.minY - 10)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        let discussion = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        discussion.name = "Plan debate with a user question and host reply"
        discussion.lifetime = .keepAlways
        add(discussion)
        // Returning to an older version requires scrolling back through the conversation.
        func openPlanChip(_ number: Int) {
            let chip = control("coding-plan-chip-\(number)")
            for _ in 0..<8 {
                if chip.exists, messageList.frame.contains(chip.frame), chip.frame.maxY < composer.frame.minY - 10, chip.isHittable {
                    chip.click()
                    return
                }
                let scrollUp = chip.exists ? chip.frame.midY < messageList.frame.midY : number == 1
                messageList.scroll(byDeltaX: 0, deltaY: scrollUp ? 210 : -210)
            }
            XCTFail("Version \(number) did not scroll into view")
        }
        openPlanChip(1)
        XCTAssertTrue(toolActivity.label.localizedCaseInsensitiveContains("succeeded"), toolActivity.debugDescription)
        XCTAssertFalse(text("Save settings.", in: debate).exists)
        XCTAssertTrue(text("Save settings.", in: document).waitForExistence(timeout: 5))
        XCTAssertEqual(send.frame, restingSend)
        let floatingScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        floatingScreenshot.name = "Floating composer over debate history"
        floatingScreenshot.lifetime = .keepAlways
        add(floatingScreenshot)
        openPlanChip(2)
        let versions = control("coding-plan-versions")
        versions.click()
        let proposal = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Reviewer 1 proposal")).firstMatch
        XCTAssertTrue(proposal.exists)
        proposal.click()
        let replacement = document.links.firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 5), document.debugDescription)
        XCTAssertFalse(text("Save settings.", in: document).exists)
        replacement.click()
        let details = control("coding-plan-change-details")
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertTrue(text("Save settings.", in: details).exists)
        XCTAssertTrue(text("Protect writes.", in: details).exists)
        app.buttons["coding-plan-add-comment"].click()
        let commentEditor = app.textViews["coding-plan-comment-text"].firstMatch
        XCTAssertTrue(commentEditor.waitForExistence(timeout: 5))
        commentEditor.click()
        enterText("Verify recovery after a restart.")
        app.buttons["Save Comment"].click()
        XCTAssertTrue(commentEditor.waitForNonExistence(timeout: 5))
        if !details.exists { replacement.click() }
        XCTAssertTrue(text("Verify recovery after a restart.", in: details).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["coding-plan-add-comment"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Plan change with original text and comments"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(.escape, modifierFlags: [])
        versions.click()
        app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Host plan")).firstMatch.click()
        app.buttons["coding-plan-revise"].click()
        let editor = app.textViews["coding-plan-revision-text"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        enterText("Implement the approved settings change.")
        app.textFields["coding-plan-revision-comment"].firstMatch.click()
        enterText("Use the approved wording.")
        app.buttons["Save Version"].click()
        XCTAssertTrue(document.links.firstMatch.waitForExistence(timeout: 5))
        document.links.firstMatch.click()
        XCTAssertTrue(text("Use the approved wording.", in: details).waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        implement.click()
        XCTAssertTrue(app.staticTexts["Implement version 4"].waitForExistence(timeout: 5))
        XCTAssertEqual(control("coding-plan-implementation-model").value as? String, "fixture-model")
        app.buttons["coding-plan-confirm-implementation"].click()
        let viewPlan = app.buttons["implementation-view-plan"]
        XCTAssertTrue(viewPlan.waitForExistence(timeout: 15))
        viewPlan.click()
        XCTAssertTrue(app.buttons["Implementation Chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(composer.exists)
        app.buttons["Implementation Chat"].click()

        let usageFooter = control("thread-usage-footer")
        XCTAssertTrue(usageFooter.waitForExistence(timeout: 10))
        let usageText = usageFooter.label + (usageFooter.value as? String ?? "")
        XCTAssertTrue(usageText.contains("5h — · 7d —"), usageFooter.debugDescription)

        let create = control("create-from-chat")
        for (action, title) in [("Create Task from Chat…", "Test task"), ("Create Story from Chat…", "Test story")] {
            create.click()
            app.menuItems[action].click()
            let generate = app.buttons["chat-board-generate"]
            XCTAssertTrue(generate.waitForExistence(timeout: 5))
            generate.click()
            let field = app.textFields["task-form-title"]
            XCTAssertTrue(field.waitForExistence(timeout: 12))
            XCTAssertEqual(field.value as? String, title)
            if title == "Test task" {
                let description = app.textViews["task-description-editor"].firstMatch
                description.click()
                paste(requirements as NSURL, in: description, matching: NSPredicate(format: "value CONTAINS %@", "[File: Plan requirements.md]"))
                let taskFile = app.sheets.buttons["attachment-preview-Plan requirements.md"].firstMatch
                XCTAssertTrue(taskFile.waitForExistence(timeout: 5))
                taskFile.click()
                XCTAssertTrue(app.sheets.buttons["Close"].firstMatch.waitForExistence(timeout: 5))
                app.sheets.buttons["Close"].firstMatch.click()
            }
            app.buttons["Save"].click()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        }
        viewPlan.rightClick()
        app.menuItems["Create Plan from Chat…"].click()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        app.buttons["Cancel"].click()
    }

    private static let acpClient = #"""
    import json, pathlib, sys, time, uuid

    def emit(payload):
        print(json.dumps(dict(jsonrpc="2.0", **payload)), flush=True)

    for line in sys.stdin:
        call = json.loads(line)
        method = call.get("method")
        if method == "initialize":
            result = {"protocolVersion": 1, "agentCapabilities": {}}
        elif method == "session/new":
            result = {"sessionId": str(uuid.uuid4())}
        elif method == "session/prompt":
            params = call["params"]
            prompt = params["prompt"][0]["text"]
            if "Distill the requested work" in prompt:
                name = "Test story" if "project story with" in prompt else "Test task"
                answer = name + "\n\nSave settings and verify reopening."
            elif "You are hosting" in prompt:
                answer = "Review storage and reopening."
            elif "As host, reply to the user's latest messages" in prompt:
                pathlib.Path(sys.argv[1]).with_name("reply-prompt").write_text(prompt)
                answer = "A backup lets you recover settings." if "Why keep a backup?" in prompt and "Keep a local backup." in prompt else "Missing context."
            elif "You are reviewer 1." in prompt:
                answer = "Protect writes.\n```suggestion\nSave settings.\n---\nSave settings atomically.\n```"
            elif "You are reviewer 2." in prompt:
                answer = "The acceptance check covers reopening."
            elif "You are the host." in prompt:
                answer = "## Implementation\n\nSave settings atomically and verify reopening."
            elif "Return the plan itself" in prompt:
                pathlib.Path(sys.argv[1]).with_name("draft-prompt").write_text(prompt)
                emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                      "update": {"sessionUpdate": "tool_call", "toolCallId": "read-brief", "kind": "read",
                                 "title": "Read requirements", "status": "in_progress", "rawInput": {"path": "Plan requirements.md"}}}})
                emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                      "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "## Implementation\n\nPersist stable keys.\n\n"}}}})
                deadline = time.monotonic() + 90
                while not pathlib.Path(sys.argv[1]).exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                      "update": {"sessionUpdate": "tool_call_update", "toolCallId": "read-brief",
                                 "status": "completed", "rawOutput": "Support reopening."}}})
                answer = "Save settings."
            else:
                answer = "Implementation complete."
            emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                  "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": answer}}}})
            result = {"stopReason": "end_turn"}
        else:
            result = {}
        if "id" in call:
            emit({"id": call["id"], "result": result})
    """#
}
