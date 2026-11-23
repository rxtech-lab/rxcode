extension IDEToolRegistry {
    static let codingPlanTools: [IDETool] = {
        let uuid: JSONValue = .object(["type": .string("string"), "format": .string("uuid")])
        let page: [String: JSONValue] = [
            "offset": .object(["type": .string("integer"), "minimum": .number(0), "default": .number(0)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(50), "default": .number(20)])
        ]
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = []) -> IDETool {
            IDETool(name: name, description: description, visibility: .alwaysIDEOnly, inputSchema: .object([
                "type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string))
            ]))
        }
        return [
            tool("ide__list_coding_plans",
                 "Discover saved coding plans across projects, newest activity first. Filter by project_id and/or a planning or linked implementation thread_id. Reports plan readiness, implementation evidence and a planned-feature excerpt. The planning debate is stored separately from chat messages.",
                 page.merging(["project_id": uuid, "thread_id": .object(["type": .string("string")])]) { _, new in new }),
            tool("ide__list_coding_plan_versions",
                 "List a coding plan's version history newest first with stable version IDs, chronological version numbers, current and approved flags. Use get_coding_plan_version to read a version.",
                 page.merging(["plan_id": uuid, "project_id": uuid]) { _, new in new }, required: ["plan_id"]),
            tool("ide__get_coding_plan_version",
                 "Read the full original Markdown of a selected version using the IDs from coding-plan discovery and version listing.",
                 ["plan_id": uuid, "version_id": uuid, "project_id": uuid], required: ["plan_id", "version_id"])
        ]
    }()
}
