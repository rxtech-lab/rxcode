import Foundation

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
public struct TaskFilterSnapshot: Codable, Sendable, Hashable {
    public var source: String
    public var tasks: [String]
    public var stories: [String]
    public init(source: String, tasks: [String], stories: [String]) {
        self.source = source
        self.tasks = tasks
        self.stories = stories
    }
}

public struct TaskSavedView: Identifiable, Codable, Sendable, Hashable {
    /// Per-column sorting syncs with this saved view. Device filters are stored separately.
    public var columnSorts: [String: TaskColumnSort] = [:]
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
    public var filterSnapshot: TaskFilterSnapshot?
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
        case id, name, layout, tags, versions, milestones, storyIds, statuses, filterScript, filterSnapshot, storyPanelStatuses, isDefault
        case columnSorts
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
        columnSorts = (try? c.decodeIfPresent([String: TaskColumnSort].self, forKey: .columnSorts)) ?? [:]
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
        filterSnapshot = try? c.decodeIfPresent(TaskFilterSnapshot.self, forKey: .filterSnapshot)
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
        try c.encode(columnSorts, forKey: .columnSorts)
        try c.encode(tags, forKey: .tags)
        try c.encode(versions, forKey: .versions)
        try c.encode(milestones, forKey: .milestones)
        try c.encode(storyIds, forKey: .storyIds)
        try c.encode(statuses, forKey: .statuses)
        try c.encodeIfPresent(filterSnapshot, forKey: .filterSnapshot)
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
