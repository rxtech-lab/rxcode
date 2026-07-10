#if os(macOS)
import AppKit
import RxCodeCore
import SwiftUI

public struct CodeEditorView: NSViewRepresentable {
    @Binding private var text: String
    private let language: String
    private let fontSize: CGFloat
    private let autocompleteProvider: (any CodeEditorAutocompleteProvider)?

    public init(
        text: Binding<String>,
        language: String,
        fontSize: CGFloat = 12,
        autocompleteProvider: (any CodeEditorAutocompleteProvider)? = nil
    ) {
        _text = text
        self.language = language
        self.fontSize = fontSize
        self.autocompleteProvider = autocompleteProvider
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        let textContainer = NSTextContainer(containerSize: containerSize)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = CompletionTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.completionRangeProvider = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.apply(text: text)
        return scrollView
    }

    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let textView = nsView.documentView as? CompletionTextView else { return }
        if textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        textView.delegate = nil
        textView.completionRangeProvider = nil
        textView.completionRangeOverride = nil
        textView.undoManager?.removeAllActions(withTarget: textView)
        textView.allowsUndo = false
        coordinator.textView = nil
        nsView.documentView = nil
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            context.coordinator.apply(text: text)
        }
    }

    @MainActor public final class Coordinator: NSObject, NSTextViewDelegate, CompletionRangeProviding {
        var parent: CodeEditorView
        weak var textView: CompletionTextView?
        private var activeCompletionContext: CodeEditorAutocompleteContext?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            if !textView.hasMarkedText() {
                highlight(textView)
                triggerAutocompleteIfNeeded(textView)
            }
        }

        func apply(text: String) {
            guard let textView else { return }
            if textView.string != text {
                textView.string = text
            }
            highlight(textView)
        }

        func completionRange(for textView: NSTextView) -> NSRange? {
            activeCompletionContext?.replacementRange
        }

        public func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard let provider = parent.autocompleteProvider,
                  let context = activeCompletionContext
            else { return [] }

            index?.pointee = 0
            return provider.completions(for: context).map(\.insertionText)
        }

        private func triggerAutocompleteIfNeeded(_ textView: CompletionTextView) {
            guard let provider = parent.autocompleteProvider else {
                activeCompletionContext = nil
                textView.completionRangeOverride = nil
                return
            }

            let selectedRange = textView.selectedRange()
            guard let context = provider.context(in: textView.string, selectedRange: selectedRange),
                  !provider.completions(for: context).isEmpty
            else {
                activeCompletionContext = nil
                textView.completionRangeOverride = nil
                return
            }

            activeCompletionContext = context
            textView.completionRangeOverride = context.replacementRange
            textView.complete(nil)
        }

        private func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selected = textView.selectedRanges
            let highlighted = SyntaxHighlighter.highlightNS(
                textView.string,
                language: parent.language,
                fontSize: parent.fontSize
            )
            storage.beginEditing()
            storage.setAttributedString(highlighted)
            storage.endEditing()
            textView.selectedRanges = selected
        }
    }
}

@MainActor protocol CompletionRangeProviding: AnyObject {
    func completionRange(for textView: NSTextView) -> NSRange?
}

@MainActor final class CompletionTextView: NSTextView {
    weak var completionRangeProvider: CompletionRangeProviding?
    var completionRangeOverride: NSRange?

    override var rangeForUserCompletion: NSRange {
        completionRangeOverride
            ?? completionRangeProvider?.completionRange(for: self)
            ?? super.rangeForUserCompletion
    }
}
#endif
