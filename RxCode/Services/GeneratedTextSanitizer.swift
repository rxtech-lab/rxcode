import Foundation

enum GeneratedTextSanitizer {
    static func cleanSummary(_ raw: String?, limit: Int, errorPrefixes: [String]) -> String? {
        guard let raw else { return nil }
        let cleaned = cleanMarkdownDocument(raw)
        guard !cleaned.isEmpty else { return nil }

        let lower = cleaned.lowercased()
        guard !errorPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return String(cleaned.prefix(limit))
    }

    static func cleanMarkdownDocument(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripSurroundingQuotes(text, includingBackticks: false)
        text = unwrapWholeDocumentFence(text)
        text = stripSurroundingQuotes(text, includingBackticks: true)
        text = unwrapWholeDocumentFence(text)
        text = dropLeadingMarkdownLanguageLabel(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrapWholeDocumentFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fence = openingFence(in: trimmed) else { return trimmed }

        var lines = trimmed.components(separatedBy: "\n")
        guard !lines.isEmpty else { return trimmed }
        lines.removeFirst()

        if let last = lines.last,
           last.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
            lines.removeLast()
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openingFence(in text: String) -> String? {
        let firstLine = text.components(separatedBy: "\n").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.hasPrefix("```") { return "```" }
        if firstLine.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func stripSurroundingQuotes(_ raw: String, includingBackticks: Bool) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = includingBackticks ? "\"'`" : "\"'"
        if let first = text.first, let last = text.last,
           wrappers.contains(first), first == last, text.count > 1 {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func dropLeadingMarkdownLanguageLabel(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lines.removeFirst()
                continue
            }
            if trimmed.lowercased() == "markdown" {
                lines.removeFirst()
            }
            break
        }
        return lines.joined(separator: "\n")
    }
}
