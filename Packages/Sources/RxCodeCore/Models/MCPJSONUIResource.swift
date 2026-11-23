import Foundation

/// Values captured at the time the user submits a native MCP App form.
public struct MCPJSONUIActionContext: Sendable, Equatable {
    public let actionID: String
    public let toolName: String
    public let arguments: [String: JSONValue]
}

public typealias MCPJSONUISubmit = @Sendable (MCPJSONUIActionContext) async throws -> JSONValue

/// A validated v1 document from an MCP server. The standard JSON UI elements also drive
/// local-only forms. Only explicitly bound submit buttons can call the originating server.
public struct MCPJSONUIResource: Sendable {
    public static let mimeType = "application/vnd.rxcode.ui+json;version=1"
    public static let maxBytes = 512_000
    private static let maxRenderItems = 4096

    public let spec: JSONUISpec
    private let bindings: [String: Binding]

    public struct InvalidDocument: LocalizedError {
        public let errorDescription: String?
        init(_ reason: String) { errorDescription = reason }
    }

    private struct Binding: Decodable, Sendable {
        let tool: String
        let arguments: [String: String]

        init(from decoder: Decoder) throws {
            let fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
            guard Set(fields.keys) == ["tool", "arguments"],
                  let tool = fields["tool"]?.stringValue, !tool.hasPrefix("mcp__"),
                  tool.range(of: #"\A[A-Za-z0-9_.-]{1,128}\z"#, options: .regularExpression) != nil,
                  let mapping = fields["arguments"]?.objectValue else {
                throw InvalidDocument("Each binding requires a local tool name and an arguments map.")
            }
            self.tool = tool
            arguments = try mapping.mapValues {
                guard let name = $0.stringValue, !name.isEmpty else {
                    throw InvalidDocument("Each argument must map to an input name.")
                }
                return name
            }
        }
    }

    private struct Document: Decodable {
        let spec: JSONUISpec
        let bindings: [String: Binding]

        private enum CodingKeys: CodingKey { case bindings }

        init(from decoder: Decoder) throws {
            spec = try JSONUISpec(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            bindings = try fields.decodeIfPresent([String: Binding].self, forKey: .bindings) ?? [:]
        }
    }

    public init(data: Data) throws {
        guard data.count <= Self.maxBytes else { throw InvalidDocument("The MCP JSON UI document is too large.") }
        try Self.checkJSONNesting(data)
        let document = try JSONDecoder().decode(Document.self, from: data)
        let spec = document.spec
        let parents = try Self.checkGraph(spec)
        if let issue = spec.issues.first { throw InvalidDocument(issue) }
        for (id, binding) in document.bindings {
            guard let button = spec.elements[id], button.type == "Button",
                  let action = button.props["action"], action["type"] == "submit" else {
                throw InvalidDocument("Binding \(id) must reference a submit Button.")
            }
            var scope = action["target"]?.stringValue ?? parents[id]
            while let ancestor = scope, spec.elements[ancestor]?.type != "Form" { scope = parents[ancestor] }
            let names = scope.map { spec.inputNames(in: $0) } ?? Set(spec.initialValues.keys)
            guard binding.arguments.keys.allSatisfy({ !$0.isEmpty }),
                  binding.arguments.values.allSatisfy(names.contains) else {
                throw InvalidDocument("Binding \(id) must map each argument to an input in its form.")
            }
        }
        self.spec = spec
        bindings = document.bindings
    }

    /// Nil for a local-only submit. Missing values are an error, never a partial call.
    public func actionContext(for id: String, values: [String: JSONValue]) throws -> MCPJSONUIActionContext? {
        guard let binding = bindings[id] else { return nil }
        let arguments = try binding.arguments.mapValues { name in
            guard let value = values[name] else { throw InvalidDocument("Missing form value for \(name).") }
            return value
        }
        return MCPJSONUIActionContext(actionID: id, toolName: binding.tool, arguments: arguments)
    }

    /// Limit nesting before Codable recursively decodes arbitrary JSON props.
    private static func checkJSONNesting(_ data: Data) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            guard byte != 0 else { throw InvalidDocument("The MCP JSON UI document must contain UTF-8 JSON.") }
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
            } else {
                switch byte {
                case 0x22: inString = true
                case 0x7b, 0x5b:
                    depth += 1
                    guard depth <= 64 else { throw InvalidDocument("The MCP JSON UI document is nested too deeply.") }
                case 0x7d, 0x5d: depth -= 1
                default: break
                }
            }
        }
    }

    /// Reject shared descendants and bound the whole forest, including detached presentations,
    /// before running any recursive spec validation or renderer code.
    private static func checkGraph(_ spec: JSONUISpec) throws -> [String: String] {
        guard spec.elements.count <= JSONUICatalog.maxElements else { throw InvalidDocument("Too many UI elements.") }
        var parents: [String: String] = [:]
        var work = spec.elements.count
        for (id, element) in spec.elements {
            for child in element.children {
                guard spec.elements[child] != nil, parents.updateValue(id, forKey: child) == nil else {
                    throw InvalidDocument("Unknown or repeated child in \(id).")
                }
            }
            for value in element.props.values { work += value.arrayValue?.count ?? 0 }
            if element.type == "Table" {
                let rows = element.props["rows"]?.arrayValue?.count ?? 0
                let columns = element.props["columns"]?.arrayValue?.count ?? 0
                work += rows * columns
            }
            guard work <= maxRenderItems else { throw InvalidDocument("The MCP JSON UI exceeds the render limit.") }
        }

        var stack = spec.elements.keys.filter { parents[$0] == nil }.map { ($0, 1) }
        var visited = 0
        while let (id, depth) = stack.popLast() {
            guard depth <= JSONUICatalog.maxDepth else { throw InvalidDocument("The MCP JSON UI graph is too deep.") }
            visited += 1
            for child in spec.elements[id]?.children ?? [] { stack.append((child, depth + 1)) }
        }
        guard visited == spec.elements.count else { throw InvalidDocument("The MCP JSON UI graph contains a cycle.") }
        return parents
    }
}
