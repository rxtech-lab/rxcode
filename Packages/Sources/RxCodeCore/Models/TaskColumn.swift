import Foundation

// MARK: - TaskStatus

/// The id of the board column a `ProjectTask` sits in.
///
/// A string rather than an enum because columns are user-defined per board
/// (`TaskBoard.columns`). The built-in ids below are the columns every board
/// starts with; their raw values are persisted, so they must stay stable.
///
/// Deliberately separate from `TodoItem.Status`: that enum mirrors the agent's
/// `TodoWrite` wire format and is scoped to a single streaming turn, whereas
/// these are user-owned states that outlive any thread.
public struct TaskStatus: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// A fresh id for a user-added column.
    public static func custom() -> TaskStatus {
        TaskStatus(rawValue: "custom-\(UUID().uuidString.lowercased())")
    }

    public static let backlog: TaskStatus = "backlog"
    public static let pending: TaskStatus = "pending"
    public static let inProgress: TaskStatus = "in_progress"
    public static let pendingReview: TaskStatus = "pending_review"
    public static let done: TaskStatus = "done"

    // Encoded as a bare string so boards written before columns were
    // configurable decode unchanged.
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - TaskTriggerEvent

/// A lifecycle event of a task's linked thread. Each column says where a card
/// sitting in it moves when one of these fires — the board's hooks.
public enum TaskTriggerEvent: String, Codable, Sendable, CaseIterable, Hashable {
    case sessionStop
    case reviewStart
    case reviewPass
    case reviewFail

    public var displayName: LocalizedStringResource {
        switch self {
        case .sessionStop: return "On session stop"
        case .reviewStart: return "On review start"
        case .reviewPass: return "On review pass"
        case .reviewFail: return "On review fail"
        }
    }

    public var systemImage: String {
        switch self {
        case .sessionStop: return "stop.circle"
        case .reviewStart: return "eye"
        case .reviewPass: return "checkmark.seal"
        case .reviewFail: return "xmark.seal"
        }
    }
}

// MARK: - TaskColumn

/// One board column and its automation.
///
/// A column can **trigger a chat**: dropping a card into it dispatches the
/// task to its assigned agent. While the card sits in such a column with a
/// linked thread, the agent owns it and it can't be moved by hand. Every column
/// can also route a card elsewhere when its thread fires a `TaskTriggerEvent`,
/// so the columns form a small state machine — e.g. In Progress →(session
/// stop)→ Pending Review →(review fail)→ In Progress.
public struct TaskColumn: Identifiable, Codable, Sendable, Hashable {
    public var id: TaskStatus
    public var name: String
    /// `#RRGGBB`.
    public var colorHex: String
    /// SF Symbol shown beside the column name and on cards.
    public var systemImage: String
    /// Optional one-line description under the column header. When empty the
    /// UI describes the column's triggers instead.
    public var details: String
    public var triggersChat: Bool
    /// Cards here count as finished for story progress and roll-up.
    public var countsAsDone: Bool
    public var onSessionStop: TaskStatus?
    public var onReviewStart: TaskStatus?
    public var onReviewPass: TaskStatus?
    public var onReviewFail: TaskStatus?

    public init(
        id: TaskStatus = .custom(),
        name: String,
        colorHex: String = TaskLabel.defaultColorHex,
        systemImage: String = "circle",
        details: String = "",
        triggersChat: Bool = false,
        countsAsDone: Bool = false,
        onSessionStop: TaskStatus? = nil,
        onReviewStart: TaskStatus? = nil,
        onReviewPass: TaskStatus? = nil,
        onReviewFail: TaskStatus? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.systemImage = systemImage
        self.details = details
        self.triggersChat = triggersChat
        self.countsAsDone = countsAsDone
        self.onSessionStop = onSessionStop
        self.onReviewStart = onReviewStart
        self.onReviewPass = onReviewPass
        self.onReviewFail = onReviewFail
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, systemImage, details, triggersChat, countsAsDone
        case onSessionStop, onReviewStart, onReviewPass, onReviewFail
    }

    /// Tolerant decoding: a column missing newer fields decodes as a plain,
    /// trigger-less column.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(TaskStatus.self, forKey: .id) ?? .custom()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? TaskLabel.defaultColorHex
        systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage) ?? "circle"
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        triggersChat = try c.decodeIfPresent(Bool.self, forKey: .triggersChat) ?? false
        countsAsDone = try c.decodeIfPresent(Bool.self, forKey: .countsAsDone) ?? false
        onSessionStop = try c.decodeIfPresent(TaskStatus.self, forKey: .onSessionStop)
        onReviewStart = try c.decodeIfPresent(TaskStatus.self, forKey: .onReviewStart)
        onReviewPass = try c.decodeIfPresent(TaskStatus.self, forKey: .onReviewPass)
        onReviewFail = try c.decodeIfPresent(TaskStatus.self, forKey: .onReviewFail)
    }

    /// Where a card in this column goes when `event` fires; `nil` stays put.
    public func target(for event: TaskTriggerEvent) -> TaskStatus? {
        switch event {
        case .sessionStop: return onSessionStop
        case .reviewStart: return onReviewStart
        case .reviewPass: return onReviewPass
        case .reviewFail: return onReviewFail
        }
    }

    public mutating func setTarget(_ target: TaskStatus?, for event: TaskTriggerEvent) {
        switch event {
        case .sessionStop: onSessionStop = target
        case .reviewStart: onReviewStart = target
        case .reviewPass: onReviewPass = target
        case .reviewFail: onReviewFail = target
        }
    }

    /// The columns a board starts with. Reproduces the original fixed board —
    /// In Progress starts the agent and hands the card to Pending Review when
    /// the turn ends — plus a Backlog in front. Built-in ids are stable so
    /// tasks written before columns were configurable keep their column.
    public static var defaults: [TaskColumn] {
        [
            TaskColumn(
                id: .backlog,
                name: String(localized: "Backlog"),
                colorHex: "#8B8D98",
                systemImage: "tray",
                details: String(localized: "Ideas and work not planned yet")
            ),
            TaskColumn(
                id: .pending,
                name: String(localized: "Pending"),
                colorHex: "#0090FF",
                systemImage: "circle",
                details: String(localized: "This item hasn't been started")
            ),
            TaskColumn(
                id: .inProgress,
                name: String(localized: "In Progress"),
                colorHex: "#F76B15",
                systemImage: "circle.dotted.circle",
                details: String(localized: "This is actively being worked on"),
                triggersChat: true,
                onSessionStop: .pendingReview
            ),
            TaskColumn(
                id: .pendingReview,
                name: String(localized: "Pending Review"),
                colorHex: "#8E4EC6",
                systemImage: "eye.circle",
                details: String(localized: "This item is in review"),
                onReviewFail: .inProgress
            ),
            TaskColumn(
                id: .done,
                name: String(localized: "Done"),
                colorHex: "#30A46C",
                systemImage: "checkmark.circle.fill",
                details: String(localized: "This has been completed"),
                countsAsDone: true
            ),
        ]
    }
}

// MARK: - TaskBoard columns

public extension TaskBoard {
    /// The columns this board shows, in order: its customized list, or the
    /// defaults until the user edits them.
    var effectiveColumns: [TaskColumn] {
        columns.isEmpty ? TaskColumn.defaults : columns
    }

    /// The column a status belongs to. A status whose column was deleted falls
    /// back to the first column, so no task is ever hidden.
    func column(for status: TaskStatus) -> TaskColumn {
        let all = effectiveColumns
        return all.first { $0.id == status } ?? all[0]
    }

    /// `task.status` normalized onto an existing column.
    func resolvedStatus(of task: ProjectTask) -> TaskStatus {
        column(for: task.status).id
    }

    /// Board position of a status, for sorting rows by column.
    func columnIndex(of status: TaskStatus) -> Int {
        effectiveColumns.firstIndex { $0.id == status } ?? 0
    }

    /// This board's column ids with `column` moved into `target`'s slot — what
    /// dragging a column header onto another column on the board produces, and
    /// the same result the columns manager's list drag would give.
    ///
    /// `nil` when the drag changes nothing (same column, or an id no longer on
    /// the board), so callers can skip the write. Columns hidden by the current
    /// saved view keep their relative position because the move runs over the
    /// whole board order, not the visible subset.
    func columnOrder(moving column: TaskStatus, to target: TaskStatus) -> [TaskStatus]? {
        var order = effectiveColumns.map(\.id)
        guard column != target,
              let from = order.firstIndex(of: column),
              let to = order.firstIndex(of: target)
        else { return nil }
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        return order
    }

    /// The first column that starts a chat — where "Run with Agent" and
    /// follow-ups put a card.
    var firstChatColumn: TaskColumn? {
        effectiveColumns.first(where: \.triggersChat)
    }

    /// The column a new task starts in.
    var firstColumn: TaskColumn {
        effectiveColumns[0]
    }

    /// An agent-owned task: it sits in a chat column with a linked thread. The
    /// board, forms and menus don't let the user change its status; the
    /// column's session-stop trigger moves it on when the turn finishes. A
    /// task placed in such a column by hand (no thread), or flagged after a
    /// failed run, stays movable.
    func isStatusLocked(_ task: ProjectTask) -> Bool {
        task.sessionKey != nil && task.attentionReason == nil && column(for: task.status).triggersChat
    }

    /// Where `task` should move when `event` fires, or `nil` to stay put. A
    /// target naming a deleted column is ignored.
    func triggerTarget(for task: ProjectTask, event: TaskTriggerEvent) -> TaskStatus? {
        let current = column(for: task.status)
        guard let target = current.target(for: event),
              target != current.id,
              effectiveColumns.contains(where: { $0.id == target })
        else { return nil }
        return target
    }

    /// The column an orphaned agent-owned task is released to at launch: its
    /// session-stop target when that isn't itself a chat column, else the next
    /// non-chat column after it, else any non-chat column.
    func releaseTarget(for task: ProjectTask) -> TaskStatus? {
        let all = effectiveColumns
        if let target = triggerTarget(for: task, event: .sessionStop),
           !column(for: target).triggersChat {
            return target
        }
        let index = columnIndex(of: resolvedStatus(of: task))
        let after = all.dropFirst(index + 1).first { !$0.triggersChat }
        return (after ?? all.first { !$0.triggersChat })?.id
    }
}
