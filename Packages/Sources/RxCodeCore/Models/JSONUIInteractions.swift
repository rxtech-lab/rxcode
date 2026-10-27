import Foundation

public extension JSONUISpec {
    func inputNames(in root: String) -> Set<String> {
        var visited: Set<String> = []
        var names: Set<String> = []
        func visit(_ id: String, depth: Int) {
            guard depth < JSONUICatalog.maxDepth, visited.insert(id).inserted, let element = elements[id] else { return }
            if JSONUICatalog.inputTypes.contains(element.type) { names.insert(element.string("name") ?? id) }
            for child in element.children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return names
    }

    /// Form values are local to one renderer. Field names must be unique across the spec.
    var initialValues: [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for (id, element) in elements.sorted(by: { $0.key < $1.key }) where JSONUICatalog.inputTypes.contains(element.type) {
            let fallback: JSONValue
            switch element.type {
            case "Toggle": fallback = .bool(false)
            case "Slider": fallback = .number(element.number("min") ?? 0)
            case "Picker": fallback = .string(element.strings("options").first ?? "")
            default: fallback = .string("")
            }
            values[element.string("name") ?? id] = element.props["value"] ?? fallback
        }
        return values
    }

    var interactionIssues: [String] {
        var issues: [String] = []
        var names: Set<String> = []
        for (id, element) in elements.sorted(by: { $0.key < $1.key }) {
            let path = "elements.\(id)"
            if JSONUICatalog.inputTypes.contains(element.type) {
                if !names.insert(element.string("name") ?? id).inserted {
                    issues.append("\(path): input names must be unique.")
                }
                if let value = element.props["value"] {
                    let valid: Bool
                    switch element.type {
                    case "Toggle": valid = value.boolValue != nil
                    case "Slider": valid = value.numberValue?.isFinite == true
                    default: valid = value.stringValue != nil
                    }
                    if !valid { issues.append("\(path): value has the wrong input type.") }
                }
                if element.type == "Picker" {
                    let options = element.strings("options")
                    if options.isEmpty || Set(options).count != options.count {
                        issues.append("\(path): options must be a nonempty array of unique strings.")
                    }
                    if let value = element.string("value"), !options.contains(value) {
                        issues.append("\(path): value must be one of options.")
                    }
                }
                if element.type == "Slider" {
                    let min = element.number("min") ?? 0
                    let max = element.number("max") ?? 100
                    let step = element.number("step") ?? 1
                    let value = element.number("value") ?? min
                    if !min.isFinite || !max.isFinite || !step.isFinite || min >= max || step <= 0 || !value.isFinite || value < min || value > max {
                        issues.append("\(path): Slider requires finite min < max, positive step, and a value within bounds.")
                    }
                }
            }
            for key in ["action", "confirmAction"] {
                guard let raw = element.props[key] else {
                    if element.type == "Button" && key == "action" { issues.append("\(path): Button requires action.") }
                    continue
                }
                guard let action = raw.objectValue, let type = action["type"]?.stringValue,
                      JSONUICatalog.actionTypes.contains(type) else {
                    issues.append("\(path).\(key): use an action type present, dismiss, set, reset, or submit.")
                    continue
                }
                if type == "present" {
                    guard let target = action["target"]?.stringValue, let destination = elements[target],
                          JSONUICatalog.presentationTypes.contains(destination.type) else {
                        issues.append("\(path).\(key): target must reference a presentation element.")
                        continue
                    }
                }
                if ["submit", "reset"].contains(type), let target = action["target"],
                   target.stringValue.flatMap({ elements[$0] })?.type != "Form" {
                    issues.append("\(path).\(key): target must reference a Form.")
                }
                if type == "set" {
                    guard let name = action["name"]?.stringValue,
                          let field = elements.first(where: { JSONUICatalog.inputTypes.contains($0.value.type) && ($0.value.string("name") ?? $0.key) == name }),
                          let value = action["value"] else {
                        issues.append("\(path).\(key): set requires an input name and value.")
                        continue
                    }
                    var changed = field.value
                    changed.props["value"] = value
                    changed.props.removeValue(forKey: "action")
                    changed.props.removeValue(forKey: "confirmAction")
                    if !JSONUISpec(root: field.key, elements: [field.key: changed]).interactionIssues.isEmpty {
                        issues.append("\(path).\(key): value is invalid for input \"\(name)\".")
                    }
                }
            }
        }
        return issues
    }
}
