import Foundation

extension IDEToolRegistry {
    static let usageCardsTool = IDETool(
        name: "ide__usage_cards",
        description: "Read credential-free integration configuration, usage snapshots, and cards, or add/update/delete a card view. Card views independently select style, size, metric, briefing visibility, menu bar visibility, and widget visibility. Use get first for integration and card IDs. Credentials and OAuth sign-in are managed in the native Briefing integration sheet, never through this tool.",
        visibility: .alwaysIDEOnly,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "operation": .object(["type": .string("string"), "enum": .array([.string("get"), .string("upsert_card"), .string("delete_card")])]),
                "card_id": .object(["type": .string("string")]),
                "integration_id": .object(["type": .string("string")]),
                "style": .object(["type": .string("string"), "enum": .array(UsageCardConfiguration.styles.map(JSONValue.string))]),
                "size": .object(["type": .string("string"), "enum": .array(UsageCardSize.optionValues.map(JSONValue.string)), "description": .string("Widget-style briefing size: small (1x1 cell), medium (2x1), large (2x2), xlarge (4x2). \"default\" follows the style.")]),
                "metric_id": .object(["type": .string("string"), "description": .string("Empty string selects all metrics.")]),
                "metric_ids": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Select multiple metric IDs. Empty array selects all metrics. Takes precedence over metric_id.")]),
                "visible": .object(["type": .string("boolean")]),
                "menu_bar": .object(["type": .string("boolean")]),
                "widget": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("operation")]),
            "additionalProperties": .bool(false)
        ])
    )
}
