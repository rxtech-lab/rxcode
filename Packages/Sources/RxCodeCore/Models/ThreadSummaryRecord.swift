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

    public init(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        summary: String,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.branch = branch
        self.title = title
        self.summary = summary
        self.updatedAt = updatedAt
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

    public init(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        summary: String,
        updatedAt: Date = .now
    ) {
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

    public func toItem() -> ThreadSummaryItem {
        ThreadSummaryItem(
            sessionId: sessionId,
            projectId: projectId,
            branch: branch,
            title: title,
            summary: summary,
            updatedAt: updatedAt
        )
    }
}
