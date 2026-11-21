import XCTest
import RxCodeCore
@testable import RxCode

extension TaskBoardHookTests {
    func testChatAgentCanCreateStoryAndTaskInIt() async throws {
        let projectArg = JSONValue.string(project.id.uuidString)
        _ = try await appState.ideHandleToolCall(
            name: "ide__create_story",
            arguments: .object(["project_id": projectArg, "title": .string("Dashboard work")]),
            sessionKey: "chat-1"
        )
        let story = try XCTUnwrap(appState.stories(projectFilter: project.id).first)

        _ = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": projectArg,
                "story_id": .string(story.id.uuidString),
                "title": .string("Add task tool"),
                "details": .string("Agents can create tasks from chat.")
            ]),
            sessionKey: "chat-1"
        )

        let task = try XCTUnwrap(appState.allTasks(projectFilter: project.id).first)
        XCTAssertEqual(task.storyId, story.id)
        XCTAssertEqual(task.sourceSessionKey, "chat-1")
        XCTAssertEqual(task.status, .backlog)

        do {
            _ = try await appState.ideHandleToolCall(
                name: "ide__create_task",
                arguments: .object([
                    "project_id": projectArg,
                    "story_id": .string(UUID().uuidString),
                    "title": .string("Wrong story")
                ]),
                sessionKey: "chat-1"
            )
            XCTFail("A task cannot link to a story from another project or an unknown story")
        } catch {
            XCTAssertEqual(appState.allTasks(projectFilter: project.id).count, 1)
        }
    }

    /// A task created from a chat that is still running joins that run in
    /// In Progress instead of starting the chat again, and leaves with it.
    func testTaskFromRunningChatAdoptsTheRunWithoutDispatching() {
        var task = makeTask(status: .backlog, sessionKey: nil)
        task.sourceSessionKey = "chat-1"
        seed([task])
        appState.sessionActivity["chat-1"] = SessionActivity(isStreaming: true)

        appState.adoptRunningChat("chat-1", forTask: task.id)

        let adopted = appState.task(id: task.id)
        XCTAssertEqual(adopted?.status, .inProgress)
        XCTAssertEqual(adopted?.sessionKey, "chat-1")
        XCTAssertTrue(appState.dispatchingTaskIds.isEmpty)
        XCTAssertFalse(appState.shouldDispatchTask(adopted!, from: adopted!.status))

        appState.sessionActivity["chat-1"] = SessionActivity(isStreaming: false)
        XCTAssertNotNil(appState.applyTaskTrigger(.sessionStop, sessionKey: "chat-1"))
        XCTAssertEqual(appState.task(id: task.id)?.status, .pendingReview)
    }

    func testTaskFromIdleChatStaysInItsColumn() {
        var task = makeTask(status: .backlog, sessionKey: nil)
        task.sourceSessionKey = "chat-1"
        seed([task])

        appState.adoptRunningChat("chat-1", forTask: task.id)

        XCTAssertEqual(appState.task(id: task.id)?.status, .backlog)
        XCTAssertNil(appState.task(id: task.id)?.sessionKey)
    }

    func testChatAgentReusesCompletedTaskWhenRecordingSameWorkAgain() async throws {
        let story = ProjectStory(projectId: project.id, title: "Dashboard work")
        let completed = ProjectTask(
            projectId: project.id,
            storyId: story.id,
            title: "Add colored provider icons",
            details: "Show colored provider icons on task cards.",
            status: .done,
            sessionKey: "completed-thread"
        )
        appState.taskBoards[project.id] = TaskBoard(stories: [story], tasks: [completed])

        let result = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(project.id.uuidString),
                "title": .string(completed.title),
                "details": .string(completed.details),
            ]),
            sessionKey: "follow-up-thread"
        )

        XCTAssertEqual(appState.allTasks(projectFilter: project.id).map(\.id), [completed.id])
        XCTAssertEqual(appState.task(id: completed.id)?.status, .done)
        let resultText = try XCTUnwrap(toolResultText(result))
        XCTAssertTrue(resultText.contains(completed.id.uuidString))
        XCTAssertTrue(resultText.contains("already_exists"))
    }

    func testChatAgentReusesCompletedTaskWhenItsThreadRephrasesTheWork() async throws {
        let completed = ProjectTask(
            projectId: project.id,
            title: "Add colored provider icons",
            details: "Show colored provider icons on task cards.",
            status: .done,
            sessionKey: "completed-thread"
        )
        appState.taskBoards[project.id] = TaskBoard(tasks: [completed])

        let result = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(project.id.uuidString),
                "title": .string("Fix provider artwork after review"),
                "details": .string("Adjust the task card logos based on the latest feedback."),
            ]),
            sessionKey: "completed-thread"
        )

        XCTAssertEqual(appState.allTasks(projectFilter: project.id).map(\.id), [completed.id])
        XCTAssertEqual(appState.task(id: completed.id)?.status, .done)
        let resultText = try XCTUnwrap(toolResultText(result))
        XCTAssertTrue(resultText.contains(completed.id.uuidString))
        XCTAssertTrue(resultText.contains("already_exists"))
    }

    func testParentInAnotherProjectStartsDependentAndDeletionClearsLink() async throws {
        let other = Project(name: "Q", path: "/tmp/q", gitHubRepo: nil)
        appState.projects = [project, other]
        var parent = ProjectTask(projectId: project.id, title: "API", status: .pending)
        appState.taskBoards[project.id] = TaskBoard(tasks: [parent])
        appState.taskBoards[other.id] = TaskBoard()

        let result = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(other.id.uuidString),
                "title": .string("Client"),
                "details": .string("Call the new API"),
                "starts_after_task_id": .string(parent.id.uuidString),
            ]),
            sessionKey: "chat-1"
        )
        XCTAssertTrue(try XCTUnwrap(toolResultText(result)).contains(parent.id.uuidString))
        let child = try XCTUnwrap(appState.taskBoard(for: other.id).tasks.first)
        XCTAssertEqual(child.parentTaskId, parent.id)
        XCTAssertFalse(appState.canLinkTask(parent.id, to: child.id))
        XCTAssertEqual(
            appState.parentTaskChoices(for: parent.id, in: project.id).flatMap { $0.groups.flatMap(\.tasks) }.map(\.id),
            []
        )

        parent.status = .pendingReview
        appState.upsertTask(parent)
        XCTAssertEqual(appState.task(id: child.id)?.status, .inProgress)

        appState.deleteTask(parent)
        XCTAssertNil(appState.task(id: child.id)?.parentTaskId)
    }

    func testIDECreateTaskWaitsForAllParentsAcrossProjects() async throws {
        let other = Project(name: "Q", path: "/tmp/q", gitHubRepo: nil)
        appState.projects = [project, other]
        var first = ProjectTask(projectId: project.id, title: "API", status: .pending)
        var second = ProjectTask(projectId: other.id, title: "Design", status: .pending)
        appState.taskBoards[project.id] = TaskBoard(tasks: [first])
        appState.taskBoards[other.id] = TaskBoard(tasks: [second])

        _ = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(other.id.uuidString),
                "title": .string("Client"),
                "starts_after_task_ids": .array([.string(first.id.uuidString), .string(second.id.uuidString)]),
            ]),
            sessionKey: "multi-parent-chat"
        )
        let child = try XCTUnwrap(appState.taskBoard(for: other.id).tasks.first { $0.title == "Client" })
        XCTAssertEqual(child.parentTaskIds, [first.id, second.id])

        first.status = .pendingReview
        appState.upsertTask(first)
        XCTAssertEqual(appState.task(id: child.id)?.status, .backlog)

        second.status = .pendingReview
        appState.upsertTask(second)
        XCTAssertEqual(appState.task(id: child.id)?.status, .inProgress)
    }

    func testChatAgentCanShareStoryAcrossProjectsAndTrackTasks() async throws {
        let other = Project(name: "Q", path: "/tmp/q", gitHubRepo: nil)
        appState.projects = [project, other]
        appState.taskBoards[project.id] = TaskBoard()
        appState.taskBoards[other.id] = TaskBoard()

        _ = try await appState.ideHandleToolCall(
            name: "ide__create_story",
            arguments: .object([
                "project_id": .string(project.id.uuidString),
                "title": .string("Cross-project work"),
                "linked_project_ids": .array([.string(other.id.uuidString)]),
            ]),
            sessionKey: "chat-1"
        )
        let story = try XCTUnwrap(appState.stories(projectFilter: project.id).first)
        let mirror = try XCTUnwrap(appState.taskBoard(for: other.id).story(id: story.id))
        XCTAssertEqual(mirror.projectId, other.id)
        XCTAssertEqual(mirror.linkedProjectIds, [project.id])
        XCTAssertEqual(story.linkedProjectIds, [other.id])

        // A task in the linked project can join the shared story.
        _ = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(other.id.uuidString),
                "story_id": .string(story.id.uuidString),
                "title": .string("Backend half"),
            ]),
            sessionKey: "chat-1"
        )
        _ = try await appState.ideHandleToolCall(
            name: "ide__create_task",
            arguments: .object([
                "project_id": .string(project.id.uuidString),
                "story_id": .string(story.id.uuidString),
                "title": .string("Frontend half"),
            ]),
            sessionKey: "chat-1"
        )

        // Editing one copy updates the other, and keeps the links.
        var renamed = mirror
        renamed.title = "Renamed"
        renamed.linkedProjectIds = []
        appState.upsertStory(renamed)
        XCTAssertEqual(appState.taskBoard(for: project.id).story(id: story.id)?.title, "Renamed")
        XCTAssertEqual(appState.taskBoard(for: other.id).story(id: story.id)?.linkedProjectIds, [project.id])

        let listed = try await appState.ideHandleToolCall(
            name: "ide__get_tasks",
            arguments: .object(["story_id": .string(story.id.uuidString)]),
            sessionKey: "chat-1"
        )
        let listedText = try XCTUnwrap(toolResultText(listed))
        XCTAssertTrue(listedText.contains("Backend half"))
        XCTAssertTrue(listedText.contains("Frontend half"))

        let backend = try XCTUnwrap(appState.allTasks(projectFilter: other.id).first)
        let status = try await appState.ideHandleToolCall(
            name: "ide__get_task_status",
            arguments: .object(["task_id": .string(backend.id.uuidString)]),
            sessionKey: "chat-1"
        )
        let statusText = try XCTUnwrap(toolResultText(status))
        XCTAssertTrue(statusText.contains("\"is_running\":false") || statusText.contains("\"is_running\" : false"))

        // Unlinking removes the copy and orphans that project's tasks.
        _ = try await appState.ideHandleToolCall(
            name: "ide__link_story",
            arguments: .object([
                "story_id": .string(story.id.uuidString),
                "unlink_project_ids": .array([.string(other.id.uuidString)]),
            ]),
            sessionKey: "chat-1"
        )
        XCTAssertNil(appState.taskBoard(for: other.id).story(id: story.id))
        XCTAssertNil(appState.task(id: backend.id)?.storyId)
        XCTAssertEqual(appState.taskBoard(for: project.id).story(id: story.id)?.linkedProjectIds, [])
    }

    /// The first text block of an IDE tool result. Matched by case because the
    /// app target redeclares `JSONValue`'s accessors, which makes them ambiguous
    /// under `@testable import`.
    private func toolResultText(_ result: JSONValue) -> String? {
        guard case .array(let blocks)? = result["content"],
              case .string(let text)? = blocks.first?["text"]
        else { return nil }
        return text
    }

    /// The story form edits links on the draft; saving applies the difference.
    func testSaveStoryAppliesFormLinkChanges() async throws {
        let other = Project(name: "Q", path: "/tmp/q", gitHubRepo: nil)
        let third = Project(name: "R", path: "/tmp/r", gitHubRepo: nil)
        appState.projects = [project, other, third]
        for id in [project.id, other.id, third.id] { appState.taskBoards[id] = TaskBoard() }

        let story = ProjectStory(projectId: project.id, title: "Shared", linkedProjectIds: [other.id])
        await appState.saveStory(story)
        XCTAssertEqual(appState.taskBoard(for: other.id).story(id: story.id)?.linkedProjectIds, [project.id])

        let task = ProjectTask(projectId: other.id, storyId: story.id, title: "Other half")
        appState.upsertTask(task)
        XCTAssertEqual(appState.tasks(inStory: story).map(\.id), [task.id])
        XCTAssertEqual(appState.stories().filter { $0.id == story.id }.count, 1)

        var edited = try XCTUnwrap(appState.taskBoard(for: project.id).story(id: story.id))
        edited.linkedProjectIds = [third.id]
        await appState.saveStory(edited)
        XCTAssertNil(appState.taskBoard(for: other.id).story(id: story.id))
        XCTAssertNil(appState.task(id: task.id)?.storyId)
        XCTAssertEqual(appState.taskBoard(for: third.id).story(id: story.id)?.linkedProjectIds, [project.id])
        XCTAssertEqual(appState.taskBoard(for: project.id).story(id: story.id)?.linkedProjectIds, [third.id])
    }
}
