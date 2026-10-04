import Foundation
import Testing
import RxCodeCore
@testable import RxCodeSync

@Suite("Task board sync payloads")
struct TaskBoardPayloadTests {
    private let projectID = UUID(uuidString: "11111111-AAAA-BBBB-CCCC-000000000001")!

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
