import AppKit
import XCTest

@MainActor
final class CodingPlanUITests: XCTestCase {
    private let app = XCUIApplication()
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanDebateUI-\(UUID())")
    private var support: URL { root.appendingPathComponent("Support") }
    private var repo: URL { root.appendingPathComponent("Repository") }
    private var finishDraft: URL { root.appendingPathComponent("finish-draft") }

    private func control(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func text(_ text: String, in pane: XCUIElement) -> XCUIElement {
        let matches = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
        return pane.descendants(matching: .any).matching(matches).firstMatch
    }

    private func paste(_ item: NSPasteboardWriting, in field: XCUIElement? = nil, matching predicate: NSPredicate? = nil) {
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
    private func enterText(_ text: String, in field: XCUIElement? = nil) {
        paste(text as NSString, in: field, matching: NSPredicate(format: "value == %@", text))
    }

    private func launchFixture() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let projectID = UUID().uuidString
        let config: [[String: Any]] = [[
            "id": "plan-fixture", "displayName": "Fixture Client", "enabled": true,
            "launch": ["binary": ["path": "/usr/bin/python3", "args": ["-u", "-c", Self.acpClient, finishDraft.path], "env": [:]]],
            "models": ["fixture-model", "alternate-model"], "extraArgs": [], "extraEnv": [:]
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
        addTeardownBlock { @MainActor [app, root] in
            app.terminate()
            try FileManager.default.removeItem(at: root)
        }
        app.launch()
        app.activate()
        let whatsNew = app.sheets.containing(.staticText, identifier: "New in RxCode").firstMatch
        if whatsNew.waitForExistence(timeout: 3) { whatsNew.buttons["xmark"].click() }
        let chat = app.buttons["general-route-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 25))
        chat.click()
    }

    /// A real ACP subprocess with deterministic answers, so this exercises
    /// streaming, native controls and session rollover without an account.
    func testPlanDebateRevisionImplementationAndChatConversions() throws {
        try launchFixture()
        let requirements = repo.appendingPathComponent("Plan requirements.md")
        try "Support reopening.".write(to: requirements, atomically: true, encoding: .utf8)
        let chatNotes = repo.appendingPathComponent("Chat notes.md")
        try "Preserve draft files.".write(to: chatNotes, atomically: true, encoding: .utf8)
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
        let importedFile = app.sheets.buttons["attachment-preview-Chat notes.md"].firstMatch
        XCTAssertTrue(importedFile.exists)
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
        XCTAssertLessThanOrEqual(filePreview.frame.height, 30)
        XCTAssertEqual(filePreview.frame.midY, importedFile.frame.midY, accuracy: 2)
        XCTAssertLessThanOrEqual(filePreview.frame.maxY, goal.frame.minY)
        let chipScreenshot = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        chipScreenshot.name = "Planning request with file chips"
        chipScreenshot.lifetime = .keepAlways
        add(chipScreenshot)
        filePreview.click()
        let closeFile = app.sheets.buttons["Close"].firstMatch
        XCTAssertTrue(closeFile.waitForExistence(timeout: 5))
        XCTAssertTrue(text("Support reopening.", in: app).waitForExistence(timeout: 5))
        closeFile.click()
        app.sheets.buttons["attachment-remove-Plan requirements.md"].click()
        XCTAssertTrue(filePreview.waitForNonExistence(timeout: 5))
        XCTAssertFalse((goal.value as? String)?.contains("Plan requirements.md") ?? true)
        XCTAssertTrue(importedFile.exists)
        goal.click()
        paste(requirements as NSURL, in: goal, matching: NSPredicate(format: "value CONTAINS %@", "[File: Plan requirements.md]"))
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
        XCTAssertTrue(text("Protect writes.", in: debate).exists)
        XCTAssertFalse(text("<!--", in: debate).exists)
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
        XCTAssertFalse(text("<!--", in: details).exists)
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
        XCTAssertTrue(usageText.contains("5h") && usageText.contains("7d") && usageText.contains("—"), usageFooter.debugDescription)

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

    func testActiveAndReadyPlanRowsDoNotShowInterrupted() throws {
        try launchFixture()
        control("composer-add-menu").click()
        control("composer-plan-mode").click()
        let goal = app.textViews["coding-plan-goal"].firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 8))
        app.sheets.popUpButtons.matching(NSPredicate(format: "value == %@", "Chat")).firstMatch.click()
        app.menuItems["Test Repository"].firstMatch.click()
        goal.click()
        let title = "Plan search"
        enterText(title, in: goal)
        app.buttons["coding-plan-start"].click()
        XCTAssertTrue(control("coding-plan-streaming-dots").waitForExistence(timeout: 15))

        let expand = app.buttons["Expand chats in Test Repository"]
        if expand.exists { expand.click() }
        let projects = app.scrollViews.containing(.button, identifier: "Collapse chats in Test Repository").firstMatch
        XCTAssertTrue(text(title, in: projects).waitForExistence(timeout: 5))
        app.buttons["global-chat-sidebar-toggle"].click()
        let historyRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'history-thread-'")).firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
        XCTAssertFalse(text("Interrupted", in: app).exists)

        try Data().write(to: finishDraft)
        XCTAssertTrue(app.buttons["coding-plan-implement"].waitForExistence(timeout: 30))
        XCTAssertTrue(historyRow.exists)
        XCTAssertTrue(text(title, in: projects).exists)
        XCTAssertFalse(text("Interrupted", in: app).exists)
    }

    func testAddAndInspectReviewerWhilePlannerIsResponding() throws {
        try launchFixture()
        control("composer-add-menu").click()
        control("composer-plan-mode").click()
        let goal = app.textViews["coding-plan-goal"].firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 8))
        goal.click()
        enterText("Plan settings storage.", in: goal)
        app.buttons["coding-plan-start"].click()
        XCTAssertTrue(control("tool-activity-toggle").waitForExistence(timeout: 15))

        let reviewers = app.buttons["coding-plan-reviewers"]
        reviewers.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(text("Review feasibility, edge cases, and verification.", in: sheet).waitForExistence(timeout: 5))
        XCTAssertTrue(text("ACP · Fixture Client", in: sheet).exists)
        XCTAssertTrue(text("fixture-model", in: sheet).exists)
        XCTAssertTrue(text("Queued", in: sheet).exists)
        app.buttons["coding-plan-add-reviewer"].click()
        let instructions = app.textViews["coding-plan-review-prompt"].firstMatch
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        instructions.click()
        enterText("Check **reopening** on launch.", in: instructions)
        app.buttons["Save Reviewer"].click()
        XCTAssertTrue(text("Reviewer 2", in: sheet).waitForExistence(timeout: 5))
        XCTAssertTrue(text("Check reopening on launch.", in: sheet).exists)
        try Data().write(to: finishDraft)
        XCTAssertTrue(text("Reviewed", in: sheet).waitForExistence(timeout: 20))
        sheet.buttons["Close"].click()
        let implement = app.buttons["coding-plan-implement"]
        XCTAssertTrue(implement.waitForExistence(timeout: 20))
        let reviewPrompt = try String(contentsOf: root.appendingPathComponent("reviewer-2-prompt"), encoding: .utf8)
        XCTAssertTrue(reviewPrompt.contains("You are reviewer 2. Check **reopening** on launch."))

        implement.click()
        app.buttons["coding-plan-confirm-implementation"].click()
        let viewPlan = app.buttons["implementation-view-plan"]
        XCTAssertTrue(viewPlan.waitForExistence(timeout: 15))
        viewPlan.click()
        reviewers.click()
        XCTAssertTrue(text("Check reopening on launch.", in: sheet).waitForExistence(timeout: 5))
        XCTAssertFalse(sheet.buttons["coding-plan-add-reviewer"].exists)
    }

    func testPlanFormWrapsFilesAndReviewerAsksThroughQuestionTool() throws {
        try launchFixture()
        control("composer-add-menu").click()
        control("composer-plan-mode").click()
        let goal = app.textViews["coding-plan-goal"].firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 8))
        goal.click()
        enterText("Plan backup retention.", in: goal)

        let shortNames = ["Plan.md", "Notes.md"]
        let otherNames = (1...4).map { "Release verification checklist \($0).md" }
        let longName = String(repeating: "Backup retention requirements and verification ", count: 4) + "notes.md"
        let sheet = app.sheets.firstMatch
        let formWidth = sheet.frame.width
        for name in shortNames + otherNames + [longName] {
            let file = repo.appendingPathComponent(name)
            try "Backup notes.".write(to: file, atomically: true, encoding: .utf8)
            paste(file as NSURL, in: goal, matching: NSPredicate(format: "value CONTAINS %@", "[File: \(name)]"))
        }
        let first = sheet.buttons["attachment-preview-\(shortNames[0])"]
        let second = sheet.buttons["attachment-preview-\(shortNames[1])"]
        XCTAssertTrue((goal.value as? String)?.contains("[File: Plan.md] [File: Notes.md]") == true)
        let long = sheet.buttons.matching(NSPredicate(format: "identifier == %@", "attachment-preview-\(longName)")).firstMatch
        let remove = sheet.buttons.matching(NSPredicate(format: "identifier == %@", "attachment-remove-\(longName)")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertEqual(sheet.frame.width, formWidth, accuracy: 2)
        XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 2)
        let lastChecklist = sheet.buttons["attachment-preview-\(otherNames[3])"]
        XCTAssertGreaterThanOrEqual(lastChecklist.frame.minY, first.frame.maxY)
        XCTAssertGreaterThanOrEqual(long.frame.minY, lastChecklist.frame.maxY)
        XCTAssertGreaterThan(long.frame.height, first.frame.height)
        XCTAssertGreaterThanOrEqual(long.frame.minX, sheet.frame.minX)
        XCTAssertLessThanOrEqual(remove.frame.maxX, sheet.frame.maxX)
        // The text view scrolls its document to the caret as files are pasted.
        let editorScrolls = sheet.scrollViews.containing(.textView, identifier: "coding-plan-goal")
        let viewport = try XCTUnwrap(editorScrolls.allElementsBoundByIndex.min { $0.frame.height < $1.frame.height })
        XCTAssertLessThanOrEqual(long.frame.maxY, viewport.frame.minY, sheet.debugDescription)
        let editorBelowWrappedRow = viewport.frame.minY
        remove.click()
        XCTAssertTrue(long.waitForNonExistence(timeout: 5))
        XCTAssertLessThan(viewport.frame.minY, editorBelowWrappedRow)

        app.buttons["coding-plan-start"].click()
        let question = app.sheets.staticTexts["How many backups should be kept?"]
        XCTAssertTrue(question.waitForExistence(timeout: 30), app.windows.firstMatch.debugDescription)
        app.sheets.buttons["Close"].click()
        let pending = app.buttons["coding-plan-pending-question"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        let field = app.textViews["coding-plan-message"].firstMatch
        let attachmentButton = app.buttons["coding-plan-message-add-files"]
        let sendButton = app.buttons["coding-plan-send"]
        func checkBannerPlacement() {
            let banner = pending.frame
            // Measure the controls inside the composer's leading and trailing padding.
            XCTAssertEqual(attachmentButton.frame.minX - banner.minX, 14, accuracy: 3)
            XCTAssertEqual(banner.maxX - sendButton.frame.maxX, 10, accuracy: 3)
            XCTAssertGreaterThan(field.frame.minY, banner.maxY)
            XCTAssertLessThanOrEqual(field.frame.minY - banner.maxY, 24)
        }
        checkBannerPlacement()
        let debate = control("coding-plan-debate")
        let divider = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Debate room width")).firstMatch
        if divider.exists {
            XCTAssertTrue(debate.frame.contains(pending.frame))
            let initialSize = pending.frame.size
            let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            handle.click(forDuration: 0.2, thenDragTo: debate.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
            XCTAssertLessThan(pending.frame.width, initialSize.width)
            XCTAssertEqual(pending.frame.height, initialSize.height, accuracy: 1)
            checkBannerPlacement()
            app.buttons["global-chat-sidebar-toggle"].click()
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            checkBannerPlacement()
        }
        pending.click()
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        app.sheets.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Two copies")).firstMatch.click()
        app.sheets.buttons["Submit"].click()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["coding-plan-implement"].waitForExistence(timeout: 20))
        XCTAssertTrue(text("Keep two backup copies.", in: control("coding-plan-document")).exists)
    }

    func testImplementPlanTwiceWithDifferentModelsAndViewFullPlan() throws {
        try launchFixture()
        control("composer-add-menu").click()
        control("composer-plan-mode").click()
        let goal = app.textViews["coding-plan-goal"].firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 8))
        goal.click()
        enterText("Plan backup retention.", in: goal)
        app.buttons["coding-plan-start"].click()
        let answer = app.sheets.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Two copies")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), app.debugDescription)
        answer.click()
        app.sheets.buttons["Submit"].click()
        let implement = app.buttons["coding-plan-implement"]
        XCTAssertTrue(implement.waitForExistence(timeout: 20))
        implement.click()
        let model = control("coding-plan-implementation-model")
        let effort = control("coding-plan-implementation-effort")
        XCTAssertEqual(model.value as? String, "fixture-model")
        XCTAssertFalse(effort.exists)
        model.click()
        app.menuItems["Sonnet"].firstMatch.click()
        // Claude reports its levels from the installed CLI. CI hosts may have only the ACP fixture.
        if effort.waitForExistence(timeout: 5) {
            effort.click()
            app.menuItems["High"].firstMatch.click()
            XCTAssertEqual(effort.value as? String, "High")
        }
        model.click()
        app.menuItems["fixture-model"].firstMatch.click()
        XCTAssertFalse(effort.exists)
        app.buttons["coding-plan-confirm-implementation"].click()
        let fullPlan = app.buttons["implementation-message-full-plan"]
        XCTAssertTrue(fullPlan.waitForExistence(timeout: 10))
        XCTAssertFalse(text("Keep two backup copies.", in: app).exists)
        fullPlan.click()
        XCTAssertTrue(text("Keep two backup copies.", in: app.sheets.firstMatch).waitForExistence(timeout: 5))
        app.sheets.buttons["Done"].click()

        let groupToggle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-plan-disclosure-")).firstMatch
        XCTAssertTrue(groupToggle.waitForExistence(timeout: 5))
        let parentID = String(groupToggle.identifier.dropFirst("history-plan-disclosure-".count))
        let planRow = control("history-thread-\(parentID)")
        planRow.click()
        XCTAssertTrue(implement.waitForExistence(timeout: 10))
        implement.click()
        model.click()
        app.menuItems["alternate-model"].firstMatch.click()
        app.buttons["coding-plan-confirm-implementation"].click()
        XCTAssertTrue(fullPlan.waitForExistence(timeout: 10))
        let history = control("global-chat-history")
        func implementationRow(_ model: String) -> XCUIElement {
            history.staticTexts.matching(NSPredicate(format: "(value CONTAINS 'Implementation' AND value CONTAINS %@) OR (label CONTAINS 'Implementation' AND label CONTAINS %@)", model, model)).firstMatch
        }
        XCTAssertTrue(implementationRow("alternate-model").waitForExistence(timeout: 5), history.debugDescription)
        XCTAssertTrue(implementationRow("fixture-model").exists)
        groupToggle.click()
        XCTAssertTrue(implementationRow("alternate-model").waitForNonExistence(timeout: 5))
        groupToggle.click()
        XCTAssertTrue(implementationRow("alternate-model").waitForExistence(timeout: 5))
    }
}
