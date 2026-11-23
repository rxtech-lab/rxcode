import XCTest
import RxCodeCore
@testable import RxCode

extension CodingPlanTests {
    private func callPlanTool(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        let result = try await state.ideHandleToolCall(name: name, arguments: .object(args), sessionKey: "plan-reader-test")
        let body = try XCTUnwrap(result["content"]?[0]?["text"]?.stringValue)
        return try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
    }

    func testPlanToolsDiscoverPersistedHistoryAndRetrieveUnabridgedContent() async throws {
        var plan = CodingPlan(id: UUID(), goal: "Extension kit", source: "", configuration: .init(planner: planner, reviewers: []))
        let source = ChatSession(id: plan.id.uuidString, projectId: project.id, title: "Extension kit",
                                 messages: [.init(role: .user, content: plan.goal)])
        state.threadStore.upsert(source.summary)
        await persistence.stubFullSession(source)
        let draft = "# Draft\n\n" + String(repeating: "- Feature A\n", count: 300)
        plan.finish(.draft, text: draft)
        plan.finish(.reconcile, text: "# Final\n\n- Feature B")
        try state.threadStore.saveCodingPlan(plan)
        XCTAssertNil(state.codingPlanRooms[plan.id])

        let discovered = try await callPlanTool("ide__list_coding_plans", ["project_id": .string(project.id.uuidString)])
        let summary = try XCTUnwrap(discovered["plans"]?[0])
        XCTAssertEqual(summary["plan_id"]?.stringValue, plan.id.uuidString)
        XCTAssertEqual(summary["planning_status"]?.stringValue, "ready")
        XCTAssertEqual(summary["implementation_status"]?.stringValue, "unimplemented")
        XCTAssertEqual(summary["version_count"]?.numberValue, 2)
        XCTAssertEqual(summary["current_version_id"]?.stringValue, plan.versions[1].id.uuidString)
        XCTAssertNil(state.codingPlanRooms[plan.id], "Discovery must not open the debate room.")

        let page = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(plan.id.uuidString), "limit": .number(1)])
        XCTAssertEqual(page["versions"]?[0]?["title"]?.stringValue, "Host plan")
        XCTAssertEqual(page["versions"]?[0]?["is_current"]?.boolValue, true)
        XCTAssertEqual(page["next_offset"]?.numberValue, 1)
        let second = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(plan.id.uuidString), "offset": .number(1)])
        XCTAssertEqual(second["versions"]?[0]?["version_id"]?.stringValue, plan.versions[0].id.uuidString)
        let result = try await callPlanTool("ide__get_coding_plan_version", [
            "plan_id": .string(plan.id.uuidString), "version_id": .string(plan.versions[0].id.uuidString)])
        XCTAssertEqual(result["version"]?["markdown"]?.stringValue, draft)

        let room = try XCTUnwrap(state.codingPlanRoom(for: source.id))
        room.plan.lastError = "Review was interrupted"
        let hydrated = try await callPlanTool("ide__list_coding_plans", ["thread_id": .string(source.id)])
        XCTAssertEqual(hydrated["plans"]?[0]?["planning_status"]?.stringValue, "interrupted")
        let wrongProject = try await callPlanTool("ide__list_coding_plans", ["project_id": .string(UUID().uuidString), "thread_id": .string(source.id)])
        XCTAssertEqual(wrongProject["total"]?.numberValue, 0)
    }

    func testPlanToolsDeduplicateHandoffAndRequireImplementationEvidence() async throws {
        var plan = CodingPlan(id: UUID(), goal: "Save snapshots", source: "", configuration: .init(planner: planner, reviewers: []))
        let source = ChatSession(id: plan.id.uuidString, projectId: project.id, title: plan.goal, messages: [])
        state.threadStore.upsert(source.summary)
        plan.finish(.draft, text: "Initial design")
        plan.finish(.reconcile, text: "Final design")
        plan.approvedVersionID = plan.versions[0].id
        let childID = UUID().uuidString.lowercased()
        let child = ChatSession(id: childID, projectId: project.id, title: "Implement snapshots", messages: [])
        try state.threadStore.saveCodingPlan(plan, implementation: child.summary)

        let plans = try await state.codingPlanActivities(projectID: project.id)
        let summary = try XCTUnwrap(plans.first)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(summary.threadID, source.id)
        XCTAssertEqual(summary.implementationThreadID, childID)
        XCTAssertEqual(summary.currentVersionID, plan.versions.last?.id)
        XCTAssertEqual(summary.approvedVersionID, plan.versions.first?.id)
        XCTAssertEqual(summary.featureExcerpt, "Initial design")
        XCTAssertEqual(summary.planningStatus, "approved")
        XCTAssertEqual(summary.implementationStatus, "unknown")
        let alias = try await callPlanTool("ide__list_coding_plans", ["thread_id": .string(childID)])
        XCTAssertEqual(alias["plans"]?[0]?["plan_id"]?.stringValue, plan.id.uuidString)

        var task = ProjectTask(projectId: project.id, title: "Implement snapshots", status: .inProgress, sessionKey: childID)
        state.taskBoards[project.id] = TaskBoard(tasks: [task])
        let inProgress = try await state.codingPlanActivities(threadID: source.id)
        XCTAssertEqual(inProgress.first?.implementationStatus, "in_progress")
        task.status = .done
        state.taskBoards[project.id] = TaskBoard(tasks: [task])
        let implemented = try await state.codingPlanActivities(threadID: source.id)
        XCTAssertEqual(implemented.first?.implementationStatus, "implemented")

        state.taskBoards[project.id] = TaskBoard()
        var check = ChatSession(id: UUID().uuidString, projectId: project.id, title: "Check", messages: []).summary
        check.parentThreadId = childID
        check.threadLabel = TaskCompletionCheckLabel.unverified
        state.threadStore.upsert(check)
        let unverified = try await state.codingPlanActivities(threadID: source.id)
        XCTAssertEqual(unverified.first?.implementationStatus, "unknown")
        check.threadLabel = TaskCompletionCheckLabel.verified
        state.threadStore.upsert(check)
        let verified = try await state.codingPlanActivities(threadID: source.id)
        XCTAssertEqual(verified.first?.implementationStatus, "implemented")

        state.threadStore.delete(id: source.id)
        let recovered = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(plan.id.uuidString)])
        XCTAssertEqual(recovered["total"]?.numberValue, 2)
        XCTAssertEqual(recovered["plan"]?["thread_id"]?.stringValue, childID)
    }

    func testPlanToolsAdvertiseReadOnlyAccessAcrossProviders() throws {
        let names = ["ide__list_coding_plans", "ide__list_coding_plan_versions", "ide__get_coding_plan_version"]
        for provider in [AgentProvider.codex, .claudeCode, .acp, .localAgent] {
            let tools = IDEToolRegistry.tools(for: provider.staticCapabilities, provider: provider)
            for name in names {
                let tool = try XCTUnwrap(tools.first { $0.name == name })
                let hints = try XCTUnwrap(IDEMCPServer.toolDescriptor(tool)["annotations"] as? [String: Bool])
                XCTAssertEqual(hints["readOnlyHint"], true)
                XCTAssertEqual(hints["destructiveHint"], false)
            }
        }
    }

    func testPlanFeatureExcerptUsesScopeAndSkipsCodeExamples() {
        let markdown = """
        # Plugin support
        The host has finished its discussion.
        ## Objective and scope
        Load signed extensions and their contributed views.
        ```swift
        implementationDetail()
        ```
        - Register custom themes.
        ## Verification
        Build the project.
        """
        XCTAssertEqual(AppState.codingPlanExcerpt(markdown, goal: "Plugins"),
                       "Load signed extensions and their contributed views.\n- Register custom themes.")
        XCTAssertEqual(AppState.codingPlanExcerpt(nil, goal: "Plugins"), "Plugins")
    }

    func testPlanToolEmptyResultsAndInvalidSelection() async throws {
        let empty = try await callPlanTool("ide__list_coding_plans", [:])
        XCTAssertEqual(empty["plans"]?.arrayValue, [])
        let plan = CodingPlan(id: UUID(), goal: "Empty debate", source: "", configuration: .init(planner: planner, reviewers: []))
        state.threadStore.upsert(ChatSession(id: plan.id.uuidString, projectId: project.id, title: plan.goal, messages: []).summary)
        try state.threadStore.saveCodingPlan(plan)
        let versions = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(plan.id.uuidString)])
        XCTAssertEqual(versions["versions"]?.arrayValue, [])
        let corruptID = UUID().uuidString
        state.threadStore.upsert(ChatSession(id: corruptID, projectId: project.id, title: "Damaged", messages: []).summary)
        let corrupt = try XCTUnwrap(state.threadStore.fetch(id: corruptID))
        corrupt.codingPlanData = Data([0])
        try state.threadStore.context.save()
        let recovered = try await callPlanTool("ide__list_coding_plans", [:])
        XCTAssertEqual(recovered["total"]?.numberValue, 1)
        do {
            _ = try await callPlanTool("ide__list_coding_plan_versions", ["plan_id": .string(corruptID)])
            XCTFail("Targeted reads must report corrupt history.")
        } catch IDEToolError.handlerFailed { }

        let invalid: [(String, [String: JSONValue])] = [
            ("ide__list_coding_plan_versions", ["plan_id": .string(UUID().uuidString)]),
            ("ide__get_coding_plan_version", ["plan_id": .string(plan.id.uuidString), "version_id": .string(UUID().uuidString)]),
            ("ide__list_coding_plans", ["project_id": .string("typo")]),
            ("ide__list_coding_plans", ["limit": .number(51)]),
        ]
        for (name, arguments) in invalid {
            do {
                _ = try await callPlanTool(name, arguments)
                XCTFail("Expected invalid arguments for \(name)")
            } catch IDEToolError.invalidArguments { }
        }
    }
}
