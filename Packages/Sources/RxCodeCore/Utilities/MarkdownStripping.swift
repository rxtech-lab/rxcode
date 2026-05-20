import Foundation

/// Convert lightweight Markdown to a single line of plain text suitable for
/// notification banners. APNs alerts and the macOS local banner render raw
/// Markdown syntax literally (`**bold**`, `` `code` ``, `[text](url)`,
/// `# heading`) rather than formatting it, so the syntax must be removed before
/// the text is shown.
///
/// This is a best-effort, heuristic stripper for short summary text — not a full
/// CommonMark parser. It drops the syntax characters and collapses the result
/// into a single trimmed line. Inline lookarounds keep `snake_case`
/// identifiers and arithmetic like `2 * 3` intact.
public func stripMarkdown(_ text: String) -> String {
    var s = text

    func replace(_ pattern: String, _ template: String) {
        s = s.replacingOccurrences(
            of: pattern,
            with: template,
            options: [.regularExpression]
        )
    }

    // Fenced code block fences (``` or ```lang) — drop the fence line, keep code.
    replace("(?m)^[ \\t]*```.*$", "")
    // Images: ![alt](url) -> alt   (before links — the syntax overlaps).
    replace("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1")
    // Links: [text](url) -> text
    replace("\\[([^\\]]*)\\]\\([^)]*\\)", "$1")
    // ATX headings: leading #'s
    replace("(?m)^[ \\t]*#{1,6}[ \\t]+", "")
    // Blockquote markers
    replace("(?m)^[ \\t]*>[ \\t]?", "")
    // Horizontal rules
    replace("(?m)^[ \\t]*[-*_]{3,}[ \\t]*$", "")
    // Unordered list markers
    replace("(?m)^[ \\t]*[-*+][ \\t]+", "")
    // Ordered list markers
    replace("(?m)^[ \\t]*\\d+\\.[ \\t]+", "")
    // Strikethrough ~~text~~
    replace("~~([\\s\\S]+?)~~", "$1")
    // Bold: **text** and __text__
    replace("\\*\\*([\\s\\S]+?)\\*\\*", "$1")
    replace("(?<![A-Za-z0-9])__([\\s\\S]+?)__(?![A-Za-z0-9])", "$1")
    // Italic: *text* and _text_ (lookarounds keep snake_case / a*b intact)
    replace("(?<![*\\w])\\*([^*\\n]+?)\\*(?![*\\w])", "$1")
    replace("(?<![A-Za-z0-9_])_([^_\\n]+?)_(?![A-Za-z0-9_])", "$1")
    // Inline code backticks
    replace("`", "")
    // Collapse every whitespace run (incl. newlines) into a single space.
    replace("\\s+", " ")

    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
