import Foundation

// MARK: - TaskAgentConfig

/// The agent assignment carried by a task.
///
/// Field-for-field the per-session override set on `WindowState`
/// (`sessionAgentProvider` / `sessionModel` / `sessionEffort` /
/// `sessionPermissionMode` / `sessionPlanMode`), so running a task is a matter
/// of copying these onto the window rather than adding new send plumbing.
public struct TaskAgentConfig: Codable, Sendable, Hashable {
    public var provider: AgentProvider?
    public var model: String?
    /// A `ReasoningLevel.id`, not an enum — the legal set is provider-dependent
    /// and fetched at runtime, so this must be re-validated through
    /// `AppState.sanitizedEffort(_:for:)` before it reaches a backend.
    public var effort: String?
    /// Excludes `.plan`; plan mode is the separate `planMode` flag below, matching
    /// every other permission picker in the app.
    public var permissionMode: PermissionMode?
    /// Orthogonal to `permissionMode` — when true the CLI is launched with
    /// `--permission-mode plan` regardless of the dropdown selection.
    public var planMode: Bool

    public init(
        provider: AgentProvider? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: PermissionMode? = nil,
        planMode: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.planMode = planMode
    }

    /// Whether the task has enough of an assignment to be run automatically.
    public var isAssigned: Bool { provider != nil || model != nil }
}

// MARK: - TaskPriority

/// How urgent a story or task is. Fixed levels with fixed colors, so priority
/// reads the same on every board.
public enum TaskPriority: String, Codable, Sendable, CaseIterable, Hashable {
    case urgent
    case high
    case medium
    case low

    public var displayName: LocalizedStringResource {
        switch self {
        case .urgent: return "Urgent"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    public var displayNameText: String {
        String(localized: displayName)
    }

    /// Distinct glyph per level, so priority reads without relying on color.
    public var systemImage: String {
        switch self {
        case .urgent: return "exclamationmark.square.fill"
        case .high: return "chevron.up.2"
        case .medium: return "equal"
        case .low: return "chevron.down"
        }
    }

    public var colorHex: String {
        switch self {
        case .urgent: return "#E5484D"
        case .high: return "#F76B15"
        case .medium: return "#E2A336"
        case .low: return "#8B8D98"
        }
    }

    /// Lower sorts first: urgent work leads a priority-sorted list.
    public var rank: Int {
        TaskPriority.allCases.firstIndex(of: self) ?? 0
    }
}

// MARK: - TaskItemType

/// A user-defined kind of work (Feature, Bug, Chore…) with its own color.
/// Stories and tasks reference a type by `id`, so renaming or recoloring a
/// type updates every item that uses it.
public struct TaskItemType: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    /// `#RRGGBB`.
    public var colorHex: String

    public init(id: UUID = UUID(), name: String, colorHex: String = TaskLabel.defaultColorHex) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? TaskLabel.defaultColorHex
    }

    /// The types a board starts with. Stable ids, so an item typed before the
    /// user customized anything keeps its type once the list is persisted.
    public static let defaults: [TaskItemType] = [
        TaskItemType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000071F1")!, name: String(localized: "Feature"), colorHex: "#3E63DD"),
        TaskItemType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000071F2")!, name: String(localized: "Bug"), colorHex: "#E5484D"),
        TaskItemType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000071F3")!, name: String(localized: "Chore"), colorHex: "#8B8D98"),
    ]
}

// MARK: - TaskLabel

/// The color assigned to a tag. Items still store tags as plain strings — a
/// label only adds styling, matched by name — so older boards need no
/// migration and a tag without a label renders in the neutral color.
public struct TaskLabel: Identifiable, Codable, Sendable, Hashable {
    public var name: String
    /// `#RRGGBB`.
    public var colorHex: String

    public var id: String { name }

    public init(name: String, colorHex: String = TaskLabel.defaultColorHex) {
        self.name = name
        self.colorHex = colorHex
    }

    public static let defaultColorHex = "#8B8D98"

    /// Starting colors for new labels and types, cycled so consecutive new
    /// entries don't all start the same color.
    public static let palette: [String] = [
        "#3E63DD", "#30A46C", "#E5484D", "#F76B15", "#E2A336",
        "#8E4EC6", "#D6409F", "#12A594", "#0090FF", "#8B8D98",
    ]
}

// MARK: - ProjectStory

/// A parent container grouping related tasks. Stories carry no status of their
/// own — progress is rolled up from their children — but share the task's
/// classification fields.
public struct ProjectStory: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var projectId: UUID
    public var assigneeProfiles: [CardAssignee] = []
    public var assigneeIds: [String] = []
    public var title: String
    public var details: String
    /// Free-form multi-select labels, colored through `TaskBoard.labels`.
    public var tags: [String]
    /// Single-select release marker, e.g. `v1.3.0`.
    public var version: String?
    /// Free-form grouping above versions, e.g. `Beta launch`.
    public var milestone: String?
    public var priority: TaskPriority?
    /// A `TaskItemType.id` from the owning board.
    public var typeId: UUID?
    /// When the story should be finished.
    public var deadline: Date?
    /// The estimated amount of work.
    public var size: TaskSize?
    /// Every recorded slip, oldest first.
    public var delays: [TaskDelay] = []
    /// Other projects that share this story. A linked story is mirrored, under
    /// the same id, onto every linked project's board, so each board groups
    /// and rolls up its own tasks under it; shared fields stay in sync across
    /// the copies.
    public var linkedProjectIds: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        title: String,
        details: String = "",
        tags: [String] = [],
        version: String? = nil,
        milestone: String? = nil,
        priority: TaskPriority? = nil,
        typeId: UUID? = nil,
        linkedProjectIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.details = details
        self.tags = tags
        self.version = version
        self.milestone = milestone
        self.priority = priority
        self.typeId = typeId
        self.linkedProjectIds = linkedProjectIds.filter { $0 != projectId }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case assigneeProfiles, assigneeIds
        case id, projectId, title, details, tags, version, milestone, priority, typeId
        case deadline, size, delays
        case linkedProjectIds, createdAt, updatedAt
    }

    /// Tolerant decoding: stories written before the classification fields
    /// existed decode with them empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId) ?? UUID()
        assigneeProfiles = try c.decodeIfPresent([CardAssignee].self, forKey: .assigneeProfiles) ?? []
        assigneeIds = try c.decodeIfPresent([String].self, forKey: .assigneeIds) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        version = try c.decodeIfPresent(String.self, forKey: .version)
        milestone = try c.decodeIfPresent(String.self, forKey: .milestone)
        priority = (try? c.decodeIfPresent(TaskPriority.self, forKey: .priority)) ?? nil
        typeId = try c.decodeIfPresent(UUID.self, forKey: .typeId)
        deadline = try? c.decodeIfPresent(Date.self, forKey: .deadline)
        size = (try? c.decodeIfPresent(TaskSize.self, forKey: .size)) ?? nil
        delays = (try? c.decodeIfPresent([TaskDelay].self, forKey: .delays)) ?? []
        linkedProjectIds = (try? c.decodeIfPresent([UUID].self, forKey: .linkedProjectIds)) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// Every project whose board holds a copy of this story, this one first.
    public var projectGroup: [UUID] {
        var seen: Set<UUID> = []
        return ([projectId] + linkedProjectIds).filter { seen.insert($0).inserted }
    }

    /// Whether the story is shared with at least one other project.
    public var isShared: Bool { !linkedProjectIds.isEmpty }

    /// This story's copy for another project in its group: the shared fields
    /// are carried over, while the owning project, the link list, and the
    /// board-local item type are rewritten for the target board.
    public func mirrored(into targetProjectId: UUID, group: [UUID], typeId: UUID?) -> ProjectStory {
        var copy = self
        copy.projectId = targetProjectId
        copy.linkedProjectIds = group.filter { $0 != targetProjectId }
        copy.typeId = typeId
        return copy
    }
}

// MARK: - ProjectTask

/// A single unit of work on the board.
///
/// Named `ProjectTask` rather than `Task` to avoid colliding with
/// `Swift.Task`, and rather than `Todo`/`Plan` to stay clear of the agent todo
/// list and the plan-mode approval artifact.
public struct ProjectTask: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var projectId: UUID
    public var storyId: UUID?
    /// Every task that must be ready before this task starts. Parents may
    /// belong to other projects.
    public var parentTaskIds: [UUID]
    /// Compatibility for single-parent callers and older cloud payloads.
    public var parentTaskId: UUID? {
        get { parentTaskIds.first }
        set { parentTaskIds = newValue.map { [$0] } ?? [] }
    }
    /// The Autopilot laptop assigned to this task. Nil means unassigned.
    public var assignedDeviceId: String?
    public var assigneeProfiles: [CardAssignee] = []
    public var assigneeIds: [String] = []
    public var title: String
    public var details: String
    public var status: TaskStatus
    /// Single-select release marker, e.g. `v1.3.0`.
    public var version: String?
    /// Free-form multi-select labels; also the basis for saved views.
    public var tags: [String]
    /// Free-form grouping above versions, e.g. `Beta launch`.
    public var milestone: String?
    public var priority: TaskPriority?
    /// A `TaskItemType.id` from the owning board.
    public var typeId: UUID?
    /// When the task should be finished.
    public var deadline: Date?
    /// The estimated amount of work.
    public var size: TaskSize?
    /// Every recorded slip, oldest first.
    public var delays: [TaskDelay] = []
    /// Who moved the task from Pending Review to done. Set by
    /// `TaskBoard.stampingReviewer` (or Autopilot for cloud boards).
    public var reviewer: CardAssignee?
    public var agent: TaskAgentConfig
    /// Persisted through `Attachment.DTO` because `Attachment` itself is not `Codable`.
    public var attachments: [Attachment.DTO]
    /// The thread this task was dispatched into, set by `AppState.startTask`.
    /// `TaskBoardHook` matches on it to advance the task when the turn finishes.
    public var sessionKey: String?
    /// The existing chat from which this task was created. This is not a run:
    /// it must not participate in column triggers.
    public var sourceSessionKey: String?
    /// Why the last run needs a person's attention before review. Cleared when
    /// a later completion check passes or the task is run again.
    public var attentionReason: String?
    /// Waiting in a chat column for a free run slot: the column already runs
    /// as many tasks as its `TaskColumn.concurrencyLimit` allows. Queued tasks
    /// start in `sortIndex` order as running ones leave.
    public var isQueued: Bool
    /// Ordering within a column. A `Double` so a drop between two neighbours is
    /// their midpoint and no renumbering pass is needed.
    public var sortIndex: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        storyId: UUID? = nil,
        parentTaskId: UUID? = nil,
        parentTaskIds: [UUID]? = nil,
        assignedDeviceId: String? = nil,
        title: String,
        details: String = "",
        status: TaskStatus = .pending,
        version: String? = nil,
        tags: [String] = [],
        milestone: String? = nil,
        priority: TaskPriority? = nil,
        typeId: UUID? = nil,
        agent: TaskAgentConfig = TaskAgentConfig(),
        attachments: [Attachment.DTO] = [],
        sessionKey: String? = nil,
        sourceSessionKey: String? = nil,
        attentionReason: String? = nil,
        isQueued: Bool = false,
        sortIndex: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.storyId = storyId
        self.parentTaskIds = Self.uniqueParentIDs(parentTaskIds ?? parentTaskId.map { [$0] } ?? [])
        self.assignedDeviceId = assignedDeviceId
        self.title = title
        self.details = details
        self.status = status
        self.version = version
        self.tags = tags
        self.milestone = milestone
        self.priority = priority
        self.typeId = typeId
        self.agent = agent
        self.attachments = attachments
        self.sessionKey = sessionKey
        self.sourceSessionKey = sourceSessionKey
        self.attentionReason = attentionReason
        self.isQueued = isQueued
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decoding: every field except `id`/`title` falls back to a
    /// default so a board written by an older build keeps loading after new
    /// fields are added.
    private enum CodingKeys: String, CodingKey {
        case assigneeProfiles, assigneeIds
        case id, projectId, storyId, parentTaskId, parentTaskIds, assignedDeviceId, title, details, status, version, tags
        case milestone, priority, typeId
        case deadline, size, delays, reviewer
        case agent, attachments, sessionKey, sourceSessionKey, attentionReason, isQueued, sortIndex, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId) ?? UUID()
        storyId = try c.decodeIfPresent(UUID.self, forKey: .storyId)
        let legacyParent = try c.decodeIfPresent(UUID.self, forKey: .parentTaskId)
        let savedParents = try c.decodeIfPresent([UUID].self, forKey: .parentTaskIds)
        parentTaskIds = Self.uniqueParentIDs(savedParents ?? legacyParent.map { [$0] } ?? [])
        assignedDeviceId = try c.decodeIfPresent(String.self, forKey: .assignedDeviceId)
        assigneeProfiles = try c.decodeIfPresent([CardAssignee].self, forKey: .assigneeProfiles) ?? []
        assigneeIds = try c.decodeIfPresent([String].self, forKey: .assigneeIds) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .pending
        version = try c.decodeIfPresent(String.self, forKey: .version)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        milestone = try c.decodeIfPresent(String.self, forKey: .milestone)
        priority = (try? c.decodeIfPresent(TaskPriority.self, forKey: .priority)) ?? nil
        typeId = try c.decodeIfPresent(UUID.self, forKey: .typeId)
        deadline = try? c.decodeIfPresent(Date.self, forKey: .deadline)
        size = (try? c.decodeIfPresent(TaskSize.self, forKey: .size)) ?? nil
        delays = (try? c.decodeIfPresent([TaskDelay].self, forKey: .delays)) ?? []
        reviewer = try? c.decodeIfPresent(CardAssignee.self, forKey: .reviewer)
        agent = try c.decodeIfPresent(TaskAgentConfig.self, forKey: .agent) ?? TaskAgentConfig()
        attachments = try c.decodeIfPresent([Attachment.DTO].self, forKey: .attachments) ?? []
        sessionKey = try c.decodeIfPresent(String.self, forKey: .sessionKey)
        sourceSessionKey = try c.decodeIfPresent(String.self, forKey: .sourceSessionKey)
        attentionReason = try c.decodeIfPresent(String.self, forKey: .attentionReason)
        isQueued = try c.decodeIfPresent(Bool.self, forKey: .isQueued) ?? false
        sortIndex = try c.decodeIfPresent(Double.self, forKey: .sortIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private static func uniqueParentIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectId, forKey: .projectId)
        try c.encodeIfPresent(storyId, forKey: .storyId)
        try c.encodeIfPresent(parentTaskId, forKey: .parentTaskId)
        try c.encode(parentTaskIds, forKey: .parentTaskIds)
        try c.encodeIfPresent(assignedDeviceId, forKey: .assignedDeviceId)
        try c.encode(assigneeProfiles, forKey: .assigneeProfiles)
        try c.encode(assigneeIds, forKey: .assigneeIds)
        try c.encode(title, forKey: .title)
        try c.encode(details, forKey: .details)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(milestone, forKey: .milestone)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(typeId, forKey: .typeId)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encodeIfPresent(size, forKey: .size)
        if !delays.isEmpty { try c.encode(delays, forKey: .delays) }
        try c.encodeIfPresent(reviewer, forKey: .reviewer)
        try c.encode(agent, forKey: .agent)
        try c.encode(attachments, forKey: .attachments)
        try c.encodeIfPresent(sessionKey, forKey: .sessionKey)
        try c.encodeIfPresent(sourceSessionKey, forKey: .sourceSessionKey)
        try c.encodeIfPresent(attentionReason, forKey: .attentionReason)
        if isQueued { try c.encode(isQueued, forKey: .isQueued) }
        try c.encode(sortIndex, forKey: .sortIndex)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// The prompt handed to the agent when the task is dispatched, also shown
    /// as the thread's first user message.
    ///
    /// Markdown, because the chat renders it: blocks are separated by blank
    /// lines and the context is a list, since single newlines would collapse
    /// into one run-on line.
    ///
    ///     **Task:** Translate untranslated terms
    ///
    ///     <description>
    ///
    ///     - **Story:** I18n
    ///     - **Tags:** i18n
    ///     - **Target version:** v1.3.0
    public func agentPrompt(storyTitle: String?, typeName: String? = nil) -> String {
        var blocks: [String] = ["**Task:** \(title)"]

        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetails.isEmpty {
            blocks.append(trimmedDetails)
        }

        var context: [String] = []
        if let storyTitle, !storyTitle.isEmpty {
            context.append("- **Story:** \(storyTitle)")
        }
        if let typeName, !typeName.isEmpty {
            context.append("- **Type:** \(typeName)")
        }
        if let priority {
            context.append("- **Priority:** \(priority.displayNameText)")
        }
        if !tags.isEmpty {
            context.append("- **Tags:** \(tags.joined(separator: ", "))")
        }
        if let version, !version.isEmpty {
            context.append("- **Target version:** \(version)")
        }
        if let milestone, !milestone.isEmpty {
            context.append("- **Milestone:** \(milestone)")
        }
        if let size {
            context.append("- **Size:** \(size.displayNameText)")
        }
        if let deadline {
            context.append("- **Deadline:** \(deadline.formatted(date: .abbreviated, time: .shortened))")
        }
        if let fixPrompt = checkErrorFixPrompt {
            blocks.append(fixPrompt)
        }
        if !context.isEmpty {
            blocks.append(context.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
    }

    /// The full check result to send when asking the task's agent to fix it.
    public var checkErrorFixPrompt: String? {
        guard let reason = attentionReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return "Fix the issue found by the task completion check, then verify the task again:\n\n\(reason)"
    }
}

// MARK: - Keyword filtering

public extension ProjectTask {
    /// Case-insensitive match over title, details, tags and version. An empty
    /// keyword matches everything.
    func matches(keyword: String) -> Bool {
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = [title, details, version ?? "", milestone ?? ""] + tags
        return haystack.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

public extension ProjectStory {
    func matches(keyword: String) -> Bool {
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let haystack = [title, details, version ?? "", milestone ?? ""] + tags
        return haystack.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
