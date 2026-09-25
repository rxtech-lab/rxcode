import Foundation

// MARK: - TaskStatus

/// The four board columns a `ProjectTask` moves through.
///
/// Deliberately separate from `TodoItem.Status`: that enum mirrors the agent's
/// `TodoWrite` wire format and is scoped to a single streaming turn, whereas
/// these are user-owned states that outlive any thread.
public enum TaskStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case pending
    case inProgress = "in_progress"
    case pendingReview = "pending_review"
    case done

    public var displayName: LocalizedStringResource {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In Progress"
        case .pendingReview: return "Pending Review"
        case .done: return "Done"
        }
    }

    public var displayNameText: String {
        String(localized: displayName)
    }

    public var systemImage: String {
        switch self {
        case .pending: return "tray"
        case .inProgress: return "bolt.horizontal"
        case .pendingReview: return "eye"
        case .done: return "checkmark.circle"
        }
    }
}

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

// MARK: - ProjectStory

/// A parent container grouping related tasks. Stories carry no status of their
/// own — progress is rolled up from their children.
public struct ProjectStory: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var projectId: UUID
    public var title: String
    public var details: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        title: String,
        details: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.details = details
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
    public var agent: TaskAgentConfig
    /// Persisted through `Attachment.DTO` because `Attachment` itself is not `Codable`.
    public var attachments: [Attachment.DTO]
    /// The thread this task was dispatched into, set by `AppState.startTask`.
    /// `TaskBoardHook` matches on it to advance the task when the turn finishes.
    public var sessionKey: String?
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
        agent: TaskAgentConfig = TaskAgentConfig(),
        attachments: [Attachment.DTO] = [],
        sessionKey: String? = nil,
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
        self.agent = agent
        self.attachments = attachments
        self.sessionKey = sessionKey
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Tolerant decoding: every field except `id`/`title` falls back to a
    /// default so a board written by an older build keeps loading after new
    /// fields are added.
    private enum CodingKeys: String, CodingKey {
        case id, projectId, storyId, title, details, status, version, tags
        case agent, attachments, sessionKey, sortIndex, createdAt, updatedAt
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
        agent = try c.decodeIfPresent(TaskAgentConfig.self, forKey: .agent) ?? TaskAgentConfig()
        attachments = try c.decodeIfPresent([Attachment.DTO].self, forKey: .attachments) ?? []
        sessionKey = try c.decodeIfPresent(String.self, forKey: .sessionKey)
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
    public func agentPrompt(storyTitle: String?) -> String {
        var blocks: [String] = ["**Task:** \(title)"]

        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetails.isEmpty {
            blocks.append(trimmedDetails)
        }

        var context: [String] = []
        if let storyTitle, !storyTitle.isEmpty {
            context.append("- **Story:** \(storyTitle)")
        }
        if !tags.isEmpty {
            context.append("- **Tags:** \(tags.joined(separator: ", "))")
        }
        if let version, !version.isEmpty {
            context.append("- **Target version:** \(version)")
        }
        if !context.isEmpty {
            blocks.append(context.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n")
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

    /// Statuses the view shows, in board order.
    public var visibleStatuses: [TaskStatus] {
        statuses.isEmpty ? TaskStatus.allCases : TaskStatus.allCases.filter(statuses.contains)
    }

    public func matches(_ task: ProjectTask) -> Bool {
        if let version, !version.isEmpty, task.version != version { return false }
        if !tags.isEmpty, !tags.allSatisfy(task.tags.contains) { return false }
        if let storyId, task.storyId != storyId { return false }
        if !statuses.isEmpty, !statuses.contains(task.status) { return false }
        return true
    }

    /// Stories carry no tags or version, so a view constrained by either hides
    /// them rather than showing every story regardless.
    public func matches(_ story: ProjectStory, rolledUpStatus: TaskStatus) -> Bool {
        if !tags.isEmpty || !(version ?? "").isEmpty { return false }
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
        let haystack = [title, details, version ?? ""] + tags
        return haystack.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

public extension ProjectStory {
    func matches(keyword: String) -> Bool {
        let needle = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(needle)
            || details.localizedCaseInsensitiveContains(needle)
    }
}

// MARK: - StoryProgress

/// Rolled-up child completion for a story — the "5 / 6  83%" bar on a GitHub
/// parent issue.
public struct StoryProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
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

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = TaskBoard.currentSchemaVersion,
        stories: [ProjectStory] = [],
        tasks: [ProjectTask] = [],
        savedViews: [TaskSavedView] = []
    ) {
        self.schemaVersion = schemaVersion
        self.stories = stories
        self.tasks = tasks
        self.savedViews = savedViews
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, stories, tasks, savedViews
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? TaskBoard.currentSchemaVersion
        stories = try c.decodeIfPresent([ProjectStory].self, forKey: .stories) ?? []
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks) ?? []
        savedViews = try c.decodeIfPresent([TaskSavedView].self, forKey: .savedViews) ?? []
    }

    public func story(id: UUID?) -> ProjectStory? {
        guard let id else { return nil }
        return stories.first { $0.id == id }
    }

    /// Tasks in one column, in board order.
    public func tasks(in status: TaskStatus) -> [ProjectTask] {
        tasks.filter { $0.status == status }.sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Tasks belonging to one story.
    public func tasks(inStory storyId: UUID) -> [ProjectTask] {
        tasks.filter { $0.storyId == storyId }
    }

    public func progress(for story: ProjectStory) -> StoryProgress {
        let children = tasks(inStory: story.id)
        return StoryProgress(done: children.filter { $0.status == .done }.count, total: children.count)
    }

    /// A story's column, derived from its children: Done once every child is
    /// done, Pending while nothing has started, In Progress otherwise — except
    /// when all unfinished children await review.
    public func rolledUpStatus(for story: ProjectStory) -> TaskStatus {
        let children = tasks(inStory: story.id)
        guard !children.isEmpty else { return .pending }
        if children.allSatisfy({ $0.status == .done }) { return .done }
        if children.allSatisfy({ $0.status == .pending }) { return .pending }
        let open = children.filter { $0.status != .done }
        if open.allSatisfy({ $0.status == .pendingReview }) { return .pendingReview }
        return .inProgress
    }

    /// The views a project shows as tabs: its saved views, or the implicit
    /// default board when none have been created.
    public var effectiveViews: [TaskSavedView] {
        savedViews.isEmpty ? [TaskSavedView.defaultView] : savedViews
    }

    /// Every distinct tag used on the board, sorted for stable picker order.
    public var allTags: [String] {
        Array(Set(tasks.flatMap(\.tags))).sorted()
    }

    /// Every distinct version used on the board, newest-looking first.
    public var allVersions: [String] {
        Array(Set(tasks.compactMap(\.version)).filter { !$0.isEmpty }).sorted(by: >)
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
