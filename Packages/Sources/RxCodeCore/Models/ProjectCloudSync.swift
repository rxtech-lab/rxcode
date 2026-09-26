import Foundation

// MARK: - Cloud projects

/// A project stored in Autopilot (a github-pm `docsRepository`). A local
/// `Project` whose `cloudId` names one of these syncs its task board through
/// Autopilot to every device signed in to the same account.
public struct CloudProject: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    /// `"standalone"` or `"github"`.
    public var type: String?
    public var name: String?
    public var displayName: String?
    public var description: String?
    /// `owner/repo` for GitHub-backed projects.
    public var repositoryFullName: String?

    public init(
        id: String,
        type: String? = nil,
        name: String? = nil,
        displayName: String? = nil,
        description: String? = nil,
        repositoryFullName: String? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.displayName = displayName
        self.description = description
        self.repositoryFullName = repositoryFullName
    }

    /// The name shown in the UI.
    public var title: String {
        for candidate in [displayName, name, repositoryFullName] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return id
    }

    /// Whether this cloud project tracks the GitHub repository `slug`.
    public func matchesRepository(_ slug: String?) -> Bool {
        guard let slug, !slug.isEmpty, let repositoryFullName else { return false }
        return repositoryFullName.caseInsensitiveCompare(slug) == .orderedSame
    }
}

public struct CloudProjectListResponse: Decodable, Sendable {
    public struct Pagination: Decodable, Sendable {
        public let nextCursor: String?
        public let hasMore: Bool
    }

    public let items: [CloudProject]
    public let pagination: Pagination?
}

// MARK: - Wire fields

/// The story fields Autopilot stores. The same shape is the local side of the
/// comparison, the remote side, and the last-synced base, so a three-way
/// comparison can tell which side changed.
public struct CloudStoryFields: Codable, Sendable, Hashable {
    public var title: String
    public var details: String
    public var tags: [String]
    public var version: String?
    public var milestone: String?
    public var priority: String?
    public var type: String?

    public init(
        title: String,
        details: String = "",
        tags: [String] = [],
        version: String? = nil,
        milestone: String? = nil,
        priority: String? = nil,
        type: String? = nil
    ) {
        self.title = CloudText.title(title)
        self.details = details
        self.tags = CloudText.tags(tags)
        self.version = CloudText.optional(version)
        self.milestone = CloudText.optional(milestone)
        self.priority = CloudText.priority(priority)
        self.type = CloudText.optional(type)
    }

    private enum CodingKeys: String, CodingKey {
        case title, details, tags, version, milestone, priority, type
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            details: try c.decodeIfPresent(String.self, forKey: .details) ?? "",
            tags: CloudText.decodeTags(c, forKey: .tags),
            version: try c.decodeIfPresent(String.self, forKey: .version),
            milestone: try c.decodeIfPresent(String.self, forKey: .milestone),
            priority: try c.decodeIfPresent(String.self, forKey: .priority),
            type: try c.decodeIfPresent(String.self, forKey: .type)
        )
    }

    /// Nil fields are sent as `null` so a PATCH clears them on the server.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(details, forKey: .details)
        try c.encode(tags, forKey: .tags)
        try c.encode(version, forKey: .version)
        try c.encode(milestone, forKey: .milestone)
        try c.encode(priority, forKey: .priority)
        try c.encode(type, forKey: .type)
    }
}

/// The task fields Autopilot stores; see `CloudStoryFields`. Story and parent
/// ids are Autopilot ids, not local UUIDs.
public struct CloudTaskFields: Codable, Sendable, Hashable {
    public var title: String
    public var details: String
    public var status: String
    public var priority: String?
    public var type: String?
    public var tags: [String]
    public var version: String?
    public var milestone: String?
    public var storyId: String?
    public var parentTaskId: String?
    public var assignedDeviceId: String?
    public var sortIndex: Double

    public init(
        title: String,
        details: String = "",
        status: String = TaskStatus.backlog.rawValue,
        priority: String? = nil,
        type: String? = nil,
        tags: [String] = [],
        version: String? = nil,
        milestone: String? = nil,
        storyId: String? = nil,
        parentTaskId: String? = nil,
        assignedDeviceId: String? = nil,
        sortIndex: Double = 0
    ) {
        self.title = CloudText.title(title)
        self.details = details
        self.status = CloudText.status(status)
        self.priority = CloudText.priority(priority)
        self.type = CloudText.optional(type)
        self.tags = CloudText.tags(tags)
        self.version = CloudText.optional(version)
        self.milestone = CloudText.optional(milestone)
        self.storyId = storyId
        self.parentTaskId = parentTaskId
        self.assignedDeviceId = assignedDeviceId
        self.sortIndex = sortIndex
    }

    private enum CodingKeys: String, CodingKey {
        case title, details, status, priority, type, tags, version, milestone
        case storyId, parentTaskId, assignedDeviceId, sortIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            details: try c.decodeIfPresent(String.self, forKey: .details) ?? "",
            status: try c.decodeIfPresent(String.self, forKey: .status) ?? TaskStatus.backlog.rawValue,
            priority: try c.decodeIfPresent(String.self, forKey: .priority),
            type: try c.decodeIfPresent(String.self, forKey: .type),
            tags: CloudText.decodeTags(c, forKey: .tags),
            version: try c.decodeIfPresent(String.self, forKey: .version),
            milestone: try c.decodeIfPresent(String.self, forKey: .milestone),
            storyId: try c.decodeIfPresent(String.self, forKey: .storyId),
            parentTaskId: try c.decodeIfPresent(String.self, forKey: .parentTaskId),
            assignedDeviceId: try c.decodeIfPresent(String.self, forKey: .assignedDeviceId),
            sortIndex: try c.decodeIfPresent(Double.self, forKey: .sortIndex) ?? 0
        )
    }

    /// Nil fields are sent as `null` so a PATCH clears them on the server.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(details, forKey: .details)
        try c.encode(status, forKey: .status)
        try c.encode(priority, forKey: .priority)
        try c.encode(type, forKey: .type)
        try c.encode(tags, forKey: .tags)
        try c.encode(version, forKey: .version)
        try c.encode(milestone, forKey: .milestone)
        try c.encode(storyId, forKey: .storyId)
        try c.encode(parentTaskId, forKey: .parentTaskId)
        try c.encode(assignedDeviceId, forKey: .assignedDeviceId)
        try c.encode(sortIndex, forKey: .sortIndex)
    }
}

/// Normalizes values the way Autopilot's validation does, so a value that
/// round-trips through the server compares equal to the local one.
public enum CloudText {
    public static let statuses: Set<String> = [
        TaskStatus.backlog.rawValue, TaskStatus.pending.rawValue, TaskStatus.inProgress.rawValue,
        TaskStatus.pendingReview.rawValue, TaskStatus.done.rawValue,
    ]

    public static func title(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

    public static func optional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(200))
    }

    public static func tags(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == 50 { break }
        }
        return result
    }

    public static func priority(_ value: String?) -> String? {
        guard let value, TaskPriority(rawValue: value) != nil else { return nil }
        return value
    }

    public static func status(_ value: String) -> String {
        statuses.contains(value) ? value : TaskStatus.backlog.rawValue
    }

    /// Tags arrive as a JSON array, or as the JSON text the database stores.
    fileprivate static func decodeTags<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> [String] {
        if let tags = try? c.decodeIfPresent([String].self, forKey: key) { return tags }
        if let text = try? c.decodeIfPresent(String.self, forKey: key),
           let data = text.data(using: .utf8),
           let tags = try? JSONDecoder().decode([String].self, from: data) {
            return tags
        }
        return []
    }
}

// MARK: - Remote rows

/// A story as Autopilot returns it.
public struct CloudRemoteStory: Identifiable, Decodable, Sendable, Hashable {
    public let id: String
    public let fields: CloudStoryFields
    public let updatedAt: Date?

    public init(id: String, fields: CloudStoryFields, updatedAt: Date? = nil) {
        self.id = id
        self.fields = fields
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        updatedAt = CloudDate.decode(c, forKey: .updatedAt)
        fields = try CloudStoryFields(from: decoder)
    }
}

/// A task as Autopilot returns it.
public struct CloudRemoteTask: Identifiable, Decodable, Sendable, Hashable {
    public let id: String
    public let fields: CloudTaskFields
    public let updatedAt: Date?

    public init(id: String, fields: CloudTaskFields, updatedAt: Date? = nil) {
        self.id = id
        self.fields = fields
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        updatedAt = CloudDate.decode(c, forKey: .updatedAt)
        fields = try CloudTaskFields(from: decoder)
    }
}

/// `GET /api/v1/docs/repositories/{id}/tasks`.
public struct CloudRemoteBoard: Decodable, Sendable {
    public var stories: [CloudRemoteStory]
    public var tasks: [CloudRemoteTask]

    public init(stories: [CloudRemoteStory] = [], tasks: [CloudRemoteTask] = []) {
        self.stories = stories
        self.tasks = tasks
    }
}

enum CloudDate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> Date? {
        if let text = try? c.decodeIfPresent(String.self, forKey: key) {
            return parse(text)
        }
        if let millis = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return nil
    }

    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - Sync state

/// A local item's Autopilot counterpart and the fields both sides agreed on
/// at the last sync.
public struct CloudItemLink<Fields: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var remoteId: String
    public var base: Fields

    public init(remoteId: String, base: Fields) {
        self.remoteId = remoteId
        self.base = base
    }
}

/// Per-board bookkeeping for cloud sync, persisted with the board. Keyed by
/// local story and task id.
public struct CloudBoardSyncState: Codable, Sendable, Hashable {
    public var stories: [UUID: CloudItemLink<CloudStoryFields>]
    public var tasks: [UUID: CloudItemLink<CloudTaskFields>]
    public var lastSyncedAt: Date?
    public var lastError: String?

    public init(
        stories: [UUID: CloudItemLink<CloudStoryFields>] = [:],
        tasks: [UUID: CloudItemLink<CloudTaskFields>] = [:],
        lastSyncedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.stories = stories
        self.tasks = tasks
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey { case stories, tasks, lastSyncedAt, lastError }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stories = (try? c.decodeIfPresent([UUID: CloudItemLink<CloudStoryFields>].self, forKey: .stories)) ?? [:]
        tasks = (try? c.decodeIfPresent([UUID: CloudItemLink<CloudTaskFields>].self, forKey: .tasks)) ?? [:]
        lastSyncedAt = try? c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
    }

    public func storyRemoteId(_ localId: UUID?) -> String? {
        localId.flatMap { stories[$0]?.remoteId }
    }

    public func taskRemoteId(_ localId: UUID?) -> String? {
        localId.flatMap { tasks[$0]?.remoteId }
    }

    public func localStoryId(forRemote remoteId: String?) -> UUID? {
        guard let remoteId else { return nil }
        return stories.first { $0.value.remoteId == remoteId }?.key
    }

    public func localTaskId(forRemote remoteId: String?) -> UUID? {
        guard let remoteId else { return nil }
        return tasks.first { $0.value.remoteId == remoteId }?.key
    }
}

/// What a three-way comparison says to do with one linked item.
public enum CloudMergeDecision: Sendable, Equatable {
    /// Both sides already agree.
    case inSync
    /// Only this device changed it: send the local fields.
    case push
    /// Only the cloud changed it: take the remote fields.
    case pull

    /// `localIsNewer` breaks the tie when both sides changed since the base.
    public static func decide<F: Equatable>(local: F, base: F, remote: F, localIsNewer: Bool) -> CloudMergeDecision {
        if local == remote { return .inSync }
        if remote == base { return .push }
        if local == base { return .pull }
        return localIsNewer ? .push : .pull
    }
}

// MARK: - Board mapping

public extension TaskBoard {
    /// The Autopilot status for a local column. Custom columns fall back to
    /// the nearest built-in meaning, since Autopilot's statuses are fixed.
    func cloudStatus(for status: TaskStatus) -> String {
        let column = column(for: status)
        if CloudText.statuses.contains(column.id.rawValue) { return column.id.rawValue }
        if column.countsAsDone { return TaskStatus.done.rawValue }
        if column.triggersChat { return TaskStatus.inProgress.rawValue }
        return TaskStatus.backlog.rawValue
    }

    /// The local column for an Autopilot status. Keeps `current` when it
    /// already maps to that status, so a custom column survives a round trip.
    func localStatus(forCloud status: String, current: TaskStatus?) -> TaskStatus {
        if let current, cloudStatus(for: current) == status { return current }
        let wanted = TaskStatus(rawValue: status)
        if effectiveColumns.contains(where: { $0.id == wanted }) { return wanted }
        if status == TaskStatus.done.rawValue, let done = effectiveColumns.first(where: \.countsAsDone) {
            return done.id
        }
        return firstColumn.id
    }

    func cloudFields(for story: ProjectStory) -> CloudStoryFields {
        CloudStoryFields(
            title: story.title,
            details: story.details,
            tags: story.tags,
            version: story.version,
            milestone: story.milestone,
            priority: story.priority?.rawValue,
            type: itemType(id: story.typeId)?.name
        )
    }

    func cloudFields(for task: ProjectTask, sync: CloudBoardSyncState) -> CloudTaskFields {
        CloudTaskFields(
            title: task.title,
            details: task.details,
            status: cloudStatus(for: task.status),
            priority: task.priority?.rawValue,
            type: itemType(id: task.typeId)?.name,
            tags: task.tags,
            version: task.version,
            milestone: task.milestone,
            storyId: sync.storyRemoteId(task.storyId),
            parentTaskId: sync.taskRemoteId(task.parentTaskId),
            assignedDeviceId: task.assignedDeviceId,
            sortIndex: task.sortIndex
        )
    }

    /// The local item type named `name`, matched case-insensitively.
    func itemTypeId(named name: String?) -> UUID? {
        guard let name, !name.isEmpty else { return nil }
        return effectiveTypes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    /// Copies Autopilot's story fields onto a local story.
    func applying(_ fields: CloudStoryFields, to story: ProjectStory, updatedAt: Date?) -> ProjectStory {
        var story = story
        story.title = fields.title
        story.details = fields.details
        story.tags = fields.tags
        story.version = fields.version
        story.milestone = fields.milestone
        story.priority = fields.priority.flatMap(TaskPriority.init(rawValue:))
        story.typeId = itemTypeId(named: fields.type)
        story.updatedAt = updatedAt ?? Date()
        return story
    }

    /// Copies Autopilot's task fields onto a local task. Agent settings, runs
    /// and attachments are device-local and left untouched.
    func applying(_ fields: CloudTaskFields, to task: ProjectTask, sync: CloudBoardSyncState, updatedAt: Date?) -> ProjectTask {
        var task = task
        task.title = fields.title
        task.details = fields.details
        task.status = localStatus(forCloud: fields.status, current: task.status)
        task.priority = fields.priority.flatMap(TaskPriority.init(rawValue:))
        task.typeId = itemTypeId(named: fields.type)
        task.tags = fields.tags
        task.version = fields.version
        task.milestone = fields.milestone
        task.storyId = sync.localStoryId(forRemote: fields.storyId)
        task.parentTaskId = sync.localTaskId(forRemote: fields.parentTaskId)
        task.assignedDeviceId = fields.assignedDeviceId
        task.sortIndex = fields.sortIndex
        task.updatedAt = updatedAt ?? Date()
        return task
    }
}

/// A laptop registered by the signed-in account. Assignment remains available offline.
public struct CloudDevice: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var lastSeenAt: Date?

    public init(id: String, name: String, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.lastSeenAt = lastSeenAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, lastSeenAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lastSeenAt = CloudDate.decode(c, forKey: .lastSeenAt)
    }
}
