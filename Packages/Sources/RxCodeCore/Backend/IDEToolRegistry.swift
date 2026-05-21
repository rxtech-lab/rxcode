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
            name: "ide__get_projects",
            description: "List every project registered in RxCode. Use to discover sibling projects you may want to read threads from or chat with.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ])
        ),
        IDETool(
            name: "ide__get_threads",
            description: "List or natural-language search chat threads. With `query`, results are ranked by the same on-device embedding search the global search overlay uses and include matched snippets + scores. Without `query`, returns recent threads sorted by updatedAt. Each result includes the AI-generated summary when available.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional UUID to restrict results to a single project. Applied after ranking when `query` is set."),
                    ]),
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional natural-language query. When set, results are ranked by semantic similarity using on-device embeddings."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of threads to return. Default 50, capped at 200."),
                    ]),
                ]),
            ])
        ),
        IDETool(
            name: "ide__get_thread_messages",
            description: "Fetch the message history of a specific thread by id. Hydrates the full ChatSession (CLI-backed history or RxCode JSON) and returns role+text per message.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "thread_id": .object(["type": .string("string")]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Most recent N messages to return. Default 200, capped at 1000."),
                    ]),
                    "include_tool_calls": .object([
                        "type": .string("boolean"),
                        "description": .string("When true, include tool-call blocks in the messages array. Default false — only user/assistant text is returned."),
                    ]),
                ]),
                "required": .array([.string("thread_id")]),
            ])
        ),
        IDETool(
            name: "ide__get_thread_detail",
            description: "Deprecated alias for ide__get_thread_messages. Prefer ide__get_thread_messages.",
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
            name: "ide__memory_search",
            description: "Search durable RxCode memories. Use this to retrieve saved user preferences, project facts, or decisions relevant to the current task.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Natural-language search query."),
                    ]),
                    "project_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional project UUID to prefer project-local memories while still including global memories."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of memories to return. Default 20, capped at 100."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        IDETool(
            name: "ide__memory_add",
            description: "Add a durable memory to RxCode. Use only when the user explicitly asks to remember something, states a stable preference, or gives a recurring instruction for future/next-time agent runs. Do not save completed work, build results, files changed, available tools, or other transient task details.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "content": .object(["type": .string("string")]),
                    "project_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional project UUID. Ignored when scope is global."),
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array([.string("preference"), .string("fact"), .string("decision")]),
                    ]),
                    "scope": .object([
                        "type": .string("string"),
                        "enum": .array([.string("project"), .string("global")]),
                    ]),
                ]),
                "required": .array([.string("content")]),
            ])
        ),
        IDETool(
            name: "ide__memory_update",
            description: "Update an existing RxCode memory by id.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "content": .object(["type": .string("string")]),
                    "project_id": .object([
                        "type": .string("string"),
                        "description": .string("Optional project UUID. Ignored when scope is global."),
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array([.string("preference"), .string("fact"), .string("decision")]),
                    ]),
                    "scope": .object([
                        "type": .string("string"),
                        "enum": .array([.string("project"), .string("global")]),
                    ]),
                ]),
                "required": .array([.string("id"), .string("content")]),
            ])
        ),
        IDETool(
            name: "ide__memory_delete",
            description: "Delete a durable RxCode memory by id.",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        IDETool(
            name: "ide__send_to_thread",
            description: "Send a chat prompt to a thread in any project — continue an existing thread by `thread_id`, or start a brand-new thread by passing `project_id`. Triggers a real agent run that may consume tokens. Returns the assistant's reply text (waits up to `timeout_seconds`).",
            visibility: .alwaysIDEOnly,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("The user message to send to the target agent."),
                    ]),
                    "thread_id": .object([
                        "type": .string("string"),
                        "description": .string("Continue this existing thread. Mutually exclusive with `project_id`."),
                    ]),
                    "project_id": .object([
                        "type": .string("string"),
                        "description": .string("Start a brand-new thread in this project. Mutually exclusive with `thread_id`."),
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("Optional model override for a new thread."),
                    ]),
                    "agent_provider": .object([
                        "type": .string("string"),
                        "description": .string("Optional agent provider override for a new thread (e.g. 'claude_code', 'codex', 'acp')."),
                    ]),
                    "effort": .object([
                        "type": .string("string"),
                        "description": .string("Optional effort override for a new thread."),
                    ]),
                    "permission_mode": .object([
                        "type": .string("string"),
                        "description": .string("Optional permission mode override for a new thread."),
                    ]),
                    "wait_for_response": .object([
                        "type": .string("boolean"),
                        "description": .string("If true (default), block until the assistant finishes or `timeout_seconds` elapses. If false, return immediately with the new thread id."),
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("number"),
                        "description": .string("How long to wait for the assistant's reply. Default 120, capped at 600. On timeout the call returns the partial text with `done: false` — the caller can poll via ide__get_thread_messages."),
                    ]),
                ]),
                "required": .array([.string("prompt")]),
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
