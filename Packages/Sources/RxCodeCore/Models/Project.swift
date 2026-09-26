import Foundation

public struct Project: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var path: String
    public var gitHubRepo: String?
    public var lastSessionId: String?
    public var lastAgentProvider: AgentProvider?
    public var lastModel: String?
    /// The Autopilot project this project's task board syncs with. `nil`
    /// means the project is local to this Mac.
    public var cloudId: String?

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        gitHubRepo: String? = nil,
        lastSessionId: String? = nil,
        lastAgentProvider: AgentProvider? = nil,
        lastModel: String? = nil,
        cloudId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitHubRepo = gitHubRepo
        self.lastSessionId = lastSessionId
        self.lastAgentProvider = lastAgentProvider
        self.lastModel = lastModel
        self.cloudId = cloudId
    }

    /// Whether the task board syncs through Autopilot.
    public var isCloud: Bool { cloudId != nil }
}

public extension [Project] {
    /// Drag-and-drop reorder: the project with id `moved` takes `target`'s
    /// slot and the projects in between shift along, matching the board's
    /// column and view-tab reorders.
    ///
    /// `nil` when either id is unknown or the two are the same, so callers can
    /// skip the write instead of persisting an unchanged order.
    func reordered(moving moved: UUID, onto target: UUID) -> [Project]? {
        var order = self
        guard moved != target,
              let from = order.firstIndex(where: { $0.id == moved }),
              let to = order.firstIndex(where: { $0.id == target })
        else { return nil }
        let project = order.remove(at: from)
        order.insert(project, at: to)
        return order
    }
}
