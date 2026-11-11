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

/// A task's connected chat or review, independent of its current column.
public struct MobileTaskLinkedSession: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case run, source, review }
    public let id: String
    public let title: String
    public let kind: Kind
    public let feedback: String?

    public init(id: String, title: String, kind: Kind, feedback: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.feedback = feedback
    }
}

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
    public let taskLinkedSessions: [String: [MobileTaskLinkedSession]]
    /// Desktop task UUID → cloud task ID for matching a direct-cloud mobile board.
    public let taskCloudIDs: [String: String]
    /// Tasks whose title/classification the desktop is still generating.
    public let classifyingTaskIDs: [UUID]
    /// The desktop's default task agent, used to prefill new task drafts.
    public let defaultAgent: TaskAgentConfig?

    public init(
        projectID: UUID,
        board: TaskBoard,
        taskSessionIDs: [String: String] = [:],
        taskLinkedSessions: [String: [MobileTaskLinkedSession]] = [:],
        taskCloudIDs: [String: String] = [:],
        classifyingTaskIDs: [UUID] = [],
        defaultAgent: TaskAgentConfig? = nil
    ) {
        self.projectID = projectID
        self.board = board
        self.taskSessionIDs = taskSessionIDs
        self.taskLinkedSessions = taskLinkedSessions
        self.taskCloudIDs = taskCloudIDs
        self.classifyingTaskIDs = classifyingTaskIDs
        self.defaultAgent = defaultAgent
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, board, taskSessionIDs, taskLinkedSessions, taskCloudIDs, classifyingTaskIDs, defaultAgent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        board = try c.decodeIfPresent(TaskBoard.self, forKey: .board) ?? TaskBoard()
        taskSessionIDs = try c.decodeIfPresent([String: String].self, forKey: .taskSessionIDs) ?? [:]
        taskCloudIDs = try c.decodeIfPresent([String: String].self, forKey: .taskCloudIDs) ?? [:]
        taskLinkedSessions = try c.decodeIfPresent([String: [MobileTaskLinkedSession]].self, forKey: .taskLinkedSessions) ?? [:]
        classifyingTaskIDs = try c.decodeIfPresent([UUID].self, forKey: .classifyingTaskIDs) ?? []
        defaultAgent = try c.decodeIfPresent(TaskAgentConfig.self, forKey: .defaultAgent)
    }

    /// Adds Mac-owned review state to a cloud board whose task UUIDs differ.
    /// Cloud refreshes do not carry this state, so apply it after each refresh.
    public func mergingDesktopFeedback(from desktop: MobileTaskBoardSnapshot) -> MobileTaskBoardSnapshot {
        var mergedBoard = board
        var links = taskLinkedSessions
        let tasksByID = Dictionary(uniqueKeysWithValues: desktop.board.tasks.map { ($0.id.uuidString, $0) })
        let desktopIDs = Dictionary(desktop.taskCloudIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for index in mergedBoard.tasks.indices {
            let id = mergedBoard.tasks[index].id
            guard let remoteID = mergedBoard.cloudSync?.taskRemoteId(id),
                  let desktopID = desktopIDs[remoteID], let task = tasksByID[desktopID] else { continue }
            // Nil is authoritative too: a successful retry clears the warning.
            if task.updatedAt >= mergedBoard.tasks[index].updatedAt {
                mergedBoard.tasks[index].attentionReason = task.attentionReason
            }
            if let connected = desktop.taskLinkedSessions[desktopID] {
                links[id.uuidString] = connected
            }
        }
        return MobileTaskBoardSnapshot(projectID: projectID, board: mergedBoard,
            taskSessionIDs: taskSessionIDs, taskLinkedSessions: links, taskCloudIDs: taskCloudIDs,
            classifyingTaskIDs: classifyingTaskIDs, defaultAgent: defaultAgent)
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
        /// Create or rename one shared tag, version or milestone.
        case editMetadata
    }

    public let clientRequestID: UUID
    public let projectID: UUID
    public let operation: Operation
    public let task: ProjectTask?
    public let story: ProjectStory?
    public let metadataEdit: TaskMetadataEdit?
    public let view: TaskSavedView?
    public let taskID: UUID?
    public let storyID: UUID?
    public let status: TaskStatus?
    /// Position within `status` for `moveTask` (a drag-and-drop drop point);
    /// `nil` appends to the end of the column.
    public let sortIndex: Double?
    public let text: String?
    /// Explicit agent chosen on mobile for this move; omitted by older clients.
    public let runAgent: TaskAgentConfig?
    /// Set when a phone runs a cloud board's task on a paired Mac: the Mac
    /// resolves its own project and task copies from these Autopilot IDs,
    /// since its local IDs differ from the phone's. `projectID` and `taskID`
    /// are then the phone's IDs and are ignored.
    public let cloudProjectID: String?
    public let cloudTaskID: String?

    public init(
        clientRequestID: UUID = UUID(),
        projectID: UUID,
        operation: Operation,
        task: ProjectTask? = nil,
        story: ProjectStory? = nil,
        view: TaskSavedView? = nil,
        metadataEdit: TaskMetadataEdit? = nil,
        taskID: UUID? = nil,
        storyID: UUID? = nil,
        status: TaskStatus? = nil,
        sortIndex: Double? = nil,
        text: String? = nil,
        runAgent: TaskAgentConfig? = nil,
        cloudProjectID: String? = nil,
        cloudTaskID: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.projectID = projectID
        self.operation = operation
        self.task = task
        self.story = story
        self.view = view
        self.metadataEdit = metadataEdit
        self.taskID = taskID
        self.storyID = storyID
        self.status = status
        self.sortIndex = sortIndex
        self.text = text
        self.runAgent = runAgent
        self.cloudProjectID = cloudProjectID
        self.cloudTaskID = cloudTaskID
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
