import Foundation

public struct CodeEditorAutocompleteItem: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let insertionText: String
    public let detail: String?

    public init(
        id: String? = nil,
        title: String,
        insertionText: String,
        detail: String? = nil
    ) {
        self.id = id ?? insertionText
        self.title = title
        self.insertionText = insertionText
        self.detail = detail
    }
}

public struct CodeEditorAutocompleteContext: Hashable, Sendable {
    public let text: String
    public let selectedRange: NSRange
    public let replacementRange: NSRange
    public let query: String

    public init(
        text: String,
        selectedRange: NSRange,
        replacementRange: NSRange,
        query: String
    ) {
        self.text = text
        self.selectedRange = selectedRange
        self.replacementRange = replacementRange
        self.query = query
    }
}

public protocol CodeEditorAutocompleteProvider: Sendable {
    /// Return a completion context when the caret is in a provider-owned trigger
    /// region. LSP-backed providers can use this boundary to map the buffer and
    /// caret into a protocol request before returning cached or fetched items.
    func context(in text: String, selectedRange: NSRange) -> CodeEditorAutocompleteContext?
    func completions(for context: CodeEditorAutocompleteContext) -> [CodeEditorAutocompleteItem]
}

public struct PredefinedAutocompleteProvider: CodeEditorAutocompleteProvider {
    public let trigger: String
    public let closingDelimiter: String?
    public let items: [CodeEditorAutocompleteItem]

    public init(
        trigger: String,
        closingDelimiter: String? = nil,
        items: [CodeEditorAutocompleteItem]
    ) {
        self.trigger = trigger
        self.closingDelimiter = closingDelimiter
        self.items = items
    }

    public func context(in text: String, selectedRange: NSRange) -> CodeEditorAutocompleteContext? {
        guard selectedRange.length == 0,
              !trigger.isEmpty,
              selectedRange.location <= (text as NSString).length
        else { return nil }

        let nsText = text as NSString
        let prefixRange = NSRange(location: 0, length: selectedRange.location)
        let triggerRange = nsText.range(of: trigger, options: [.backwards], range: prefixRange)
        guard triggerRange.location != NSNotFound else { return nil }

        let queryStart = triggerRange.location + triggerRange.length
        let queryLength = selectedRange.location - queryStart
        guard queryLength >= 0 else { return nil }

        let queryRange = NSRange(location: queryStart, length: queryLength)
        let query = nsText.substring(with: queryRange)
        guard isValidQuery(query) else { return nil }

        if let closingDelimiter,
           !closingDelimiter.isEmpty,
           query.contains(closingDelimiter) {
            return nil
        }

        return CodeEditorAutocompleteContext(
            text: text,
            selectedRange: selectedRange,
            replacementRange: NSRange(
                location: triggerRange.location,
                length: selectedRange.location - triggerRange.location
            ),
            query: query
        )
    }

    public func completions(for context: CodeEditorAutocompleteContext) -> [CodeEditorAutocompleteItem] {
        let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }

        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.insertionText.localizedCaseInsensitiveContains(query)
                || (item.detail?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func isValidQuery(_ query: String) -> Bool {
        for scalar in query.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            switch scalar {
            case "{", "}", "\"", "'", "`", ":", ",", "[", "]", "(", ")":
                return false
            default:
                continue
            }
        }
        return true
    }
}

public extension PredefinedAutocompleteProvider {
    static func keywords(
        _ keywords: [String],
        trigger: String,
        closingDelimiter: String? = nil
    ) -> PredefinedAutocompleteProvider {
        PredefinedAutocompleteProvider(
            trigger: trigger,
            closingDelimiter: closingDelimiter,
            items: keywords.map { keyword in
                CodeEditorAutocompleteItem(
                    title: keyword,
                    insertionText: keyword
                )
            }
        )
    }

    static func placeholders(_ placeholders: [String]) -> PredefinedAutocompleteProvider {
        PredefinedAutocompleteProvider(
            trigger: "{{",
            closingDelimiter: "}}",
            items: placeholders.map { placeholder in
                CodeEditorAutocompleteItem(
                    title: placeholder,
                    insertionText: "{{\(placeholder)}}",
                    detail: "Context placeholder"
                )
            }
        )
    }
}
