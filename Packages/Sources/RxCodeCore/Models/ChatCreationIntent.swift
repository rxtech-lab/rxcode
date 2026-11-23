import Foundation

/// Captures the source when a chat action is invoked, including actions on a
/// history row that is not the currently selected conversation.
public struct ChatCreationIntent: Identifiable, Sendable {
    public enum Kind: Sendable { case plan, task, story }
    public let id = UUID()
    public let kind: Kind
    public let sessionID: String?
    public let goal: String

    public init(_ kind: Kind, sessionID: String?, goal: String = "") {
        self.kind = kind
        self.sessionID = sessionID
        self.goal = goal
    }
}
