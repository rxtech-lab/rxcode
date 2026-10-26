import Foundation

/// Presentation only: recognizing a tool never grants it permission.
public enum ComputerUsePresentation {
    public static func recognizes(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["computer", "computer_use", "computeruse", "computer_call"].contains(name)
            || name.hasPrefix("mcp__cua__")
            || name.hasPrefix("mcp__cua_repl__")
            || name.hasPrefix("mcp__computer_use__")
            || name.hasPrefix("cua_repl.")
    }

    public static func summary(name: String, input: [String: JSONValue]) -> String? {
        guard recognizes(name) else { return nil }
        let action = input["action"]?.objectValue
        let description = input["title"]?.stringValue
            ?? input["action"]?.stringValue
            ?? action?["type"]?.stringValue
        guard let description, !description.isEmpty else { return "Computer use" }
        return "Computer use — \(description.replacingOccurrences(of: "_", with: " "))"
    }
}
