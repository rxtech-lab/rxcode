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

    /// Per-provider native session/resume ids for this thread, keyed by
    /// `AgentProvider.rawValue` and JSON-encoded. Lets a single thread carry a
    /// distinct backend session id per provider it has run under, so switching
    /// provider (e.g. Claude ↔ Codex) resumes each provider's own native
    /// session instead of feeding one provider another's id. Defaulted for
    /// clean SwiftData migration; deliberately kept out of `apply()`/`toSummary`
    /// (like `cliSessionId`) so summary upserts never wipe it.
    public var providerSessionIdsJSON: String? = nil

    public var agentProviderRaw: String?
    public var originRaw: String?
    public var model: String?
    public var effort: String?
    public var permissionModeRaw: String?
    public var worktreePath: String?
    public var worktreeBranch: String?

    public var isArchived: Bool = false
    public var archivedAt: Date?

    /// Id of the thread this thread was spawned from (e.g. a `[Code Review]`
    /// thread links back to the reviewed thread). Defaulted for clean migration.
    public var parentThreadId: String? = nil
    /// Short label chip shown in the UI (e.g. `"Code Review"`).
    public var threadLabel: String? = nil
    /// When true, lifecycle hooks are skipped for this thread.
    public var skipHooks: Bool = false
    /// Latest code-review verdict for this thread (set by `CodeReviewHook`):
    /// `true` = passed, `false` = found issues, `nil` = never reviewed. Persisted
    /// so the sidebar review dot survives an app reload. Defaulted for clean migration.
    public var reviewPassed: Bool? = nil

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
        archivedAt: Date? = nil,
        parentThreadId: String? = nil,
        threadLabel: String? = nil,
        skipHooks: Bool = false,
        reviewPassed: Bool? = nil
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
        self.parentThreadId = parentThreadId
        self.threadLabel = threadLabel
        self.skipHooks = skipHooks
        self.reviewPassed = reviewPassed
    }
}

extension ChatThread {
    /// Decoded view of `providerSessionIdsJSON`. Reads/writes the JSON blob so
    /// callers work with a plain `[providerRawValue: nativeSessionId]` map.
    public var providerSessionIds: [String: String] {
        get {
            guard let json = providerSessionIdsJSON,
                  let data = json.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return map
        }
        set {
            providerSessionIdsJSON = (try? JSONEncoder().encode(newValue))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

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
            archivedAt: archivedAt,
            parentThreadId: parentThreadId,
            threadLabel: threadLabel,
            skipHooks: skipHooks
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
        parentThreadId = summary.parentThreadId
        threadLabel = summary.threadLabel
        skipHooks = summary.skipHooks
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
            archivedAt: summary.archivedAt,
            parentThreadId: summary.parentThreadId,
            threadLabel: summary.threadLabel,
            skipHooks: summary.skipHooks
        )
    }
}
