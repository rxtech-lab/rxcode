import Foundation

// MARK: - TaskPromptContent

/// A thread's user message split back into its parts, so the Run tab and the
/// chat message list can show a dispatched task as a card instead of raw
/// Markdown.
///
/// Understands the `ProjectTask.agentPrompt` layout and the attachment lines
/// `buildPromptWithAttachments` puts in front of it. Anything else (a typed
/// follow-up) parses with a nil `title` and the whole text as `body`.
public struct TaskPromptContent: Sendable, Hashable {
    public struct Field: Sendable, Hashable {
        public var label: String
        public var value: String
    }

    public struct Reference: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case file, image, link
        }

        public var kind: Kind
        public var value: String
    }

    /// Files and links attached to the message.
    public var references: [Reference]
    /// The task title, when the message is a dispatched task.
    public var title: String?
    /// The description, or a follow-up's full text. Markdown.
    public var body: String
    /// The trailing `- **Label:** value` context list.
    public var fields: [Field]

    public static func parse(_ text: String) -> TaskPromptContent {
        var lines = text.components(separatedBy: "\n")[...]
        var references: [Reference] = []
        while let line = lines.first, let reference = Self.reference(in: line) {
            references.append(reference)
            lines = lines.dropFirst()
        }

        let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks = rest.components(separatedBy: "\n\n")

        let titlePrefix = "**Task:** "
        guard let first = blocks.first, first.hasPrefix(titlePrefix), !first.contains("\n") else {
            return TaskPromptContent(references: references, title: nil, body: rest, fields: [])
        }
        let title = String(first.dropFirst(titlePrefix.count)).trimmingCharacters(in: .whitespaces)
        blocks.removeFirst()

        var fields: [Field] = []
        if let last = blocks.last {
            let parsed = last.components(separatedBy: "\n").map(Self.field(in:))
            if !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) {
                fields = parsed.compactMap { $0 }
                blocks.removeLast()
            }
        }

        let body = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskPromptContent(references: references, title: title, body: body, fields: fields)
    }

    /// The parse of `text` when it is a dispatched task message — a
    /// `**Task:**` heading followed by its context list — and `nil` for
    /// anything else, such as a typed follow-up that happens to use Markdown.
    /// Callers use this to decide between the task card and plain Markdown.
    public static func task(in text: String) -> TaskPromptContent? {
        let content = parse(text)
        return content.title == nil ? nil : content
    }

    /// `[Attached image: /path]`, `[Attached file: /path]` or `[Link: url]`.
    private static func reference(in line: String) -> Reference? {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        let inner = line.dropFirst().dropLast()
        if inner.hasPrefix("Link: ") {
            return Reference(kind: .link, value: String(inner.dropFirst("Link: ".count)))
        }
        guard inner.hasPrefix("Attached "), let colon = inner.range(of: ": ") else { return nil }
        let type = inner[inner.index(inner.startIndex, offsetBy: "Attached ".count)..<colon.lowerBound]
        return Reference(kind: type == "image" ? .image : .file, value: String(inner[colon.upperBound...]))
    }

    /// `- **Label:** value`.
    private static func field(in line: String) -> Field? {
        guard line.hasPrefix("- **"), let end = line.range(of: ":** ") else { return nil }
        let label = line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound]
        let value = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Field(label: String(label), value: value)
    }
}
