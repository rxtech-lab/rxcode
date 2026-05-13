import Foundation
import SwiftData

@Model
public final class ChatThread {
    @Attribute(.unique) public var id: String
    public var projectId: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool

    public var cliSessionId: String?

    public var model: String?
    public var effort: String?
    public var permissionModeRaw: String?
    public var worktreePath: String?
    public var worktreeBranch: String?

    public init(
        id: String,
        projectId: UUID,
        title: String = ChatSession.defaultTitle,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        cliSessionId: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionModeRaw: String? = nil,
        worktreePath: String? = nil,
        worktreeBranch: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.cliSessionId = cliSessionId
        self.model = model
        self.effort = effort
        self.permissionModeRaw = permissionModeRaw
        self.worktreePath = worktreePath
        self.worktreeBranch = worktreeBranch
    }
}

extension ChatThread {
    public func toSummary() -> ChatSession.Summary {
        ChatSession.Summary(
            id: id,
            projectId: projectId,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: isPinned,
            model: model,
            effort: effort,
            permissionMode: permissionModeRaw.flatMap(PermissionMode.init(rawValue:)),
            origin: .cliBacked,
            worktreePath: worktreePath,
            worktreeBranch: worktreeBranch
        )
    }

    public func apply(_ summary: ChatSession.Summary) {
        title = summary.title
        updatedAt = summary.updatedAt
        isPinned = summary.isPinned
        model = summary.model
        effort = summary.effort
        permissionModeRaw = summary.permissionMode?.rawValue
        worktreePath = summary.worktreePath
        worktreeBranch = summary.worktreeBranch
    }

    public static func from(_ summary: ChatSession.Summary, cliSessionId: String? = nil) -> ChatThread {
        ChatThread(
            id: summary.id,
            projectId: summary.projectId,
            title: summary.title,
            createdAt: summary.createdAt,
            updatedAt: summary.updatedAt,
            isPinned: summary.isPinned,
            cliSessionId: cliSessionId,
            model: summary.model,
            effort: summary.effort,
            permissionModeRaw: summary.permissionMode?.rawValue,
            worktreePath: summary.worktreePath,
            worktreeBranch: summary.worktreeBranch
        )
    }
}
