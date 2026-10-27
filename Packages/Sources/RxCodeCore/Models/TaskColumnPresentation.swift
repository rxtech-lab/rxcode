import Foundation

/// Presentation order only; agent queues continue to use manual sort indices.
public struct TaskColumnSort: Codable, Sendable, Hashable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case manual, priority, title, createdAt, updatedAt, version, milestone

        public var title: String {
            switch self {
            case .manual: String(localized: "Manual order")
            case .priority: String(localized: "Priority")
            case .title: String(localized: "Title")
            case .createdAt: String(localized: "Created date")
            case .updatedAt: String(localized: "Updated date")
            case .version: String(localized: "Version")
            case .milestone: String(localized: "Milestone")
            }
        }
    }

    public var field: Field
    public var descending: Bool

    public init(field: Field = .manual, descending: Bool = false) {
        self.field = field
        self.descending = descending
    }

    public func sorted(_ tasks: [ProjectTask]) -> [ProjectTask] {
        tasks.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch field {
            case .manual: comparison = compare(lhs.sortIndex, rhs.sortIndex)
            case .priority: comparison = compare(lhs.priority?.rank, rhs.priority?.rank)
            case .title: comparison = compare(lhs.title.lowercased(), rhs.title.lowercased())
            case .createdAt: comparison = compare(lhs.createdAt, rhs.createdAt)
            case .updatedAt: comparison = compare(lhs.updatedAt, rhs.updatedAt)
            case .version: comparison = compare(lhs.version?.lowercased(), rhs.version?.lowercased())
            case .milestone: comparison = compare(lhs.milestone?.lowercased(), rhs.milestone?.lowercased())
            }
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        // Missing values stay last in either direction.
        guard let lhs else { return rhs == nil ? .orderedSame : .orderedDescending }
        guard let rhs else { return .orderedAscending }
        guard lhs != rhs else { return .orderedSame }
        return (lhs < rhs) != (descending && field != .manual) ? .orderedAscending : .orderedDescending
    }
}

/// Stored exclusively in this device's UserDefaults, never in a board or sync payload.
public struct TaskColumnFilter: Codable, Sendable, Equatable {
    public var priorities: [TaskPriority] = []
    public var typeIDs: [UUID] = []
    public var tags: [String] = []
    public var versions: [String] = []
    public var milestones: [String] = []
    public var storyIDs: [UUID] = []

    public init() {}

    public var isEmpty: Bool {
        priorities.isEmpty && typeIDs.isEmpty && tags.isEmpty && versions.isEmpty && milestones.isEmpty && storyIDs.isEmpty
    }

    public func matches(_ task: ProjectTask) -> Bool {
        (priorities.isEmpty || task.priority.map(priorities.contains) == true)
            && (typeIDs.isEmpty || task.typeId.map(typeIDs.contains) == true)
            && (tags.isEmpty || tags.allSatisfy(task.tags.contains))
            && (versions.isEmpty || versions.contains(task.version ?? ""))
            && (milestones.isEmpty || milestones.contains(task.milestone ?? ""))
            && (storyIDs.isEmpty || task.storyId.map(storyIDs.contains) == true)
    }

    public static let storageKey = "tasks.deviceColumnFilters"

    public static func scope(project: String, viewID: UUID, columnID: TaskStatus) -> String {
        "\(project)|\(viewID.uuidString)|\(columnID.rawValue)"
    }

    public static func load(from data: Data, scope: String) -> Self {
        (try? JSONDecoder().decode([String: Self].self, from: data)[scope]) ?? Self()
    }

    public func storing(in data: Data, scope: String) throws -> Data {
        var filters = (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
        filters[scope] = isEmpty ? nil : self
        return try JSONEncoder().encode(filters)
    }
}

public extension TaskSavedView {
    func sort(for column: TaskStatus) -> TaskColumnSort {
        columnSorts[column.rawValue] ?? TaskColumnSort()
    }
}
