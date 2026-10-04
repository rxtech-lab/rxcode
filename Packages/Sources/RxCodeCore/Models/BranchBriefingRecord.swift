import Foundation
import SwiftData

public struct BranchBriefingItem: Identifiable, Sendable, Equatable {
    public var id: String { BranchBriefingRecord.makeId(projectId: projectId, branch: branch, day: day) }

    public let projectId: UUID
    public let branch: String
    /// Start of the local calendar day this briefing covers. `nil` for legacy
    /// briefings generated before briefings were split per day; those
    /// summarize the whole branch.
    public let day: Date?
    public let briefing: String
    public let updatedAt: Date
    /// When the briefing was first generated. Records persisted before this
    /// was tracked fall back to `updatedAt`.
    public let createdAt: Date

    public init(
        projectId: UUID,
        branch: String,
        day: Date? = nil,
        briefing: String,
        updatedAt: Date,
        createdAt: Date? = nil
    ) {
        self.projectId = projectId
        self.branch = branch
        self.day = day
        self.briefing = briefing
        self.updatedAt = updatedAt
        self.createdAt = createdAt ?? updatedAt
    }
}

/// One generated briefing for a project branch on a single calendar day. A
/// branch worked on across several days has one record per day, each built
/// from the chats created that day.
@Model
public final class BranchBriefingRecord {
    @Attribute(.unique) public var id: String
    public var projectId: UUID
    public var branch: String
    /// Start of the local calendar day this briefing covers. Optional so
    /// existing stores migrate; `nil` marks a legacy whole-branch briefing.
    public var day: Date?
    public var briefing: String
    public var updatedAt: Date
    /// Last time the branch was observed (e.g. as the current branch of its
    /// project, or when the briefing was regenerated). Used to garbage-collect
    /// briefings for branches that no longer exist locally or remotely.
    public var lastSeenAt: Date = Date.distantPast
    /// When the briefing was first generated. Optional so existing stores
    /// migrate without a value; `nil` means it predates creation tracking.
    public var createdAt: Date?

    public init(
        projectId: UUID,
        branch: String,
        day: Date? = nil,
        briefing: String,
        updatedAt: Date = .now,
        lastSeenAt: Date = .now,
        createdAt: Date? = nil
    ) {
        self.id = Self.makeId(projectId: projectId, branch: branch, day: day)
        self.createdAt = createdAt ?? updatedAt
        self.projectId = projectId
        self.branch = branch
        self.day = day
        self.briefing = briefing
        self.updatedAt = updatedAt
        self.lastSeenAt = lastSeenAt
    }

    /// Legacy (day-less) ids keep their original `project::branch` form so
    /// existing records stay addressable.
    public static func makeId(projectId: UUID, branch: String, day: Date? = nil) -> String {
        let base = "\(projectId.uuidString)::\(branch)"
        guard let day else { return base }
        return "\(base)::\(dayKey(day))"
    }

    /// Stable `yyyy-MM-dd` key for the local calendar day containing `date`.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func apply(briefing: String, updatedAt: Date = .now) {
        self.briefing = briefing
        self.updatedAt = updatedAt
        self.lastSeenAt = updatedAt
    }

    public func touch(at date: Date = .now) {
        if date > lastSeenAt {
            lastSeenAt = date
        }
    }

    public func toItem() -> BranchBriefingItem {
        BranchBriefingItem(
            projectId: projectId,
            branch: branch,
            day: day,
            briefing: briefing,
            updatedAt: updatedAt,
            createdAt: createdAt
        )
    }
}

public extension Array where Element == BranchBriefingItem {
    /// All briefings for one branch merged into a single document, oldest day
    /// first, so consumers that need the whole branch story (PR text, code
    /// review, agent context) still see every day's work. Returns `nil` when
    /// the branch has no non-empty briefing.
    func combinedBriefing(projectId: UUID, branch: String) -> String? {
        let items = filter {
            $0.projectId == projectId
                && $0.branch == branch
                && !$0.briefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .sorted { ($0.day ?? $0.createdAt) < ($1.day ?? $1.createdAt) }
        guard !items.isEmpty else { return nil }
        guard items.count > 1 else { return items[0].briefing }
        return items.map { item in
            let date = (item.day ?? item.createdAt).formatted(date: .abbreviated, time: .omitted)
            return "## \(date)\n\n\(item.briefing.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        .joined(separator: "\n\n")
    }
}
