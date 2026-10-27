import Foundation

// Interactive explanations described as JSON and drawn natively, in the spirit of Vercel's
// json-render. A spec is a flat map of elements keyed by id plus the id of its root; containers
// list their children by id. Every element's `type` comes from the closed catalog in
// `JSONUICatalog`, so agents can only compose components the clients know how to draw.
// SwiftUI renderer: `RxCodeChatKit/JSONUIView.swift`. Agents reach it through `JSONUITool`.

/// One element of a spec: a catalog component (`Stack`, `Table`, `Stat`…), its props and, for
/// containers, the ids of its children. Props stay raw JSON so a spec round-trips unchanged and
/// components a client doesn't know yet are skipped rather than failing the whole view.
public struct JSONUIElement: Codable, Sendable, Hashable {
    public var type: String
    public var props: [String: JSONValue]
    public var children: [String]

    public init(type: String, props: [String: JSONValue] = [:], children: [String] = []) {
        self.type = type
        self.props = props
        self.children = children
    }

    private enum CodingKeys: String, CodingKey { case type, props, children }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        props = try c.decodeIfPresent([String: JSONValue].self, forKey: .props) ?? [:]
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(props, forKey: .props)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }
}

/// A json-render style spec: a flat map of elements and the id of the root.
public struct JSONUISpec: Codable, Sendable, Hashable {
    public var root: String
    public var elements: [String: JSONUIElement]

    public init(root: String, elements: [String: JSONUIElement]) {
        self.root = root
        self.elements = elements
    }

    /// Reads a spec from a JSON value: an object with `root` and `elements`, or that object
    /// serialized as a string (some models stringify nested arguments).
    public init?(json: JSONValue?) {
        var value = json
        if case .string(let text)? = value {
            value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        }
        guard case .object? = value,
              let data = try? JSONEncoder().encode(value),
              let spec = try? JSONDecoder().decode(JSONUISpec.self, from: data) else { return nil }
        self = spec
    }
}

/// The component catalog shared by the tool's description, validation and the renderer.
public enum JSONUICatalog {
    public static let containerTypes: Set<String> = ["Stack", "Grid", "Card", "Disclosure", "Tabs", "Form", "Sheet", "Dialog", "Overlay"]
    public static let leafTypes: Set<String> = [
        "Heading", "Text", "Badge", "Stat", "Callout", "KeyValue", "List", "Steps", "Table",
        "BarChart", "Progress", "Code", "Divider", "Link", "Image", "Gallery",
        "Button", "TextField", "TextEditor", "Toggle", "Picker", "Slider", "Alert", "ConfirmationDialog",
    ]
    public static let elementTypes = containerTypes.union(leafTypes)
    public static let inputTypes: Set<String> = ["TextField", "TextEditor", "Toggle", "Picker", "Slider"]
    public static let presentationTypes: Set<String> = ["Sheet", "Dialog", "Overlay", "Alert", "ConfirmationDialog"]
    public static let actionTypes: Set<String> = ["present", "dismiss", "set", "reset", "submit"]
    public static let tones = ["default", "muted", "accent", "positive", "negative", "warning"]
    public static let maxElements = 300
    public static let maxDepth = 24
}

public extension JSONUISpec {
    /// Problems with the spec: a missing root or child, an element used twice, an unknown
    /// component, a leaf with children, too many elements. Empty when the spec can be drawn.
    var issues: [String] {
        var issues: [String] = []
        if elements.count > JSONUICatalog.maxElements {
            issues.append("At most \(JSONUICatalog.maxElements) elements are allowed (got \(elements.count)).")
        }
        for (id, element) in elements.sorted(by: { $0.key < $1.key }) {
            if !JSONUICatalog.elementTypes.contains(element.type) {
                issues.append("elements.\(id): unknown type \"\(element.type)\". Use one of: \(JSONUICatalog.elementTypes.sorted().joined(separator: ", ")).")
            } else if !element.children.isEmpty && !JSONUICatalog.containerTypes.contains(element.type) {
                issues.append("elements.\(id): only \(JSONUICatalog.containerTypes.sorted().joined(separator: ", ")) have children.")
            }
        }
        issues += interactionIssues
        guard elements[root] != nil else {
            issues.append("root: unknown element \"\(root)\".")
            return issues
        }
        // Presentations can be detached from the root, so validate every tree in the map.
        var seenChildren: Set<String> = []
        var uniqueChildren = true
        for (parent, element) in elements.sorted(by: { $0.key < $1.key }) {
            for (index, child) in element.children.enumerated() {
                if elements[child] == nil {
                    issues.append("elements.\(parent).children[\(index)]: unknown element \"\(child)\".")
                } else if child == root || !seenChildren.insert(child).inserted {
                    uniqueChildren = false
                    issues.append("elements.\(parent).children[\(index)]: element \"\(child)\" is used more than once.")
                }
            }
        }
        func checkPath(_ id: String, path: Set<String>) -> Bool {
            guard !path.contains(id), path.count < JSONUICatalog.maxDepth else { return false }
            var path = path
            path.insert(id)
            return (elements[id]?.children ?? []).allSatisfy { checkPath($0, path: path) }
        }
        if uniqueChildren && !elements.keys.allSatisfy({ checkPath($0, path: []) }) {
            issues.append("elements: trees must be acyclic and at most \(JSONUICatalog.maxDepth) levels deep.")
        }
        return issues
    }

    /// The readable text of the view, top to bottom: the plain-text picture returned to the
    /// agent and used where the view can't be drawn.
    var textLines: [String] {
        var lines: [String] = []
        var visited: Set<String> = []
        func show(_ value: JSONValue?) -> String {
            switch value {
            case .string(let text)?: text
            case .number(let number)?: number.formatted()
            case .bool(let flag)?: flag ? "yes" : "no"
            default: ""
            }
        }
        func visit(_ id: String, depth: Int) {
            guard depth < JSONUICatalog.maxDepth, visited.insert(id).inserted, let element = elements[id] else { return }
            switch element.type {
            case "Card", "Disclosure", "Form", "Sheet", "Dialog", "Overlay", "Alert", "ConfirmationDialog":
                if let title = element.string("title") { lines.append(title) }
            case "Button", "TextField", "TextEditor", "Toggle", "Picker", "Slider":
                if let label = element.string("label") { lines.append(label) }
            case "Heading", "Text", "Badge":
                if let text = element.string("text") { lines.append(text) }
            case "Callout":
                lines.append([element.string("title"), element.string("text")].compactMap { $0 }.joined(separator: ": "))
            case "Stat", "Progress":
                lines.append("\(element.string("label") ?? ""): \(show(element.props["value"]))")
            case "KeyValue":
                lines += element.objects("items").map { "\(show($0["label"])): \(show($0["value"]))" }
            case "List":
                lines += element.strings("items").map { "- \($0)" }
            case "Steps":
                lines += element.objects("items").enumerated().map { index, item in
                    "\(index + 1). \(show(item["title"]))" + (item["detail"].map { " — \(show($0))" } ?? "")
                }
            case "Table":
                let table = JSONUITable(element)
                if let caption = table.caption { lines.append(caption) }
                lines.append(table.columns.map(\.label).joined(separator: " | "))
                for row in table.rows {
                    lines.append(table.columns.map { show(row.cells[$0.key]?.value) }.joined(separator: " | "))
                }
            case "BarChart":
                if let title = element.string("title") { lines.append(title) }
                lines += element.objects("items").map { "\(show($0["label"])): \(show($0["value"]))" }
            case "Code":
                if let caption = element.string("caption") { lines.append(caption) }
                if let code = element.string("code") { lines.append(code) }
            case "Link":
                lines.append("\(element.string("title") ?? ""): \(element.string("url") ?? "")")
            case "Image":
                if let caption = element.string("caption") { lines.append(caption) }
            default:
                break
            }
            if element.type == "Tabs" {
                let labels = element.strings("tabs")
                for (index, child) in element.children.enumerated() {
                    if index < labels.count { lines.append("[\(labels[index])]") }
                    visit(child, depth: depth + 1)
                }
            } else {
                for child in element.children { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return lines.filter { !$0.isEmpty }
    }
}

// MARK: - Reading props

public extension JSONUIElement {
    func string(_ key: String) -> String? {
        switch props[key] {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value): value.formatted()
        default: nil
        }
    }

    func number(_ key: String) -> Double? {
        props[key]?.numberValue
    }

    func bool(_ key: String) -> Bool? {
        props[key]?.boolValue
    }

    func strings(_ key: String) -> [String] {
        (props[key]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    func objects(_ key: String) -> [[String: JSONValue]] {
        (props[key]?.arrayValue ?? []).compactMap(\.objectValue)
    }
}

/// How a view displays a value: text as is, numbers by `format` (`number`, `money`, `percent`, `bytes`, `duration`).
public enum JSONUIFormat {
    public static func text(_ value: JSONValue?, format: String?, currency: String? = nil) -> String {
        switch value {
        case .string(let text)?: return text
        case .bool(let flag)?: return flag ? "Yes" : "No"
        case .number(let number)?:
            switch format {
            case "money":
                return number.formatted(.currency(code: currency ?? "USD"))
            case "percent":
                return (number / 100).formatted(.percent.precision(.fractionLength(0...1)))
            case "bytes":
                return Int64(number).formatted(.byteCount(style: .file))
            case "duration":
                // Seconds; sub-second values read better as milliseconds.
                if abs(number) < 1 { return "\((number * 1000).formatted(.number.precision(.fractionLength(0...1)))) ms" }
                return Duration.seconds(number).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
            default:
                return number.formatted()
            }
        default:
            return "—"
        }
    }
}

/// A `Table` element's columns and rows, with the totals of columns marked `total`.
public struct JSONUITable: Sendable, Hashable {
    public struct Column: Sendable, Hashable, Identifiable {
        public var key: String
        public var label: String
        /// `leading`, `center` or `trailing`.
        public var align: String?
        public var format: String?
        public var currency: String?
        public var total: Bool
        public var id: String { key }
    }

    /// A cell: its value, an optional line of detail under it, and its tone.
    public struct Cell: Sendable, Hashable {
        public var value: JSONValue?
        public var detail: String?
        public var tone: String?
    }

    public struct Row: Sendable, Hashable {
        public var cells: [String: Cell]
        /// `default`, `muted`, `emphasis` or `total`.
        public var style: String?
    }

    public var caption: String?
    public var columns: [Column]
    public var rows: [Row]
    public var totalLabel: String?

    public init(_ element: JSONUIElement) {
        caption = element.string("caption")
        totalLabel = element.string("totalLabel")
        columns = element.objects("columns").compactMap { column in
            guard let key = column["key"]?.stringValue else { return nil }
            return Column(
                key: key,
                label: column["label"]?.stringValue ?? key,
                align: column["align"]?.stringValue,
                format: column["format"]?.stringValue,
                currency: column["currency"]?.stringValue,
                total: column["total"]?.boolValue == true
            )
        }
        rows = element.objects("rows").map { row in
            var cells: [String: Cell] = [:]
            for (key, value) in row["cells"]?.objectValue ?? [:] {
                if case .object(let object) = value {
                    cells[key] = Cell(value: object["value"], detail: object["detail"]?.stringValue, tone: object["tone"]?.stringValue)
                } else {
                    cells[key] = Cell(value: value)
                }
            }
            return Row(cells: cells, style: row["style"]?.stringValue)
        }
    }

    /// Whether any column asks for a total row.
    public var hasTotals: Bool { columns.contains(where: \.total) }

    /// The sum of a column's numeric cells, skipping rows already styled as totals; nil when the
    /// column has no total.
    public func total(of column: Column) -> Double? {
        guard column.total else { return nil }
        return rows.filter { $0.style != "total" }.reduce(0) { $0 + ($1.cells[column.key]?.value?.numberValue ?? 0) }
    }
}
