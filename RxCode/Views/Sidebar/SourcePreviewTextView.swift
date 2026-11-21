import AppKit
import RxCodeCore
import SwiftUI

/// AppKit selections and TextKit glyph mappings both use UTF-16 offsets.
nonisolated struct SourcePreviewContent: @unchecked Sendable {
    let text: NSAttributedString
    let lineStarts: [Int]

    init(_ text: NSAttributedString) {
        self.text = NSAttributedString(attributedString: text)
        let string = self.text.string as NSString
        var starts = [0]
        var offset = 0
        while offset < string.length {
            var end = 0
            var contentsEnd = 0
            string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            if end > contentsEnd { starts.append(end) }
            offset = end
        }
        lineStarts = starts
    }

    func lineNumber(at offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

struct ThemedSourcePreview: View {
    let text: String
    let language: String
    @State private var content: SourcePreviewContent?

    private struct Input: Equatable {
        let text: String
        let language: String
        let theme: AppTheme
    }

    var body: some View {
        let input = Input(text: text, language: language, theme: ThemeStore.shared.current)
        Group {
            if let content {
                CodeTextRenderer(content: content)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClaudeTheme.codeBackground)
        .task(id: input) {
            let highlighted = await Task.detached {
                SourcePreviewContent(SyntaxHighlighter.highlightNS(input.text, language: input.language, colors: input.theme.colors))
            }.value
            guard !Task.isCancelled else { return }
            content = highlighted
        }
    }
}

struct CodeTextRenderer: NSViewRepresentable {
    let content: SourcePreviewContent

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SourcePreviewTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.height]
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            container.lineFragmentPadding = 0
        }

        scrollView.documentView = textView
        let ruler = SourceLineNumberRuler(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clipsToBounds = true
        ruler.reservedThicknessForMarkers = 0
        ruler.reservedThicknessForAccessoryView = 0
        scrollView.hasHorizontalRuler = false
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        textView.display(content)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.documentView as? SourcePreviewTextView)?.display(content)
        scrollView.verticalRulerView?.needsDisplay = true
    }
}

final class SourcePreviewTextView: NSTextView {
    private(set) var source: SourcePreviewContent?

    func display(_ content: SourcePreviewContent) {
        guard source?.text !== content.text else { return }
        let selection = source?.text.string == content.text.string ? selectedRanges : nil
        source = content
        textStorage?.setAttributedString(content.text)
        if let selection { selectedRanges = selection }
        (enclosingScrollView?.verticalRulerView as? SourceLineNumberRuler)?.updateWidth(for: content.lineStarts.count)
    }

    var selectedExcerpt: PreviewExcerpt? {
        guard let source else { return nil }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard let first = ranges.first, let last = ranges.last else { return nil }
        let string = source.text.string as NSString
        let passage = ranges.map { string.substring(with: $0) }.joined(separator: "\n")
        let firstLine = source.lineNumber(at: first.location)
        let lastLine = source.lineNumber(at: NSMaxRange(last) - 1)
        let location = firstLine == lastLine ? "Line \(firstLine)" : "Lines \(firstLine)–\(lastLine)"
        return PreviewExcerpt(passage, location: location)
    }
}

extension NSTextView {
    func containsSelectedText(at point: NSPoint) -> Bool {
        guard let layout = layoutManager, let container = textContainer else { return false }
        let origin = textContainerOrigin
        let location = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let index = layout.glyphIndex(for: location, in: container)
        guard index < layout.numberOfGlyphs else { return false }
        let glyph = NSRange(location: index, length: 1)
        guard layout.boundingRect(forGlyphRange: glyph, in: container).contains(location) else { return false }
        let characters = layout.characterRange(forGlyphRange: glyph, actualGlyphRange: nil)
        return selectedRanges.contains { NSIntersectionRange($0.rangeValue, characters).length > 0 }
    }
}

/// The scroll view keeps this ruler beside the document during horizontal scrolling.
private final class SourceLineNumberRuler: NSRulerView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    func updateWidth(for lineCount: Int) {
        let digits = (String(lineCount) as NSString).size(withAttributes: [.font: font]).width
        ruleThickness = max(34, ceil(digits) + 16)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let visibleGutter = dirtyRect.intersection(bounds)
        guard !visibleGutter.isEmpty else { return }
        NSColor(ClaudeTheme.codeBackground).setFill()
        visibleGutter.fill()
        NSColor(ClaudeTheme.borderSubtle).setFill()
        NSRect(x: bounds.maxX - 1, y: visibleGutter.minY, width: 1, height: visibleGutter.height).fill()

        guard let view = scrollView?.documentView as? SourcePreviewTextView, let source = view.source,
              let layout = view.layoutManager, let container = view.textContainer else { return }
        let origin = view.textContainerOrigin
        let visible = view.convert(visibleGutter, from: self)
        let rows = NSRect(x: 0, y: visible.minY - origin.y, width: max(1, view.bounds.width), height: visible.height)
        let glyphs = layout.glyphRange(forBoundingRect: rows, in: container)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(ClaudeTheme.textSecondary)]

        func drawNumber(_ number: Int, in fragment: NSRect) {
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            let center = convert(NSPoint(x: 0, y: fragment.midY + origin.y), from: view)
            label.draw(at: NSPoint(x: bounds.maxX - 8 - size.width, y: center.y - size.height / 2), withAttributes: attributes)
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            let start = layout.characterIndexForGlyph(at: range.location)
            let number = source.lineNumber(at: start)
            if source.lineStarts[number - 1] == start { drawNumber(number, in: rect) }
        }
        if layout.extraLineFragmentTextContainer === container, source.lineStarts.last == source.text.length {
            drawNumber(source.lineStarts.count, in: layout.extraLineFragmentRect)
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func isAccessibilityElement() -> Bool { false }
}
