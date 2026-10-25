import Foundation

/// The "show UI" tool: an agent passes a `JSONUISpec` and the chat draws it inline as native
/// components. The desktop exposes it through the IDE MCP server as `ide__show_ui`; the mobile
/// Flowcy agent declares it as `show_ui` and answers it on the phone.
public enum JSONUITool {
    public static let ideName = "ide__show_ui"
    public static let flowcyName = "show_ui"

    /// Whether a chat tool call is this tool, however the runtime prefixed it
    /// (`mcp__rxcode-ide__ide__show_ui`, `mcp__rxcode__ide__show_ui`, `show_ui`…).
    public static func matches(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        return name == flowcyName || name.hasSuffix(ideName)
    }

    /// Whether a chat tool call is this tool. Also recognizes calls saved under a generic MCP name
    /// (`mcp__rxcode-ide`, `mcpToolCall`) before the Codex parser read the tool name, by their input.
    public static func matches(_ toolCall: ToolCall) -> Bool {
        if matches(toolCall.name) { return true }
        let name = toolCall.name.lowercased()
        guard ["mcp__rxcode-ide", "mcp__rxcode", "mcptoolcall"].contains(name) else { return false }
        if let tool = toolCall.input["tool"]?.stringValue, matches(tool) { return true }
        return toolCall.input["spec"].map { JSONUISpec(json: $0) != nil } ?? false
    }

    /// The view a tool call asks for: its optional title and spec. The spec is nil while the
    /// call is still streaming its arguments or when they can't be read.
    public struct Payload: Sendable, Hashable {
        public var title: String?
        public var spec: JSONUISpec?
    }

    public static func payload(from input: [String: JSONValue]) -> Payload {
        // A raw Codex item carries the arguments under `arguments`.
        if input["spec"] == nil, let arguments = input["arguments"]?.objectValue {
            return payload(from: arguments)
        }
        let title = input["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // Accept the spec nested under `spec` or, leniently, inlined at the top level.
        let spec = JSONUISpec(json: input["spec"]) ?? JSONUISpec(json: .object(input))
        return Payload(title: title, spec: spec)
    }

    /// Validates a call's arguments and returns the text result for the agent. Throws a message
    /// listing every problem so the agent can fix the spec and call again.
    public static func result(for arguments: JSONValue) throws -> String {
        let payload = payload(from: arguments.objectValue ?? [:])
        guard let spec = payload.spec else {
            throw JSONUIToolError(message: "Missing `spec`: pass an object { root, elements } where elements maps ids to { type, props, children? }.")
        }
        let issues = spec.issues
        guard issues.isEmpty else {
            throw JSONUIToolError(message: "The view was not shown. Fix these problems and call again:\n" + issues.map { "- \($0)" }.joined(separator: "\n"))
        }
        let name = payload.title.map { "\"\($0)\"" } ?? "The view"
        return "\(name) is displayed to the user in the chat (\(spec.elements.count) elements). Don't repeat its content in text; refer to it briefly instead."
    }

    public static let description = """
    Show the user an interactive native UI inline in the chat to explain something visually: comparisons, \
    architecture or flow walkthroughs, step-by-step plans, metrics, option trade-offs, test or build summaries. \
    Prefer it over long Markdown tables or lists when structure helps understanding. The view is described as JSON \
    in the style of Vercel's json-render: `spec: { root, elements }` where `elements` maps element ids to \
    `{ type, props, children? }` and `root` is the top element's id. Containers list children by id; each id is used \
    once. Unknown types are refused.

    Containers (have `children`):
    - Stack { direction?: vertical|horizontal, gap?: none|small|medium|large }
    - Grid { columns?: 1-4 }
    - Card { title?, subtitle?, tone? }
    - Disclosure { title, expanded? } — collapsible section, collapsed by default
    - Tabs { tabs: string[] } — segmented tabs; child i is the content of tabs[i]

    Leaves:
    - Heading { text, level?: 1-3 }
    - Text { text, tone?, size?: small|body|large, weight?: regular|semibold|bold } — Markdown allowed
    - Badge { text, tone? }
    - Stat { label, value, format?, currency?, detail?, tone? }
    - Callout { title?, text, tone?: info|tip|warning|success }
    - KeyValue { items: [{ label, value, format?, currency?, tone? }] }
    - List { items: string[], ordered? }
    - Steps { items: [{ title, detail?, status?: pending|active|done|failed }] } — numbered timeline
    - Table { caption?, columns: [{ key, label, align?: leading|center|trailing, format?, currency?, total? }], \
    rows: [{ cells: { [key]: value | { value, detail?, tone? } }, style?: default|muted|emphasis|total }], totalLabel? }
    - BarChart { title?, format?, currency?, items: [{ label, value: number, detail?, tone? }] }
    - Progress { label, value: number, total?: number (default 100), detail?, tone? }
    - Code { code, language?, caption? }
    - Divider {}
    - Link { title, url } — http(s) only
    - Image { url (https), caption?, aspect?: wide|square|portrait }
    - Gallery { images: [{ url (https), caption? }] }

    Values are strings, numbers or null. `format`: text|number|money|percent|bytes|duration (seconds). \
    Tones: default|muted|accent|positive|negative|warning. At most 300 elements. After the call, don't repeat \
    the view's content in text.
    """

    public static let inputSchema: JSONValue = {
        let types: [JSONValue] = JSONUICatalog.elementTypes.sorted().map { .string($0) }
        let element: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "type": .object(["type": .string("string"), "enum": .array(types)]),
                "props": .object(["type": .string("object")]),
                "children": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ]),
            "required": .array([.string("type")]),
        ])
        let spec: JSONValue = .object([
            "type": .string("object"),
            "description": .string("The json-render spec: { root, elements }."),
            "properties": .object([
                "root": .object(["type": .string("string"), "description": .string("Id of the top element in `elements`.")]),
                "elements": .object([
                    "type": .string("object"),
                    "description": .string("Map of element id to { type, props, children? }."),
                    "additionalProperties": element,
                ]),
            ]),
            "required": .array([.string("root"), .string("elements")]),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"), "description": .string("Optional short title shown above the view.")]),
                "spec": spec,
            ]),
            "required": .array([.string("spec")]),
        ])
    }()
}

public struct JSONUIToolError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
