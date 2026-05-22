import SwiftUI
#if os(macOS)
import AppKit
import RxCodeCore

// SwiftUI's TextEditor (PlatformTextView) overrides insertText to enforce binding sync, which
// races and discards composing Hangul on commit. Hosting an NSTextView directly lets us own the
// binding and skip write-back while marked text is active, eliminating the race.
struct IMETextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var hasMarkedText: Bool
    /// Bumping this UUID asks the view to take first responder. Plain SwiftUI re-renders
    /// must NOT steal focus — that races with text-selection NSTextView in message bubbles.
    var focusTrigger: UUID?
    var font: NSFont
    var textColor: NSColor
    var placeholder: String = ""
    var onReturn: () -> Void
    var onUpArrow: () -> Bool
    var onDownArrow: () -> Bool
    var onTab: () -> Bool
    var onShiftTab: () -> Void
    var onEscape: () -> Bool
    var onPasteCommandV: () -> Bool
    var onImageChipTap: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Install a custom layout manager so we can draw a rounded background behind
        // [Image\d+] tokens, turning them into visual chips.
        let textStorage = NSTextStorage()
        let layoutManager = ChipLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 5
        layoutManager.addTextContainer(container)

        let textView = _IMETextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = textColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.setAccessibilityIdentifier("chat-input-text-view")
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        applyCallbacks(to: textView)
        textView.refreshChipAppearance()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? _IMETextView else { return }
        applyCallbacks(to: textView)
        // Skip write-in while IME is composing — same reason coordinator skips write-back.
        // Compare against coordinator's cached value to avoid materializing textView.string
        // (O(n) in length) on every parent re-render.
        if !textView.hasMarkedText(), context.coordinator.lastAppliedText != text {
            textView.string = text
            context.coordinator.lastAppliedText = text
            textView.refreshChipAppearance()
        }
        if textView.font != font { textView.font = font }
        if textView.textColor != textColor { textView.textColor = textColor }
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        // Take first responder only when an explicit focus request fires (UUID changed).
        // Plain SwiftUI re-renders no longer race with text selection in message bubbles.
        if let trigger = focusTrigger,
           trigger != context.coordinator.lastAppliedFocusTrigger {
            context.coordinator.lastAppliedFocusTrigger = trigger
            if let window = textView.window, window.isKeyWindow,
               window.firstResponder !== textView {
                DispatchQueue.main.async {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    private func applyCallbacks(to textView: _IMETextView) {
        textView.onReturn = onReturn
        textView.onUpArrow = onUpArrow
        textView.onDownArrow = onDownArrow
        textView.onTab = onTab
        textView.onShiftTab = onShiftTab
        textView.onEscape = onEscape
        textView.onPasteCommandV = onPasteCommandV
        textView.onImageChipTap = onImageChipTap
        textView.onMarkedTextChange = { active in
            if hasMarkedText != active {
                hasMarkedText = active
            }
        }
        textView.onFocusChange = { focused in
            if isFocused != focused {
                isFocused = focused
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        var lastAppliedText: String = ""
        var lastAppliedFocusTrigger: UUID?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Skip binding write-back during IME composition; the binding picks up the committed
            // text from the next textDidChange after the IME finalizes.
            if tv.hasMarkedText() { return }
            let current = tv.string
            lastAppliedText = current
            if text.wrappedValue != current {
                text.wrappedValue = current
            }
            (tv as? _IMETextView)?.refreshChipAppearance()
        }
    }
}

// MARK: - Chip pattern

nonisolated private let chipRegex: NSRegularExpression = {
    // Force-try is safe — the pattern is a string literal validated at compile time.
    try! NSRegularExpression(pattern: #"\[Image(\d+)\]"#)
}()

nonisolated private func enumerateChipRanges(in text: String, _ body: (NSRange, Int) -> Void) {
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    chipRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
        guard let m = match, m.numberOfRanges >= 2 else { return }
        let numRange = m.range(at: 1)
        guard let idx = Int(nsText.substring(with: numRange)) else { return }
        body(m.range, idx)
    }
}

// MARK: - Chip Layout Manager

fileprivate final class ChipLayoutManager: NSLayoutManager, @unchecked Sendable {
    nonisolated override init() {
        super.init()
    }

    nonisolated required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    nonisolated override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage,
              let container = textContainers.first else { return }

        // ClaudeTheme is MainActor-isolated; drawing runs on the main thread but inside a
        // nonisolated override. Reading the accent color through MainActor.assumeIsolated is safe
        // because AppKit only calls drawBackground on the main thread.
        let fillColor: NSColor = MainActor.assumeIsolated {
            NSColor(ClaudeTheme.accent).withAlphaComponent(0.18)
        }
        let borderColor: NSColor = MainActor.assumeIsolated {
            NSColor(ClaudeTheme.accent).withAlphaComponent(0.35)
        }

        enumerateChipRanges(in: storage.string) { charRange, _ in
            let glyphRange = self.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            let visible = NSIntersectionRange(glyphRange, glyphsToShow)
            guard visible.length > 0 else { return }

            self.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                var r = rect.offsetBy(dx: origin.x, dy: origin.y)
                r = r.insetBy(dx: -3, dy: 0)
                let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
                fillColor.setFill()
                path.fill()
                borderColor.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
        }
    }
}

fileprivate final class _IMETextView: NSTextView {
    var onReturn: () -> Void = {}
    var onUpArrow: () -> Bool = { false }
    var onDownArrow: () -> Bool = { false }
    var onTab: () -> Bool = { false }
    var onShiftTab: () -> Void = {}
    var onEscape: () -> Bool = { false }
    var onPasteCommandV: () -> Bool = { false }
    var onImageChipTap: ((Int) -> Void)?
    var onMarkedTextChange: (Bool) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChange(false) }
        return result
    }

    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty && !hasMarkedText(), !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let inset = textContainerInset
        let rect = NSRect(
            x: inset.width + padding,
            y: inset.height,
            width: max(0, bounds.width - inset.width * 2 - padding),
            height: max(0, bounds.height - inset.height * 2)
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        placeholder.draw(in: rect, withAttributes: attrs)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChange(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChange(false)
    }

    override func keyDown(with event: NSEvent) {
        // Shift+Enter: NSTextView doesn't bind this to a doCommand by default. Force-commit any
        // composing IME text, then insert the newline through NSTextView so AppKit updates the
        // insertion point and scroll position together.
        if event.keyCode == 36, event.modifierFlags.contains(.shift) {
            commitMarkedTextIfNeeded()
            insertShiftReturnNewline()
            return
        }
        // Shift+Tab: NSTextView routes this to insertBacktab: which we intercept here so it
        // can never disturb the input text, regardless of marked-text state.
        if event.keyCode == 48, event.modifierFlags.contains(.shift) {
            onShiftTab()
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            // IME has already committed any composing text via insertText: before this command
            // is dispatched. Binding is up-to-date.
            onReturn()
            return
        case #selector(insertTab(_:)):
            if onTab() { return }
        case #selector(moveUp(_:)):
            if onUpArrow() { return }
        case #selector(moveDown(_:)):
            if onDownArrow() { return }
        case #selector(cancelOperation(_:)):
            if onEscape() { return }
        default:
            break
        }
        super.doCommand(by: selector)
    }

    override func paste(_ sender: Any?) {
        if onPasteCommandV() { return }
        super.paste(sender)
    }

    override func mouseDown(with event: NSEvent) {
        if onImageChipTap != nil,
           let idx = imageChipIndex(at: event.locationInWindow) {
            onImageChipTap?(idx)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard onImageChipTap != nil,
              let layoutManager = layoutManager,
              let container = textContainer,
              let storage = textStorage else { return }

        let origin = textContainerOrigin
        enumerateChipRanges(in: storage.string) { charRange, _ in
            let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                let r = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
                self.addCursorRect(r, cursor: .pointingHand)
            }
        }
    }

    private func imageChipIndex(at locationInWindow: NSPoint) -> Int? {
        guard let layoutManager = layoutManager,
              let container = textContainer,
              let storage = textStorage else { return nil }
        let pointInView = convert(locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: pointInView.x - origin.x, y: pointInView.y - origin.y)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: container,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        // glyphIndex(for:) clamps to nearest glyph even when point is outside text. Verify the
        // point is actually within the glyph's bounding rect to avoid false positives from clicks
        // past end-of-line.
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: container
        )
        guard glyphRect.contains(containerPoint) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        var matched: Int?
        enumerateChipRanges(in: storage.string) { charRange, idx in
            if NSLocationInRange(charIndex, charRange) {
                matched = idx
            }
        }
        return matched
    }

    /// Reapply per-chip temporary attributes (foreground color) and refresh cursor rects.
    /// Background drawing is handled by ChipLayoutManager.drawBackground and refreshes
    /// automatically whenever the storage is edited.
    func refreshChipAppearance() {
        guard let layoutManager = layoutManager, let storage = textStorage else { return }
        let nsText = storage.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        let chipTextColor = NSColor(ClaudeTheme.accent)
        enumerateChipRanges(in: storage.string) { charRange, _ in
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: chipTextColor,
                forCharacterRange: charRange
            )
        }
        layoutManager.invalidateDisplay(forCharacterRange: fullRange)
        window?.invalidateCursorRects(for: self)
    }

    private func commitMarkedTextIfNeeded() {
        guard hasMarkedText() else { return }
        let range = markedRange()
        guard range.location != NSNotFound, range.length > 0,
              let storage = textStorage,
              NSMaxRange(range) <= (storage.string as NSString).length else { return }
        let composing = (storage.string as NSString).substring(with: range)
        insertText(composing, replacementRange: range)
    }

    private func insertShiftReturnNewline() {
        insertText("\n", replacementRange: selectedRange())
        revealInsertionPoint()
    }

    private func revealInsertionPoint() {
        let textLength = (string as NSString).length
        let location = min(max(selectedRange().location, 0), textLength)
        let caretRange = NSRange(location: location, length: 0)
        scrollRangeToVisible(caretRange)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let textLength = (self.string as NSString).length
            let location = min(max(self.selectedRange().location, 0), textLength)
            self.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
    }
}
#endif
