import Foundation

public struct Project: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var path: String
    public var gitHubRepo: String?
    public var lastSessionId: String?

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        gitHubRepo: String? = nil,
        lastSessionId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitHubRepo = gitHubRepo
        self.lastSessionId = lastSessionId
    }
}
