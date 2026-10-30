import Foundation

/// A narrow metadata mutation, safe to apply to the latest board received from another device.
public struct TaskMetadataEdit: Codable, Sendable {
    public enum Field: String, Codable, Sendable, CaseIterable, Identifiable {
        case tags, versions, milestones
        public var id: Self { self }
        public var title: String {
            switch self {
            case .tags: "Tags"
            case .versions: "Versions"
            case .milestones: "Milestones"
            }
        }
        public func values(in board: TaskBoard) -> [String] {
            switch self {
            case .tags: board.allTags
            case .versions: board.allVersions
            case .milestones: board.allMilestones
            }
        }
    }

    public var field: Field
    public var original: String?
    public var name: String

    public init(field: Field, original: String? = nil, name: String) {
        self.field = field
        self.original = original
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacing(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.map { $0 == original ? name : $0 }.filter { seen.insert($0).inserted }
    }

    public func apply(to view: inout TaskSavedView) {
        guard !name.isEmpty, original != nil else { return }
        switch field {
        case .tags: view.tags = replacing(view.tags)
        case .versions: view.versions = replacing(view.versions)
        case .milestones: view.milestones = replacing(view.milestones)
        }
    }

    public func apply(to board: inout TaskBoard) {
        guard !name.isEmpty else { return }
        for index in board.savedViews.indices { apply(to: &board.savedViews[index]) }
        switch field {
        case .tags:
            for index in board.tasks.indices { board.tasks[index].tags = replacing(board.tasks[index].tags) }
            for index in board.stories.indices { board.stories[index].tags = replacing(board.stories[index].tags) }
            if !board.labels.contains(where: { $0.name == name }) {
                if let index = board.labels.firstIndex(where: { $0.name == original }) {
                    board.labels[index].name = name
                } else {
                    board.labels.append(TaskLabel(name: name))
                }
            } else if let original, original != name {
                board.labels.removeAll { $0.name == original }
            }
        case .versions:
            board.versions = replacing(board.versions)
            if !board.versions.contains(name) { board.versions.append(name) }
            if let original {
                for index in board.tasks.indices where board.tasks[index].version == original { board.tasks[index].version = name }
                for index in board.stories.indices where board.stories[index].version == original { board.stories[index].version = name }
            }
        case .milestones:
            board.milestones = replacing(board.milestones)
            if !board.milestones.contains(name) { board.milestones.append(name) }
            if let original {
                for index in board.tasks.indices where board.tasks[index].milestone == original { board.tasks[index].milestone = name }
                for index in board.stories.indices where board.stories[index].milestone == original { board.stories[index].milestone = name }
            }
        }
    }
}
