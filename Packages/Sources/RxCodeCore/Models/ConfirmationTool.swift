import Foundation

/// The "show confirmation" tool: an agent asks the user to confirm or cancel an action in a
/// native confirmation dialog, and the call waits for their decision. The desktop exposes it
/// through the IDE MCP server as `ide__show_confirmation`.
public enum ConfirmationTool {
    public static let ideName = "ide__show_confirmation"

    /// What the dialog shows: its title, optional message, and button labels.
    public struct Request: Sendable, Hashable {
        public var title: String
        public var message: String?
        public var confirmLabel: String
        public var cancelLabel: String
        /// Draws the confirm button as destructive (red) for deletes, overwrites and the like.
        public var isDestructive: Bool

        public init(title: String, message: String? = nil, confirmLabel: String = "Confirm", cancelLabel: String = "Cancel", isDestructive: Bool = false) {
            self.title = title
            self.message = message
            self.confirmLabel = confirmLabel
            self.cancelLabel = cancelLabel
            self.isDestructive = isDestructive
        }
    }

    /// Reads a call's arguments. Throws when the title is missing.
    public static func request(from arguments: JSONValue) throws -> Request {
        func text(_ key: String) -> String? {
            arguments[key]?.stringValue.flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        guard let title = text("title") else {
            throw ConfirmationToolError(message: "Missing `title`: pass a short question such as \"Delete 3 files?\".")
        }
        return Request(
            title: title,
            message: text("message"),
            confirmLabel: text("confirm_label") ?? "Confirm",
            cancelLabel: text("cancel_label") ?? "Cancel",
            isDestructive: arguments["destructive"]?.boolValue ?? false
        )
    }

    /// The JSON result reported back to the agent for the user's decision.
    public static func result(confirmed: Bool) -> JSONValue {
        .object([
            "confirmed": .bool(confirmed),
            "message": .string(confirmed
                ? "The user confirmed. Go ahead."
                : "The user cancelled. Do not perform the action or ask again unless they request it."),
        ])
    }

    public static let description = """
    Ask the user to confirm or cancel an action in a native confirmation dialog, and wait for their decision. \
    Use it before doing something the user should approve first: deleting or overwriting data, pushing, publishing, \
    spending money or tokens, or any hard-to-undo step. Returns { confirmed: true|false }. If confirmed is false, \
    don't perform the action. Keep `title` a short question and put details in `message`.
    """

    public static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "title": .object(["type": .string("string"), "description": .string("Short question shown as the dialog title, e.g. \"Delete 3 files?\".")]),
            "message": .object(["type": .string("string"), "description": .string("Optional detail shown under the title: what will happen and what it affects.")]),
            "confirm_label": .object(["type": .string("string"), "description": .string("Label of the confirm button, e.g. \"Delete\". Defaults to \"Confirm\".")]),
            "cancel_label": .object(["type": .string("string"), "description": .string("Label of the cancel button. Defaults to \"Cancel\".")]),
            "destructive": .object(["type": .string("boolean"), "description": .string("Show the confirm button as destructive (red). Use for deletes and overwrites.")]),
        ]),
        "required": .array([.string("title")]),
        "additionalProperties": .bool(false),
    ])
}

public struct ConfirmationToolError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
