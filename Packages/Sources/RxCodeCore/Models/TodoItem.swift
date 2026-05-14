import Foundation

// MARK: - Todo Item

public struct TodoItem: Identifiable, Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public let id: Int
    public let content: String
    public let activeForm: String
    public let status: Status

    public init(id: Int, content: String, activeForm: String, status: Status) {
        self.id = id
        self.content = content
        self.activeForm = activeForm
        self.status = status
    }
}

// MARK: - Todo Extractor

public enum TodoExtractor {
    /// Find the most recent `TodoWrite` tool call across the message list and
    /// parse its `todos` input into typed ``TodoItem`` values.
    ///
    /// Returns `nil` if no TodoWrite has been emitted yet, or if its `input`
    /// has not finished streaming. Returns an empty array if the call exists
    /// but contains no todos.
    public static func latest(in messages: [ChatMessage]) -> [TodoItem]? {
        for message in messages.reversed() {
            for block in message.blocks.reversed() {
                guard let toolCall = block.toolCall,
                      toolCall.name.lowercased() == "todowrite" else { continue }
                return parse(input: toolCall.input)
            }
        }
        return nil
    }

    /// Parse a raw `TodoWrite` `input` dictionary into typed ``TodoItem`` values.
    public static func parse(input: [String: JSONValue]) -> [TodoItem] {
        guard let array = input["todos"]?.arrayValue else { return [] }
        return array.enumerated().map { index, value in
            let content = value["content"]?.stringValue ?? ""
            let activeForm = value["activeForm"]?.stringValue ?? content
            let rawStatus = value["status"]?.stringValue ?? ""
            let status = TodoItem.Status(rawValue: rawStatus) ?? .pending
            return TodoItem(id: index, content: content, activeForm: activeForm, status: status)
        }
    }
}
