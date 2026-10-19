import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class IDETaskMutationTests: XCTestCase {
    private var persistence: MockAppStatePersistence!
    private var appState: AppState!
    private var project: Project!

    override func setUp() async throws {
        persistence = MockAppStatePersistence()
        appState = AppState(persistence: persistence, startBackgroundServices: false)
        project = Project(name: "P", path: "/tmp/p", gitHubRepo: nil)
        appState.projects = [project]
    }

    override func tearDown() async throws {
        appState = nil
        persistence = nil
        project = nil
    }

    func testMCPUpdateTaskPreservesOmittedFieldsAndClearsAssignments() async throws {
        var task = makeTask(status: .backlog, sessionKey: nil)
        task.details = "Original description"
        task.version = "v1"
        task.priority = .high
        seed([task])
        _ = try await appState.ideHandleToolCall(
            name: "ide__update_task",
            arguments: .object([
                "task_id": .string(task.id.uuidString),
                "title": .string("Updated title"),
                "version": .null,
                "priority": .null,
                "tags": .array([.string("mcp")]),
                "status": .string(TaskStatus.done.rawValue),
            ]), sessionKey: "chat-1"
        )
        let updated = try XCTUnwrap(appState.task(id: task.id))
        XCTAssertEqual(updated.title, "Updated title")
        XCTAssertEqual(updated.details, task.details)
        XCTAssertEqual(updated.agent, task.agent)
        XCTAssertEqual(updated.status, .done)
        XCTAssertEqual(updated.tags, ["mcp"])
        XCTAssertNil(updated.version)
        XCTAssertNil(updated.priority)
    }

    func testMCPUpdateRejectsInvalidPatchWithoutPartialSave() async throws {
        let task = makeTask(status: .backlog, sessionKey: nil)
        seed([task])
        for patch: [String: JSONValue] in [
            ["title": .string("Changed"), "status": .string("missing-column")],
            ["title": .string("Changed"), "priority": .string("invalid")],
            ["starts_after_task_ids": .array([.string(task.id.uuidString)])],
            ["tags": .null],
            [:],
        ] {
            var arguments = patch
            arguments["task_id"] = .string(task.id.uuidString)
            do {
                _ = try await appState.ideHandleToolCall(
                    name: "ide__update_task", arguments: .object(arguments), sessionKey: "chat-1"
                )
                XCTFail("Invalid patch must fail")
            } catch { }
            XCTAssertEqual(appState.task(id: task.id), task)
        }
    }

    func testMCPUpdateRejectsLockedDescriptionAndStatus() async throws {
        let task = makeTask()
        seed([task])
        for field in ["details", "status"] {
            do {
                _ = try await appState.ideHandleToolCall(
                    name: "ide__update_task",
                    arguments: .object([
                        "task_id": .string(task.id.uuidString),
                        field: .string(field == "details" ? "Changed" : TaskStatus.done.rawValue),
                    ]), sessionKey: "chat-1"
                )
                XCTFail("Locked field must fail")
            } catch { }
        }
        XCTAssertEqual(appState.task(id: task.id), task)
    }

    func testMCPDeleteClearsCrossProjectDependenciesAndKeepsThread() async throws {
        let task = makeTask(status: .done)
        let other = Project(name: "Other", path: "/tmp/other", gitHubRepo: nil)
        appState.projects.append(other)
        let child = ProjectTask(projectId: other.id, parentTaskIds: [task.id], title: "Child")
        seed([task])
        appState.taskBoards[other.id] = TaskBoard(tasks: [child])
        _ = try await appState.ideHandleToolCall(
            name: "ide__delete_task",
            arguments: .object(["task_id": .string(task.id.uuidString)]), sessionKey: "chat-1"
        )
        XCTAssertNil(appState.task(id: task.id))
        XCTAssertEqual(appState.task(id: child.id)?.parentTaskIds, [])
        let deletedSessions = await persistence.deletedSessionRecords()
        XCTAssertTrue(deletedSessions.isEmpty)
    }

    func testMCPDeleteRejectsRunningTaskAndUnknownId() async throws {
        let task = makeTask()
        seed([task])
        appState.sessionActivity["sess-1"] = SessionActivity(isStreaming: true)
        for id in [task.id.uuidString, UUID().uuidString, "invalid"] {
            do {
                _ = try await appState.ideHandleToolCall(
                    name: "ide__delete_task",
                    arguments: .object(["task_id": .string(id)]), sessionKey: "chat-1"
                )
                XCTFail("Running or missing task must fail")
            } catch { }
        }
        XCTAssertNotNil(appState.task(id: task.id))
    }

    func testMCPUpdateDependenciesRejectsCycles() async throws {
        let task = makeTask(status: .backlog, sessionKey: nil)
        let child = ProjectTask(projectId: project.id, parentTaskIds: [task.id], title: "Child")
        seed([task, child])
        do {
            _ = try await appState.ideHandleToolCall(
                name: "ide__update_task",
                arguments: .object([
                    "task_id": .string(task.id.uuidString),
                    "starts_after_task_ids": .array([.string(child.id.uuidString)]),
                ]), sessionKey: "chat-1"
            )
            XCTFail("Dependency cycle must fail")
        } catch { }
        XCTAssertEqual(appState.task(id: task.id)?.parentTaskIds, [])
    }

    func testUpdateAgentAssignmentResetsIncompatibleModelAndEffort() async throws {
        var task = makeTask(status: .backlog, sessionKey: nil)
        task.agent.effort = "high"
        seed([task])
        appState.codexModels = [AgentModel(provider: .codex, id: "test-codex", displayName: "Test Codex")]
        _ = try await update(task, fields: ["provider": .string("codex")])
        var updated = try XCTUnwrap(appState.task(id: task.id))
        XCTAssertEqual(updated.agent.provider, .codex)
        XCTAssertNil(updated.agent.model)
        XCTAssertNil(updated.agent.effort)
        _ = try await update(task, fields: ["model": .string("test-codex")])
        updated = try XCTUnwrap(appState.task(id: task.id))
        XCTAssertEqual(updated.agent.model, "test-codex")
        XCTAssertEqual(updated.details, task.details)
        _ = try await update(task, fields: ["provider": .null])
        updated = try XCTUnwrap(appState.task(id: task.id))
        XCTAssertNil(updated.agent.provider)
        XCTAssertNil(updated.agent.model)
    }

    func testUpdateAgentAssignmentValidatesBeforeSaving() async throws {
        let task = makeTask(status: .backlog, sessionKey: nil)
        seed([task])
        for fields: [String: JSONValue] in [
            ["provider": .string("missing")],
            ["model": .string("")],
            ["provider": .string("codex"), "model": .string("opus")],
            ["provider": .null, "model": .string("opus")],
            ["model": .bool(true)],
        ] {
            do {
                _ = try await update(task, fields: fields.merging(["title": .string("Changed")]) { $1 })
                XCTFail("Invalid assignment must fail")
            } catch { }
            XCTAssertEqual(appState.task(id: task.id), task)
        }
    }

    func testUpdateAgentAssignmentRejectsRunningTask() async throws {
        let task = makeTask()
        seed([task])
        appState.sessionActivity["sess-1"] = SessionActivity(isStreaming: true)
        do {
            _ = try await update(task, fields: ["provider": .string("codex")])
            XCTFail("Running assignment must stay unchanged")
        } catch { }
        XCTAssertEqual(appState.task(id: task.id), task)
    }

    func testListModelsIncludesAllProvidersAndEnabledACPClients() async throws {
        appState.codexModels = [AgentModel(provider: .codex, id: "test-codex", displayName: "Test Codex")]
        appState.acpClients = [
            acpClient("test-acp", models: ["model-a"]),
            acpClient("default-acp"),
            acpClient("disabled-acp", enabled: false, models: ["hidden"]),
        ]
        let catalog = try await modelCatalog()
        let providers = try XCTUnwrap(jsonArray(catalog["providers"]))
        XCTAssertEqual(providers.compactMap { jsonString($0["provider"]) }, ["claudeCode", "codex", "acp"])
        let groups = providers.flatMap { jsonArray($0["groups"]) ?? [] }
        let modelIds = groups.flatMap { jsonArray($0["models"]) ?? [] }.compactMap { jsonString($0["id"]) }
        XCTAssertTrue(modelIds.contains("opus"))
        XCTAssertTrue(modelIds.contains("test-codex"))
        XCTAssertTrue(modelIds.contains("test-acp::model-a"))
        XCTAssertTrue(modelIds.contains("default-acp::"))
        XCTAssertFalse(modelIds.contains("disabled-acp::hidden"))
        let codex = try XCTUnwrap(groups.first { jsonString($0["id"]) == "codex" })
        XCTAssertEqual(jsonString(codex["model_source"]), "discovered")
        let task = makeTask(status: .backlog, sessionKey: nil)
        seed([task])
        _ = try await update(task, fields: ["provider": .string("acp"), "model": .string("test-acp::model-a")])
        XCTAssertEqual(appState.task(id: task.id)?.agent.model, "test-acp::model-a")
        _ = try await update(task, fields: ["model": .string("default-acp::")])
        XCTAssertEqual(appState.task(id: task.id)?.agent.model, "default-acp::")
        _ = try await update(task, fields: ["model": .null])
        XCTAssertNil(appState.task(id: task.id)?.agent.model)
    }

    func testListModelsMarksCodexFallbackAndIncludesACPWithoutClients() async throws {
        appState.codexModels = []
        appState.acpClients = []
        let catalog = try await modelCatalog()
        let providers = try XCTUnwrap(jsonArray(catalog["providers"]))
        let codex = try XCTUnwrap(providers.first { jsonString($0["provider"]) == "codex" })
        let group = try XCTUnwrap(jsonArray(codex["groups"])?.first)
        XCTAssertEqual(jsonString(group["model_source"]), "fallback")
        XCTAssertEqual(jsonArray(group["models"])?.compactMap { jsonString($0["id"]) }, AppState.fallbackCodexModels)
        let acp = try XCTUnwrap(providers.first { jsonString($0["provider"]) == "acp" })
        XCTAssertEqual(jsonArray(acp["groups"]), [])
    }

    private func update(_ task: ProjectTask, fields: [String: JSONValue]) async throws -> JSONValue {
        var arguments = fields
        arguments["task_id"] = .string(task.id.uuidString)
        return try await appState.ideHandleToolCall(
            name: "ide__update_task", arguments: .object(arguments), sessionKey: "chat-1"
        )
    }

    private func jsonString(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private func jsonArray(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let items)? = value else { return nil }
        return items
    }

    private func modelCatalog() async throws -> JSONValue {
        let result = try await appState.ideHandleToolCall(
            name: "ide__list_agent_models", arguments: .object([:]), sessionKey: "chat-1"
        )
        let text = try XCTUnwrap(jsonString(jsonArray(result["content"])?.first?["text"]))
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func acpClient(_ id: String, enabled: Bool = true, models: [String] = []) -> ACPClientSpec {
        ACPClientSpec(id: id, displayName: id, enabled: enabled,
                      launch: .custom(command: "test-only", args: [], env: [:]), models: models)
    }

    private func seed(_ tasks: [ProjectTask]) {
        appState.taskBoards[project.id] = TaskBoard(tasks: tasks)
    }

    private func makeTask(
        status: TaskStatus = .inProgress,
        sessionKey: String? = "sess-1"
    ) -> ProjectTask {
        ProjectTask(
            projectId: project.id,
            title: "Wire the board",
            status: status,
            agent: TaskAgentConfig(provider: .claudeCode, model: "opus"),
            sessionKey: sessionKey,
            sortIndex: 1
        )
    }

}
