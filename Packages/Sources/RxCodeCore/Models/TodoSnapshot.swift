import Foundation
import SwiftData

/// Persisted snapshot of the latest `TodoWrite` tool call for a chat session.
/// One row per session id; updated each time the CLI emits a new TodoWrite.
@Model
public final class TodoSnapshot {
    @Attribute(.unique) public var sessionId: String
    public var total: Int
    public var done: Int
    public var inProgress: Int
    public var itemsData: Data
    public var updatedAt: Date

    public init(sessionId: String, items: [TodoItem], updatedAt: Date = .now) {
        self.sessionId = sessionId
        self.total = items.count
        self.done = items.filter { $0.status == .completed }.count
        self.inProgress = items.filter { $0.status == .inProgress }.count
        self.itemsData = (try? JSONEncoder().encode(items)) ?? Data()
        self.updatedAt = updatedAt
    }

    public func apply(items: [TodoItem], at date: Date = .now) {
        self.total = items.count
        self.done = items.filter { $0.status == .completed }.count
        self.inProgress = items.filter { $0.status == .inProgress }.count
        self.itemsData = (try? JSONEncoder().encode(items)) ?? Data()
        self.updatedAt = date
    }

    public var items: [TodoItem] {
        (try? JSONDecoder().decode([TodoItem].self, from: itemsData)) ?? []
    }
}
