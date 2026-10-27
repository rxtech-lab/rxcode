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
        public var presentation: Presentation = .inline
    }

    /// Where the view is shown: inline in the transcript, or in a dialog over the chat that a
    /// card in the transcript reopens.
    public enum Presentation: String, Sendable, Hashable, CaseIterable {
        case inline
        case dialog
    }

    public static func payload(from input: [String: JSONValue]) -> Payload {
        // A raw Codex item carries the arguments under `arguments`.
        if input["spec"] == nil, let arguments = input["arguments"]?.objectValue {
            return payload(from: arguments)
        }
        let title = input["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // Accept the spec nested under `spec` or, leniently, inlined at the top level.
        let spec = JSONUISpec(json: input["spec"]) ?? JSONUISpec(json: .object(input))
        let presentation = input["presentation"]?.stringValue.flatMap { Presentation(rawValue: $0.lowercased()) } ?? .inline
        return Payload(title: title, spec: spec, presentation: presentation)
    }

    /// Validates a call's arguments and returns the text result for the agent. Throws a message
    /// listing every problem so the agent can fix the spec and call again. Pass
    /// `supportsDialog: false` from hosts that only draw views inline.
    public static func result(for arguments: JSONValue, supportsDialog: Bool = true) throws -> String {
        try validated(arguments, supportsDialog: supportsDialog).message
    }

    /// Validates a call's arguments and returns the payload to show with the agent's text result.
    public static func validated(_ arguments: JSONValue, supportsDialog: Bool = true) throws -> (payload: Payload, spec: JSONUISpec, message: String) {
        let payload = payload(from: arguments.objectValue ?? [:])
        if let raw = arguments["presentation"]?.stringValue, Presentation(rawValue: raw.lowercased()) == nil {
            throw JSONUIToolError(message: "Unknown `presentation` \"\(raw)\". Use \"inline\" or \"dialog\".")
        }
        guard let spec = payload.spec else {
            throw JSONUIToolError(message: "Missing `spec`: pass an object { root, elements } where elements maps ids to { type, props, children? }.")
        }
        let issues = spec.issues
        guard issues.isEmpty else {
            throw JSONUIToolError(message: "The view was not shown. Fix these problems and call again:\n" + issues.map { "- \($0)" }.joined(separator: "\n"))
        }
        let name = payload.title.map { "\"\($0)\"" } ?? "The view"
        let place = supportsDialog && payload.presentation == .dialog
            ? "in a dialog; the chat shows a card that reopens it"
            : "in the chat"
        let message = "\(name) is displayed to the user \(place) (\(spec.elements.count) elements). Don't repeat its content in text; refer to it briefly instead."
        return (payload, spec, message)
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

    - Form { title? } — local input group; put create/update/delete forms in a dedicated Sheet or Dialog
    - Sheet { title? }, Dialog { title? } — hidden until presented, full-height native sheet on Apple platforms
    - Overlay { title? } — hidden until presented, dismissible status overlay

    Controls:
    - Button { label, action, role?: destructive, disabled? }
    - TextField { label, name?, value?: string, placeholder?, required?, disabled? }
    - TextEditor { label, name?, value?: string, required?, disabled? }
    - Toggle { label, name?, value?: boolean, disabled? }
    - Picker { label, name?, options: string[], value?: string, disabled? }
    - Slider { label, name?, min?: number (0), max?: number (100), step?: number (1), value?: number, disabled? }
    - Alert { title, message?, confirmLabel?, destructive?, confirmAction? } — native alert
    - ConfirmationDialog { title, message?, confirmLabel?, destructive?, confirmAction? } — native confirmation

    Inputs share local state by unique name (defaults to element id). An action is an object:
    { type: "present", target: "element-id" } opens a Sheet, Dialog, Alert, ConfirmationDialog or Overlay;
    { type: "dismiss" } closes it; { type: "set", name: "field-name", value: ... } updates an input;
    { type: "reset" } restores defaults; { type: "submit" } checks required text inputs and captures values locally.
    Submit/reset operate on the enclosing Form, or all inputs outside a Form. An optional target Form id selects a scope.
    Presentation elements can live outside the root tree; their children follow the same tree rules.
    Only one presentation opens at a time; dismiss it before opening another. Action status appears in an overlay.
    These actions do not call tools, execute commands, persist data, or send answers back to the agent.
    The tool returns immediately. Form values are temporary and reset when the view is recreated.
    A host may explicitly supply a submission callback; standard chat rendering captures values locally only.

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

    Display values are strings, numbers or null; controls also accept booleans and action objects. `format`: text|number|money|percent|bytes|duration (seconds). \
    Tones: default|muted|accent|positive|negative|warning. At most 300 elements. After the call, don't repeat \
    the view's content in text.

    `presentation`: "inline" (default) draws the view in the chat. "dialog" opens it in a dialog over the chat \
    instead, and the chat shows a small card that reopens it; the thread's Views list keeps it after the user closes \
    it. Use dialog for larger content that deserves the full window, such as a final report or a dashboard. The call \
    returns without waiting for the dialog to close.
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
                "presentation": .object([
                    "type": .string("string"),
                    "enum": .array(Presentation.allCases.map { .string($0.rawValue) }),
                    "description": .string("inline (default) draws the view in the chat; dialog opens it in a dialog, with a card in the chat to reopen it."),
                ]),
            ]),
            "required": .array([.string("spec")]),
        ])
    }()
}

public struct JSONUIToolError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
