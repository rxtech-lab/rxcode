import AppKit
import PDFKit
import VisionKit
import WebKit

/// Holds the renderer’s original range while the comment field has keyboard focus.
struct PreviewSelectionHighlight {
    var show: () -> Void
    var hide: () -> Void = {}

    static func pdf(_ selection: PDFSelection, in view: PDFView) -> Self {
        let mark = selection.copy() as! PDFSelection
        mark.color = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.65)
        return Self(show: { [weak view] in
            view?.highlightedSelections = (view?.highlightedSelections ?? []) + [mark]
        }, hide: { [weak view] in
            view?.highlightedSelections?.removeAll { $0 === mark }
        })
    }

    static func liveText(in view: ImageAnalysisOverlayView) -> Self {
        let ranges = view.selectedRanges
        return Self { [weak view] in view?.selectedRanges = ranges }
    }

    static func text(in view: NSTextView) -> Self {
        let ranges = view.selectedRanges
        let color = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.65)
        var marked = false
        return Self(show: { [weak view] in
            guard let view, view.selectedRanges == ranges else { return }
            marked = true
            for range in ranges {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range.rangeValue)
            }
        }, hide: { [weak view] in
            guard let view, marked else { return }
            marked = false
            let document = NSRange(location: 0, length: (view.string as NSString).length)
            for range in ranges {
                view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(document, range.rangeValue))
            }
        })
    }

    /// Selectable SwiftUI text can release its field editor when another field starts editing.
    /// Keep a non-interactive mark on the original text view, in its scrolling coordinate space.
    static func accessible(_ element: NSAccessibilityProtocol, in view: NSView) -> Self? {
        guard let window = view.window, let root = window.contentView else { return nil }
        let range = element.accessibilitySelectedTextRange()
        var marks: [SelectionMark] = []
        var start = range.location
        while start != NSNotFound && start < NSMaxRange(range) {
            let index = element.accessibilityLine(for: start)
            let line = index == NSNotFound ? NSRange(location: NSNotFound, length: 0) : element.accessibilityRange(forLine: index)
            let end = line.location != NSNotFound && NSMaxRange(line) > start ? min(NSMaxRange(line), NSMaxRange(range)) : NSMaxRange(range)
            let rect = element.accessibilityFrame(for: NSRange(location: start, length: end - start))
            if !rect.isEmpty {
                marks.append(SelectionMark(frame: view.convert(window.convertFromScreen(rect), from: nil)))
            }
            start = end
        }
        if marks.isEmpty {
            // Some SwiftUI text blocks expose the passage only through Services. Preserve that block's
            // selected appearance before its field editor resigns, including wrapping and inline styles.
            let block = view.bounds.intersection(view.visibleRect)
            let rect = root.convert(block, from: view).intersection(root.visibleRect)
            guard !rect.isEmpty, let bitmap = root.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            root.cacheDisplay(in: rect, to: bitmap)
            let mark = SelectionMark(frame: view.convert(rect, from: root))
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            mark.snapshot = image
            marks.append(mark)
        }
        return Self(show: { [weak view] in
            for mark in marks { view?.addSubview(mark) }
        }, hide: {
            for mark in marks { mark.removeFromSuperview() }
        })
    }

    /// Keep the DOM Range in the isolated client world. CSS highlights follow wrapping, scrolling,
    /// and zoom and leave the page's selection and markup intact.
    static func web(in view: WKWebView, key: String) -> Self {
        func run(_ script: String) {
            view.callAsyncJavaScript(script, arguments: ["key": key], in: nil, in: .defaultClient, completionHandler: nil)
        }
        return Self(show: {
            run("""
                const saved = globalThis.rxcodeCommentRanges?.get(key);
                if (!saved || saved.sheet) return;
                const doc = saved.range.startContainer.ownerDocument;
                const sheet = new doc.defaultView.CSSStyleSheet();
                sheet.replaceSync('::highlight(' + key + ') { background-color: Highlight; color: HighlightText; }');
                doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
                doc.defaultView.CSS.highlights.set(key, new doc.defaultView.Highlight(saved.range));
                saved.sheet = sheet;
                """)
        }, hide: {
            run("""
                const saved = globalThis.rxcodeCommentRanges?.get(key);
                if (!saved) return;
                const doc = saved.range.startContainer.ownerDocument;
                doc.defaultView?.CSS.highlights.delete(key);
                if (saved.sheet) doc.adoptedStyleSheets = doc.adoptedStyleSheets.filter(sheet => sheet !== saved.sheet);
                rxcodeCommentRanges.delete(key);
                """)
        })
    }
}

private final class SelectionMark: NSView {
    var snapshot: NSImage?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if let snapshot {
            snapshot.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).setFill()
        dirtyRect.fill()
    }
}
