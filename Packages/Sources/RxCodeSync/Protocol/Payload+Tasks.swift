import Foundation
import RxCodeCore

// MARK: - Task board remote management (mobile ↔ desktop)
//
// The desktop owns every project's `TaskBoard` (stories, tasks, columns) and is
// the only side that can dispatch a task to an agent. Mobile fetches a
// project's board, sends mutations as `taskBoardRequest`, and receives the
// resulting board in `taskBoardResult`. Any later change on the desktop (agent
// runs moving cards, background classification, edits on the Mac) is pushed
// to every paired device as `taskBoardUpdate`.

/// One project's board as mobile renders it, plus the desktop-only state the
/// board alone can't express.
public struct MobileTaskBoardSnapshot: Codable, Sendable {
    public let projectID: UUID
    /// Mutable so mobile can apply a move optimistically before the desktop
    /// confirms it.
    public var board: TaskBoard
    /// Task id (uuid string) → the chat thread it was dispatched into, already
    /// resolved through the desktop's session-id redirects. Only threads that
    /// still exist are listed, so mobile can offer "Open Chat" exactly when the
    /// desktop would.
    public let taskSessionIDs: [String: String]
    /// Tasks whose title/classification the desktop is still generating.
    public let classifyingTaskIDs: [UUID]
    /// The desktop's default task agent, used to prefill new task drafts.
    public let defaultAgent: TaskAgentConfig?

    public init(
        projectID: UUID,
        board: TaskBoard,
        taskSessionIDs: [String: String] = [:],
        classifyingTaskIDs: [UUID] = [],
        defaultAgent: TaskAgentConfig? = nil
    ) {
        self.projectID = projectID
        self.board = board
        self.taskSessionIDs = taskSessionIDs
        self.classifyingTaskIDs = classifyingTaskIDs
        self.defaultAgent = defaultAgent
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, board, taskSessionIDs, classifyingTaskIDs, defaultAgent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        board = try c.decodeIfPresent(TaskBoard.self, forKey: .board) ?? TaskBoard()
        taskSessionIDs = try c.decodeIfPresent([String: String].self, forKey: .taskSessionIDs) ?? [:]
        classifyingTaskIDs = try c.decodeIfPresent([UUID].self, forKey: .classifyingTaskIDs) ?? []
        defaultAgent = try c.decodeIfPresent(TaskAgentConfig.self, forKey: .defaultAgent)
    }

    /// The resolved chat thread for `taskID`, if it has one.
    public func sessionID(for taskID: UUID) -> String? {
        taskSessionIDs[taskID.uuidString]
    }
}

public struct TaskBoardRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        /// Return the current board; no mutation.
        case fetch
        /// Insert or replace `task`. Entering a chat column dispatches it.
        case upsertTask
        /// Delete the task `taskID`.
        case deleteTask
        /// Move the task `taskID` to `status`. Moving into a chat column is
        /// how a task is run with its agent.
        case moveTask
        /// Create a task from free text (`text`) in `storyID`, letting the
        /// desktop's default agent title and classify it.
        case quickAddTask
        /// Send `text` as a follow-up into the task's existing thread.
        case followUp
        /// Insert or replace `story`.
        case upsertStory
        /// Delete the story `storyID`; its tasks are kept, unparented.
        case deleteStory
        /// Return the task `taskID`'s runs — each prompt its thread was sent
        /// and the agent's final answer — in `TaskBoardResultPayload.runs`.
        case fetchRuns
        /// Insert or replace a saved project view.
        case upsertView
    }

    public let clientRequestID: UUID
    public let projectID: UUID
    public let operation: Operation
    public let task: ProjectTask?
    public let story: ProjectStory?
    public let view: TaskSavedView?
    public let taskID: UUID?
    public let storyID: UUID?
    public let status: TaskStatus?
    /// Position within `status` for `moveTask` (a drag-and-drop drop point);
    /// `nil` appends to the end of the column.
    public let sortIndex: Double?
    public let text: String?

    public init(
        clientRequestID: UUID = UUID(),
        projectID: UUID,
        operation: Operation,
        task: ProjectTask? = nil,
        story: ProjectStory? = nil,
        view: TaskSavedView? = nil,
        taskID: UUID? = nil,
        storyID: UUID? = nil,
        status: TaskStatus? = nil,
        sortIndex: Double? = nil,
        text: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.operation = operation
        self.task = task
        self.story = story
        self.view = view
        self.taskID = taskID
        self.storyID = storyID
        self.status = status
        self.sortIndex = sortIndex
        self.text = text
    }
}

public struct TaskBoardResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let projectID: UUID
    public let ok: Bool
    public let errorMessage: String?
    /// The board after the operation; present whenever the project exists.
    public let snapshot: MobileTaskBoardSnapshot?
    /// The task the operation created or touched (e.g. a quick-added task).
    public let taskID: UUID?
    /// For `fetchRuns`: the task's prompt → response turns. `nil` when the
    /// task has no chat thread.
    public let runs: [TaskRunTurn]?

    public init(
        clientRequestID: UUID,
        projectID: UUID,
        ok: Bool,
        errorMessage: String? = nil,
        snapshot: MobileTaskBoardSnapshot? = nil,
        taskID: UUID? = nil,
        runs: [TaskRunTurn]? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.ok = ok
        self.errorMessage = errorMessage
        self.snapshot = snapshot
        self.taskID = taskID
        self.runs = runs
    }
}

/// Desktop → mobile push after a project's board changes.
public struct TaskBoardUpdatePayload: Codable, Sendable {
    public let snapshot: MobileTaskBoardSnapshot

    public init(snapshot: MobileTaskBoardSnapshot) {
        self.snapshot = snapshot
    }
}
