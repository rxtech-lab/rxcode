import Foundation
import SwiftData

public struct BranchBriefingItem: Identifiable, Sendable, Equatable {
    public var id: String { "\(projectId.uuidString)::\(branch)" }

    public let projectId: UUID
    public let branch: String
    public let briefing: String
    public let updatedAt: Date

    public init(projectId: UUID, branch: String, briefing: String, updatedAt: Date) {
        self.projectId = projectId
        self.branch = branch
        self.briefing = briefing
        self.updatedAt = updatedAt
    }
}

@Model
public final class BranchBriefingRecord {
    @Attribute(.unique) public var id: String
    public var projectId: UUID
    public var branch: String
    public var briefing: String
    public var updatedAt: Date
    /// Last time the branch was observed (e.g. as the current branch of its
    /// project, or when the briefing was regenerated). Used to garbage-collect
    /// briefings for branches that no longer exist locally or remotely.
    public var lastSeenAt: Date = Date.distantPast

    public init(
        projectId: UUID,
        branch: String,
        briefing: String,
        updatedAt: Date = .now,
        lastSeenAt: Date = .now
    ) {
        self.id = Self.makeId(projectId: projectId, branch: branch)
        self.projectId = projectId
        self.branch = branch
        self.briefing = briefing
        self.updatedAt = updatedAt
        self.lastSeenAt = lastSeenAt
    }

    public static func makeId(projectId: UUID, branch: String) -> String {
        "\(projectId.uuidString)::\(branch)"
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
            briefing: briefing,
            updatedAt: updatedAt
        )
    }
}
