import Foundation

/// A short title written from a longer description.
///
/// Quick add takes what the user types as the *description*, so the title has
/// to come from somewhere: a model summarizes the description into one line.
/// `fallback(from:)` derives a usable title locally for the moments no model
/// answers — before the suggestion lands, when auto-fill is turned off in
/// Settings → Tasks, or when the reply holds nothing usable.
public enum TaskTitleSuggestion {
    /// Longest title produced here. Cards give a title two lines, so a summary
    /// much longer than this is cropped by the UI anyway.
    public static let maxLength = 72

    // MARK: - Prompt

    /// The one-shot prompt. Deliberately asks for a bare line rather than JSON:
    /// the answer is a single value, and a fenced object is one more thing a
    /// small model can get wrong.
    public static func prompt(details: String, storyTitle: String?) -> String {
        var lines: [String] = [
            "You write the title of an item on a software project board.",
            "Reply with ONLY the title: no quotes, no markdown, no trailing period, nothing else.",
            "",
            "Rules:",
            "- At most \(maxLength) characters, and shorter when the work is simple.",
            "- Say what the work is, in the imperative: \"Fix the crash on paste\", not \"The app crashes\".",
            "- Keep identifiers, file names and version numbers exactly as written.",
            "- Write in the same language as the description.",
        ]
        if let storyTitle, !storyTitle.isEmpty {
            lines.append("- Don't restate the parent story, which is already titled: \(storyTitle)")
        }
        lines.append(contentsOf: [
            "",
            "Description:",
            details.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// The title in `raw`. Models label, fence and quote the answer despite
    /// being told not to, so the first line that carries text wins and the
    /// decoration around it is stripped. `nil` when nothing is left.
    public static func parse(_ raw: String) -> String? {
        let line = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.hasPrefix("```") && !clean($0).isEmpty }
        guard let line else { return nil }
        return truncate(clean(line))
    }

    /// A title derived from the description without asking a model: its first
    /// line that carries text, stripped of Markdown and shortened.
    public static func fallback(from details: String) -> String {
        let line = details
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !clean($0).isEmpty }
        guard let line else { return "" }
        return truncate(clean(line))
    }

    /// Cuts to `maxLength`, on a word boundary when one falls near enough to
    /// the limit, and marks the cut with an ellipsis. Text without spaces —
    /// Chinese, Japanese — is cut where the limit lands.
    public static func truncate(_ value: String) -> String {
        guard value.count > maxLength else { return value }
        let head = value.prefix(maxLength)
        if let space = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: space) >= maxLength / 2 {
            return head[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Removes the decoration a title picks up from Markdown or from a model
    /// that answered in a sentence: heading and bullet markers, a numbered
    /// prefix, a "Title:" label, wrapping quotes and a single closing period.
    private static func clean(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)

        while let first = text.first, "#-*•>".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for pattern in [#"^\d+[.)]\s+"#, #"^title\s*[:：]\s*"#] {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                text.removeSubrange(range)
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)

        // Quotes and a closing period nest either way round — `"Title".` as
        // often as `"Title."` — so peel until nothing more comes off.
        let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "「", "」", "《", "》"]
        var peeled = true
        while peeled {
            peeled = false
            if text.count > 1, let first = text.first, let last = text.last,
               quotes.contains(first), quotes.contains(last) {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                peeled = true
            }
            // One closing period, but not an ellipsis the writer meant to keep.
            if text.hasSuffix("。") || (text.hasSuffix(".") && !text.hasSuffix("..")) {
                text.removeLast()
                text = text.trimmingCharacters(in: .whitespaces)
                peeled = true
            }
        }
        return text
    }
}
