import Foundation

/// An agent's guess at a task or story's properties.
///
/// Every field is optional. Applying a suggestion only fills empty fields.
public struct TaskClassification: Codable, Sendable, Hashable {
    public var type: String?
    public var priority: String?
    public var tags: [String]?
    public var version: String?
    public var milestone: String?
    /// Title of the story a task belongs to. Never asked for a story.
    public var story: String?

    public init(
        type: String? = nil,
        priority: String? = nil,
        tags: [String]? = nil,
        version: String? = nil,
        milestone: String? = nil,
        story: String? = nil
    ) {
        self.type = type
        self.priority = priority
        self.tags = tags
        self.version = version
        self.milestone = milestone
        self.story = story
    }

    private enum CodingKeys: String, CodingKey {
        case type, priority, tags, version, milestone, story
    }

    /// Decodes each field on its own so one malformed value — a numeric
    /// version, a single tag string — doesn't discard the whole suggestion.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return String(value) }
            return nil
        }
        type = text(.type)
        priority = text(.priority)
        version = text(.version)
        milestone = text(.milestone)
        story = text(.story)
        if let list = try? container.decodeIfPresent([String].self, forKey: .tags) {
            tags = list
        } else {
            tags = text(.tags).map { [$0] }
        }
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
        board: TaskBoard,
        isStory: Bool = false
    ) -> String {
        func list(_ values: [String]) -> String {
            values.isEmpty ? "(none yet)" : values.joined(separator: ", ")
        }

        // Only a task without a parent is asked to pick one.
        let choosesStory = !isStory && (storyTitle ?? "").isEmpty && !board.stories.isEmpty
        let storyKey = choosesStory ? #", "story": string|null"# : ""

        var lines: [String] = [
            isStory ? "You classify a software story on a project board." : "You classify a software task on a project board.",
            "Reply with ONLY a JSON object, no prose and no markdown fences, with these keys:",
            #"{"type": string|null, "priority": string|null, "tags": [string], "version": string|null, "milestone": string|null"# + storyKey + "}",
            "",
            "Rules:",
            "- type: exactly one of [\(board.effectiveTypes.map(\.name).joined(separator: ", "))], or null.",
            "- priority: always one of [urgent, high, medium, low]. Use medium when nothing suggests otherwise.",
            "- tags: up to \(maxTags) short lowercase labels. Prefer existing tags: \(list(board.allTags)).",
            versionRule(board.allVersions),
            milestoneRule(board.allMilestones),
        ]
        if choosesStory {
            let titles = board.stories.map { "\"\($0.title)\"" }.joined(separator: ", ")
            lines.append("- story: the exact title of the existing story this task is part of, from [\(titles)]. Use null unless the task clearly belongs to one; never invent a story.")
        }
        lines += [
            "",
            "\(isStory ? "Story" : "Task") title: \(title)",
        ]
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetails.isEmpty {
            lines.append("\(isStory ? "Story" : "Task") description: \(trimmedDetails)")
        }
        if let storyTitle, !storyTitle.isEmpty {
            lines.append("Parent story: \(storyTitle)")
        }
        return lines.joined(separator: "\n")
    }

    /// Version is filled whenever the board gives the model something to
    /// pick: a stated version wins, otherwise the best existing one (newest
    /// for new work). Only a board with no versions yet allows null.
    private static func versionRule(_ versions: [String]) -> String {
        let stated = "- version: use a version explicitly stated in the title or description, even if new."
        guard let newest = versions.first else { return "\(stated) Otherwise null." }
        return "\(stated) Otherwise pick the most fitting existing version from [\(versions.joined(separator: ", "))]; for new work use the newest, \(newest). Never null."
    }

    /// Same as `versionRule`: fill from the board's milestones when it has any.
    private static func milestoneRule(_ milestones: [String]) -> String {
        let stated = "- milestone: use a milestone explicitly stated in the title or description, even if new."
        guard !milestones.isEmpty else { return "\(stated) Otherwise null." }
        return "\(stated) Otherwise pick the most fitting existing milestone from [\(milestones.joined(separator: ", "))]. Never null."
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
        // The story goes first so its version and milestone are inherited,
        // like quick add in a story, before the model's own guesses.
        if task.storyId == nil, let title = Self.clean(story),
           let parent = board.stories.first(where: {
               $0.projectId == task.projectId
                   && $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                   .compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            task.storyId = parent.id
            if (task.version ?? "").isEmpty { task.version = parent.version }
            if (task.milestone ?? "").isEmpty { task.milestone = parent.milestone }
        }
        if task.typeId == nil, let type = Self.clean(type) {
            task.typeId = board.effectiveTypes.first {
                $0.name.compare(type, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }?.id
        }
        if task.priority == nil, let priority = Self.priority(from: priority) {
            task.priority = priority
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

    /// Stories share the same classification fields but do not carry an agent.
    public func apply(to story: inout ProjectStory, board: TaskBoard) {
        if story.typeId == nil, let type = Self.clean(type) {
            story.typeId = board.effectiveTypes.first {
                $0.name.compare(type, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }?.id
        }
        if story.priority == nil, let priority = Self.priority(from: priority) {
            story.priority = priority
        }
        if (story.version ?? "").isEmpty, let version = Self.clean(version) {
            story.version = version
        }
        if (story.milestone ?? "").isEmpty, let milestone = Self.clean(milestone) {
            story.milestone = milestone
        }
        let suggested = (tags ?? []).compactMap(Self.clean).map { tag in
            board.allTags.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag
        }
        for tag in suggested.prefix(Self.maxTags) where !story.tags.contains(tag) {
            story.tags.append(tag)
        }
    }

    /// Maps the model's priority word to the board's, accepting common
    /// synonyms and P0–P3 labels.
    static func priority(from value: String?) -> TaskPriority? {
        guard let raw = clean(value)?.lowercased() else { return nil }
        if let priority = TaskPriority(rawValue: raw) { return priority }
        switch raw {
        case "critical", "blocker", "highest", "p0": return .urgent
        case "p1": return .high
        case "normal", "moderate", "p2": return .medium
        case "lowest", "minor", "trivial", "p3", "p4": return .low
        default: return nil
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
