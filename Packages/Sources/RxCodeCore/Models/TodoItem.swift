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

/// A todo list and the time it was last updated. An empty list clears progress.
public struct TodoListSnapshot: Sendable, Equatable {
    public let items: [TodoItem]
    public let updatedAt: Date

    public init(items: [TodoItem], updatedAt: Date) {
        self.items = items
        self.updatedAt = updatedAt
    }

    public static func latest(transcript: Self?, recorded: Self?) -> Self? {
        guard let recorded else { return transcript }
        if let transcript, transcript.updatedAt > recorded.updatedAt {
            return transcript
        }
        return recorded
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
        latestSnapshot(in: messages)?.items
    }

    public static func latestSnapshot(in messages: [ChatMessage]) -> TodoListSnapshot? {
        for message in messages.reversed() {
            for block in message.blocks.reversed() {
                guard let toolCall = block.toolCall,
                      toolCall.name.lowercased() == "todowrite",
                      toolCall.input["todos"]?.arrayValue != nil else { continue }
                return TodoListSnapshot(items: parse(input: toolCall.input), updatedAt: message.timestamp)
            }
        }
        // Newer Claude Code drives its task list through the incremental
        // `TaskCreate` / `TaskUpdate` tools instead of `TodoWrite`. Fall back to
        // reconstructing the list from those when no `TodoWrite` is present.
        return taskToolSnapshot(in: messages)
    }

    /// Reconstruct a todo list from the newer Claude Code task tools
    /// (`TaskCreate` / `TaskUpdate`).
    ///
    /// Unlike `TodoWrite` — which submits the whole list on every call — the
    /// task tools are incremental: `TaskCreate` adds a single `pending` task
    /// whose id is assigned by the tool and returned in the result text
    /// ("Task #N created successfully: …"), and `TaskUpdate` mutates a task by
    /// `taskId` (status, subject, …; `deleted` removes it). We replay every
    /// task tool call in message order to rebuild the current state.
    ///
    /// Returns `nil` when the transcript contains no task tool calls, so callers
    /// can distinguish "no task list" from "an empty task list".
    public static func fromTaskTools(in messages: [ChatMessage]) -> [TodoItem]? {
        taskToolSnapshot(in: messages)?.items
    }

    private static func taskToolSnapshot(in messages: [ChatMessage]) -> TodoListSnapshot? {
        struct Task {
            var subject: String
            var activeForm: String
            var status: TodoItem.Status
        }
        var order: [Int] = []
        var tasks: [Int: Task] = [:]
        var updatedAt: Date?

        for message in messages {
            for block in message.blocks {
                guard let toolCall = block.toolCall else { continue }
                switch toolCall.name.lowercased() {
                case "taskcreate":
                    // The id is only known once the tool result lands; skip
                    // until then (the task surfaces on the next render).
                    guard let id = parseCreatedTaskId(fromResult: toolCall.result) else { continue }
                    updatedAt = message.timestamp
                    let subject = toolCall.input["subject"]?.stringValue ?? ""
                    let activeForm = toolCall.input["activeForm"]?.stringValue ?? subject
                    if tasks[id] == nil { order.append(id) }
                    tasks[id] = Task(subject: subject, activeForm: activeForm, status: .pending)

                case "taskupdate":
                    guard let idString = toolCall.input["taskId"]?.stringValue,
                          let id = Int(idString) else { continue }
                    let rawStatus = toolCall.input["status"]?.stringValue
                    if rawStatus == "deleted" {
                        if tasks.removeValue(forKey: id) != nil {
                            order.removeAll { $0 == id }
                            updatedAt = message.timestamp
                        }
                        continue
                    }
                    guard var task = tasks[id] else { continue }
                    updatedAt = message.timestamp
                    if let rawStatus, let status = TodoItem.Status(rawValue: rawStatus) {
                        task.status = status
                    }
                    if let subject = toolCall.input["subject"]?.stringValue { task.subject = subject }
                    if let activeForm = toolCall.input["activeForm"]?.stringValue { task.activeForm = activeForm }
                    tasks[id] = task

                default:
                    continue
                }
            }
        }

        guard let updatedAt else { return nil }
        let items = order.compactMap { id -> TodoItem? in
            guard let task = tasks[id] else { return nil }
            return TodoItem(id: id, content: task.subject, activeForm: task.activeForm, status: task.status)
        }
        return TodoListSnapshot(items: items, updatedAt: updatedAt)
    }

    /// Pull the assigned task id out of a `TaskCreate` result string such as
    /// "Task #1 created successfully: …". Returns `nil` if the result is absent
    /// (still streaming) or doesn't carry a `#<number>` id.
    static func parseCreatedTaskId(fromResult result: String?) -> Int? {
        guard let result, let hash = result.firstIndex(of: "#") else { return nil }
        let digits = result[result.index(after: hash)...].prefix { $0.isNumber }
        return Int(digits)
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

    /// Parse Codex app-server `turn/plan/updated` params into the same todo
    /// shape used by `TodoWrite`.
    public static func parseCodexPlanUpdate(params: [String: JSONValue]) -> [TodoItem]? {
        guard let array = params["plan"]?.arrayValue else { return nil }
        return array.enumerated().map { index, value in
            let step = value["step"]?.stringValue ?? ""
            let rawStatus = value["status"]?.stringValue ?? ""
            return TodoItem(
                id: index,
                content: step,
                activeForm: step,
                status: parseCodexPlanStatus(rawStatus)
            )
        }
    }

    private static func parseCodexPlanStatus(_ rawStatus: String) -> TodoItem.Status {
        switch rawStatus {
        case "completed":
            return .completed
        case "inProgress", "in_progress":
            return .inProgress
        default:
            return .pending
        }
    }
}
