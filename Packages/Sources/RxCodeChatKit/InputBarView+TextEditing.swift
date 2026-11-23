#if os(macOS)
import SwiftUI
import TipKit
import UniformTypeIdentifiers
import RxCodeCore

extension InputBarView {
    @ViewBuilder
    var inputTextField: some View {
        IMETextView(
            text: Bindable(windowState).inputText,
            isFocused: $isInputFocused,
            hasMarkedText: $inputHasMarkedText,
            focusTrigger: inputFocusTrigger,
            font: .systemFont(ofSize: ClaudeTheme.size(14)),
            textColor: NSColor(ClaudeTheme.textPrimary),
            placeholder: composerPlaceholder,
            onReturn: handleReturnKey,
            onUpArrow: { handleUpArrow() == .handled },
            onDownArrow: { handleDownArrow() == .handled },
            onTab: { handleTab() == .handled },
            onEscape: handleEscapeKey,
            onPasteCommandV: handlePaste,
            onImageChipTap: handleImageChipTap
        )
        .id(textFieldLayoutID)
        .accessibilityIdentifier("chat-input")
        .onChange(of: windowState.inputText) { oldValue, newValue in
            handleInputTextChange(oldValue: oldValue, newValue: newValue)
        }
        .frame(height: clampedInputHeight)
        .background(InputHeightMeasurer(text: windowState.inputText, measuredHeight: $measuredInputHeight))
    }

    var clampedInputHeight: CGFloat {
        let oneLine: CGFloat = 20
        let minHeight: CGFloat = 38
        let maxLines: CGFloat = 10
        return min(max(measuredInputHeight, minHeight), oneLine * maxLines)
    }

    private func handleInputTextChange(oldValue: String, newValue: String) {
        // Safety net for paste routes onKeyPress doesn't intercept (context menu, Edit menu).
        // delta > 1 filters out single-keystroke typing; IME commits are too short to hit
        // the longTextThreshold, so false positives are not a concern.
        if newValue.count - oldValue.count > 1,
           let inserted = insertedSubstring(oldValue: oldValue, newValue: newValue) {
            if let attachment = attachmentFromPastedText(inserted) {
                windowState.addAttachment(attachment)
                windowState.inputText = oldValue
                return
            }
            if chatBridge.autoPreviewSettings.longText,
               inserted.count >= AttachmentFactory.longTextThreshold {
                windowState.addAttachment(AttachmentFactory.fromLongText(inserted))
                windowState.inputText = oldValue
                return
            }
        }

        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        let hasSpaceAfterSlash = newValue.contains(" ")
        let shouldShowSlash = trimmed.hasPrefix("/") && !hasSpaceAfterSlash
        if shouldShowSlash != showSlashPopup {
            withAnimation(.easeOut(duration: 0.15)) { showSlashPopup = shouldShowSlash }
        }
        if shouldShowSlash { slashSelectedIndex = 0 }

        let shouldShowAt = !shouldShowSlash && hasActiveAtQuery(in: newValue)
        if shouldShowAt != showAtPopup {
            withAnimation(.easeOut(duration: 0.15)) { showAtPopup = shouldShowAt }
        }
        if shouldShowAt { atSelectedIndex = 0 }
    }

    private func handleUpArrow() -> KeyPress.Result {
        if showAtPopup && atCombinedCount > 0 {
            let count = atCombinedCount
            atSelectedIndex = (atSelectedIndex - 1 + count) % count
            return .handled
        }
        if showSlashPopup && !slashFilteredCommands.isEmpty {
            let count = slashFilteredCommands.count
            slashSelectedIndex = (slashSelectedIndex - 1 + count) % count
            return .handled
        }
        let history = userMessageHistory
        guard !history.isEmpty else { return .ignored }
        let nextIndex = historyIndex + 1
        if nextIndex < history.count {
            historyIndex = nextIndex
            let msgIndex = history.count - 1 - historyIndex
            windowState.inputText = history[msgIndex]
        }
        return .handled
    }

    private func handleDownArrow() -> KeyPress.Result {
        if showAtPopup && atCombinedCount > 0 {
            let count = atCombinedCount
            atSelectedIndex = (atSelectedIndex + 1) % count
            return .handled
        }
        if showSlashPopup && !slashFilteredCommands.isEmpty {
            let count = slashFilteredCommands.count
            slashSelectedIndex = (slashSelectedIndex + 1) % count
            return .handled
        }
        guard historyIndex >= 0 else { return .ignored }
        historyIndex -= 1
        if historyIndex < 0 {
            windowState.inputText = ""
        } else {
            let history = userMessageHistory
            let msgIndex = history.count - 1 - historyIndex
            if msgIndex >= 0 && msgIndex < history.count {
                windowState.inputText = history[msgIndex]
            }
        }
        return .handled
    }

    private func handleTab() -> KeyPress.Result {
        if showAtPopup && atCombinedCount > 0 {
            selectAtMention(at: atSelectedIndex)
            return .handled
        }
        guard showSlashPopup && !slashFilteredCommands.isEmpty else { return .ignored }
        let commands = slashFilteredCommands
        if slashSelectedIndex < commands.count { selectSlashCommand(commands[slashSelectedIndex]) }
        return .handled
    }

    // Returns true to suppress NSTextView's native paste; false lets the default plain-text paste run.
    private func handlePaste() -> Bool {
        let pb = NSPasteboard.general

        if let attachment = imageAttachmentFromPasteboard(pb) {
            if chatBridge.autoPreviewSettings.image {
                windowState.addAttachment(attachment)
            }
            return true
        }

        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: \.isFileURL) {
            let isImage = AttachmentFactory.imageExtensions.contains(url.pathExtension.lowercased())
            let allowed = isImage ? chatBridge.autoPreviewSettings.image : chatBridge.autoPreviewSettings.filePath
            if allowed, let attachment = AttachmentFactory.fromFileURL(url) {
                windowState.addAttachment(attachment)
            } else {
                insertAtCursor(url.path)
            }
            return true
        }

        guard let text = pb.string(forType: .string), !text.isEmpty else { return true }

        if let attachment = attachmentFromPastedText(text) {
            windowState.addAttachment(attachment)
            return true
        }

        if chatBridge.autoPreviewSettings.longText,
           text.count >= AttachmentFactory.longTextThreshold {
            windowState.addAttachment(AttachmentFactory.fromLongText(text))
            return true
        }

        insertAtCursor(text)
        return true
    }

    private func attachmentFromPastedText(_ text: String) -> Attachment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let attachment = attachmentFromPathText(trimmed) {
            let allowed = attachment.type == .image
                ? chatBridge.autoPreviewSettings.image
                : chatBridge.autoPreviewSettings.filePath
            if allowed { return attachment }
        }
        if chatBridge.autoPreviewSettings.url,
           !trimmed.contains(" "), !trimmed.contains("\n"),
           let url = URL(string: trimmed),
           let scheme = url.scheme, ["http", "https"].contains(scheme),
           url.host != nil {
            return AttachmentFactory.fromURL(url)
        }
        return nil
    }

    /// Assumes a single insertion (paste/type at one cursor position) — not a general diff.
    private func insertedSubstring(oldValue: String, newValue: String) -> String? {
        guard newValue.count > oldValue.count else { return nil }

        var oldPrefix = oldValue.startIndex
        var newPrefix = newValue.startIndex
        while oldPrefix < oldValue.endIndex, newPrefix < newValue.endIndex,
              oldValue[oldPrefix] == newValue[newPrefix] {
            oldValue.formIndex(after: &oldPrefix)
            newValue.formIndex(after: &newPrefix)
        }

        var oldSuffix = oldValue.endIndex
        var newSuffix = newValue.endIndex
        while oldSuffix > oldPrefix, newSuffix > newPrefix {
            let prevOld = oldValue.index(before: oldSuffix)
            let prevNew = newValue.index(before: newSuffix)
            guard oldValue[prevOld] == newValue[prevNew] else { break }
            oldSuffix = prevOld
            newSuffix = prevNew
        }

        guard newPrefix < newSuffix else { return nil }
        return String(newValue[newPrefix..<newSuffix])
    }

    // Image paths skip fileExists — some screenshot tools write the clipboard before the file.
    private func attachmentFromPathText(_ trimmed: String) -> Attachment? {
        guard !trimmed.contains("\n"), !trimmed.isEmpty else { return nil }

        let path: String
        if trimmed.hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            path = url.path
        } else if trimmed.hasPrefix("/") {
            path = trimmed
        } else if trimmed.hasPrefix("~/") {
            path = (trimmed as NSString).expandingTildeInPath
        } else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if AttachmentFactory.imageExtensions.contains(ext) {
            return AttachmentFactory.fromFileURL(url)
        }
        if FileManager.default.fileExists(atPath: path) {
            return AttachmentFactory.fromFileURL(url)
        }
        return nil
    }

    private func insertAtCursor(_ text: String) {
        let current = windowState.inputText
        if let editor = NSApp.keyWindow?.firstResponder as? NSText {
            let range = editor.selectedRange
            if range.location != NSNotFound {
                windowState.inputText = (current as NSString).replacingCharacters(in: range, with: text)
                resetIMEState()
                return
            }
        }
        windowState.inputText = current + text
        resetIMEState()
    }

    private func imageAttachmentFromPasteboard(_ pb: NSPasteboard) -> Attachment? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type) {
                return Attachment(type: .image, name: "clipboard-\(UUID().uuidString.prefix(8)).png", imageData: data)
            }
        }
        if let image = NSImage(pasteboard: pb),
           let tiffData = image.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return Attachment(type: .image, name: "clipboard-\(UUID().uuidString.prefix(8)).png", imageData: pngData)
        }
        return nil
    }

    // Recreate the text field to clear NSTextView state (e.g. after sending) and reassert focus.
    func resetIMEState() {
        textFieldLayoutID += 1
        DispatchQueue.main.async { inputFocusTrigger = UUID() }
    }

    private func handleEscapeKey() -> Bool {
        if showAtPopup {
            withAnimation(.easeOut(duration: 0.15)) { showAtPopup = false }
            return true
        }
        if showSlashPopup {
            withAnimation(.easeOut(duration: 0.15)) { showSlashPopup = false }
            return true
        }
        if chatBridge.isStreaming {
            Task { await chatBridge.cancelStreaming() }
            return true
        }
        return false
    }
}

// IMETextView's NSScrollView doesn't surface intrinsic height, so a hidden Text at the same
// width/font reports the wrapped height that drives clampedInputHeight.
private struct InputHeightMeasurer: View {
    let text: String
    @Binding var measuredHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            Text(measuringText)
                .font(.system(size: ClaudeTheme.size(14)))
                .frame(width: geo.size.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(heightReporter)
                .hidden()
                .allowsHitTesting(false)
        }
    }

    private var heightReporter: some View {
        GeometryReader { inner in
            Color.clear
                .onAppear { measuredHeight = inner.size.height }
                .onChange(of: inner.size.height) { _, h in
                    measuredHeight = h
                }
        }
    }

    // A trailing \n has zero intrinsic height when rendered through Text, so append a space to
    // force the empty final line to be measured. Cap input length: clampedInputHeight saturates
    // at 10 lines (~200pt), so once the text definitely exceeds that we don't need exact height
    // and can avoid laying out arbitrarily large pasted buffers on every keystroke.
    private var measuringText: String {
        if text.isEmpty { return " " }
        let capped = text.count > 2000 ? String(text.prefix(2000)) : text
        return capped.hasSuffix("\n") ? capped + " " : capped
    }
}
#endif
