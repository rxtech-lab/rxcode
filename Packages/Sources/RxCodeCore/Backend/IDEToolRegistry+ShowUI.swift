import Foundation

extension IDEToolRegistry {
    static let showUITool = IDETool(
        name: JSONUITool.ideName,
        description: JSONUITool.description + " Pet sessions always open interactive views beside the desktop pet, overriding the shared inline/dialog presentation behavior above; they never open the companion window or its sheet. Strongly prefer a compact inline UI card directly below the speech caption, keeping the caption visible above it. The UI card fits its content and never replaces the caption: omit pet_presentation or use bubble. First summarize and simplify to essential read-only information in at most five short visible rows, without scrolling, controls or collapse support. Prefer simple Text, Stat or KeyValue elements; avoid unnecessary headings, cards, tables, buttons or decorative layout that would force a popover. Do not choose a dedicated popover merely to include more detail. Use pet_presentation=popover only for explicitly requested expanded views, essential information that cannot reasonably be summarized into the caption, or required interaction such as a requested form. Oversized or interactive specs automatically use a popover. Popover views keep a persistent small entry bubble after collapse or outside-click dismissal, preserving local form state for reopening. Caption UI has no entry or collapse control. Only explicit Remove discards it; entries never auto-expire. Successful pet results confirm visible presentation.",
        visibility: .alwaysIDEOnly,
        inputSchema: {
            var schema = JSONUITool.inputSchema.objectValue ?? [:]
            var properties = schema["properties"]?.objectValue ?? [:]
            properties["pet_presentation"] = .object(["type": .string("string"), "enum": .array([.string("popover"), .string("bubble")])])
            schema["properties"] = .object(properties)
            return .object(schema)
        }()
    )
}
