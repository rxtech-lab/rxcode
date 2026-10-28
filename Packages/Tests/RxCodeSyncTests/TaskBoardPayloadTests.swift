import Foundation
import Testing
import RxCodeCore
@testable import RxCodeSync

@Suite("Task board sync payloads")
struct TaskBoardPayloadTests {
    private let projectID = UUID(uuidString: "11111111-AAAA-BBBB-CCCC-000000000001")!

    @Test("column sorting travels from phone mutation to desktop board update")
    func columnSortRoundTrips() throws {
        var view = TaskSavedView.defaultView
        view.columnSorts["pending"] = TaskColumnSort(field: .priority, descending: true)
        let request = TaskBoardRequestPayload(projectID: projectID, operation: .upsertView, view: view)
        let received = try JSONDecoder().decode(TaskBoardRequestPayload.self, from: JSONEncoder().encode(request))
        #expect(received.view?.columnSorts == view.columnSorts)
        let update = TaskBoardUpdatePayload(snapshot: MobileTaskBoardSnapshot(
            projectID: projectID, board: TaskBoard(savedViews: [view])
        ))
        let decoded = try JSONDecoder().decode(TaskBoardUpdatePayload.self, from: JSONEncoder().encode(update))
        #expect(decoded.snapshot.board.defaultView.columnSorts == view.columnSorts)
    }

    @Test("task board request round trips a task mutation")
    func requestRoundTrips() throws {
        let task = ProjectTask(projectId: projectID, title: "Ship tasks", details: "On iOS", status: .inProgress, tags: ["Mobile"])
        let request = Payload.taskBoardRequest(TaskBoardRequestPayload(
            projectID: projectID,
            operation: .moveTask,
            task: task,
            taskID: task.id,
            status: .pendingReview
        ))

        let data = try JSONEncoder().encode(request)
        guard case .taskBoardRequest(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected task board request")
            return
        }
        #expect(decoded.operation == .moveTask)
        #expect(decoded.projectID == projectID)
        #expect(decoded.taskID == task.id)
        #expect(decoded.status == .pendingReview)
        #expect(decoded.task?.title == "Ship tasks")
        #expect(decoded.task?.tags == ["Mobile"])
    }

    @Test("cloud task run request carries Autopilot IDs")
    func cloudRunRequestRoundTrips() throws {
        let request = TaskBoardRequestPayload(
            projectID: projectID,
            operation: .moveTask,
            status: .inProgress,
            runAgent: TaskAgentConfig(provider: .acp, model: "client:model", planMode: true),
            cloudProjectID: "cloud-project",
            cloudTaskID: "cloud-task"
        )
        let decoded = try JSONDecoder().decode(TaskBoardRequestPayload.self, from: JSONEncoder().encode(request))
        #expect(decoded.cloudProjectID == "cloud-project")
        #expect(decoded.cloudTaskID == "cloud-task")
        #expect(decoded.runAgent == TaskAgentConfig(provider: .acp, model: "client:model", planMode: true))
    }

    @Test("local run preserves the selected provider and model", arguments: [AgentProvider.claudeCode, .codex, .acp])
    func localRunAgentRoundTrips(provider: AgentProvider) throws {
        let agent = TaskAgentConfig(provider: provider, model: "chosen-model", effort: "high", planMode: true)
        let request = TaskBoardRequestPayload(
            projectID: projectID,
            operation: .moveTask,
            taskID: UUID(),
            status: .inProgress,
            sortIndex: 42,
            runAgent: agent
        )
        let decoded = try JSONDecoder().decode(TaskBoardRequestPayload.self, from: JSONEncoder().encode(request))
        #expect(decoded.runAgent == agent)
        #expect(decoded.sortIndex == 42)
        #expect(decoded.cloudProjectID == nil)
    }

    @Test("request from an older phone decodes without cloud IDs")
    func legacyRequestDecodes() throws {
        let json = """
        {"clientRequestID":"\(UUID().uuidString)","projectID":"\(projectID.uuidString)","operation":"fetch"}
        """
        let decoded = try JSONDecoder().decode(TaskBoardRequestPayload.self, from: Data(json.utf8))
        #expect(decoded.operation == .fetch)
        #expect(decoded.cloudProjectID == nil)
        #expect(decoded.cloudTaskID == nil)
        #expect(decoded.runAgent == nil)
    }

    @Test("task board result carries the board and resolved chat threads")
    func resultRoundTrips() throws {
        let story = ProjectStory(projectId: projectID, title: "Projects Dashboard")
        let task = ProjectTask(projectId: projectID, storyId: story.id, title: "Add iOS support", sessionKey: "pending-1")
        let snapshot = MobileTaskBoardSnapshot(
            projectID: projectID,
            board: TaskBoard(stories: [story], tasks: [task]),
            taskSessionIDs: [task.id.uuidString: "session-1"],
            classifyingTaskIDs: [task.id],
            defaultAgent: TaskAgentConfig(provider: .claudeCode, model: "opus")
        )
        let result = Payload.taskBoardResult(TaskBoardResultPayload(
            clientRequestID: UUID(),
            projectID: projectID,
            ok: true,
            snapshot: snapshot,
            taskID: task.id
        ))

        let data = try JSONEncoder().encode(result)
        guard case .taskBoardResult(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected task board result")
            return
        }
        let decodedSnapshot = try #require(decoded.snapshot)
        #expect(decoded.ok)
        #expect(decoded.taskID == task.id)
        #expect(decodedSnapshot.board.stories.map(\.title) == ["Projects Dashboard"])
        #expect(decodedSnapshot.board.tasks.first?.storyId == story.id)
        #expect(decodedSnapshot.sessionID(for: task.id) == "session-1")
        #expect(decodedSnapshot.classifyingTaskIDs == [task.id])
        #expect(decodedSnapshot.defaultAgent?.model == "opus")
    }

    @Test("snapshot from an older desktop decodes with empty extras")
    func snapshotToleratesMissingFields() throws {
        let json = #"{"projectID":"\#(projectID.uuidString)","board":{"stories":[],"tasks":[]}}"#
        let snapshot = try JSONDecoder().decode(MobileTaskBoardSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.projectID == projectID)
        #expect(snapshot.taskSessionIDs.isEmpty)
        #expect(snapshot.classifyingTaskIDs.isEmpty)
        #expect(snapshot.defaultAgent == nil)
    }

    @Test("fetch-runs result carries prompt and response turns")
    func runsRoundTrip() throws {
        let messages = [
            ChatMessage(role: .user, content: "**Task:** Add iOS support"),
            ChatMessage(role: .assistant, content: "Working on it"),
            ChatMessage(role: .assistant, content: "Done: added the Tasks tab."),
            ChatMessage(role: .user, content: "Also support iPad"),
        ]
        let turns = TaskRunTurn.turns(from: messages)
        let result = Payload.taskBoardResult(TaskBoardResultPayload(
            clientRequestID: UUID(),
            projectID: projectID,
            ok: true,
            runs: turns
        ))

        let data = try JSONEncoder().encode(result)
        guard case .taskBoardResult(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected task board result")
            return
        }
        let runs = try #require(decoded.runs)
        #expect(runs.count == 2)
        #expect(runs[0].response == "Done: added the Tasks tab.")
        #expect(runs[1].prompt == "Also support iPad")
        #expect(runs[1].response.isEmpty)
    }

    @Test("task board update round trips")
    func updateRoundTrips() throws {
        let update = Payload.taskBoardUpdate(TaskBoardUpdatePayload(
            snapshot: MobileTaskBoardSnapshot(projectID: projectID, board: TaskBoard())
        ))
        let data = try JSONEncoder().encode(update)
        guard case .taskBoardUpdate(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected task board update")
            return
        }
        #expect(decoded.snapshot.projectID == projectID)
        #expect(update.logName == "task_board_update")
    }
}
