import Foundation

/// Renderer mechanics only: the agent owns all content, meaning and composition.
public enum PetWidgetSchema {
    public static let components: Set<String> = ["Stack", "Grid", "Card", "Heading", "Text", "Badge", "Stat", "Progress", "Divider", "KeyValue"]
    private static let props: [String: Set<String>] = [
        "Stack": ["direction", "gap"], "Grid": ["columns"], "Card": ["title", "subtitle", "tone"],
        "Heading": ["text", "level"], "Text": ["text", "tone", "size", "weight"], "Badge": ["text", "tone"],
        "Stat": ["label", "value", "detail", "tone", "format", "currency"], "Progress": ["label", "value", "total", "detail", "tone"],
        "Divider": [], "KeyValue": ["items"]
    ]

    public static func validate(_ spec: JSONUISpec) throws {
        guard spec.elements.count <= 16 else { throw ValidationError("A compact widget supports at most 16 elements.") }
        guard (try JSONEncoder().encode(spec)).count <= 12_000 else { throw ValidationError("Widget JSON must fit in 12 KB.") }
        guard spec.issues.isEmpty else { throw ValidationError(spec.issues.joined(separator: "\n")) }
        var visited: Set<String> = []
        func visit(_ id: String, depth: Int) throws {
            guard depth <= 4 else { throw ValidationError("Widget nesting is limited to four levels.") }
            visited.insert(id)
            guard let element = spec.elements[id], components.contains(element.type) else {
                throw ValidationError("Unsupported widget component at '\(id)'. Supported: \(components.sorted().joined(separator: ", ")).")
            }
            for (key, value) in element.props {
                guard props[element.type, default: []].contains(key) else { throw ValidationError("Unsupported property '\(key)' for \(element.type).") }
                try validateValue(value)
                if key == "items" {
                    guard case .array(let items) = value else { throw ValidationError("items must be an array.") }
                    for item in items {
                        guard case .object(let fields) = item, Set(fields.keys).isSubset(of: ["label", "value", "format", "currency", "tone"]) else {
                            throw ValidationError("KeyValue items support label, value, format, currency and tone.")
                        }
                        for (field, content) in fields { try validateProperty(field, content, type: "KeyValue") }
                    }
                } else { try validateProperty(key, value, type: element.type) }
            }
            for child in element.children { try visit(child, depth: depth + 1) }
        }
        try visit(spec.root, depth: 1)
        guard visited.count == spec.elements.count else { throw ValidationError("Every widget element must be reachable from root.") }
    }

    private static func validateProperty(_ key: String, _ value: JSONValue, type: String) throws {
        if value["$ide"] != nil {
            guard ["value", "text", "label", "detail", "subtitle", "title"].contains(key) else { throw ValidationError("Live values cannot control renderer layout.") }
            return
        }
        if key == "columns" || key == "level" {
            guard let n = value.numberValue, n.rounded() == n, (1...3).contains(n) else { throw ValidationError("\(key) must be an integer from 1 to 3.") }
        } else if key == "value" {
            guard value.stringValue != nil || value.numberValue != nil || value == .null else { throw ValidationError("value must be a string, number, null or live IDE binding.") }
            if type == "Progress", value.numberValue == nil { throw ValidationError("Progress value must be numeric or a live IDE binding.") }
        } else if key == "total" {
            guard let n = value.numberValue, n > 0 else { throw ValidationError("total must be a positive number.") }
        } else {
            guard let text = value.stringValue else { throw ValidationError("\(key) must be a string.") }
            let enums: [String: [String]] = ["direction": ["vertical", "horizontal"], "gap": ["none", "small", "medium", "large"],
                "tone": JSONUICatalog.tones, "size": ["small", "body", "large"], "weight": ["regular", "semibold", "bold"],
                "format": ["text", "number", "money", "percent", "bytes", "duration"]]
            if let choices = enums[key], !choices.contains(text) { throw ValidationError("Unsupported \(key): \(text).") }
        }
    }

    private static func validateValue(_ value: JSONValue) throws {
        switch value {
        case .string(let text):
            guard text.count <= 180 else { throw ValidationError("Widget strings are limited to 180 characters.") }
        case .number(let number):
            guard number.isFinite else { throw ValidationError("Numbers must be finite.") }
        case .array(let values):
            guard values.count <= 4 else { throw ValidationError("Widget arrays support at most four entries.") }
            for value in values { try validateValue(value) }
        case .object(let object):
            if object.keys.contains("$ide") {
                guard object.count == 1, ["running_tasks", "running_sessions"].contains(object["$ide"]?.stringValue ?? "") else {
                    throw ValidationError("Live binding must be exactly {\"$ide\":\"running_tasks\"} or {\"$ide\":\"running_sessions\"}.")
                }
            } else { for value in object.values { try validateValue(value) } }
        default: break
        }
    }

    /// Bind values at rendering time using existing observable IDE state; no timer or polling.
    public static func resolved(_ spec: JSONUISpec, runningTasks: Int, runningSessions: Int) -> JSONUISpec {
        func resolve(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let object):
                if let binding = object["$ide"]?.stringValue { return .number(Double(binding == "running_tasks" ? runningTasks : runningSessions)) }
                return .object(object.mapValues(resolve))
            case .array(let values): return .array(values.map(resolve))
            default: return value
            }
        }
        var result = spec
        for (id, element) in spec.elements {
            var resolved = element
            resolved.props = element.props.mapValues(resolve)
            result.elements[id] = resolved
        }
        return result
    }

    /// Legacy compositions remain readable, but status never renders dashboard layout/chrome.
    public static func indicatorText(_ spec: JSONUISpec, runningTasks: Int, runningSessions: Int) -> String {
        var resolved = resolved(spec, runningTasks: runningTasks, runningSessions: runningSessions)
        for (id, var element) in resolved.elements {
            if let number = element.props["text"]?.numberValue {
                element.props["text"] = .string(number.formatted())
                resolved.elements[id] = element
            }
        }
        return resolved.textLines.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public struct ValidationError: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }
}
