import Foundation

/// Catalog of IDE-side MCP tools the editor can expose to agent backends.
/// Tools are gated by the *complement* of the backend's capability set:
/// if a backend natively supports a feature, the corresponding polyfill
/// tool is NOT registered for that session. Tools tagged `.alwaysIDEOnly`
/// are exposed to every backend regardless of capabilities — they expose
/// IDE-only state (running jobs, thread history, usage) that has no
/// equivalent in any agent's native toolset.
public struct IDETool: Sendable {
    public enum Visibility: Sendable {
        /// Exposed only when the backend lacks the matched capability.
        case polyfill(BackendCapability)
        /// Exposed unconditionally — agent-native equivalents don't exist.
        case alwaysIDEOnly
    }

    public let name: String
    public let description: String
    public let visibility: Visibility
    /// JSON Schema for the tool's input parameters, serialized as a
    /// `JSONValue` object. Consumed by the MCP server's `tools/list` handler.
    public let inputSchema: JSONValue

    public init(name: String, description: String, visibility: Visibility, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.visibility = visibility
        self.inputSchema = inputSchema
    }
}

public enum IDEToolRegistry {
    public static let allTools: [IDETool] = [
        IDETool(
            name: "ide__ask_user",
            description: "Ask the user a question and wait for their selection. Use when you need clarification or a decision the user must make.",
            visibility: .polyfill(.askUserQuestion),
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "question": .object([
                        "type": .string("string"),
                        "description": .string("The question to show the user."),
                    ]),
                    "options": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("2–4 mutually-exclusive options the user can pick from."),
                    ]),
                    "allow_multiple": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether more than one option may be selected."),
                    ]),
                ]),
                "required": .array([.string("question"), .string("options")]),
            ])
        ),
        IDETool(
            name: "ide__set_todos",
            description: "Replace the current todo list shown in the IDE sidebar. Use to track multi-step work.",
            visibility: .polyfill(.todos),
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "todos": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "content": .object(["type": .string("string")]),
                                "status": .object([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string("pending"),
                                        .string("in_progress"),
                                        .string("completed"),
                                    ]),
                                ]),
                            ]),
                            "required": .array([.string("content"), .string("status")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("todos")]),
            ])
        ),
        IDETool(
            name: "ide__get_running_jobs",
            description: "List run-profile jobs (dev servers, scripts) currently executing in the IDE.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        IDETool(
            name: "ide__get_job_output",
            description: "Fetch the tail of a running job's output buffer.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "job_id": .object(["type": .string("string")]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum lines to return from the tail. Defaults to 200."),
                    ]),
                ]),
                "required": .array([.string("job_id")]),
            ])
        ),
        IDETool(
            name: "ide__get_threads",
            description: "List chat threads in the current project (or all projects if none specified).",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": .object(["type": .string("string")]),
                ]),
            ])
        ),
        IDETool(
            name: "ide__get_thread_detail",
            description: "Fetch the message history of a specific thread by id.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "thread_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("thread_id")]),
            ])
        ),
        IDETool(
            name: "ide__get_usage",
            description: "Get current rate-limit / token usage stats reported by the active provider.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
    ]

    /// Returns the tools that should be exposed to an agent whose declared
    /// capabilities are `capabilities`. Polyfill tools whose capability is
    /// already covered natively are filtered out; `alwaysIDEOnly` tools
    /// always pass through.
    public static func tools(for capabilities: CapabilitySet) -> [IDETool] {
        allTools.filter { tool in
            switch tool.visibility {
            case .polyfill(let cap):
                return !capabilities.contains(cap)
            case .alwaysIDEOnly:
                return true
            }
        }
    }
}
