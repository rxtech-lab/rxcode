import Foundation

/// An agent's guess at a quick-added task's properties.
///
/// Quick add only takes a title, so the board asks a model to fill in type,
/// priority, tags, version and milestone from the title and what the board
/// already uses. Every field is optional — the model may leave any blank — and
/// `apply(to:board:)` only fills fields the task doesn't already have.
public struct TaskClassification: Codable, Sendable, Hashable {
    public var type: String?
    public var priority: String?
    public var tags: [String]?
    public var version: String?
    public var milestone: String?

    public init(
        type: String? = nil,
        priority: String? = nil,
        tags: [String]? = nil,
        version: String? = nil,
        milestone: String? = nil
    ) {
        self.type = type
        self.priority = priority
        self.tags = tags
        self.version = version
        self.milestone = milestone
    }

    /// Caps how many tags a suggestion can add, so a chatty model can't bury
    /// the card in labels.
    public static let maxTags = 3

    // MARK: - Prompt

    /// The one-shot prompt. Existing tags, versions and milestones are listed
    /// so the model reuses the board's vocabulary instead of inventing near
    /// duplicates.
    public static func prompt(
        title: String,
        details: String,
        storyTitle: String?,
        board: TaskBoard
    ) -> String {
        func list(_ values: [String]) -> String {
            values.isEmpty ? "(none yet)" : values.joined(separator: ", ")
        }

        var lines: [String] = [
            "You classify a software task on a project board.",
            "Reply with ONLY a JSON object, no prose and no markdown fences, with these keys:",
            #"{"type": string|null, "priority": string|null, "tags": [string], "version": string|null, "milestone": string|null}"#,
            "",
            "Rules:",
            "- type: exactly one of [\(board.effectiveTypes.map(\.name).joined(separator: ", "))], or null.",
            "- priority: one of [urgent, high, medium, low], or null when unclear.",
            "- tags: up to \(maxTags) short lowercase labels. Prefer existing tags: \(list(board.allTags)).",
            "- version: only reuse an existing version when the task clearly belongs to it: \(list(board.allVersions)). Otherwise null.",
            "- milestone: only reuse an existing milestone when the task clearly belongs to it: \(list(board.allMilestones)). Otherwise null.",
            "",
            "Task title: \(title)",
        ]
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetails.isEmpty {
            lines.append("Task description: \(trimmedDetails)")
        }
        if let storyTitle, !storyTitle.isEmpty {
            lines.append("Parent story: \(storyTitle)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Decodes the first JSON object in `raw`. Models often wrap the object in
    /// a fence or a sentence despite being told not to, so everything outside
    /// the outermost braces is ignored.
    public static func parse(_ raw: String) -> TaskClassification? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(TaskClassification.self, from: data)
    }

    // MARK: - Applying

    /// Fills the task's empty fields from the suggestion. Anything the task
    /// already carries — typed by the user, inherited from its story or a
    /// filtered view — wins. Types and priorities that don't match the board
    /// are dropped rather than created.
    public func apply(to task: inout ProjectTask, board: TaskBoard) {
        if task.typeId == nil, let type = Self.clean(type) {
            task.typeId = board.effectiveTypes.first {
                $0.name.compare(type, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }?.id
        }
        if task.priority == nil, let priority = Self.clean(priority) {
            task.priority = TaskPriority(rawValue: priority.lowercased())
        }
        if (task.version ?? "").isEmpty, let version = Self.clean(version) {
            task.version = version
        }
        if (task.milestone ?? "").isEmpty, let milestone = Self.clean(milestone) {
            task.milestone = milestone
        }
        let suggested = (tags ?? []).compactMap(Self.clean).map { tag in
            // Reuse the board's spelling of a tag that differs only by case.
            board.allTags.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag
        }
        for tag in suggested.prefix(Self.maxTags) where !task.tags.contains(tag) {
            task.tags.append(tag)
        }
    }

    /// Trims, and treats empty strings and a literal "null" as absent.
    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.lowercased() != "null"
        else { return nil }
        return trimmed
    }
}
