import XCTest
import RxCodeCore
@testable import RxCode

extension CodingPlanTests {
    func testDebateStreamsOncePerRoleAndHandsOnlyTheChosenVersionToFreshThread() async throws {
        let writer = backend(.codex), moderator = backend(.claudeCode), critic = backend(.acp)
        let implementer = backend(.flowcy)
        let first = "## Storage\n\nUse a file. Reopen the project."
        await writer.enqueueScript([
            .init(delay: 0, event: .textDelta(first)), .assistantText(first), .result(sessionId: "writer-native")
        ], forCwd: repo.path)
        await answer("Check interrupted writes.", using: moderator)
        await answer("Handle interruptions.\n```suggestion\nUse a file.\n---\nWrite atomically.\n```", using: critic)
        await answer("The revised draft also needs a reload check.", using: critic)
        await answer("## Implementation\n\nWrite atomically and test reopening.", using: moderator)

        let config = CodingPlan.Configuration(planner: planner, hostOverride: host, reviewers: [
            .init(model: reviewer, prompt: "Audit persistence"), .init(model: reviewer, prompt: "Audit reloads")
        ])
        try await state.startCodingPlan(goal: "Persist settings", source: "Original chat marker", configuration: config,
                                        project: project, worktreePath: repo.path, worktreeBranch: "feature", in: window)
        let sourceID = try XCTUnwrap(window.currentSessionId)
        var room = try XCTUnwrap(state.codingPlanRoom(for: sourceID))
        await room.task?.value
        XCTAssertNil(room.plan.lastError)
        XCTAssertNil(room.plan.nextStep)
        XCTAssertEqual(room.plan.contributions.map(\.role), ["Planner", "Host", "Reviewer 1", "Reviewer 2", "Host"])
        XCTAssertEqual(room.plan.versions.map(\.title), ["Planner draft", "Reviewer 1 proposal", "Host plan"])
        XCTAssertEqual(room.plan.versions.first?.markdown, first)
        XCTAssertEqual(room.plan.versions[1].markdown, "## Storage\n\nWrite atomically. Reopen the project.")
        let reviews = await critic.receivedRequests
        XCTAssertEqual(reviews.map(\.model), ["review", "review"])
        XCTAssertEqual(reviews.first?.acpSpec?.id, "test")
        XCTAssertTrue(reviews[0].prompt.contains("Audit persistence"))
        XCTAssertTrue(reviews[1].prompt.contains("Audit reloads"))
        XCTAssertTrue(reviews[1].prompt.contains("Write atomically. Reopen"))
        XCTAssertTrue(reviews[0].prompt.contains("Check interrupted writes."))
        XCTAssertTrue(reviews.allSatisfy { $0.isEphemeral && $0.sessionId == nil && $0.planMode && $0.permissionMode == .plan })
        XCTAssertNotEqual(reviews[0].clientSessionKey, reviews[1].clientSessionKey)

        state.codingPlanRooms.removeAll()
        room = try XCTUnwrap(state.codingPlanRoom(for: sourceID))
        let hostVersion = try XCTUnwrap(room.plan.versions.last)
        try state.reviseCodingPlan(room, base: hostVersion.id, text: "Manually edited plan", askHost: false, cwd: repo.path)
        let edited = try XCTUnwrap(room.plan.versions.last)
        XCTAssertThrowsError(try state.reviseCodingPlan(room, base: hostVersion.id, text: "Stale edit", askHost: false, cwd: repo.path))
        await answer("Newer host-only revision", using: moderator)
        try state.reviseCodingPlan(room, base: edited.id, text: "Another approach", askHost: true, cwd: repo.path)
        await room.task?.value
        XCTAssertEqual(room.plan.versions.last?.markdown, "Newer host-only revision")
        let resultID = UUID().uuidString
        await implementer.enqueueScript([.systemInit(sessionId: resultID), .assistantText("Implemented"), .result(sessionId: resultID)], forCwd: repo.path)
        let implementationModel = AgentModel(provider: .flowcy, id: "implementation", displayName: "Implementation model")
        let stream = await state.implementCodingPlan(room, versionID: edited.id, model: implementationModel, in: window)
        let finished = await state.awaitStreamCompletion(streamId: try XCTUnwrap(stream), timeout: 10, acceptsPartial: false)
        XCTAssertNotNil(finished)
        let requests = await implementer.receivedRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.prompt, CodingPlan.implementationPrompt(for: edited))
        XCTAssertNil(request.sessionId)
        XCTAssertTrue(request.history.isEmpty)
        XCTAssertFalse(request.planMode)
        XCTAssertFalse(request.isEphemeral)
        XCTAssertEqual(request.model, implementationModel.id)
        XCTAssertEqual(request.cwd, repo.path)
        XCTAssertEqual(state.threadStore.implementationThreads(for: room.plan.id).map(\.id), [resultID])
        XCTAssertEqual(window.currentSessionId, resultID)
        XCTAssertEqual(state.messages(in: window).filter { $0.role == .user }.map(\.content), [request.prompt])
        XCTAssertEqual(state.threadStore.codingPlan(for: sourceID)?.approvedVersionID, edited.id)
        state.codingPlanRooms.removeAll()
        let archive = try XCTUnwrap(state.codingPlanRoom(for: resultID))
        XCTAssertEqual(archive.plan.approvedVersionID, edited.id)
        XCTAssertEqual(archive.plan.versions.count, 5)
        XCTAssertThrowsError(try state.sendCodingPlanMessage("Change the approved plan", to: archive, cwd: repo.path))
        XCTAssertThrowsError(try state.addCodingPlanReviewer(.init(model: reviewer, prompt: "Another review"), to: archive, cwd: repo.path))
    }

    func testRepeatedImplementationKeepsEachVersionModelAndThinkingLevel() async throws {
        state.selectedEffort = "medium"
        let codex = backend(.codex), claude = backend(.claudeCode)
        var plan = CodingPlan(id: UUID(), goal: "Backup settings", source: "", configuration: .init(planner: planner, reviewers: []))
        plan.finish(.draft, text: "Keep one backup.")
        plan.finish(.reconcile, text: "Keep two backups.")
        let source = ChatSession(id: plan.id.uuidString, projectId: project.id, title: plan.goal, threadLabel: "Plan")
        state.threadStore.upsert(source.summary)
        try state.threadStore.saveCodingPlan(plan)
        state.allSessionSummaries = [source.summary]
        window.currentSessionId = source.id
        let room = try XCTUnwrap(state.codingPlanRoom(for: source.id))

        func run(_ version: CodingPlan.Version, from room: CodingPlanRoom, model: AgentModel,
                 effort: String, using backend: MockAgentBackend) async throws -> String {
            let id = UUID().uuidString
            await backend.enqueueScript([.systemInit(sessionId: id), .assistantText("Implemented."), .result(sessionId: id)], forCwd: repo.path)
            let stream = await state.implementCodingPlan(room, versionID: version.id, model: model, effort: effort, in: window)
            let completed = await state.awaitStreamCompletion(streamId: try XCTUnwrap(stream), timeout: 10, acceptsPartial: false)
            XCTAssertNotNil(completed)
            let request = await backend.receivedRequests.last
            let prompt = CodingPlan.implementationPrompt(for: version)
            // Providers with inline project instructions prefix the exact user request.
            XCTAssertTrue(request?.prompt == prompt || request?.prompt.hasSuffix("\n\nUser request:\n" + prompt) == true)
            XCTAssertEqual(request?.model, model.id)
            XCTAssertEqual(request?.history.isEmpty, true)
            XCTAssertEqual(window.currentSessionId, id)
            return id
        }

        let first = try await run(plan.versions[0], from: room, model: planner, effort: "high", using: codex)
        let firstRequest = await codex.receivedRequests.last
        XCTAssertEqual(firstRequest?.effort, "high")
        let check = ChatSession(id: "verified", projectId: project.id, title: "Verified", parentThreadId: first,
                                threadLabel: TaskCompletionCheckLabel.verified)
        state.threadStore.upsert(check.summary)
        window.currentSessionId = source.id
        let second = try await run(plan.versions[1], from: room, model: host, effort: "max", using: claude)
        let secondRequest = await claude.receivedRequests.last
        XCTAssertEqual(secondRequest?.effort, "max")
        XCTAssertEqual(state.threadStore.fetch(id: first)?.effort, "high")
        XCTAssertEqual(state.threadStore.fetch(id: second)?.effort, "max")
        XCTAssertEqual(state.threadStore.implementationThreads(for: plan.id).map(\.id), [second, first])
        XCTAssertEqual(state.codingPlanRoom(for: first)?.plan.approvedVersionID, plan.versions[0].id)
        XCTAssertEqual(state.codingPlanRoom(for: second)?.plan.approvedVersionID, plan.versions[1].id)
        let summary = try await state.codingPlanActivities(threadID: source.id).first
        XCTAssertEqual(summary?.implementationStatus, "unknown")
        XCTAssertEqual(summary?.linkedImplementationIDs, [second, first])
        let earlier = try await state.codingPlanActivities(threadID: first).first
        XCTAssertEqual(earlier?.implementationStatus, "implemented")
        XCTAssertEqual(earlier?.approvedVersionID, plan.versions[0].id)

        let implementation = try XCTUnwrap(state.codingPlanRoom(for: second))
        let third = try await run(plan.versions[0], from: implementation, model: planner, effort: "max", using: codex)
        let thirdRequest = await codex.receivedRequests.last
        XCTAssertEqual(thirdRequest?.effort, "medium")
        let afterRetry = try await state.codingPlanActivities(threadID: source.id).first
        XCTAssertEqual(afterRetry?.implementationStatus, "implemented")
        XCTAssertNil(state.threadStore.fetch(id: third)?.effort)
        let groups = HistoryListView.planGroups(in: state.threadStore.implementationThreads(for: plan.id).map {
            HistoryListView.DisplaySession(summary: $0, isBackgroundStreaming: false, projectName: nil)
        } + [.init(summary: source.summary, isBackgroundStreaming: false, projectName: nil)])
        XCTAssertEqual(groups.map(\.id), [source.id])
        XCTAssertEqual(Set(groups.first?.runs.map(\.id) ?? []), [first, second, third])
    }

    func testEarlierDebatesRecoverTheirExactMessageVersionLinks() throws {
        var plan = CodingPlan(id: UUID(), goal: "Persist preferences", source: "", configuration:
            .init(planner: planner, reviewers: [.init(model: reviewer, prompt: "Review writes")]))
        plan.finish(.draft, text: "Save settings.")
        plan.finish(.moderate, text: "Host answer")
        plan.finish(.review(0), text: "```suggestion\nSave settings.\n---\nSave atomically.\n```")
        plan.finish(.reconcile, text: "Host answer")
        plan.edit(markdown: "My version")
        let expected = plan.versions.map(\.id)
        for index in plan.contributions.indices { plan.contributions[index].versionID = nil }
        var decoded = try JSONDecoder().decode(CodingPlan.self, from: JSONEncoder().encode(plan))
        decoded.restoreVersionLinks()
        XCTAssertEqual(decoded.contributions.map(\.versionID), [expected[0], nil, expected[1], expected[2], expected[3]])
    }

    func testReloadKeepsQuotedPlanTextInItsOwnChatBubble() {
        var plan = CodingPlan(id: UUID(), goal: "Edit", source: "", configuration: .init(planner: planner, reviewers: []))
        plan.finish(.draft, text: "Draft")
        plan.finish(.reconcile, text: "Final")
        plan.contributions.append(.init(role: "You", model: nil, text: "Edited the implementation plan."))
        plan.finish(.reply, text: "Save two copies.")
        plan.edit(markdown: "Manual edit")
        plan.contributions.append(.init(role: "You", model: nil, text: "How should we store it?"))
        plan.finish(.reply, text: "Save two copies.")
        plan.finish(.revise("Add backups"), text: "Save two copies.")
        let links = plan.contributions.map(\.versionID)
        plan.restoreVersionLinks()
        XCTAssertEqual(plan.contributions.map(\.versionID), links)
    }

    func testSuggestionsRequireCompletedUniqueNonoverlappingQuotes() {
        let review = CodingPlanReview("""
        Findings
        ```suggestion
        one
        ---
        ONE
        ```
        ```suggestion
        repeat
        ---
        duplicate
        ```
        ```suggestion
        on
        ---
        overlapping
        ```
        ```suggestion
        two
        ---
        unfinished
        """)
        let result = review.applying(to: "one two repeat repeat")
        XCTAssertEqual(result.markdown, "ONE two repeat repeat")
        XCTAssertEqual(result.edits.count, 1)
        XCTAssertEqual(review.commentary, "Findings")
    }

    func testReviewExplanationsRenderAsSeparateMarkdownQuotesAfterReload() throws {
        let review = """
        <!-- Keep the **published revision**. -->
        ```suggestion
        Remove expired versions.
        ---
        Keep published versions.
        ```
        <!--
        Test the `101st` save.
        Check the recipient URL.
        -->
        ```suggestion
        Check the link.
        ---
        Check the link after pruning.
        ```
        > Verify the résumé metadata.
        """
        var plan = CodingPlan(id: UUID(), goal: "Review history", source: "", configuration:
            .init(planner: planner, reviewers: [.init(model: reviewer, prompt: "Check retention")]))
        plan.finish(.draft, text: "Remove expired versions. Check the link.")
        plan.finish(.review(0), text: review)
        let saved = try JSONDecoder().decode(CodingPlan.self, from: JSONEncoder().encode(plan))
        let message = try XCTUnwrap(saved.contributions.last)
        let version = try XCTUnwrap(saved.versions.last)
        let first = "> Keep the **published revision**."
        let second = "> Test the `101st` save.\n> Check the recipient URL."
        let expected = [first, second, "> Verify the résumé metadata."].joined(separator: "\n\n")
        let commentary = CodingPlanReview(message.text).commentary
        XCTAssertEqual(CodingPlanReview.feedbackMarkdown(commentary, streaming: true), expected)
        XCTAssertEqual(CodingPlanReview.feedbackMarkdown(commentary), expected)
        XCTAssertEqual(version.edits.compactMap(\.comment).map { CodingPlanReview.feedbackMarkdown($0) }, [first, second])
        XCTAssertEqual(version.markdown, "Keep published versions. Check the link after pruning.")
    }

    func testStreamingReviewDelimitersAndLiteralCode() {
        for prefix in ["<", "<!", "<!-", "<!--", "<!-- "] {
            XCTAssertEqual(CodingPlanReview.feedbackMarkdown(prefix, streaming: true), "")
        }
        for suffix in ["", " ", " -", " --", " -->"] {
            XCTAssertEqual(CodingPlanReview.feedbackMarkdown("<!-- Keep **history**" + suffix, streaming: true),
                           "> Keep **history**")
        }
        let code = "Use `<!-- inline -->` here.\n\n```html\n<!-- literal -->\n```"
        let review = code + "\n\n<!-- First --> <!-- Second -->"
        XCTAssertEqual(CodingPlanReview.feedbackMarkdown(review), code + "\n\n> First\n\n> Second")

        let suggested = CodingPlanReview("> First\n```suggestion\n<!-- old -->\n---\n<!-- new -->\n```\n> Second")
        XCTAssertEqual(suggested.commentary, "> First\n\n> Second")
        XCTAssertEqual(suggested.applying(to: "<!-- old -->").markdown, "<!-- new -->")
    }

    func testInlineReviewCommentsSurviveReloadAndStayWithTheirPassage() throws {
        let id = UUID()
        let session = ChatSession(id: id.uuidString, projectId: project.id, title: "Review", messages: [])
        state.threadStore.upsert(session.summary)
        var plan = CodingPlan(id: id, goal: "Review", source: "", configuration:
            .init(planner: planner, reviewers: [.init(model: reviewer, prompt: "Review")]))
        plan.finish(.draft, text: "👩‍💻 Keep one and two. Remove this.")
        plan.finish(.review(0), text: """
        This is redundant.
        ```suggestion
         Remove this.
        ---
        ```
        Use the same term here.
        ```suggestion
        two
        ---
        one
        ```
        """)
        let room = CodingPlanRoom(plan)
        let proposal = try XCTUnwrap(plan.versions.last)
        XCTAssertEqual(proposal.markdown, "👩‍💻 Keep one and one.")
        XCTAssertEqual(proposal.edits.map(\.comment), ["Use the same term here.", "This is redundant."])
        let source = proposal.markdown as NSString
        XCTAssertEqual(proposal.edits[0].range, source.range(of: "one", options: .backwards))
        XCTAssertEqual(proposal.edits[1].range, NSRange(location: source.length, length: 0))
        try state.addCodingPlanComment(" Keep this wording. ", to: 0, in: proposal.id, room: room)
        let stored = try XCTUnwrap(state.threadStore.codingPlan(for: id.uuidString)?.versions.last)
        XCTAssertEqual(stored.edits[0].userComments, ["Keep this wording."])
        XCTAssertNil(stored.edits[1].userComments)
        XCTAssertEqual(stored.markdown, proposal.markdown)
        XCTAssertThrowsError(try state.addCodingPlanComment(" ", to: 0, in: proposal.id, room: room))
        XCTAssertThrowsError(try state.addCodingPlanComment("Stale", to: 3, in: proposal.id, room: room))

        // Strip the new optional fields to exercise existing debates on disk.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var versions = try XCTUnwrap(json["versions"] as? [[String: Any]])
        versions[1]["edits"] = proposal.edits.map { ["original": $0.original, "replacement": $0.replacement] }
        json["versions"] = versions
        var legacy = try JSONDecoder().decode(CodingPlan.self, from: JSONSerialization.data(withJSONObject: json))
        legacy.restoreVersionLinks()
        XCTAssertEqual(legacy.versions.last?.edits, proposal.edits)
        versions[1].removeValue(forKey: "edits")
        json["versions"] = versions
        var untracked = try JSONDecoder().decode(CodingPlan.self, from: JSONSerialization.data(withJSONObject: json))
        untracked.restoreVersionLinks()
        XCTAssertEqual(untracked.versions.last?.edits, proposal.edits)
    }

    func testManualAndHostRevisionsRoundTripExactMarkdownWithComments() throws {
        var plan = CodingPlan(id: UUID(), goal: "Edit", source: "", configuration: .init(planner: planner, reviewers: []))
        let original = "# Plan\n\nKeep 📝 then remove this paragraph.\n\n- Finish now."
        let revised = "# Plan\n\nKeep 📝 then **save twice**.\n\n- Finish later.\n"
        plan.finish(.draft, text: original)
        plan.edit(markdown: revised, comment: "Exercise recovery.")
        plan.finish(.revise("Check the reload."), text: revised + "\nReload.")
        for (index, note) in [(1, "Exercise recovery."), (2, "Check the reload.")] {
            let version = plan.versions[index]
            let restored = NSMutableString(string: version.markdown)
            XCTAssertFalse(version.edits.isEmpty)
            for edit in version.edits.reversed() {
                let range = try XCTUnwrap(edit.range)
                XCTAssertEqual(restored.substring(with: range), edit.replacement)
                XCTAssertEqual(edit.userComments, [note])
                restored.replaceCharacters(in: range, with: edit.original)
            }
            XCTAssertEqual(restored as String, plan.versions[index - 1].markdown)
        }
        XCTAssertEqual(CodingPlan.implementationPrompt(for: plan.versions[1]), "Implement this approved plan and verify the result.\n\n" + revised)
    }
}
