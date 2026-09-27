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
    public static var defaults: [TaskItemType] {
        [
            TaskItemType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000071F1")!, name: String(localized: "Feature"), colorHex: "#3E63DD"),
            TaskItemType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000071F2")!, name: String(localized: "Bug"), colorHex: "#E5484D"),
            TaskItemType(id: UUID(uuidString: "00000000-0000-0000-0000-0000000071F3")!, name: String(localized: "Chore"), colorHex: "#8B8D98"),
        ]
    }
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
        case id, projectId, title, details, tags, version, milestone, priority, typeId
        case linkedProjectIds, createdAt, updatedAt
    }

    /// Tolerant decoding: stories written before the classification fields
    /// existed decode with them empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        version = try c.decodeIfPresent(String.self, forKey: .version)
        milestone = try c.decodeIfPresent(String.self, forKey: .milestone)
        priority = (try? c.decodeIfPresent(TaskPriority.self, forKey: .priority)) ?? nil
        typeId = try c.decodeIfPresent(UUID.self, forKey: .typeId)
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
    public var agent: TaskAgentConfig
    /// Persisted through `Attachment.DTO` because `Attachment` itself is not `Codable`.
    public var attachments: [Attachment.DTO]
    /// The thread this task was dispatched into, set by `AppState.startTask`.
    /// `TaskBoardHook` matches on it to advance the task when the turn finishes.
    public var sessionKey: String?
    /// The existing chat from which this task was created. This is not a run:
    /// it must not lock the description or participate in column triggers.
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
        case id, projectId, storyId, parentTaskId, parentTaskIds, assignedDeviceId, title, details, status, version, tags
        case milestone, priority, typeId
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
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .pending
        version = try c.decodeIfPresent(String.self, forKey: .version)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        milestone = try c.decodeIfPresent(String.self, forKey: .milestone)
        priority = (try? c.decodeIfPresent(TaskPriority.self, forKey: .priority)) ?? nil
        typeId = try c.decodeIfPresent(UUID.self, forKey: .typeId)
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
        try c.encode(title, forKey: .title)
        try c.encode(details, forKey: .details)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(milestone, forKey: .milestone)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(typeId, forKey: .typeId)
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

    /// The description is what the agent was prompted with, so it is frozen
    /// once the task has been dispatched.
    public var isDescriptionLocked: Bool { sessionKey != nil }

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

// MARK: - TaskPromptContent

/// A thread's user message split back into its parts, so the Run tab and the
/// chat message list can show a dispatched task as a card instead of raw
/// Markdown.
///
/// Understands the `ProjectTask.agentPrompt` layout and the attachment lines
/// `buildPromptWithAttachments` puts in front of it. Anything else (a typed
/// follow-up) parses with a nil `title` and the whole text as `body`.
public struct TaskPromptContent: Sendable, Hashable {
    public struct Field: Sendable, Hashable {
        public var label: String
        public var value: String
    }

    public struct Reference: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case file, image, link
        }

        public var kind: Kind
        public var value: String
    }

    /// Files and links attached to the message.
    public var references: [Reference]
    /// The task title, when the message is a dispatched task.
    public var title: String?
    /// The description, or a follow-up's full text. Markdown.
    public var body: String
    /// The trailing `- **Label:** value` context list.
    public var fields: [Field]

    public static func parse(_ text: String) -> TaskPromptContent {
        var lines = text.components(separatedBy: "\n")[...]
        var references: [Reference] = []
        while let line = lines.first, let reference = Self.reference(in: line) {
            references.append(reference)
            lines = lines.dropFirst()
        }

        let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks = rest.components(separatedBy: "\n\n")

        let titlePrefix = "**Task:** "
        guard let first = blocks.first, first.hasPrefix(titlePrefix), !first.contains("\n") else {
            return TaskPromptContent(references: references, title: nil, body: rest, fields: [])
        }
        let title = String(first.dropFirst(titlePrefix.count)).trimmingCharacters(in: .whitespaces)
        blocks.removeFirst()

        var fields: [Field] = []
        if let last = blocks.last {
            let parsed = last.components(separatedBy: "\n").map(Self.field(in:))
            if !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) {
                fields = parsed.compactMap { $0 }
                blocks.removeLast()
            }
        }

        let body = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskPromptContent(references: references, title: title, body: body, fields: fields)
    }

    /// The parse of `text` when it is a dispatched task message — a
    /// `**Task:**` heading followed by its context list — and `nil` for
    /// anything else, such as a typed follow-up that happens to use Markdown.
    /// Callers use this to decide between the task card and plain Markdown.
    public static func task(in text: String) -> TaskPromptContent? {
        let content = parse(text)
        return content.title == nil ? nil : content
    }

    /// `[Attached image: /path]`, `[Attached file: /path]` or `[Link: url]`.
    private static func reference(in line: String) -> Reference? {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        let inner = line.dropFirst().dropLast()
        if inner.hasPrefix("Link: ") {
            return Reference(kind: .link, value: String(inner.dropFirst("Link: ".count)))
        }
        guard inner.hasPrefix("Attached "), let colon = inner.range(of: ": ") else { return nil }
        let type = inner[inner.index(inner.startIndex, offsetBy: "Attached ".count)..<colon.lowerBound]
        return Reference(kind: type == "image" ? .image : .file, value: String(inner[colon.upperBound...]))
    }

    /// `- **Label:** value`.
    private static func field(in line: String) -> Field? {
        guard line.hasPrefix("- **"), let end = line.range(of: ":** ") else { return nil }
        let label = line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound]
        let value = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Field(label: String(label), value: value)
    }
}

// MARK: - TaskViewLayout

/// How a saved view renders its items — the GitHub Projects "Board" / "Table"
/// layouts.
public enum TaskViewLayout: String, Codable, Sendable, CaseIterable, Hashable {
    case board
    case table

    public var displayName: LocalizedStringResource {
        switch self {
        case .board: return "Board"
        case .table: return "Table"
        }
    }

    public var systemImage: String {
        switch self {
        case .board: return "rectangle.split.3x1"
        case .table: return "tablecells"
        }
    }
}

// MARK: - TaskSavedView

/// A customizable per-project view, shown as a tab on the project's task page
/// (the GitHub Projects "Backlog", "Priority board", "Team items" tabs).
///
/// Conditions are conjunctive — a task must pass every one that is set — and
/// multi-value conditions match any of their values: a task in any selected
/// story, targeting any selected version or milestone, and sitting in one of
/// the visible statuses. Tags are the exception: a task must carry every
/// selected tag.
public struct TaskSavedView: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var layout: TaskViewLayout
    public var tags: [String]
    /// Limits the view to these versions. Empty means every version.
    public var versions: [String]
    /// Limits the view to these milestones. Empty means every milestone.
    public var milestones: [String]
    /// Limits the view to these stories' tasks. Empty means every story.
    public var storyIds: [UUID]
    /// Visible statuses — board columns, or table rows. Empty means all.
    public var statuses: [TaskStatus]
    /// Agent-written Swift that further narrows the view; see
    /// `TaskFilterScript`. `nil` means no script.
    public var filterScript: String?
    /// Statuses the board's story panel shows, matched against each story's
    /// rolled-up status. Empty means every status the view's columns allow.
    public var storyPanelStatuses: [TaskStatus]
    /// The view a project opens on, and the one its dashboard card previews.
    /// At most one view per board carries it; see `TaskBoard.defaultView`.
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        layout: TaskViewLayout = .board,
        tags: [String] = [],
        versions: [String] = [],
        milestones: [String] = [],
        storyIds: [UUID] = [],
        statuses: [TaskStatus] = [],
        filterScript: String? = nil,
        storyPanelStatuses: [TaskStatus] = [],
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.tags = tags
        self.versions = versions
        self.milestones = milestones
        self.storyIds = storyIds
        self.statuses = statuses
        self.filterScript = filterScript
        self.storyPanelStatuses = storyPanelStatuses
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, layout, tags, versions, milestones, storyIds, statuses, filterScript, storyPanelStatuses, isDefault
        /// Single-value filters written before multi-select existed.
        case version, storyId
    }

    /// Tolerant decoding: views written before `layout` / `statuses` existed
    /// decode as an unfiltered board, and the legacy single `version` /
    /// `storyId` filters become one-element lists.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        layout = (try? c.decodeIfPresent(TaskViewLayout.self, forKey: .layout)) ?? .board
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        if let versions = try? c.decodeIfPresent([String].self, forKey: .versions) {
            self.versions = versions
        } else {
            let legacy = (try? c.decodeIfPresent(String.self, forKey: .version)) ?? nil
            versions = legacy.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        }
        milestones = (try? c.decodeIfPresent([String].self, forKey: .milestones)) ?? []
        if let storyIds = try? c.decodeIfPresent([UUID].self, forKey: .storyIds) {
            self.storyIds = storyIds
        } else {
            let legacy = (try? c.decodeIfPresent(UUID.self, forKey: .storyId)) ?? nil
            storyIds = legacy.map { [$0] } ?? []
        }
        statuses = (try? c.decodeIfPresent([TaskStatus].self, forKey: .statuses)) ?? []
        filterScript = try? c.decodeIfPresent(String.self, forKey: .filterScript)
        storyPanelStatuses = (try? c.decodeIfPresent([TaskStatus].self, forKey: .storyPanelStatuses)) ?? []
        isDefault = (try? c.decodeIfPresent(Bool.self, forKey: .isDefault)) ?? false
    }

    /// Also writes the legacy single-value keys when a list holds exactly one
    /// value, so an older build reading a synced view keeps that filter.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(layout, forKey: .layout)
        try c.encode(tags, forKey: .tags)
        try c.encode(versions, forKey: .versions)
        try c.encode(milestones, forKey: .milestones)
        try c.encode(storyIds, forKey: .storyIds)
        try c.encode(statuses, forKey: .statuses)
        try c.encodeIfPresent(filterScript, forKey: .filterScript)
        try c.encode(storyPanelStatuses, forKey: .storyPanelStatuses)
        if isDefault { try c.encode(isDefault, forKey: .isDefault) }
        if versions.count == 1 { try c.encode(versions[0], forKey: .version) }
        if storyIds.count == 1 { try c.encode(storyIds[0], forKey: .storyId) }
    }

    /// Stable id of the implicit view every project shows before the user
    /// creates one. Editing it persists it under the same id.
    public static let defaultViewId = UUID(uuidString: "00000000-0000-0000-0000-00000000B0A7")!

    public static var defaultView: TaskSavedView {
        TaskSavedView(id: defaultViewId, name: String(localized: "Board"), layout: .board)
    }

    /// A view with no constraints matches everything.
    public var isEmpty: Bool {
        tags.isEmpty && versions.isEmpty && milestones.isEmpty && storyIds.isEmpty && statuses.isEmpty
    }

    /// Columns the view shows, in board order. A view whose every chosen
    /// column was deleted shows the whole board rather than nothing.
    public func visibleColumns(in columns: [TaskColumn]) -> [TaskColumn] {
        let filtered = columns.filter { statuses.contains($0.id) }
        return statuses.isEmpty || filtered.isEmpty ? columns : filtered
    }

    /// Whether the board's story panel shows a story with this rolled-up status.
    public func storyPanelShows(_ rolledUpStatus: TaskStatus) -> Bool {
        storyPanelStatuses.isEmpty || storyPanelStatuses.contains(rolledUpStatus)
    }

    public func matches(_ task: ProjectTask) -> Bool {
        if !versions.isEmpty, !versions.contains(task.version ?? "") { return false }
        if !milestones.isEmpty, !milestones.contains(task.milestone ?? "") { return false }
        if !tags.isEmpty, !tags.allSatisfy(task.tags.contains) { return false }
        if !storyIds.isEmpty, !(task.storyId.map(storyIds.contains) ?? false) { return false }
        if !statuses.isEmpty, !statuses.contains(task.status) { return false }
        return true
    }

    /// Stories match on their own tags, version and milestone, like tasks;
    /// their status is the one rolled up from their children.
    public func matches(_ story: ProjectStory, rolledUpStatus: TaskStatus) -> Bool {
        if !versions.isEmpty, !versions.contains(story.version ?? "") { return false }
        if !milestones.isEmpty, !milestones.contains(story.milestone ?? "") { return false }
        if !tags.isEmpty, !tags.allSatisfy(story.tags.contains) { return false }
        if !storyIds.isEmpty, !storyIds.contains(story.id) { return false }
        if !statuses.isEmpty, !statuses.contains(rolledUpStatus) { return false }
        return true
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

// MARK: - StoryProgress

/// Rolled-up child completion for a story — the "5 / 6  83%" bar on a GitHub
/// parent issue.
public struct StoryProgress: Sendable, Hashable {
    public var done: Int
    /// Unfinished children that have been started — sitting in the first chat
    /// column or any column after it. Drawn as the pending segment of the bar.
    public var active: Int
    public var total: Int

    public init(done: Int, active: Int = 0, total: Int) {
        self.done = done
        self.active = active
        self.total = total
    }

    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    public var activeFraction: Double { total == 0 ? 0 : Double(active) / Double(total) }
    public var percent: Int { Int((fraction * 100).rounded()) }
}

/// A story's rolled-up progress and column, as computed by
/// `TaskBoard.storyRollups()`.
public struct StoryRollup: Sendable, Hashable {
    public var progress: StoryProgress
    public var status: TaskStatus

    public init(progress: StoryProgress, status: TaskStatus) {
        self.progress = progress
        self.status = status
    }
}

/// A board's columns resolved once, so rolling up many stories doesn't
/// re-resolve the column list for every child task.
private struct StoryRollupContext {
    let columns: [TaskColumn]
    let indexById: [TaskStatus: Int]
    let chatStartIndex: Int?

    init(board: TaskBoard) {
        columns = board.effectiveColumns
        indexById = Dictionary(
            columns.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        chatStartIndex = columns.firstIndex(where: \.triggersChat)
    }

    /// Board position of `status`; a status whose column was deleted counts
    /// as the first column, like `TaskBoard.column(for:)`.
    func index(of status: TaskStatus) -> Int { indexById[status] ?? 0 }

    func column(for status: TaskStatus) -> TaskColumn { columns[index(of: status)] }

    func progress(of children: [ProjectTask]) -> StoryProgress {
        var done = 0
        var active = 0
        for task in children {
            let index = index(of: task.status)
            if columns[index].countsAsDone {
                done += 1
            } else if let chatStartIndex, index >= chatStartIndex {
                active += 1
            }
        }
        return StoryProgress(done: done, active: active, total: children.count)
    }

    func status(of children: [ProjectTask]) -> TaskStatus {
        let statuses = children.map { columns[index(of: $0.status)].id }
        guard let first = statuses.first else { return columns[0].id }
        if Set(statuses).count == 1 { return first }
        let open = statuses.filter { !column(for: $0).countsAsDone }
        if open.isEmpty {
            return columns.first(where: \.countsAsDone)?.id ?? first
        }
        if Set(open).count == 1 { return open[0] }
        if let chatStartIndex { return columns[chatStartIndex].id }
        return open.max { index(of: $0) < index(of: $1) } ?? open[0]
    }
}

// MARK: - TaskBoard

/// One project's board. Persisted as `task_board/<projectId>.json`; the global
/// board shown in the UI is an in-memory aggregation across projects.
public struct TaskBoard: Codable, Sendable {
    public var schemaVersion: Int
    public var stories: [ProjectStory]
    public var tasks: [ProjectTask]
    public var savedViews: [TaskSavedView]
    /// Tag colors. A tag with no entry renders in the neutral color.
    public var labels: [TaskLabel]
    /// Customized item types. Empty means the board still offers
    /// `TaskItemType.defaults`; see `effectiveTypes`.
    public var itemTypes: [TaskItemType]
    /// Customized columns, in board order. Empty means the board still shows
    /// `TaskColumn.defaults`; see `effectiveColumns`.
    public var columns: [TaskColumn]
    /// Autopilot sync bookkeeping. `nil` for a local-only project's board.
    public var cloudSync: CloudBoardSyncState?

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = TaskBoard.currentSchemaVersion,
        stories: [ProjectStory] = [],
        tasks: [ProjectTask] = [],
        savedViews: [TaskSavedView] = [],
        labels: [TaskLabel] = [],
        itemTypes: [TaskItemType] = [],
        columns: [TaskColumn] = [],
        cloudSync: CloudBoardSyncState? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.stories = stories
        self.tasks = tasks
        self.savedViews = savedViews
        self.labels = labels
        self.itemTypes = itemTypes
        self.columns = columns
        self.cloudSync = cloudSync
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, stories, tasks, savedViews, labels, itemTypes, columns, cloudSync
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? TaskBoard.currentSchemaVersion
        stories = try c.decodeIfPresent([ProjectStory].self, forKey: .stories) ?? []
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks) ?? []
        savedViews = try c.decodeIfPresent([TaskSavedView].self, forKey: .savedViews) ?? []
        labels = try c.decodeIfPresent([TaskLabel].self, forKey: .labels) ?? []
        itemTypes = try c.decodeIfPresent([TaskItemType].self, forKey: .itemTypes) ?? []
        columns = try c.decodeIfPresent([TaskColumn].self, forKey: .columns) ?? []
        cloudSync = try? c.decodeIfPresent(CloudBoardSyncState.self, forKey: .cloudSync)
    }

    public func story(id: UUID?) -> ProjectStory? {
        guard let id else { return nil }
        return stories.first { $0.id == id }
    }

    /// Tasks in one column, in board order. Tasks whose column was deleted
    /// count as the first column's.
    public func tasks(in status: TaskStatus) -> [ProjectTask] {
        tasks.filter { resolvedStatus(of: $0) == status }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Tasks belonging to one story.
    public func tasks(inStory storyId: UUID) -> [ProjectTask] {
        tasks.filter { $0.storyId == storyId }
    }

    public func progress(for story: ProjectStory) -> StoryProgress {
        StoryRollupContext(board: self).progress(of: tasks(inStory: story.id))
    }

    /// A story's column, derived from its children:
    /// - no children → the first column;
    /// - every child finished → the first done column;
    /// - every child, or every unfinished child, in one column → that column;
    /// - otherwise the story is being worked on: the first chat column, or
    ///   the latest column an unfinished child has reached on a board without
    ///   one.
    public func rolledUpStatus(for story: ProjectStory) -> TaskStatus {
        StoryRollupContext(board: self).status(of: tasks(inStory: story.id))
    }

    /// `progress(for:)` and `rolledUpStatus(for:)` for every story, in one
    /// pass over the tasks. Views that show many stories and cards at once
    /// should use this rather than calling the per-story methods per card,
    /// which each rescan every task.
    public func storyRollups() -> [UUID: StoryRollup] {
        var children: [UUID: [ProjectTask]] = [:]
        for task in tasks {
            if let storyId = task.storyId { children[storyId, default: []].append(task) }
        }
        let context = StoryRollupContext(board: self)
        var rollups: [UUID: StoryRollup] = [:]
        rollups.reserveCapacity(stories.count)
        for story in stories {
            let storyTasks = children[story.id] ?? []
            rollups[story.id] = StoryRollup(
                progress: context.progress(of: storyTasks),
                status: context.status(of: storyTasks)
            )
        }
        return rollups
    }

    /// Every distinct tag on the board — used by a story or task, or given a
    /// color — sorted for stable picker order.
    public var allTags: [String] {
        Array(Set(tasks.flatMap(\.tags) + stories.flatMap(\.tags) + labels.map(\.name))).sorted()
    }

    /// Every distinct version used on the board, newest-looking first.
    public var allVersions: [String] {
        Array(Set(tasks.compactMap(\.version) + stories.compactMap(\.version)).filter { !$0.isEmpty })
            .sorted(by: >)
    }

    /// Every distinct milestone used on the board, sorted for picker order.
    public var allMilestones: [String] {
        Array(Set(tasks.compactMap(\.milestone) + stories.compactMap(\.milestone)).filter { !$0.isEmpty })
            .sorted()
    }

    /// The types this board offers: its customized list, or the defaults until
    /// the user edits them.
    public var effectiveTypes: [TaskItemType] {
        itemTypes.isEmpty ? TaskItemType.defaults : itemTypes
    }

    public func itemType(id: UUID?) -> TaskItemType? {
        guard let id else { return nil }
        return effectiveTypes.first { $0.id == id }
    }

    /// The color assigned to `tag`, or `nil` when it has none.
    public func labelColorHex(for tag: String) -> String? {
        labels.first { $0.name == tag }?.colorHex
    }
}

public struct ParentTaskGroup: Sendable {
    public let story: ProjectStory?
    public let tasks: [ProjectTask]

    public init(story: ProjectStory?, tasks: [ProjectTask]) {
        self.story = story
        self.tasks = tasks
    }
}

// MARK: - Sort index placement

public extension TaskBoard {
    /// The `sortIndex` a task should take when dropped into `status` between
    /// `after` and `before`. Midpoint placement keeps every other card untouched.
    static func sortIndex(
        between after: ProjectTask?,
        and before: ProjectTask?,
        in column: [ProjectTask]
    ) -> Double {
        switch (after, before) {
        case (nil, nil):
            return column.isEmpty ? 0 : (column.map(\.sortIndex).min() ?? 0) - 1
        case (let a?, nil):
            return a.sortIndex + 1
        case (nil, let b?):
            return b.sortIndex - 1
        case (let a?, let b?):
            return (a.sortIndex + b.sortIndex) / 2
        }
    }

    /// The `sortIndex` that appends to the end of `status`.
    func appendSortIndex(for status: TaskStatus) -> Double {
        (tasks(in: status).last?.sortIndex ?? 0) + 1
    }
}

// MARK: - Attachment persistence

public extension Attachment {
    /// The same attachment with inlined bytes dropped, for storing in a task
    /// board. `AttachmentFactory.fromFileURL` eagerly reads image data into
    /// memory, and persisting that as base64 would bloat the board JSON for no
    /// benefit — the file is still on disk and is re-read at send time.
    ///
    /// Attachments with no `path` (a pasted clipboard image, which exists only
    /// in memory until `resolvingClipboardImages` writes it out) are returned
    /// unchanged, since dropping their data would lose the image entirely.
    func persistableInTaskBoard() -> Attachment {
        guard !path.isEmpty else { return self }
        return Attachment(
            id: id,
            type: type,
            name: name,
            path: path,
            fileSize: fileSize,
            textContent: textContent,
            imageData: nil
        )
    }
}
