import Foundation

extension IDEToolRegistry {
    static let taskViewsTool = IDETool(
        name: TaskViewsTool.name,
        description: "Manage a project's saved task views. List first to discover view and column IDs; use ide__get_stories for story IDs. Supports list, create, update, delete, and reorder. Returns views in saved model format (camelCase fields), including hidden views. Updates use snake_case arguments and preserve omitted fields; empty filter arrays clear those filters. Set is_default to choose the project's opening view. Reorder requires every view ID exactly once, including hidden views. Deleting a view keeps its tasks; the last view cannot be deleted. Uses the current chat's project unless project_id is supplied. Device-local column filters are not changed.",
        visibility: .alwaysIDEOnly,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(TaskViewsTool.properties),
            "required": .array([.string("operation")]),
            "additionalProperties": .bool(false),
        ])
    )
}

/// Shared validation keeps MCP mutations atomic before the app persists or syncs a board.
public enum TaskViewsTool {
    public static let name = "ide__task_views"

    static var properties: [String: JSONValue] {
        let string: JSONValue = .object(["type": .string("string")])
        let strings: JSONValue = .object(["type": .string("array"), "items": string])
        let boolean: JSONValue = .object(["type": .string("boolean")])
        return [
            "operation": .object(["type": .string("string"), "enum": .array(
                ["list", "create", "update", "delete", "reorder"].map(JSONValue.string))]),
            "project_id": string,
            "view_id": .object(["type": .string("string"), "description": .string("Required for update and delete.")]),
            "view_ids": .object(["type": .string("array"), "items": string,
                                 "description": .string("Complete ordered list of view UUIDs for reorder.")]),
            "name": string,
            "layout": .object(["type": .string("string"), "enum": .array([.string("board"), .string("table")])]),
            "tags": strings, "versions": strings, "milestones": strings, "story_ids": strings,
            "statuses": strings, "story_panel_statuses": strings,
            "is_default": boolean, "is_hidden": boolean,
            "filter_script": .object(["type": .array([.string("string"), .string("null")]),
                                      "description": .string("Optional Swift filter script; null clears it. Uses the same filter runner as the view editor.")]),
            "column_sorts": .object([
                "type": .string("object"),
                "description": .string("Column ID to sort settings; replaces all saved column sorts. Empty object clears sorting."),
                "additionalProperties": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "field": .object(["type": .string("string"), "enum": .array(TaskColumnSort.Field.allCases.map { .string($0.rawValue) })]),
                        "descending": boolean,
                    ]),
                    "required": .array([.string("field"), .string("descending")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]
    }

    /// Returns all effective views, in tab order, after a successful operation.
    public static func apply(_ arguments: JSONValue, to board: inout TaskBoard) throws -> JSONValue {
        guard let object = arguments.objectValue,
              let operation = arguments["operation"]?.stringValue else {
            throw IDEToolError.invalidArguments("operation is required.")
        }
        let viewFields: Set<String> = ["name", "layout", "tags", "versions", "milestones", "story_ids",
                                      "statuses", "story_panel_statuses", "is_default", "is_hidden", "filter_script", "column_sorts"]
        let allowed: Set<String>
        switch operation {
        case "list": allowed = []
        case "create": allowed = viewFields
        case "update": allowed = viewFields.union(["view_id"])
        case "delete": allowed = ["view_id"]
        case "reorder": allowed = ["view_ids"]
        default: throw IDEToolError.invalidArguments("Unknown operation: \(operation).")
        }
        let extra = Set(object.keys).subtracting(allowed.union(["operation", "project_id"]))
        guard extra.isEmpty else {
            throw IDEToolError.invalidArguments("Unsupported fields for \(operation): \(extra.sorted().joined(separator: ", ")).")
        }
        var updated = board
        switch operation {
        case "create", "update":
            var view = TaskSavedView(name: "")
            if operation == "update" {
                let id: UUID = try required("view_id", in: arguments)
                guard let existing = board.effectiveViews.first(where: { $0.id == id }) else {
                    throw IDEToolError.invalidArguments("Unknown view_id. List task views first.")
                }
                view = existing
            }
            if let value: String = try optional("name", in: arguments) {
                view.name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !view.name.isEmpty else { throw IDEToolError.invalidArguments("A nonempty name is required.") }
            if let value: TaskViewLayout = try optional("layout", in: arguments) { view.layout = value }
            if let value: [String] = try optional("tags", in: arguments) { view.tags = value }
            if let value: [String] = try optional("versions", in: arguments) { view.versions = value }
            if let value: [String] = try optional("milestones", in: arguments) { view.milestones = value }
            if let value: [UUID] = try optional("story_ids", in: arguments) {
                guard Set(value).isSubset(of: Set(board.stories.map(\.id))) else {
                    throw IDEToolError.invalidArguments("story_ids contains an unknown story. Call ide__get_stories first.")
                }
                view.storyIds = value
            }
            if let value: [TaskStatus] = try optional("statuses", in: arguments) {
                try validateStatuses(value, board: board)
                view.statuses = value
            }
            if let value: [TaskStatus] = try optional("story_panel_statuses", in: arguments) {
                try validateStatuses(value, board: board)
                view.storyPanelStatuses = value
            }
            if let value: Bool = try optional("is_default", in: arguments) { view.isDefault = value }
            if let value: Bool = try optional("is_hidden", in: arguments) { view.isHidden = value }
            if arguments["filter_script"] != nil {
                view.filterScript = arguments["filter_script"] == .null ? nil : try required("filter_script", in: arguments)
                view.filterSnapshot = nil
            }
            if let value: [String: TaskColumnSort] = try optional("column_sorts", in: arguments) {
                try validateStatuses(value.keys.map { TaskStatus(rawValue: $0) }, board: board)
                view.columnSorts = value
            }
            updated.upsertSavedView(view)
        case "delete":
            let id: UUID = try required("view_id", in: arguments)
            guard board.effectiveViews.contains(where: { $0.id == id }) else {
                throw IDEToolError.invalidArguments("Unknown view_id. List task views first.")
            }
            guard board.effectiveViews.count > 1 else {
                throw IDEToolError.invalidArguments("The last task view cannot be deleted.")
            }
            updated.savedViews.removeAll { $0.id == id }
        case "reorder":
            let ids: [UUID] = try required("view_ids", in: arguments)
            let views = board.effectiveViews
            guard ids.count == views.count, Set(ids) == Set(views.map(\.id)) else {
                throw IDEToolError.invalidArguments("view_ids must contain every view ID exactly once.")
            }
            let byId = Dictionary(uniqueKeysWithValues: views.map { ($0.id, $0) })
            updated.savedViews = ids.compactMap { byId[$0] }
        default: break
        }
        let result = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(updated.effectiveViews))
        board = updated
        return result
    }

    private static func optional<T: Decodable>(_ key: String, in arguments: JSONValue) throws -> T? {
        guard arguments[key] != nil else { return nil }
        let value: T = try required(key, in: arguments)
        return value
    }

    private static func required<T: Decodable>(_ key: String, in arguments: JSONValue) throws -> T {
        guard let value = arguments[key] else { throw IDEToolError.invalidArguments("\(key) is required.") }
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            throw IDEToolError.invalidArguments("Invalid \(key): \(error.localizedDescription)")
        }
    }

    private static func validateStatuses(_ values: [TaskStatus], board: TaskBoard) throws {
        guard Set(values).isSubset(of: Set(board.effectiveColumns.map(\.id))) else {
            throw IDEToolError.invalidArguments("Unknown column ID. List task views to discover board columns.")
        }
    }
}
