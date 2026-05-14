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

    public var agentProviderRaw: String?
    public var originRaw: String?
    public var model: String?
    public var effort: String?
    public var permissionModeRaw: String?
    public var worktreePath: String?
    public var worktreeBranch: String?

    public var isArchived: Bool = false
    public var archivedAt: Date?

    public init(
        id: String,
        projectId: UUID,
        title: String = ChatSession.defaultTitle,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        cliSessionId: String? = nil,
        agentProviderRaw: String? = AgentProvider.claudeCode.rawValue,
        originRaw: String? = SessionOrigin.cliBacked.rawValue,
        model: String? = nil,
        effort: String? = nil,
        permissionModeRaw: String? = nil,
        worktreePath: String? = nil,
        worktreeBranch: String? = nil,
        isArchived: Bool = false,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.cliSessionId = cliSessionId
        self.agentProviderRaw = agentProviderRaw
        self.originRaw = originRaw
        self.model = model
        self.effort = effort
        self.permissionModeRaw = permissionModeRaw
        self.worktreePath = worktreePath
        self.worktreeBranch = worktreeBranch
        self.isArchived = isArchived
        self.archivedAt = archivedAt
    }
}

extension ChatThread {
    public func toSummary() -> ChatSession.Summary {
        let agentProvider = agentProviderRaw.flatMap(AgentProvider.init(rawValue:)) ?? .claudeCode
        let origin = originRaw.flatMap(SessionOrigin.init(rawValue:))
            ?? (agentProvider == .codex ? .codexAppServer : .cliBacked)

        return ChatSession.Summary(
            id: id,
            projectId: projectId,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: isPinned,
            agentProvider: agentProvider,
            model: model,
            effort: effort,
            permissionMode: permissionModeRaw.flatMap(PermissionMode.init(rawValue:)),
            origin: origin,
            worktreePath: worktreePath,
            worktreeBranch: worktreeBranch,
            isArchived: isArchived,
            archivedAt: archivedAt
        )
    }

    public func apply(_ summary: ChatSession.Summary) {
        title = summary.title
        updatedAt = summary.updatedAt
        isPinned = summary.isPinned
        agentProviderRaw = summary.agentProvider.rawValue
        originRaw = summary.origin.rawValue
        model = summary.model
        effort = summary.effort
        permissionModeRaw = summary.permissionMode?.rawValue
        worktreePath = summary.worktreePath
        worktreeBranch = summary.worktreeBranch
        isArchived = summary.isArchived
        archivedAt = summary.archivedAt
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
            agentProviderRaw: summary.agentProvider.rawValue,
            originRaw: summary.origin.rawValue,
            model: summary.model,
            effort: summary.effort,
            permissionModeRaw: summary.permissionMode?.rawValue,
            worktreePath: summary.worktreePath,
            worktreeBranch: summary.worktreeBranch,
            isArchived: summary.isArchived,
            archivedAt: summary.archivedAt
        )
    }
}
