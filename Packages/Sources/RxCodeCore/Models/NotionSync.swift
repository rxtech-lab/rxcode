import Foundation

// MARK: - NotionBoardLink

/// The Notion database a project's board is linked to, persisted on the
/// board. Pushing writes every task as a page of that database; importing
/// reads its pages back as tasks.
public struct NotionBoardLink: Codable, Sendable, Hashable {
    public var databaseId: String
    public var databaseTitle: String
    /// Push changes to Notion shortly after the board changes, instead of only
    /// on "Sync Now".
    public var autoSync: Bool
    /// Keyed by `ProjectTask.id.uuidString` — a string key so the JSON stays an
    /// object rather than Swift's flat key/value array for `UUID` keys.
    public var pages: [String: NotionPageLink]
    public var lastSyncedAt: Date?

    public init(
        databaseId: String,
        databaseTitle: String,
        autoSync: Bool = false,
        pages: [String: NotionPageLink] = [:],
        lastSyncedAt: Date? = nil
    ) {
        self.databaseId = databaseId
        self.databaseTitle = databaseTitle
        self.autoSync = autoSync
        self.pages = pages
        self.lastSyncedAt = lastSyncedAt
    }

    private enum CodingKeys: String, CodingKey {
        case databaseId, databaseTitle, autoSync, pages, lastSyncedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        databaseId = try c.decodeIfPresent(String.self, forKey: .databaseId) ?? ""
        databaseTitle = try c.decodeIfPresent(String.self, forKey: .databaseTitle) ?? ""
        autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? false
        pages = try c.decodeIfPresent([String: NotionPageLink].self, forKey: .pages) ?? [:]
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }

    public func page(for taskId: UUID) -> NotionPageLink? {
        pages[taskId.uuidString]
    }

    /// The task linked to a Notion page, if any.
    public func taskId(forPage pageId: String) -> UUID? {
        let normalized = NotionID.normalized(pageId)
        return pages.first { NotionID.normalized($0.value.pageId) == normalized }
            .flatMap { UUID(uuidString: $0.key) }
    }
}

/// One task's Notion page and what was last written to it.
public struct NotionPageLink: Codable, Sendable, Hashable {
    public var pageId: String
    /// `NotionTaskMapper.fingerprint` of the properties last pushed. A task
    /// whose properties still hash the same is skipped on the next push, so
    /// auto-sync doesn't rewrite every page after each board change.
    public var fingerprint: String?

    public init(pageId: String, fingerprint: String? = nil) {
        self.pageId = pageId
        self.fingerprint = fingerprint
    }
}

/// Notion ids come dashed or undashed depending on where they were copied
/// from; compare them without dashes.
public enum NotionID {
    public static func normalized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

// MARK: - Database schema

/// One property (column) of a Notion database.
public struct NotionProperty: Sendable, Hashable {
    public var name: String
    /// Notion's property type: `title`, `rich_text`, `select`, `multi_select`,
    /// `status`, …
    public var type: String
    /// Option names of a `select`, `multi_select` or `status` property.
    public var options: [String]
    /// A `status` property's option names by group. Notion's groups are
    /// always To-do, In progress and Complete; see `NotionStatusGroup`.
    public var groups: [NotionStatusGroup: [String]]

    public init(name: String, type: String, options: [String] = [], groups: [NotionStatusGroup: [String]] = [:]) {
        self.name = name
        self.type = type
        self.options = options
        self.groups = groups
    }

    /// The existing option matching `name` case-insensitively.
    public func option(matching name: String) -> String? {
        options.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The status group `option` belongs to.
    public func group(of option: String) -> NotionStatusGroup? {
        groups.first { $0.value.contains { $0.caseInsensitiveCompare(option) == .orderedSame } }?.key
    }
}

/// The fixed groups a Notion `status` property sorts its options into.
public enum NotionStatusGroup: String, Sendable, Hashable, CaseIterable {
    case toDo = "to-do"
    case inProgress = "in progress"
    case complete = "complete"

    /// Where a board column falls: done columns are Complete, the first
    /// chat column and everything after it In progress, the rest To-do.
    public static func group(for column: TaskColumn, on board: TaskBoard) -> NotionStatusGroup {
        if column.countsAsDone { return .complete }
        let columns = board.effectiveColumns
        if let chatStart = columns.firstIndex(where: \.triggersChat),
           let index = columns.firstIndex(where: { $0.id == column.id }),
           index >= chatStart {
            return .inProgress
        }
        return .toDo
    }
}

/// A Notion data source — the table inside a database, which holds the
/// properties and pages — as returned by `search` or `data_sources/{id}`.
/// `id` is the data source id; `databaseId` the database containing it.
/// Also decodes a pre-2025-09-03 `database` object, whose id is both.
public struct NotionDatabase: Identifiable, Sendable, Hashable {
    public var id: String
    public var databaseId: String?
    public var title: String
    public var url: String?
    public var properties: [NotionProperty]

    public init(id: String, databaseId: String? = nil, title: String, url: String? = nil, properties: [NotionProperty]) {
        self.id = id
        self.databaseId = databaseId
        self.title = title
        self.url = url
        self.properties = properties
    }

    public init?(json: JSONValue) {
        let object = json["object"]?.stringValue
        guard object == "data_source" || object == "database", let id = json["id"]?.stringValue else { return nil }
        self.id = id
        databaseId = object == "database" ? id : json["parent"]?["database_id"]?.stringValue
        let title = NotionText.plainText(json["title"])
        self.title = title.isEmpty ? String(localized: "Untitled") : title
        url = json["url"]?.stringValue
        properties = (json["properties"]?.objectValue ?? [:])
            .compactMap { key, value -> NotionProperty? in
                guard let type = value["type"]?.stringValue else { return nil }
                let config = value[type]
                var names: [String: String] = [:]
                let options = (config?["options"]?.arrayValue ?? []).compactMap { option -> String? in
                    guard let name = option["name"]?.stringValue else { return nil }
                    if let id = option["id"]?.stringValue { names[id] = name }
                    return name
                }
                var groups: [NotionStatusGroup: [String]] = [:]
                for group in config?["groups"]?.arrayValue ?? [] {
                    guard let raw = group["name"]?.stringValue?.lowercased(),
                          let kind = NotionStatusGroup(rawValue: raw)
                    else { continue }
                    groups[kind] = (group["option_ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap { names[$0] } }
                }
                return NotionProperty(name: value["name"]?.stringValue ?? key, type: type, options: options, groups: groups)
            }
            .sorted { $0.name < $1.name }
    }
}

/// Which database properties hold which task fields. Properties are matched
/// by conventional name ("Status", "Priority", "Tags", …) and a compatible
/// type; fields with no matching property are neither pushed nor imported.
public struct NotionFieldMap: Sendable, Hashable {
    public var title: NotionProperty
    public var status: NotionProperty?
    public var priority: NotionProperty?
    public var tags: NotionProperty?
    public var version: NotionProperty?
    public var milestone: NotionProperty?
    public var type: NotionProperty?
    public var story: NotionProperty?
    public var description: NotionProperty?

    public init?(database: NotionDatabase) {
        let props = database.properties
        guard let title = props.first(where: { $0.type == "title" }) else { return nil }
        self.title = title

        func find(_ names: [String], types: Set<String>) -> NotionProperty? {
            for name in names {
                if let match = props.first(where: {
                    types.contains($0.type) && $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    return match
                }
            }
            return nil
        }

        let singleValue: Set<String> = ["select", "status", "rich_text"]
        status = find(["Status", "State", "Column", "RxCode Status"], types: ["status", "select"])
            ?? props.first { $0.type == "status" }
        priority = find(["Priority", "RxCode Priority"], types: ["select", "status"])
        tags = find(["Tags", "Labels", "Tag", "Label", "RxCode Tags"], types: ["multi_select"])
        version = find(["Version", "Target version", "Release", "RxCode Version"], types: singleValue.union(["multi_select"]))
        milestone = find(["Milestone", "RxCode Milestone"], types: singleValue.union(["multi_select"]))
        type = find(["Type", "Kind", "RxCode Type"], types: ["select"])
        story = find(["Story", "Epic", "RxCode Story"], types: ["select", "rich_text"])
        description = find(["Description", "Details", "Notes", "RxCode Description"], types: ["rich_text"])
    }

    /// Schemas for the task fields this database has no property for, keyed
    /// by the name to create them under — what a push adds so every field is
    /// synced. Select options are seeded from the board (columns, priorities,
    /// types); the rest are created on first use. A name already taken by a
    /// property of another type gets an "RxCode " prefix.
    public static func missingProperties(in database: NotionDatabase, board: TaskBoard) -> [String: JSONValue] {
        let map = NotionFieldMap(database: database)
        let taken = Set(database.properties.map { $0.name.lowercased() })
        func select(_ names: [String]) -> JSONValue {
            let unique = names.map(NotionText.optionName).filter { !$0.isEmpty }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return .object(["select": .object(["options": .array(unique.map { .object(["name": .string($0)]) })])])
        }
        let empty = JSONValue.object([:])
        let fields: [(name: String, present: Bool, schema: JSONValue)] = [
            ("Status", map?.status != nil, select(board.effectiveColumns.map(\.name))),
            ("Priority", map?.priority != nil, select(TaskPriority.allCases.map(\.displayNameText))),
            ("Tags", map?.tags != nil, .object(["multi_select": empty])),
            ("Version", map?.version != nil, .object(["select": empty])),
            ("Milestone", map?.milestone != nil, .object(["select": empty])),
            ("Type", map?.type != nil, select(board.effectiveTypes.map(\.name))),
            ("Story", map?.story != nil, .object(["select": empty])),
            ("Description", map?.description != nil, .object(["rich_text": empty])),
        ]
        var result: [String: JSONValue] = [:]
        for field in fields where !field.present {
            let name = taken.contains(field.name.lowercased()) ? "RxCode \(field.name)" : field.name
            result[name] = field.schema
        }
        return result
    }

    /// Property names the task fields map to, for showing the user what a
    /// sync will write.
    public var mappedFields: [(field: String, property: String)] {
        [
            (String(localized: "Title"), title),
            (String(localized: "Status"), status),
            (String(localized: "Priority"), priority),
            (String(localized: "Tags"), tags),
            (String(localized: "Version"), version),
            (String(localized: "Milestone"), milestone),
            (String(localized: "Type"), type),
            (String(localized: "Story"), story),
            (String(localized: "Description"), description),
        ].compactMap { field, property in property.map { (field, $0.name) } }
    }
}

// MARK: - Rich text

public enum NotionText {
    /// Notion rejects a single text object longer than this.
    static let maxChunkLength = 2000
    /// And a rich-text array longer than this.
    static let maxChunks = 100

    /// Concatenated `plain_text` of a rich-text array.
    public static func plainText(_ value: JSONValue?) -> String {
        (value?.arrayValue ?? []).compactMap { $0["plain_text"]?.stringValue ?? $0["text"]?["content"]?.stringValue }
            .joined()
    }

    /// `text` as a rich-text array, split into chunks Notion accepts.
    public static func richText(_ text: String) -> JSONValue {
        var chunks: [JSONValue] = []
        var remaining = Substring(text)
        while !remaining.isEmpty, chunks.count < maxChunks {
            let chunk = remaining.prefix(maxChunkLength)
            chunks.append(.object(["type": .string("text"), "text": .object(["content": .string(String(chunk))])]))
            remaining = remaining.dropFirst(chunk.count)
        }
        return .array(chunks)
    }

    /// Select option names can't contain commas.
    static func optionName(_ name: String) -> String {
        name.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Mapping

/// A Notion page read back as task fields, before it is placed on a board.
public struct NotionImportedItem: Sendable, Hashable {
    public var pageId: String
    public var title: String
    public var details: String
    public var statusName: String?
    /// The status group `statusName` belongs to, for a `status` property.
    public var statusGroup: NotionStatusGroup?
    public var priorityName: String?
    public var tags: [String]
    public var version: String?
    public var milestone: String?
    public var typeName: String?
    public var storyTitle: String?

    public init(
        pageId: String,
        title: String,
        details: String = "",
        statusName: String? = nil,
        statusGroup: NotionStatusGroup? = nil,
        priorityName: String? = nil,
        tags: [String] = [],
        version: String? = nil,
        milestone: String? = nil,
        typeName: String? = nil,
        storyTitle: String? = nil
    ) {
        self.pageId = pageId
        self.title = title
        self.details = details
        self.statusName = statusName
        self.statusGroup = statusGroup
        self.priorityName = priorityName
        self.tags = tags
        self.version = version
        self.milestone = milestone
        self.typeName = typeName
        self.storyTitle = storyTitle
    }
}

public enum NotionTaskMapper {

    // MARK: Push

    /// The `properties` object of the Notion page for `task`. Only mapped
    /// properties are written.
    public static func properties(for task: ProjectTask, board: TaskBoard, map: NotionFieldMap) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            map.title.name: .object(["title": NotionText.richText(task.title)]),
        ]
        if let status = map.status {
            result[status.name] = value(statusName(for: board.column(for: task.status), board: board, property: status), for: status)
        }
        if let priority = map.priority {
            result[priority.name] = value(task.priority?.displayNameText, for: priority)
        }
        if let tags = map.tags {
            let names = task.tags.map(NotionText.optionName).filter { !$0.isEmpty }
            result[tags.name] = .object(["multi_select": .array(names.map { .object(["name": .string($0)]) })])
        }
        if let version = map.version {
            result[version.name] = value(task.version, for: version)
        }
        if let milestone = map.milestone {
            result[milestone.name] = value(task.milestone, for: milestone)
        }
        if let type = map.type {
            result[type.name] = value(board.itemType(id: task.typeId)?.name, for: type)
        }
        if let story = map.story {
            result[story.name] = value(board.story(id: task.storyId)?.title, for: story)
        }
        if let description = map.description {
            result[description.name] = value(task.details, for: description)
        }
        return result.compactMapValues { $0 }
    }

    /// What a task in `column` shows in the status property. A `select`
    /// takes the column name, creating the option if needed. A `status`
    /// property's options can't be extended without rewriting them all, so
    /// it takes the option named like the column, else the first option of
    /// the group the column falls in — Done → Complete, the agent's columns
    /// → In progress, the rest → To-do.
    static func statusName(for column: TaskColumn, board: TaskBoard, property: NotionProperty) -> String? {
        guard property.type == "status" else { return column.name }
        if let exact = property.option(matching: column.name) { return exact }
        return property.groups[NotionStatusGroup.group(for: column, on: board)]?.first
    }

    /// One property value, shaped for the property's type. `nil` leaves the
    /// property untouched (a status with no matching option).
    static func value(_ text: String?, for property: NotionProperty) -> JSONValue? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch property.type {
        case "status":
            guard !trimmed.isEmpty, let option = property.option(matching: trimmed) else { return nil }
            return .object(["status": .object(["name": .string(option)])])
        case "select":
            let name = NotionText.optionName(trimmed)
            return .object(["select": name.isEmpty ? .null : .object(["name": .string(property.option(matching: name) ?? name)])])
        case "multi_select":
            let name = NotionText.optionName(trimmed)
            return .object(["multi_select": .array(name.isEmpty ? [] : [.object(["name": .string(name)])])])
        case "rich_text":
            return .object(["rich_text": NotionText.richText(trimmed)])
        default:
            return nil
        }
    }

    /// A stable digest of a page's properties, to tell whether a task changed
    /// since it was last pushed.
    public static func fingerprint(_ properties: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(properties) else { return UUID().uuidString }
        return data.base64EncodedString()
    }

    // MARK: Import

    /// A database page as task fields. `nil` for trashed pages.
    public static func importedItem(from page: JSONValue, map: NotionFieldMap) -> NotionImportedItem? {
        guard let pageId = page["id"]?.stringValue,
              page["archived"]?.boolValue != true,
              page["in_trash"]?.boolValue != true
        else { return nil }
        let props = page["properties"]

        func text(_ property: NotionProperty?) -> String? {
            guard let property, let value = props?[property.name] else { return nil }
            let result: String
            switch value["type"]?.stringValue ?? property.type {
            case "title": result = NotionText.plainText(value["title"])
            case "rich_text": result = NotionText.plainText(value["rich_text"])
            case "select": result = value["select"]?["name"]?.stringValue ?? ""
            case "status": result = value["status"]?["name"]?.stringValue ?? ""
            case "multi_select": result = value["multi_select"]?[0]?["name"]?.stringValue ?? ""
            default: result = ""
            }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var tags: [String] = []
        if let tagsProperty = map.tags, let value = props?[tagsProperty.name] {
            tags = (value["multi_select"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        }

        let statusName = text(map.status)
        return NotionImportedItem(
            pageId: pageId,
            title: text(map.title) ?? String(localized: "Untitled"),
            details: text(map.description) ?? "",
            statusName: statusName,
            statusGroup: statusName.flatMap { map.status?.group(of: $0) },
            priorityName: text(map.priority),
            tags: tags,
            version: text(map.version),
            milestone: text(map.milestone),
            typeName: text(map.type),
            storyTitle: text(map.story)
        )
    }
}

// MARK: - Board import

/// What an import changed.
public struct NotionImportResult: Sendable, Hashable {
    public var added: Int
    public var skipped: Int
    public var storiesCreated: Int

    public init(added: Int = 0, skipped: Int = 0, storiesCreated: Int = 0) {
        self.added = added
        self.skipped = skipped
        self.storiesCreated = storiesCreated
    }
}

public extension TaskBoard {
    /// Adds `items` as tasks, linking each to its Notion page. Pages already
    /// linked to a task are skipped so re-importing never duplicates work or
    /// overwrites local edits.
    ///
    /// A Notion status matching a column name puts the task in that column,
    /// and one in the Complete status group puts it in the first done column —
    /// except chat columns, which would dispatch every imported task to an
    /// agent at once; those tasks, and ones with an unknown status, land in
    /// the first column. A story name with no matching story creates one.
    mutating func applyNotionImport(
        _ items: [NotionImportedItem],
        projectId: UUID,
        link: NotionBoardLink,
        agent: TaskAgentConfig = TaskAgentConfig(),
        now: Date = Date()
    ) -> NotionImportResult {
        var link = link
        var result = NotionImportResult()
        let columns = effectiveColumns
        let fallbackColumn = columns.first { !$0.triggersChat } ?? firstColumn

        for item in items {
            if link.taskId(forPage: item.pageId).map({ id in tasks.contains { $0.id == id } }) == true {
                result.skipped += 1
                continue
            }

            let column = item.statusName.flatMap { name in
                columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            } ?? (item.statusGroup == .complete ? columns.first(where: \.countsAsDone) : nil)
            let status = (column.flatMap { $0.triggersChat ? nil : $0 } ?? fallbackColumn).id

            var storyId: UUID?
            if let storyTitle = item.storyTitle {
                if let existing = stories.first(where: { $0.title.caseInsensitiveCompare(storyTitle) == .orderedSame }) {
                    storyId = existing.id
                } else {
                    let story = ProjectStory(projectId: projectId, title: storyTitle, createdAt: now, updatedAt: now)
                    stories.append(story)
                    storyId = story.id
                    result.storiesCreated += 1
                }
            }

            let priority = item.priorityName.flatMap { name in
                TaskPriority.allCases.first {
                    $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
                        || $0.displayNameText.caseInsensitiveCompare(name) == .orderedSame
                }
            }
            let typeId = item.typeName.flatMap { name in
                effectiveTypes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            }

            let task = ProjectTask(
                projectId: projectId,
                storyId: storyId,
                title: item.title,
                details: item.details,
                status: status,
                version: item.version,
                tags: item.tags,
                milestone: item.milestone,
                priority: priority,
                typeId: typeId,
                agent: agent,
                sortIndex: appendSortIndex(for: status),
                createdAt: now,
                updatedAt: now
            )
            tasks.append(task)
            // No fingerprint: the next push writes the board's view of the
            // task back, e.g. a status that fell back to the first column.
            link.pages[task.id.uuidString] = NotionPageLink(pageId: item.pageId)
            result.added += 1
        }

        notion = link
        return result
    }
}

public extension TaskBoard {
    /// Whether anything a Notion page shows changed between two versions of
    /// the board. Link bookkeeping (page ids, fingerprints, sync time) is
    /// ignored, so recording a finished sync doesn't schedule another.
    func notionContentDiffers(from other: TaskBoard) -> Bool {
        tasks != other.tasks
            || stories != other.stories
            || columns != other.columns
            || itemTypes != other.itemTypes
    }
}
