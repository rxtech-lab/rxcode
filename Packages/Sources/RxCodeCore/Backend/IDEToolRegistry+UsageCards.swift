import Foundation

extension IDEToolRegistry {
    static let integrationUsageTool = IDETool(
        name: "ide__get_integration_usage",
        description: "Get usage and billing metrics for configured Vercel, Neon, Turso, Cloudflare, GitHub CI, AI usage/limits, and supported ACP integrations in the current workspace. Omit filters to discover all connections, including connections without cards or data. Returns metric values and units, scope, period, ISO 8601 fetch timestamps, stale status, and per-integration errors. Cached by default; set refresh to fetch selected connections using stored credentials. Configure connections in the native Briefing integration sheet. Never returns credentials. For the active agent's rate limits use ide__get_usage.",
        visibility: .alwaysIDEOnly,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "plugin_id": .object(["type": .string("string"), "description": .string("Optional plugin ID, e.g. vercel, neon, turso, cloudflare, github-ci, ai-usage, ai-limits, acp-opencode, or acp-antigravity.")]),
                "integration_id": .object(["type": .string("string"), "description": .string("Optional connection UUID from a previous response. Combined with plugin_id when both are supplied.")]),
                "refresh": .object(["type": .string("boolean"), "default": .bool(false), "description": .string("Fetch fresh usage for matching connections. A failed refresh preserves previous metrics and marks them stale with an error.")])
            ]),
            "additionalProperties": .bool(false)
        ])
    )

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
