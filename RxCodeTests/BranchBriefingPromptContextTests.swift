import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class BranchBriefingPromptContextTests: XCTestCase {
    func testProjectBriefingPromptUsesThreeCalendarDaysAcrossProjectBranches() throws {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let projectId = UUID()
        for (offset, branch, briefing) in [
            (0, "main", "### Features\n- Added natural-language thread search.\n\n### Improvements\n- Updated indexing."),
            (-1, "feature/search", "Yesterday's work"),
            (-2, "main", "Earlier work"),
            (-3, "main", "Old work"),
            (1, "main", "Future work"),
            (0, "blank", " \n\t "),
        ] {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
            state.threadStore.upsertBranchBriefing(projectId: projectId, branch: branch, day: day, briefing: briefing)
        }
        state.threadStore.upsertBranchBriefing(projectId: UUID(), branch: "main", day: today, briefing: "Another project")
        state.threadStore.context.insert(BranchBriefingRecord(projectId: projectId, branch: "main", briefing: "Undated work"))
        state.threadStore.save()

        let prompt = state.projectBriefingSystemPrompt(projectId: projectId, canFetchDetails: true, now: today, calendar: calendar)

        XCTAssertTrue(prompt.contains("# Recent project briefings"))
        XCTAssertTrue(prompt.contains("main: Added natural-language thread search. Updated indexing."))
        XCTAssertTrue(prompt.contains("feature/search: Yesterday's work"))
        XCTAssertTrue(prompt.contains("main: Earlier work"))
        XCTAssertTrue(prompt.contains("ide__project_briefing_get"))
        for excluded in ["Old work", "Future work", "Another project", "Undated work", "blank:"] {
            XCTAssertFalse(prompt.contains(excluded))
        }
    }

    func testProjectBriefingPromptBoundsBusyDaysAndLongEntries() throws {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let projectId = UUID()
        let today = Calendar.current.startOfDay(for: .now)
        for offset in 0...2 {
            let date = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -offset, to: today))
            for branch in ["main", "feature", "other"] {
                state.threadStore.upsertBranchBriefing(
                    projectId: projectId, branch: branch, day: date, briefing: String(repeating: "x", count: 20_000)
                )
            }
        }
        let prompt = state.projectBriefingSystemPrompt(projectId: projectId, canFetchDetails: true, now: today)
        XCTAssertEqual(prompt.split(separator: "\n").filter { $0.hasPrefix("- ") }.count, 6)
        XCTAssertLessThan(prompt.count, 1_300)
        XCTAssertTrue(prompt.contains("…"))
        XCTAssertFalse(state.projectBriefingSystemPrompt(projectId: projectId, canFetchDetails: false, now: today)
            .contains("ide__project_briefings"))
    }

    func testSkillCatalogSendsOnlyNamesAndToolReturnsFullInstructions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skill-prompt-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instructions = "---\nname: example\ndescription: Use for release tasks.\n---\n" + String(repeating: "Full instructions.\n", count: 1_000)
        let config = MarketplacePluginConfiguration(plugins: [
            MarketplacePluginRecord(name: "example", marketplace: "test", summary: "Use for release tasks.",
                                    marketplaceSource: nil, instructions: instructions, enabledProviders: [.codex]),
            MarketplacePluginRecord(name: "example", marketplace: "other", marketplaceSource: nil, instructions: "Other instructions."),
            MarketplacePluginRecord(name: "disabled", marketplace: "test", marketplaceSource: nil, isGloballyEnabled: false),
        ])
        try JSONEncoder().encode(config).write(to: directory.appending(path: "skills.json"))
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let service = MarketplaceService(baseURL: directory)
        state.marketplace = service
        var session = SessionStreamState()
        session.agentProvider = .codex
        state.sessionStates["current"] = session
        state.sessionIdRedirect["pending"] = "current"

        let prompt = await service.promptContext(for: .codex)
        XCTAssertEqual(prompt.split(separator: "\n").last, "other/example, rxcode-pet-look, test/example")
        let claudePrompt = await service.promptContext(for: .claudeCode)
        XCTAssertEqual(claudePrompt.split(separator: "\n").last, "example, rxcode-pet-look")

        let response = try await state.ideHandleToolCall(
            name: "ide__skill_get", arguments: .object(["name": .string("test/example")]), sessionKey: "pending"
        )
        XCTAssertEqual(try toolText(response), instructions)
    }

    func testProjectBriefingToolsListAndReadOlderBriefing() async throws {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let project = Project(id: UUID(), name: "Project", path: "/tmp/TestProject")
        state.projects = [project]
        let day = Date.distantPast
        state.threadStore.upsertBranchBriefing(projectId: project.id, branch: "main", day: day, briefing: "Full older briefing.")
        state.threadStore.upsertBranchBriefing(projectId: project.id, branch: "main", briefing: "Newer briefing.")
        state.threadStore.upsertBranchBriefing(projectId: project.id, branch: "other", briefing: "Other branch.")
        state.threadStore.upsert(ChatSession(id: "briefing-test", projectId: project.id, title: "Test", messages: []).summary)

        let listed = try await state.ideHandleToolCall(
            name: "ide__project_briefings",
            arguments: .object(["branch": .string("main"), "offset": .number(1), "limit": .number(1)]),
            sessionKey: "briefing-test"
        )
        let listText = try toolText(listed)
        let entries = try JSONDecoder().decode([JSONValue].self, from: Data(listText.utf8))
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["day"], .string(BranchBriefingRecord.dayKey(day)))
        XCTAssertNil(entry["content"])
        guard case .string(let id) = entry["id"] else {
            XCTFail("Missing briefing ID")
            return
        }

        let read = try await state.ideHandleToolCall(
            name: "ide__project_briefing_get", arguments: .object(["id": .string(id)]), sessionKey: "briefing-test"
        )
        let readText = try toolText(read)
        let briefing = try JSONDecoder().decode(JSONValue.self, from: Data(readText.utf8))
        XCTAssertEqual(briefing["content"], .string("Full older briefing."))
    }

    private func toolText(_ result: JSONValue) throws -> String {
        let content = try XCTUnwrap(result["content"])
        let firstBlock = try XCTUnwrap(content[0])
        guard case .string(let text) = firstBlock["text"] else {
            XCTFail("Missing tool response text")
            return ""
        }
        return text
    }

    func testPromptWithBackgroundContextPrefixesCodexAndACPContext() {
        let briefingContext = "# Recent project briefings\n- Recent work updated MCP tool rendering."
        let memoryContext = "# Relevant user memory\n\nAlways write unit tests."

        let prompt = AppState.promptWithBackgroundContext(
            [briefingContext, memoryContext],
            prompt: "Implement it for all clients."
        )

        XCTAssertTrue(prompt.contains("# Recent project briefings"))
        XCTAssertTrue(prompt.contains("- Recent work updated MCP tool rendering."))
        XCTAssertTrue(prompt.contains("# Relevant user memory"))
        XCTAssertTrue(prompt.hasSuffix("User request:\nImplement it for all clients."))
    }

    func testPromptWithBackgroundContextLeavesPromptUntouchedWhenContextIsEmpty() {
        XCTAssertEqual(
            AppState.promptWithBackgroundContext(["", " \n\t "], prompt: "Only the request."),
            "Only the request."
        )
    }

    func testConfiguredPromptsKeepGlobalBeforeProjectAndIgnoreBlankValues() {
        XCTAssertEqual(
            AppState.configuredPromptContext(global: "  Use English.  ", project: "  Follow project conventions.\n"),
            "# Global instructions\n\nUse English.\n\n# Project instructions\n\nFollow project conventions."
        )
        XCTAssertEqual(AppState.configuredPromptContext(global: "  ", project: nil), "")
    }
}
