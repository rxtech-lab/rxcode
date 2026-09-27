import Foundation

/// Agent-written Swift that filters a project view's tasks and stories.
///
/// The script defines two functions:
/// ```swift
/// func includeTask(_ task: FilterTask) -> Bool { ... }
/// func includeStory(_ story: FilterStory) -> Bool { ... }
/// ```
/// The desktop app wraps it in `harness(userScript:)`, compiles the result with
/// `swiftc`, pipes every task and story of the board in as JSON (`Input`) and
/// reads back the ids it kept (`Output`). The script only narrows what the
/// view's other filters already allow.
public enum TaskFilterScript {
    // MARK: - Input records

    /// A task as the script sees it. Mirrored field for field by the
    /// `FilterTask` struct in the harness.
    public struct Task: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var details: String
        /// Name of the board column the task sits in.
        public var status: String
        public var isDone: Bool
        public var tags: [String]
        public var version: String?
        public var milestone: String?
        /// `urgent`, `high`, `medium` or `low`.
        public var priority: String?
        /// Item type name, such as "Bug" or "Feature".
        public var type: String?
        public var storyId: String?
        public var storyTitle: String?
        public var parentTaskId: String?
        public var parentTaskIds: [String]
        public var hasAgent: Bool
        public var needsAttention: Bool
        public var createdAt: Date
        public var updatedAt: Date
    }

    /// A story as the script sees it. `status` is rolled up from its tasks.
    public struct Story: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var details: String
        public var status: String
        public var isDone: Bool
        public var tags: [String]
        public var version: String?
        public var milestone: String?
        public var priority: String?
        public var type: String?
        public var taskCount: Int
        public var doneTaskCount: Int
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct Input: Codable, Sendable {
        public var tasks: [Task]
        public var stories: [Story]
    }

    /// The ids the script kept.
    public struct Output: Codable, Sendable, Hashable {
        public var tasks: [String]
        public var stories: [String]
    }

    /// The ids of the tasks and stories a script kept, parsed back into UUIDs.
    public struct Selection: Sendable, Hashable {
        public var taskIds: Set<UUID>
        public var storyIds: Set<UUID>

        public init(taskIds: Set<UUID>, storyIds: Set<UUID>) {
            self.taskIds = taskIds
            self.storyIds = storyIds
        }

        public init(_ output: Output) {
            taskIds = Set(output.tasks.compactMap(UUID.init(uuidString:)))
            storyIds = Set(output.stories.compactMap(UUID.init(uuidString:)))
        }
    }

    /// Every task and story on `board`, flattened into script input.
    public static func input(for board: TaskBoard) -> Input {
        let rollups = board.storyRollups()
        let tasks = board.tasks.map { task -> Task in
            let column = board.column(for: task.status)
            return Task(
                id: task.id.uuidString,
                title: task.title,
                details: task.details,
                status: column.name,
                isDone: column.countsAsDone,
                tags: task.tags,
                version: task.version,
                milestone: task.milestone,
                priority: task.priority?.rawValue,
                type: board.itemType(id: task.typeId)?.name,
                storyId: task.storyId?.uuidString,
                storyTitle: board.story(id: task.storyId)?.title,
                parentTaskId: task.parentTaskId?.uuidString,
                parentTaskIds: task.parentTaskIds.map(\.uuidString),
                hasAgent: task.agent.isAssigned,
                needsAttention: task.attentionReason != nil,
                createdAt: task.createdAt,
                updatedAt: task.updatedAt
            )
        }
        let stories = board.stories.map { story -> Story in
            let rollup = rollups[story.id]
            let column = board.column(for: rollup?.status ?? board.rolledUpStatus(for: story))
            return Story(
                id: story.id.uuidString,
                title: story.title,
                details: story.details,
                status: column.name,
                isDone: column.countsAsDone,
                tags: story.tags,
                version: story.version,
                milestone: story.milestone,
                priority: story.priority?.rawValue,
                type: board.itemType(id: story.typeId)?.name,
                taskCount: rollup?.progress.total ?? 0,
                doneTaskCount: rollup?.progress.done ?? 0,
                createdAt: story.createdAt,
                updatedAt: story.updatedAt
            )
        }
        return Input(tasks: tasks, stories: stories)
    }

    public static func encode(_ input: Input) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(input)
    }

    public static func decodeOutput(_ data: Data) throws -> Output {
        try JSONDecoder().decode(Output.self, from: data)
    }

    // MARK: - Script source

    /// The API the script codes against, shared by the harness and the prompt
    /// so the agent is told exactly what compiles.
    public static let apiDeclarations = """
    struct FilterTask: Codable {
        let id: String
        let title: String
        let details: String
        let status: String          // board column name, e.g. "Todo", "In Progress", "Done"
        let isDone: Bool            // true when the column counts as done
        let tags: [String]
        let version: String?
        let milestone: String?
        let priority: String?       // "urgent", "high", "medium" or "low"
        let type: String?           // item type name, e.g. "Bug", "Feature"
        let storyId: String?
        let storyTitle: String?
        let parentTaskId: String?
        let parentTaskIds: [String]
        let hasAgent: Bool          // an agent is assigned to run the task
        let needsAttention: Bool    // flagged as needing attention
        let createdAt: Date
        let updatedAt: Date
    }

    struct FilterStory: Codable {
        let id: String
        let title: String
        let details: String
        let status: String          // column rolled up from the story's tasks
        let isDone: Bool
        let tags: [String]
        let version: String?
        let milestone: String?
        let priority: String?
        let type: String?
        let taskCount: Int
        let doneTaskCount: Int
        let createdAt: Date
        let updatedAt: Date
    }
    """

    /// Wraps the user's two functions in a program that reads `Input` JSON
    /// from stdin and prints `Output` JSON.
    public static func harness(userScript: String) -> String {
        """
        import Foundation

        \(apiDeclarations)

        // ---- User script ----
        \(userScript)
        // ---- End user script ----

        private struct __RxCodeFilterInput: Codable {
            let tasks: [FilterTask]
            let stories: [FilterStory]
        }

        private struct __RxCodeFilterOutput: Codable {
            let tasks: [String]
            let stories: [String]
        }

        @main
        struct __RxCodeFilterRunner {
            static func main() throws {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let input = try decoder.decode(__RxCodeFilterInput.self, from: data)
                let output = __RxCodeFilterOutput(
                    tasks: input.tasks.filter { includeTask($0) }.map(\\.id),
                    stories: input.stories.filter { includeStory($0) }.map(\\.id)
                )
                let encoded = try JSONEncoder().encode(output)
                FileHandle.standardOutput.write(encoded)
            }
        }
        """
    }

    /// The code the editor starts from before anything is generated.
    public static let starterScript = """
    func includeTask(_ task: FilterTask) -> Bool {
        // Example: unfinished high-priority work.
        !task.isDone && (task.priority == "urgent" || task.priority == "high")
    }

    func includeStory(_ story: FilterStory) -> Bool {
        !story.isDone
    }
    """

    /// The prompt that asks an agent for a filter script. Lists the board's
    /// columns, tags, versions and milestones so the code can use real values.
    public static func prompt(requirement: String, board: TaskBoard) -> String {
        let columns = board.effectiveColumns.map(\.name).joined(separator: ", ")
        let tags = board.allTags.joined(separator: ", ")
        let versions = board.allVersions.joined(separator: ", ")
        let milestones = board.allMilestones.joined(separator: ", ")
        let types = board.effectiveTypes.map(\.name).joined(separator: ", ")
        return """
        You are writing a Swift filter for a project's task board in a macOS app.
        Output ONLY Swift source — no prose, no markdown — defining exactly these two functions:

            func includeTask(_ task: FilterTask) -> Bool { ... }
            func includeStory(_ story: FilterStory) -> Bool { ... }

        Return true to KEEP the task or story in the view. Both functions are required;
        if the requirement only concerns tasks, return true from includeStory (and vice versa).

        These types are already defined — do NOT redeclare them:

        \(apiDeclarations)

        Foundation is available. The code must be pure: no file, network or process access.
        Compare strings case-insensitively where the user's wording is loose.
        You may add small private helper functions.

        Board context:
        - Columns: \(columns.isEmpty ? "(none)" : columns)
        - Tags: \(tags.isEmpty ? "(none)" : tags)
        - Versions: \(versions.isEmpty ? "(none)" : versions)
        - Milestones: \(milestones.isEmpty ? "(none)" : milestones)
        - Types: \(types.isEmpty ? "(none)" : types)

        Requirement: \(requirement)
        """
    }

    /// Pulls Swift source out of a model reply, stripping one ```/```swift
    /// fenced block if present. `nil` for empty output.
    public static func extractSwift(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let fenceStart = text.range(of: "```") {
            var rest = String(text[fenceStart.upperBound...])
            if let newline = rest.firstIndex(of: "\n") {
                let firstLine = rest[..<newline].trimmingCharacters(in: .whitespaces)
                if firstLine.isEmpty || firstLine.lowercased() == "swift" {
                    rest = String(rest[rest.index(after: newline)...])
                }
            }
            if let fenceEnd = rest.range(of: "```") {
                rest = String(rest[..<fenceEnd.lowerBound])
            }
            text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}

public extension TaskSavedView {
    /// Whether the view carries an agent-written Swift filter.
    var hasFilterScript: Bool {
        !(filterScript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
