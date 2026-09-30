import Foundation
import SwiftData

public struct ThreadSummaryItem: Identifiable, Sendable, Equatable {
    public var id: String { sessionId }

    public let sessionId: String
    public let projectId: UUID
    public let branch: String
    public let title: String
    public let summary: String
    public let updatedAt: Date
    /// When the chat itself was created. A chat belongs to the briefing of the
    /// day it was started. Records persisted before this was tracked fall back
    /// to `updatedAt`.
    public let createdAt: Date

    public init(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        summary: String,
        updatedAt: Date,
        createdAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.branch = branch
        self.title = title
        self.summary = summary
        self.updatedAt = updatedAt
        self.createdAt = createdAt ?? updatedAt
    }

    public static func titleSeed(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        updatedAt: Date = .now
    ) -> ThreadSummaryItem {
        ThreadSummaryItem(
            sessionId: sessionId,
            projectId: projectId,
            branch: branch,
            title: title,
            summary: "",
            updatedAt: updatedAt
        )
    }

    public func updatingTitle(projectId: UUID, branch: String, title: String, updatedAt: Date = .now) -> ThreadSummaryItem {
        ThreadSummaryItem(
            sessionId: sessionId,
            projectId: projectId,
            branch: branch,
            title: title,
            summary: summary,
            updatedAt: updatedAt,
            createdAt: createdAt
        )
    }
}

@Model
public final class ThreadSummaryRecord {
    @Attribute(.unique) public var sessionId: String
    public var projectId: UUID
    public var branch: String
    public var title: String
    public var summary: String
    public var updatedAt: Date
    /// Creation time of the chat this summary describes. Optional so existing
    /// stores migrate without a value; backfilled from the chat on launch.
    public var createdAt: Date?

    public init(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        summary: String,
        updatedAt: Date = .now,
        createdAt: Date? = nil
    ) {
        self.createdAt = createdAt
        self.sessionId = sessionId
        self.projectId = projectId
        self.branch = branch
        self.title = title
        self.summary = summary
        self.updatedAt = updatedAt
    }

    public func apply(projectId: UUID, branch: String, title: String, summary: String, updatedAt: Date = .now) {
        self.projectId = projectId
        self.branch = branch
        self.title = title
        self.summary = summary
        self.updatedAt = updatedAt
    }

    public func applyTitle(projectId: UUID, branch: String, title: String, updatedAt: Date = .now) {
        self.projectId = projectId
        self.branch = branch
        self.title = title
        self.updatedAt = updatedAt
    }

    public func toItem() -> ThreadSummaryItem {
        ThreadSummaryItem(
            sessionId: sessionId,
            projectId: projectId,
            branch: branch,
            title: title,
            summary: summary,
            updatedAt: updatedAt,
            createdAt: createdAt
        )
    }
}
