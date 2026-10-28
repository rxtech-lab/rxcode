import Foundation

extension IDEToolRegistry {
    static let usageCardsTool = IDETool(
        name: "ide__usage_cards",
        description: "Read credential-free integration configuration, usage snapshots, and cards, or add/update/delete a card view. Card views independently select style, metric, briefing visibility, menu bar visibility, and widget visibility. Use get first for integration and card IDs. Credentials and OAuth sign-in are managed in the native Briefing integration sheet, never through this tool.",
        visibility: .alwaysIDEOnly,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "operation": .object(["type": .string("string"), "enum": .array([.string("get"), .string("upsert_card"), .string("delete_card")])]),
                "card_id": .object(["type": .string("string")]),
                "integration_id": .object(["type": .string("string")]),
                "style": .object(["type": .string("string"), "enum": .array(UsageCardConfiguration.styles.map(JSONValue.string))]),
                "metric_id": .object(["type": .string("string"), "description": .string("Empty string selects all metrics.")]),
                "visible": .object(["type": .string("boolean")]),
                "menu_bar": .object(["type": .string("boolean")]),
                "widget": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("operation")]),
            "additionalProperties": .bool(false)
        ])
    )
}
