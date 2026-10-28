import Foundation

// MARK: - TaskSize

/// How much work a story or task is, as a T-shirt size. Fixed levels so the
/// estimate reads the same on every board and device.
public enum TaskSize: String, Codable, Sendable, CaseIterable, Hashable {
    case xs
    case s
    case m
    case l
    case xl

    /// The short label shown on cards.
    public var shortName: String {
        switch self {
        case .xs: return "XS"
        case .s: return "S"
        case .m: return "M"
        case .l: return "L"
        case .xl: return "XL"
        }
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .xs: return "Extra Small"
        case .s: return "Small"
        case .m: return "Medium"
        case .l: return "Large"
        case .xl: return "Extra Large"
        }
    }

    public var displayNameText: String {
        String(localized: displayName)
    }

    /// Smaller sorts first.
    public var rank: Int {
        TaskSize.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - TaskDelay

/// One recorded slip of a story or task: why it slipped, when it was
/// recorded, and who recorded it.
public struct TaskDelay: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var reason: String
    public var createdAt: Date
    /// Who recorded the delay. Nil until the saving device stamps it.
    public var author: CardAssignee?

    public init(id: UUID = UUID(), reason: String, createdAt: Date = Date(), author: CardAssignee? = nil) {
        self.id = id
        self.reason = reason
        self.createdAt = createdAt
        self.author = author
    }

    private enum CodingKeys: String, CodingKey {
        case id, reason, createdAt, author
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        author = try? c.decodeIfPresent(CardAssignee.self, forKey: .author)
    }
}

public extension Array where Element == TaskDelay {
    /// Gives every delay without an author to `actor`, so the device that
    /// saves a new delay records who added it.
    func stampingAuthors(_ actor: CardAssignee?) -> [TaskDelay] {
        guard let actor else { return self }
        return map { delay in
            var delay = delay
            if delay.author == nil { delay.author = actor }
            return delay
        }
    }
}

// MARK: - Deadline state

/// How close a card is to its deadline.
public enum TaskDeadlineState: Sendable, Hashable {
    case upcoming
    /// Due within the next 24 hours.
    case dueSoon
    case overdue
    /// The deadline has passed but the work is finished, so it no longer warns.
    case met

    public static func of(deadline: Date, isDone: Bool, now: Date = Date()) -> TaskDeadlineState {
        if isDone { return .met }
        if deadline < now { return .overdue }
        if deadline.timeIntervalSince(now) < 24 * 60 * 60 { return .dueSoon }
        return .upcoming
    }
}

// MARK: - Reviewer

public extension TaskBoard {
    /// Records who finished the review when a task moves from Pending Review
    /// into a done column. A task that leaves done, or reaches done without
    /// passing review, has no reviewer; a move between done columns keeps it.
    func stampingReviewer(_ task: ProjectTask, from previous: TaskStatus?, actor: CardAssignee?) -> ProjectTask {
        guard let previous, previous != task.status else { return task }
        var task = task
        let isDone = column(for: task.status).countsAsDone
        if !isDone {
            task.reviewer = nil
        } else if column(for: previous).id == .pendingReview {
            task.reviewer = actor
        } else if !column(for: previous).countsAsDone {
            task.reviewer = nil
        }
        return task
    }
}
