import Foundation

/// Hugging Face model cards mix markdown with raw HTML — centred `<p>` logo
/// blocks, `<a>` link rows, `<img>` badges — which the markdown renderer would
/// show as literal tags. This rewrites the common tags as markdown, strips the
/// rest and decodes entities, leaving fenced and inline code untouched.
nonisolated enum ModelCardMarkdown {
    static func normalize(_ markdown: String) -> String {
        var output: [String] = []
        var prose: [String] = []
        var fence: String?

        func flushProse() {
            guard !prose.isEmpty else { return }
            output.append(convert(prose.joined(separator: "\n")))
            prose.removeAll()
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                output.append(line)
                if trimmed.hasPrefix(marker) { fence = nil }
            } else if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                flushProse()
                fence = marker
                output.append(line)
            } else {
                prose.append(line)
            }
        }
        flushProse()
        return output.joined(separator: "\n")
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTML tags known to appear in model cards. Anything else in angle
    /// brackets (`<think>`, `<|im_start|>`) is prose and is kept.
    private static let htmlTags = "a|abbr|b|big|blockquote|br|center|code|del|details|div|em|figcaption|figure|font|h[1-6]|hr|i|img|ins|kbd|li|mark|ol|p|picture|pre|s|section|small|source|span|strong|sub|summary|sup|table|tbody|td|th|thead|tr|u|ul|video"

    private static func convert(_ text: String) -> String {
        // Inline code spans are set aside so tags inside them stay literal.
        var spans: [String] = []
        var result = replace(#"`[^`\n]+`"#, in: text) { match in
            spans.append(match[0])
            return "\u{1}\(spans.count - 1)\u{1}"
        }

        result = replace(#"<!--.*?-->"#, in: result) { _ in "" }
        result = replace(#"<img\b[^>]*>"#, in: result) { match in
            guard let src = attribute("src", in: match[0]) else { return "" }
            return "![\(attribute("alt", in: match[0]) ?? "")](\(src))"
        }
        result = replace(#"<a\b([^>]*)>(.*?)</a\s*>"#, in: result) { match in
            let inner = match[2]
            // A linked image (a badge) keeps the image; the renderer can't nest it in a link.
            if inner.contains("![") { return stripTags(inner) }
            let label = collapse(stripTags(inner))
            guard let href = attribute("href", in: match[1]), !label.isEmpty else { return label }
            return "[\(label)](\(href))"
        }
        result = replace(#"<h([1-6])\b[^>]*>(.*?)</h\1\s*>"#, in: result) { match in
            "\n\n\(String(repeating: "#", count: Int(match[1]) ?? 1)) \(collapse(stripTags(match[2])))\n\n"
        }
        result = replace(#"<(b|strong)\b[^>]*>(.*?)</\1\s*>"#, in: result) { match in
            let inner = collapse(match[2])
            return inner.isEmpty ? "" : "**\(inner)**"
        }
        result = replace(#"<(i|em)\b[^>]*>(.*?)</\1\s*>"#, in: result) { match in
            let inner = collapse(match[2])
            return inner.isEmpty ? "" : "*\(inner)*"
        }
        result = replace(#"<code\b[^>]*>(.*?)</code\s*>"#, in: result) { match in "`\(match[1])`" }
        result = replace(#"<br\s*/?>"#, in: result) { _ in "\n" }
        result = replace(#"<hr\b[^>]*>"#, in: result) { _ in "\n\n---\n\n" }
        result = replace(#"<li\b[^>]*>"#, in: result) { _ in "\n- " }
        result = replace(#"[ \t]*</?(p|div|center|section|details|summary|ul|ol|table|thead|tbody|tr|blockquote|figure|picture|pre)\b[^>]*>[ \t]*"#, in: result) { _ in "\n\n" }
        result = replace(#"</?(td|th)\b[^>]*>"#, in: result) { _ in " " }
        result = stripTags(result)
        result = decodeEntities(result)
        // The renderer has no backslash escapes; drop them except where the
        // character would otherwise start emphasis, code, a link or a block.
        result = replace(#"\\([~_.(){}!"':;=])"#, in: result) { match in match[1] }
        // Spacing left by removed tags and `&nbsp;`: runs of spaces inside a
        // line become one, and trailing spaces go. Leading indentation is kept
        // for nested lists.
        result = result.components(separatedBy: "\n")
            .map { line in
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                let body = line.dropFirst(indent.count).replacing(#/[ \t]{2,}/#, with: " ")
                    .trimmingCharacters(in: .whitespaces)
                return body.isEmpty ? "" : indent + body
            }
            .joined(separator: "\n")

        return replace("\u{1}(\\d+)\u{1}", in: result) { match in
            Int(match[1]).flatMap { spans.indices.contains($0) ? spans[$0] : nil } ?? ""
        }
    }

    private static func stripTags(_ text: String) -> String {
        replace("</?(\(htmlTags))\\b[^>]*>", in: text) { _ in "" }
    }

    /// Runs of whitespace, including newlines inside HTML, become one space.
    private static func collapse(_ text: String) -> String {
        text.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    private static let entities = [
        "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
        "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&copy;": "©", "&reg;": "®", "&trade;": "™",
    ]

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        result = replace(#"&#(x[0-9a-fA-F]+|\d+);"#, in: result) { match in
            let code = match[1]
            let value = code.hasPrefix("x") || code.hasPrefix("X") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? match[0]
        }
        // Last, so `&amp;lt;` decodes to the text `&lt;`.
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Regex replacement where `transform` receives the match and its groups
    /// (empty strings for groups that didn't participate).
    private static func replace(_ pattern: String, in text: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
