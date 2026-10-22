import Foundation

/// A small, credential-free projection of the frontmost workspace for WidgetKit.
public struct DesktopWidgetSnapshot: Codable, Equatable, Sendable {
    public var workspaceID: String
    public var workspaceName: String
    public var projects: [WidgetProject]
    public var agents: [WidgetAgentUsage]
    public var updatedAt: Date

    public init(workspaceID: String, workspaceName: String, projects: [WidgetProject], agents: [WidgetAgentUsage], updatedAt: Date = .now) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.projects = projects
        self.agents = agents
        self.updatedAt = updatedAt
    }

    public static let empty = Self(workspaceID: "", workspaceName: "RxCode", projects: [], agents: [], updatedAt: .distantPast)

    public func url(projectID: UUID? = nil, taskID: UUID? = nil, usage: Bool = false) -> URL {
        var components = URLComponents()
        components.scheme = "rxcode"
        components.host = "widget"
        components.path = usage ? "/usage" : "/tasks"
        components.queryItems = [URLQueryItem(name: "workspace", value: workspaceID)]
        if let projectID { components.queryItems?.append(URLQueryItem(name: "project", value: projectID.uuidString)) }
        if let taskID { components.queryItems?.append(URLQueryItem(name: "task", value: taskID.uuidString)) }
        return components.url!
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
                              isOngoing: board.isStatusLocked(task), isDone: column.countsAsDone, isQueued: task.isQueued)
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
