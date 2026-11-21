import Foundation

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
    /// Registered values remain available before a task or story uses them.
    public var versions: [String]
    public var milestones: [String]
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
        versions: [String] = [],
        milestones: [String] = [],
        itemTypes: [TaskItemType] = [],
        columns: [TaskColumn] = [],
        cloudSync: CloudBoardSyncState? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.stories = stories
        self.tasks = tasks
        self.savedViews = savedViews
        self.labels = labels
        self.versions = versions
        self.milestones = milestones
        self.itemTypes = itemTypes
        self.columns = columns
        self.cloudSync = cloudSync
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, stories, tasks, savedViews, labels, versions, milestones, itemTypes, columns, cloudSync
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? TaskBoard.currentSchemaVersion
        stories = try c.decodeIfPresent([ProjectStory].self, forKey: .stories) ?? []
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks) ?? []
        savedViews = try c.decodeIfPresent([TaskSavedView].self, forKey: .savedViews) ?? []
        labels = try c.decodeIfPresent([TaskLabel].self, forKey: .labels) ?? []
        versions = try c.decodeIfPresent([String].self, forKey: .versions) ?? []
        milestones = try c.decodeIfPresent([String].self, forKey: .milestones) ?? []
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

    /// When each story was last touched — its own edit or any of its tasks'
    /// — in one pass over the tasks. Finished stories age off the board's
    /// story panel by this date, so a story whose last task just finished
    /// stays in view.
    public func storyLastActivity() -> [UUID: Date] {
        var dates = Dictionary(stories.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: max)
        for task in tasks {
            guard let storyId = task.storyId, let current = dates[storyId] else { continue }
            if task.updatedAt > current { dates[storyId] = task.updatedAt }
        }
        return dates
    }

    /// Every distinct tag on the board — used by a story or task, or given a
    /// color — sorted for stable picker order.
    public var allTags: [String] {
        Array(Set(tasks.flatMap(\.tags) + stories.flatMap(\.tags) + labels.map(\.name))).sorted()
    }

    /// Registered and used versions, newest-looking first.
    public var allVersions: [String] {
        Array(Set(versions + tasks.compactMap(\.version) + stories.compactMap(\.version)).filter { !$0.isEmpty })
            .sorted(by: >)
    }

    /// Registered and used milestones, sorted for picker order.
    public var allMilestones: [String] {
        Array(Set(milestones + tasks.compactMap(\.milestone) + stories.compactMap(\.milestone)).filter { !$0.isEmpty })
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
