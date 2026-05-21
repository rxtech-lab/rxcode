import SwiftUI
import TipKit
import UniformTypeIdentifiers
import RxCodeCore

#if os(macOS)

struct InputBarView<Accessory: View, TopAccessory: View>: View {
    @Environment(ChatBridge.self) private var environmentChatBridge: ChatBridge?
    @Environment(WindowState.self) private var environmentWindowState: WindowState?
    @State private var isInputFocused: Bool = false
    @State private var inputFocusTrigger: UUID? = nil

    private let accessory: Accessory
    private let topAccessory: TopAccessory
    private let injectedChatBridge: ChatBridge?
    private let injectedWindowState: WindowState?

    @State private var showFilePicker = false
    @State private var showSlashPopup = false
    @State private var slashSelectedIndex = 0
    @State private var slashDetailCommand: SlashCommand?
    @State private var textPreviewAttachment: Attachment?
    @State private var imagePreviewAttachment: Attachment?
    @State private var isDragOver = false
    @State private var showAtFilePopup = false
    @State private var atFileSelectedIndex = 0
    @State private var historyIndex: Int = -1
    @State private var textFieldLayoutID = 0
    @State private var measuredInputHeight: CGFloat = 20
    @State private var inputHasMarkedText = false

    init(accessory: Accessory, @ViewBuilder topAccessory: () -> TopAccessory) {
        self.accessory = accessory
        self.topAccessory = topAccessory()
        self.injectedChatBridge = nil
        self.injectedWindowState = nil
    }

    init(
        windowState: WindowState,
        chatBridge: ChatBridge,
        accessory: Accessory,
        @ViewBuilder topAccessory: () -> TopAccessory
    ) {
        self.accessory = accessory
        self.topAccessory = topAccessory()
        self.injectedChatBridge = chatBridge
        self.injectedWindowState = windowState
    }

    var chatBridge: ChatBridge {
        injectedChatBridge ?? environmentChatBridge!
    }

    var windowState: WindowState {
        injectedWindowState ?? environmentWindowState!
    }

    var body: some View {
        VStack(spacing: 0) {
            if !windowState.attachments.isEmpty {
                attachmentPreviews
                    .padding(.horizontal, 16)
                    .transition(.offset(y: 10).combined(with: .opacity))
            }

            if !windowState.messageQueue.isEmpty {
                queuedMessagePreviews
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            topAccessory

            inputComposer
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .background(ClaudeTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusPill))
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusPill)
                    .strokeBorder(ClaudeTheme.inputBorder, lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.top, 0)
            .padding(.bottom, 12)
            .sheet(item: $slashDetailCommand) { cmd in CommandDetailSheet(command: cmd) }
            .sheet(item: $textPreviewAttachment) { attachment in TextPreviewSheet(attachment: attachment) }
            .sheet(item: $imagePreviewAttachment) { attachment in ImagePreviewSheet(attachment: attachment) }
            .onDrop(of: [.fileURL, .image], isTargeted: $isDragOver) { providers in
                processItemProviders(providers)
                return true
            }
            .overlay { dragOverlay }
        }
        .overlay(alignment: .top) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 4) {
                    if showSlashPopup && !slashFilteredCommands.isEmpty {
                        SlashCommandPopup(
                            query: slashQuery,
                            onSelect: { cmd in selectSlashCommand(cmd) },
                            selectedIndex: $slashSelectedIndex
                        )
                        .transition(.offset(y: 10).combined(with: .opacity))
                    }
                    if showAtFilePopup && !atFileFilteredEntries.isEmpty {
                        AtFilePopup(
                            entries: atFileFilteredEntries,
                            onSelect: { relativePath in selectAtFile(relativePath) },
                            selectedIndex: $atFileSelectedIndex
                        )
                        .transition(.offset(y: 10).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(.horizontal, 16)
            .offset(y: -4)
            // Show floating popups above the input bar by mapping top guide to bottom.
            .alignmentGuide(.top) { $0[.bottom] }
        }
        .onChange(of: windowState.requestInputFocus) { _, newValue in
            if newValue {
                inputFocusTrigger = UUID()
                windowState.requestInputFocus = false
            }
        }
        .onChange(of: windowState.currentSessionId) { _, _ in
            historyIndex = -1
            // Queue auto-flush is owned by AppState (`flushNextQueuedMessageIfNeeded`)
            // so the macOS and mobile paths share one arbiter — no duplicate sends.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                inputFocusTrigger = UUID()
            }
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                inputFocusTrigger = UUID()
            }
            if let path = windowState.selectedProject?.path {
                AtFileSearch.prefetch(projectPath: path)
            }
        }
        .onChange(of: windowState.selectedProject?.path) { _, newPath in
            if let path = newPath {
                AtFileSearch.prefetch(projectPath: path)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { inputFocusTrigger = UUID() }
    }

    // MARK: - Input Composer

    @ViewBuilder
    private var inputComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputTextField
            composerActionRow
        }
        .disabled(chatBridge.hasPendingPlanDecision)
        .opacity(chatBridge.hasPendingPlanDecision ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: chatBridge.hasPendingPlanDecision)
    }

    private var composerActionRow: some View {
        HStack(spacing: 10) {
            attachButton

            if windowState.sessionPlanMode {
                planModeChip
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            accessory
                .frame(maxWidth: .infinity, alignment: .leading)

            sendOrStopControls
        }
        .frame(height: 32)
        .animation(.easeInOut(duration: 0.15), value: windowState.sessionPlanMode)
    }

    private var hasComposerContent: Bool {
        !windowState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || inputHasMarkedText
            || !windowState.attachments.isEmpty
    }

    @ViewBuilder
    private var sendOrStopControls: some View {
        HStack(spacing: 8) {
            // While streaming, show the send button only when the user has typed
            // something to enqueue. When idle, always show send (disabled when empty).
            if !chatBridge.isStreaming || hasComposerContent {
                if !showSlashPopup {
                    ClaudeSendButton(
                        isEnabled: hasComposerContent,
                        action: sendMessage
                    )
                    .keyboardShortcut(.return, modifiers: .command)
                } else {
                    ClaudeSendButton(isEnabled: false, action: {}).disabled(true)
                }
            }

            if chatBridge.isStreaming {
                ClaudeStopButton(action: stopGeneration)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: chatBridge.isStreaming)
    }

    private func stopGeneration() {
        Task { await chatBridge.cancelStreaming() }
    }

    private var attachButton: some View {
        Menu {
            Button {
                showFilePicker = true
            } label: {
                Label("Attach file…", systemImage: "paperclip")
            }

            Divider()

            Toggle(isOn: planModeBinding) {
                Label("Plan mode", systemImage: "checklist")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: ClaudeTheme.size(15), weight: .regular))
                .foregroundStyle(windowState.sessionPlanMode ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(windowState.sessionPlanMode ? "Plan mode is on — Add menu" : "Add — attach file or toggle plan mode")
        .accessibilityIdentifier("composer-add-menu")
        .popoverTip(ChatFeatureTips.PlanModeTip(), arrowEdge: .top)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    private var planModeChip: some View {
        Button {
            Task { await chatBridge.togglePlanMode() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: ClaudeTheme.size(10), weight: .semibold))

                Text("Plan", bundle: .module)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.size(8), weight: .bold))
            }
            .foregroundStyle(ClaudeTheme.accent)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(ClaudeTheme.accentSubtle, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(ClaudeTheme.accent.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Turn off plan mode", bundle: .module))
        .accessibilityIdentifier("plan-mode-chip")
    }

    /// Mirrors `windowState.sessionPlanMode` into a Binding so the Menu's `Toggle`
    /// drives `chatBridge.togglePlanMode()` — the same path used by Shift+Tab.
    private var planModeBinding: Binding<Bool> {
        Binding(
            get: { windowState.sessionPlanMode },
            set: { _ in Task { await chatBridge.togglePlanMode() } }
        )
    }

    @ViewBuilder
    private var inputTextField: some View {
        IMETextView(
            text: Bindable(windowState).inputText,
            isFocused: $isInputFocused,
            hasMarkedText: $inputHasMarkedText,
            focusTrigger: inputFocusTrigger,
            font: .systemFont(ofSize: ClaudeTheme.size(14)),
            textColor: NSColor(ClaudeTheme.textPrimary),
            placeholder: String(localized: "Type a message...", bundle: .module),
            onReturn: handleReturnKey,
            onShiftReturn: handleShiftReturnKey,
            onUpArrow: { handleUpArrow() == .handled },
            onDownArrow: { handleDownArrow() == .handled },
            onTab: { handleTab() == .handled },
            onShiftTab: { Task { await chatBridge.togglePlanMode() } },
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

    private var clampedInputHeight: CGFloat {
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
        if shouldShowAt != showAtFilePopup {
            withAnimation(.easeOut(duration: 0.15)) { showAtFilePopup = shouldShowAt }
        }
        if shouldShowAt { atFileSelectedIndex = 0 }
    }

    private func handleUpArrow() -> KeyPress.Result {
        if showAtFilePopup && !atFileFilteredEntries.isEmpty {
            let count = atFileFilteredEntries.count
            atFileSelectedIndex = (atFileSelectedIndex - 1 + count) % count
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
        if showAtFilePopup && !atFileFilteredEntries.isEmpty {
            let count = atFileFilteredEntries.count
            atFileSelectedIndex = (atFileSelectedIndex + 1) % count
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
        if showAtFilePopup && !atFileFilteredEntries.isEmpty {
            let entries = atFileFilteredEntries
            if atFileSelectedIndex < entries.count { selectAtFile(entries[atFileSelectedIndex].relativePath) }
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
    private func resetIMEState() {
        textFieldLayoutID += 1
        DispatchQueue.main.async { inputFocusTrigger = UUID() }
    }

    private func handleEscapeKey() -> Bool {
        if showAtFilePopup {
            withAnimation(.easeOut(duration: 0.15)) { showAtFilePopup = false }
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

    // MARK: - Slash / At Queries

    private var slashQuery: String {
        let text = windowState.inputText
        guard !text.contains(" ") else { return "" }
        guard text.hasPrefix("/") else { return "" }
        return text
    }

    private var slashFilteredCommands: [SlashCommand] {
        SlashCommandRegistry.filtered(by: slashQuery)
    }

    private var userMessageHistory: [String] {
        chatBridge.messages.filter { $0.role == .user }.map(\.content)
    }

    private var atFileQuery: String {
        let text = windowState.inputText
        guard let atRange = text.range(of: "@", options: .backwards) else { return "" }
        let afterAt = String(text[atRange.upperBound...])
        if afterAt.contains(" ") { return "" }
        return afterAt
    }

    private var atFileFilteredEntries: [AtFileEntry] {
        guard let project = windowState.selectedProject else { return [] }
        return AtFileSearch.search(query: atFileQuery, projectPath: project.path)
    }

    private func selectSlashCommand(_ cmd: SlashCommand) {
        withAnimation(.easeOut(duration: 0.15)) { showSlashPopup = false }
        if cmd.acceptsInput && !cmd.isInteractive {
            windowState.inputText = cmd.command + " "
        } else {
            windowState.inputText = ""
            Task { await chatBridge.sendSlashCommand(cmd.command) }
        }
    }

    private func selectAtFile(_ relativePath: String) {
        withAnimation(.easeOut(duration: 0.15)) { showAtFilePopup = false }
        var text = windowState.inputText
        if let atRange = text.range(of: "@", options: .backwards) {
            text.replaceSubrange(atRange.lowerBound..., with: "@\(relativePath) ")
        }
        windowState.inputText = text
    }

    private func hasActiveAtQuery(in text: String) -> Bool {
        guard let atRange = text.range(of: "@", options: .backwards) else { return false }
        let afterAt = String(text[atRange.upperBound...])
        return !afterAt.contains(" ")
    }

    // MARK: - Drag Overlay

    @ViewBuilder private var dragOverlay: some View {
        if isDragOver {
            let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusPill)
            shape
                .strokeBorder(ClaudeTheme.accent.opacity(0.6), lineWidth: 2, antialiased: true)
                .background(ClaudeTheme.accent.opacity(0.05), in: shape)
                .padding(.horizontal, 16)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Attachment Previews

    private var attachmentPreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(windowState.attachments) { attachment in
                    AttachmentPreviewItem(attachment: attachment) {
                        windowState.removeAttachment(attachment.id)
                    } onTap: {
                        switch attachment.type {
                        case .text: textPreviewAttachment = attachment
                        case .image: imagePreviewAttachment = attachment
                        default: break
                        }
                    }
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    private func handleImageChipTap(_ index: Int) {
        let images = windowState.attachments.filter { $0.type == .image }
        guard index >= 1, index <= images.count else { return }
        imagePreviewAttachment = images[index - 1]
    }

    // MARK: - Send / Return

    private func sendMessage() {
        guard !chatBridge.hasPendingPlanDecision else { return }
        guard !windowState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !windowState.attachments.isEmpty else { return }
        historyIndex = -1

        if chatBridge.isStreaming {
            withAnimation(.easeOut(duration: 0.2)) {
                chatBridge.enqueueMessage(text: windowState.inputText, attachments: windowState.attachments)
            }
            windowState.inputText = ""
            windowState.attachments = []
            resetIMEState()
            return
        }

        Task { await chatBridge.send() }
        resetIMEState()
    }

    private func handleReturnKey() {
        // IMETextView dispatches doCommand(insertNewline:) only after the IME has finalized any
        // composing text, so windowState.inputText is already up-to-date here.
        if showSlashPopup && !slashFilteredCommands.isEmpty {
            let commands = slashFilteredCommands
            if slashSelectedIndex < commands.count {
                selectSlashCommand(commands[slashSelectedIndex])
            }
            return
        }
        if showAtFilePopup && !atFileFilteredEntries.isEmpty {
            let entries = atFileFilteredEntries
            if atFileSelectedIndex < entries.count {
                selectAtFile(entries[atFileSelectedIndex].relativePath)
            }
            return
        }
        sendMessage()
    }

    private func handleShiftReturnKey() {
        windowState.inputText.append("\n")
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
