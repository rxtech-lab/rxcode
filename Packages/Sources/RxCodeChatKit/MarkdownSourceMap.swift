#if os(macOS)
import Foundation

extension NSAttributedString.Key {
    static let markdownAnnotation = Self("RxCodeMarkdownAnnotation")
}

/// Translates source ranges to the selectable Markdown view's text storage.
/// Block decorations such as list bullets and code headers are outside these spans.
struct MarkdownSourceMap {
    private struct Span {
        var source: NSRange
        var rendered: NSRange
        var literal: Bool
    }

    private let markdown: String
    private let source: NSString
    private var spans: [Span] = []

    init(markdown: String) {
        self.markdown = markdown
        source = markdown as NSString
    }

    mutating func record(_ position: AttributedString.MarkdownSourcePosition?, in storage: NSAttributedString,
                         from start: Int, codeBlock: Bool = false) {
        guard let position, let sourceRange = Range(position, in: markdown), storage.length > start else { return }
        var range = NSRange(sourceRange, in: markdown)
        let rendered = NSRange(location: start, length: storage.length - start)
        let text = storage.attributedSubstring(from: rendered).string
        if codeBlock {
            let block = source.substring(with: range)
            if block.hasPrefix("```") || block.hasPrefix("~~~"),
               let newline = block.firstIndex(of: "\n") {
                let fence = block[...newline].utf16.count
                range = NSRange(location: range.location + fence, length: range.length - fence)
            }
        }
        let literal = source.range(of: text, options: .literal, range: range)
        spans.append(Span(source: literal.location == NSNotFound ? range : literal,
                          rendered: rendered, literal: literal.location != NSNotFound))
    }

    func renderedRanges(for range: NSRange) -> [NSRange] {
        spans.compactMap { span in
            let intersection = NSIntersectionRange(range, span.source)
            guard intersection.length > 0 else { return nil }
            let start = renderedOffset(intersection.location, in: span)
            let end = renderedOffset(NSMaxRange(intersection), in: span)
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
    }

    func insertionPoint(for sourceOffset: Int) -> Int {
        guard let span = spans.first(where: { NSMaxRange($0.source) > sourceOffset }) else {
            return spans.last.map { NSMaxRange($0.rendered) } ?? 0
        }
        return renderedOffset(sourceOffset, in: span)
    }

    private func renderedOffset(_ offset: Int, in span: Span) -> Int {
        if offset <= span.source.location { return span.rendered.location }
        if offset >= NSMaxRange(span.source) { return NSMaxRange(span.rendered) }
        let length = offset - span.source.location
        if span.literal { return span.rendered.location + length }
        // A Markdown escape or entity can occupy several source characters.
        let prefix = source.substring(with: NSRange(location: span.source.location, length: length))
        let decoded = try? AttributedString(markdown: prefix, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let visibleLength = decoded.map { String($0.characters).utf16.count } ?? length
        return span.rendered.location + min(span.rendered.length, visibleLength)
    }
}
#endif
