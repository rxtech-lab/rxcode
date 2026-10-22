import Foundation

/// A small, credential-free projection of the frontmost workspace for WidgetKit.
public struct DesktopWidgetSnapshot: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var workspaceName: String
    public var projects: [WidgetProject]
    public var agents: [WidgetAgentUsage]
    public var updatedAt: Date
    public var threads: [WidgetThread]?

    public init(workspaceID: String, workspaceName: String, projects: [WidgetProject], agents: [WidgetAgentUsage], updatedAt: Date = .now, threads: [WidgetThread] = []) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.projects = projects
        self.agents = agents
        self.updatedAt = updatedAt
        self.threads = threads
    }

    public static let empty = Self(workspaceID: "", workspaceName: "RxCode", projects: [], agents: [], updatedAt: .distantPast)

    /// Reserve space for recent completions even when the active list is full.
    public func taskRows(projectID: UUID? = nil, ongoingOnly: Bool = false, limit: Int, now: Date) -> [(project: WidgetProject, task: WidgetTask)] {
        guard limit > 0 else { return [] }
        let rows = projects.filter { projectID == nil || $0.id == projectID }.flatMap { project in
            project.tasks.map { (project: project, task: $0) }
        }
        let active = rows.filter { !$0.task.isDone && (!ongoingOnly || $0.task.isOngoing) }
            .sorted {
                if $0.task.isOngoing != $1.task.isOngoing { return $0.task.isOngoing }
                return false
            }
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let finished = rows.filter {
            $0.task.isDone && ($0.task.updatedAt.map { $0 >= cutoff && $0 <= now } ?? false)
        }.sorted {
            if $0.task.updatedAt != $1.task.updatedAt { return $0.task.updatedAt! > $1.task.updatedAt! }
            return $0.task.id.uuidString < $1.task.id.uuidString
        }
        let reserved = min(finished.count, max(1, limit / 2))
        let visibleActive = Array(active.prefix(limit - reserved))
        return visibleActive + finished.prefix(limit - visibleActive.count)
    }

    public func threadRows(projectID: UUID? = nil, limit: Int, now: Date) -> [WidgetThread] {
        guard limit > 0 else { return [] }
        let matching = (threads ?? []).filter { projectID == nil || $0.projectID == projectID }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
        let ongoing = matching.filter(\.isOngoing)
        let stopped = matching.filter {
            !$0.isOngoing && $0.updatedAt >= now.addingTimeInterval(-7 * 86400) && $0.updatedAt <= now
        }
        let reserved = min(stopped.count, max(1, limit / 2))
        let active = Array(ongoing.prefix(limit - reserved))
        return active + stopped.prefix(limit - active.count)
    }

    public func url(projectID: UUID? = nil, taskID: UUID? = nil, threadID: String? = nil, usage: Bool = false) -> URL {
        var components = URLComponents()
        components.scheme = "rxcode"
        components.host = "widget"
        components.path = usage ? "/usage" : (threadID == nil ? "/tasks" : "/thread")
        components.queryItems = [URLQueryItem(name: "workspace", value: workspaceID)]
        if let projectID { components.queryItems?.append(URLQueryItem(name: "project", value: projectID.uuidString)) }
        if let taskID { components.queryItems?.append(URLQueryItem(name: "task", value: taskID.uuidString)) }
        if let threadID { components.queryItems?.append(URLQueryItem(name: "thread", value: threadID)) }
        return components.url!
    }
}

public struct WidgetThread: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var projectID: UUID
    public var projectName: String
    public var title: String
    public var isOngoing: Bool
    public var updatedAt: Date

    public init(id: String, projectID: UUID, projectName: String, title: String, isOngoing: Bool, updatedAt: Date) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.title = title
        self.isOngoing = isOngoing
        self.updatedAt = updatedAt
    }
}

public struct WidgetProject: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var tasks: [WidgetTask]
    public var stories: [WidgetStory]
    public var ongoingCount: Int { tasks.filter(\.isOngoing).count }
    public var openCount: Int { tasks.filter { !$0.isDone }.count }

    public init(id: UUID, name: String, board: TaskBoard) {
        self.id = id
        self.name = name
        tasks = board.tasks.sorted {
            if board.isStatusLocked($0) != board.isStatusLocked($1) { return board.isStatusLocked($0) }
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id.uuidString < $1.id.uuidString
        }.map { task in
            let column = board.column(for: task.status)
            return WidgetTask(id: task.id, title: task.title, storyID: task.storyId, status: column.name,
                              isOngoing: board.isStatusLocked(task), isDone: column.countsAsDone, isQueued: task.isQueued, updatedAt: task.updatedAt)
        }
        let projectedTasks = tasks
        stories = board.stories.map { story in
            let children = projectedTasks.filter { $0.storyID == story.id }
            return WidgetStory(id: story.id, title: story.title, doneCount: children.filter(\.isDone).count, taskCount: children.count)
        }
    }
}

public struct WidgetTask: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var storyID: UUID?
    public var status: String
    public var isOngoing: Bool
    public var isDone: Bool
    public var isQueued: Bool
    public var updatedAt: Date?
}

public struct WidgetStory: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var doneCount: Int
    public var taskCount: Int
}

public struct WidgetAgentUsage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var usage: RateLimitUsage?
    public var supportsLimits: Bool
    public var measuredAt: Date?

    public init(id: String, name: String, usage: RateLimitUsage?, supportsLimits: Bool = true, measuredAt: Date? = nil) {
        self.id = id
        self.name = name
        self.usage = usage
        self.supportsLimits = supportsLimits
        self.measuredAt = measuredAt
    }
}

/// Both processes use the same App Group; snapshots contain no prompts or tokens.
public enum DesktopWidgetStore {
    // macOS team-prefixed groups do not require provisioning-profile registration.
    public static let appGroupID = "P9KK452K8P.com.rxlab.RxCode"
    private static let key = "desktop.widget.snapshot.v1"

    public static func load() -> DesktopWidgetSnapshot {
        guard let data = UserDefaults(suiteName: appGroupID)?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(DesktopWidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    public static func save(_ snapshot: DesktopWidgetSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: key)
    }
}
