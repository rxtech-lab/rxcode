import Foundation

extension IDEToolRegistry {
    static let listAgentModelsTool = IDETool(
        name: "ide__list_agent_models",
        description: "List all supported providers (Claude Code, Codex, ACP) and currently available model ids grouped like the app's model picker, including every enabled ACP client. Use the returned provider and model ids with ide__update_task or ide__run_task. Reads the current catalog without starting an agent: Claude aliases are built in, Codex uses discovered models or marked fallback entries, and ACP uses configured/discovered models or a client Default entry. Disabled ACP clients are omitted.",
        visibility: .alwaysIDEOnly,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )
}
