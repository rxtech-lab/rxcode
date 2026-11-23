import Foundation

nonisolated extension CodingPlanReview {
    /// Older reviews use HTML comments for the rationale before each suggestion.
    /// Format only the feedback for display. Suggested edits still use their exact source.
    static func feedbackMarkdown(_ text: String, streaming: Bool = false) -> String {
        let opener = "<!--"
        let partialOpener = streaming ? ["<!-", "<!", "<"].first(where: text.hasSuffix) : nil
        guard text.contains(opener) || partialOpener != nil else { return text }

        // Complete a streaming delimiter for the Markdown parser. Only characters
        // received from the agent can appear in the result.
        let suffix: String
        if let partialOpener {
            suffix = opener.dropFirst(partialOpener.count) + " -->"
        } else if streaming {
            suffix = text.hasSuffix("--") ? ">" : text.hasSuffix("-") ? "->" : " -->"
        } else {
            suffix = ""
        }
        let source = text + suffix
        let end = source.index(source.endIndex, offsetBy: -suffix.count)
        guard let document = try? AttributedString(markdown: source, options: .init(appliesSourcePositionAttributes: true))
        else { return text }

        var blocks: [String] = []
        var cursor = source.startIndex
        func appendProse(_ prose: Substring) {
            if prose.contains(where: { !$0.isWhitespace }) {
                blocks.append(prose.trimmingCharacters(in: .newlines))
            }
        }

        for run in document.runs {
            guard let intent = run.inlinePresentationIntent, !intent.intersection([.blockHTML, .inlineHTML]).isEmpty,
                  let position = run.markdownSourcePosition, let range = Range(position, in: source),
                  range.lowerBound >= cursor, range.lowerBound < end else { continue }
            var start = range.lowerBound
            // A single HTML block can contain several adjacent comments on one line.
            while start < end, source[start...].hasPrefix(opener) {
                appendProse(source[cursor..<start])
                let rest = source[start...].dropFirst(opener.count)
                let close = rest.range(of: "-->")
                let bodyEnd = min(close?.lowerBound ?? end, end)
                if rest.startIndex < bodyEnd {
                    let body = source[rest.startIndex..<bodyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        blocks.append(body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                            .map { "> " + $0 }.joined(separator: "\n"))
                    }
                }
                cursor = min(close?.upperBound ?? end, end)
                start = source[cursor..<end].drop(while: { $0 == " " || $0 == "\t" }).startIndex
            }
        }
        guard cursor > source.startIndex else { return text }
        appendProse(source[cursor..<end])
        return blocks.joined(separator: "\n\n")
    }
}
