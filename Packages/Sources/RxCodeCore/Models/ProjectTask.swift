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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectId, title, details, tags, version, milestone, priority, typeId
        case createdAt, updatedAt
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
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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
    /// Ordering within a column. A `Double` so a drop between two neighbours is
    /// their midpoint and no renumbering pass is needed.
    public var sortIndex: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        storyId: UUID? = nil,
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
        sortIndex: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.storyId = storyId
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
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decoding: every field except `id`/`title` falls back to a
    /// default so a board written by an older build keeps loading after new
    /// fields are added.
    private enum CodingKeys: String, CodingKey {
        case id, projectId, storyId, title, details, status, version, tags
        case milestone, priority, typeId
        case agent, attachments, sessionKey, sourceSessionKey, attentionReason, sortIndex, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId) ?? UUID()
        storyId = try c.decodeIfPresent(UUID.self, forKey: .storyId)
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
        sortIndex = try c.decodeIfPresent(Double.self, forKey: .sortIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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
/// Filters are conjunctive: a task must carry every tag, match the version,
/// belong to the story, and sit in one of the visible statuses.
public struct TaskSavedView: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var layout: TaskViewLayout
    public var tags: [String]
    public var version: String?
    /// Limits the view to one story's tasks. `nil` means every story.
    public var storyId: UUID?
    /// Visible statuses — board columns, or table rows. Empty means all.
    public var statuses: [TaskStatus]

    public init(
        id: UUID = UUID(),
        name: String,
        layout: TaskViewLayout = .board,
        tags: [String] = [],
        version: String? = nil,
        storyId: UUID? = nil,
        statuses: [TaskStatus] = []
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.tags = tags
        self.version = version
        self.storyId = storyId
        self.statuses = statuses
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, layout, tags, version, storyId, statuses
    }

    /// Tolerant decoding: views written before `layout` / `storyId` /
    /// `statuses` existed decode as an unfiltered board.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        layout = (try? c.decodeIfPresent(TaskViewLayout.self, forKey: .layout)) ?? .board
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        version = try c.decodeIfPresent(String.self, forKey: .version)
        storyId = try c.decodeIfPresent(UUID.self, forKey: .storyId)
        statuses = (try? c.decodeIfPresent([TaskStatus].self, forKey: .statuses)) ?? []
    }

    /// Stable id of the implicit view every project shows before the user
    /// creates one. Editing it persists it under the same id.
    public static let defaultViewId = UUID(uuidString: "00000000-0000-0000-0000-00000000B0A7")!

    public static var defaultView: TaskSavedView {
        TaskSavedView(id: defaultViewId, name: String(localized: "Board"), layout: .board)
    }

    /// A view with no constraints matches everything.
    public var isEmpty: Bool {
        tags.isEmpty && (version ?? "").isEmpty && storyId == nil && statuses.isEmpty
    }

    /// Columns the view shows, in board order. A view whose every chosen
    /// column was deleted shows the whole board rather than nothing.
    public func visibleColumns(in columns: [TaskColumn]) -> [TaskColumn] {
        let filtered = columns.filter { statuses.contains($0.id) }
        return statuses.isEmpty || filtered.isEmpty ? columns : filtered
    }

    public func matches(_ task: ProjectTask) -> Bool {
        if let version, !version.isEmpty, task.version != version { return false }
        if !tags.isEmpty, !tags.allSatisfy(task.tags.contains) { return false }
        if let storyId, task.storyId != storyId { return false }
        if !statuses.isEmpty, !statuses.contains(task.status) { return false }
        return true
    }

    /// Stories match on their own tags and version, like tasks; their status is
    /// the one rolled up from their children.
    public func matches(_ story: ProjectStory, rolledUpStatus: TaskStatus) -> Bool {
        if let version, !version.isEmpty, story.version != version { return false }
        if !tags.isEmpty, !tags.allSatisfy(story.tags.contains) { return false }
        if let storyId, story.id != storyId { return false }
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

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = TaskBoard.currentSchemaVersion,
        stories: [ProjectStory] = [],
        tasks: [ProjectTask] = [],
        savedViews: [TaskSavedView] = [],
        labels: [TaskLabel] = [],
        itemTypes: [TaskItemType] = [],
        columns: [TaskColumn] = []
    ) {
        self.schemaVersion = schemaVersion
        self.stories = stories
        self.tasks = tasks
        self.savedViews = savedViews
        self.labels = labels
        self.itemTypes = itemTypes
        self.columns = columns
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, stories, tasks, savedViews, labels, itemTypes, columns
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
        let children = tasks(inStory: story.id)
        let done = children.filter { column(for: $0.status).countsAsDone }.count
        let startIndex = firstChatColumn.map { columnIndex(of: $0.id) }
        let active = children.filter { task in
            let status = resolvedStatus(of: task)
            guard !column(for: status).countsAsDone, let startIndex else { return false }
            return columnIndex(of: status) >= startIndex
        }.count
        return StoryProgress(done: done, active: active, total: children.count)
    }

    /// A story's column, derived from its children:
    /// - no children → the first column;
    /// - every child finished → the first done column;
    /// - every child, or every unfinished child, in one column → that column;
    /// - otherwise the story is being worked on: the first chat column, or
    ///   the latest column an unfinished child has reached on a board without
    ///   one.
    public func rolledUpStatus(for story: ProjectStory) -> TaskStatus {
        let children = tasks(inStory: story.id).map(resolvedStatus(of:))
        guard !children.isEmpty else { return firstColumn.id }
        let columns = effectiveColumns
        if Set(children).count == 1 { return children[0] }
        let open = children.filter { !column(for: $0).countsAsDone }
        if open.isEmpty {
            return columns.first(where: \.countsAsDone)?.id ?? children[0]
        }
        if Set(open).count == 1 { return open[0] }
        return firstChatColumn?.id
            ?? open.max { columnIndex(of: $0) < columnIndex(of: $1) }
            ?? open[0]
    }

    /// The views a project shows as tabs: its saved views, or the implicit
    /// default board when none have been created.
    public var effectiveViews: [TaskSavedView] {
        savedViews.isEmpty ? [TaskSavedView.defaultView] : savedViews
    }

    /// The view-tab order after dropping `view` onto `target`'s tab: the
    /// dragged tab takes the target's slot, like `columnOrder(moving:to:)`.
    /// `nil` when the drop is a no-op or either id isn't a tab.
    public func viewOrder(moving view: UUID, to target: UUID) -> [TaskSavedView]? {
        var order = effectiveViews
        guard view != target,
              let from = order.firstIndex(where: { $0.id == view }),
              let to = order.firstIndex(where: { $0.id == target })
        else { return nil }
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        return order
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
