import SwiftUI
import AppKit
import RxCodeCore

struct MessageBubble: View {
    @Environment(ChatBridge.self) private var chatBridge
    let message: ChatMessage
    @State private var isCopied = false
    @State private var cursorVisible = true
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isEditFocused: Bool
    @State private var isLongTextExpanded = false
    @State private var hoveredBlockId: String? = nil
    @State private var isHoveringUserBubble = false
    @State private var previewImagePath: String?

    /// Threshold (character count) for collapsing long text
    private static let longTextThreshold = 500

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                // Show attachments
                if !message.attachmentPaths.isEmpty {
                    attachmentPreview
                }

                if message.role == .user {
                    let displayed = ChatSession.extractDisplayedContent(from: message.content)
                    // Inline-render `[Attached image: /path]` markers found in content. For
                    // freshly-sent messages `attachmentPaths` already covers this; for sessions
                    // reloaded from CLI history, the marker is in the content text and this is
                    // the only path that surfaces the actual image.
                    if !displayed.imagePaths.isEmpty, message.attachmentPaths.isEmpty {
                        inlineAttachedImages(paths: displayed.imagePaths)
                    }
                    // User message: single text bubble
                    if !displayed.text.isEmpty {
                        textBubble(displayText: displayed.text)
                    }
                } else if message.isCompactBoundary {
                    compactBoundaryBubble
                } else if message.isError {
                    // Error message: warning-style bubble
                    errorBubble
                } else {
                    // Assistant message: render blocks in order
                    let hidden = message.isStreaming ? [] : message.blocks.compactMap(\.toolCall).filter { isTransientTool($0) && $0.hasNonEmptyResult }
                    // Filter to only renderable blocks — exclude hidden transient tool blocks from ForEach
                    // to prevent zero-height TupleViews from introducing VStack spacing.
                    // Adjacent text blocks made contiguous by hidden tools are merged into a single bubble
                    // (so continuous text Claude sent across turns due to tool_use appears as one bubble)
                    let visibleBlocks = Self.mergeAdjacentTextBlocks(
                        in: message.blocks.filter { block in
                            if PlanCardView.shouldHideBlock(block, in: message, allMessages: chatBridge.messages) { return false }
                            if let text = block.text { return !text.isEmpty }
                            if let toolCall = block.toolCall {
                                if PlanCardView.isSupersededExitPlanMode(
                                    toolCall: toolCall,
                                    in: message,
                                    allMessages: chatBridge.messages
                                ) { return false }
                                if message.isStreaming { return true }
                                if isTransientTool(toolCall) { return false }
                                // Agent/Edit/Write tools are always shown even without a result
                                // Agent/Edit/Write/AskUserQuestion are always shown even without a result
                                if toolCall.isKeepAlways { return true }
                                // Other non-transient tools: only show when there is a result or error (prevents empty tool bubbles)
                                return toolCall.result != nil || toolCall.isError
                            }
                            return false
                        }
                    )

                    // Hidden tool summary — shown before text (reflects tool execution → text response order)
                    if !hidden.isEmpty {
                        transientToolSummary(hidden: hidden)
                    }

                    ForEach(visibleBlocks) { block in
                        Group {
                            if let text = block.text, !text.isEmpty {
                                assistantTextBubble(text: text, blockId: block.id, hasHiddenTools: !hidden.isEmpty)
                            }
                            if let toolCall = block.toolCall {
                                if toolCall.name == "AskUserQuestion" {
                                    AskUserQuestionView(toolCall: toolCall)
                                } else if let planMd = PlanCardView.renderMarkdown(for: toolCall, in: message) {
                                    let external: String? = (PlanCardView.isExitPlanMode(toolCall) && planMd.isEmpty)
                                        ? PlanCardView.latestPriorPlanMarkdown(before: message, in: chatBridge.messages)
                                        : nil
                                    PlanCardView(
                                        toolCall: toolCall,
                                        planMarkdown: planMd,
                                        isMessageStreaming: message.isStreaming,
                                        externalPlanMarkdown: external
                                    )
                                } else {
                                    ToolResultView(toolCall: toolCall, isMessageStreaming: message.isStreaming)
                                }
                            }
                        }
                        .transition(blockFadeTransition)
                    }
                    .animation(.easeOut(duration: 0.28), value: visibleBlocks.map(\.id))
                }

                // Response complete indicator + elapsed time
                if message.role == .assistant && !message.isStreaming,
                   let duration = message.duration {
                    HStack(spacing: 4) {
                        if message.isResponseComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: ClaudeTheme.messageSize(11)))
                                .foregroundStyle(ClaudeTheme.statusSuccess)
                        }
                        Text(duration.formattedDuration)
                            .font(.system(size: ClaudeTheme.messageSize(11), design: .monospaced))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
        .sheet(item: Binding<ImagePreviewItem?>(
            get: { previewImagePath.map(ImagePreviewItem.init) },
            set: { previewImagePath = $0?.path }
        )) { item in
            MessageImagePreviewSheet(path: item.path) { previewImagePath = nil }
        }
    }

    // MARK: - Compact Boundary Bubble

    private var compactBoundaryBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(message.content)
                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.border, lineWidth: BubbleStyle.borderWidth)
        )
    }

    // MARK: - Error Bubble

    private var errorBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: ClaudeTheme.messageSize(13)))
                .foregroundStyle(ClaudeTheme.statusWarning)
            Text(message.content)
                .font(.system(size: ClaudeTheme.messageSize(14)))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .textSelection(.enabled)
        }
        .bubbleStyle(.error)
    }

    // MARK: - User Text Bubble

    @ViewBuilder
    private func textBubble(displayText: String) -> some View {
        if isEditing {
            VStack(alignment: .trailing, spacing: 8) {
                TextField(String(localized: "Edit message...", bundle: .module), text: $editText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.messageSize(14)))
                    .foregroundStyle(ClaudeTheme.userBubbleText)
                    .focused($isEditFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(ClaudeTheme.userBubble, in: bubbleShape)
                    .overlay(
                        bubbleShape
                            .strokeBorder(ClaudeTheme.accent, lineWidth: 1.5)
                    )
                    .onKeyPress(.return, phases: .down) { keyPress in
                        guard !keyPress.modifiers.contains(.shift) else { return .ignored }
                        submitEdit()
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        isEditing = false
                        return .handled
                    }

                HStack(spacing: 8) {
                    Button(String(localized: "Cancel", bundle: .module)) {
                        isEditing = false
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: ClaudeTheme.messageSize(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)

                    Button(String(localized: "Send", bundle: .module)) {
                        submitEdit()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.accent)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                let isLong = displayText.count > Self.longTextThreshold
                Text(chipifiedAttributedString(displayText))
                    .font(.system(size: ClaudeTheme.messageSize(14)))
                    .foregroundStyle(ClaudeTheme.userBubbleText)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .lineLimit(isLong && !isLongTextExpanded ? 5 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        // Intercept the synthetic `rxcode-image://<index>` link
                        // emitted by chipifiedAttributedString — open the matching
                        // image in the preview sheet rather than the system browser.
                        guard url.scheme == "rxcode-image",
                              let index = Int(url.host ?? ""),
                              let path = imagePath(forChipIndex: index) else {
                            return .systemAction
                        }
                        previewImagePath = path
                        return .handled
                    })
                if isLong {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isLongTextExpanded.toggle()
                        }
                    } label: {
                        if isLongTextExpanded {
                            Text("Collapse", bundle: .module)
                        } else {
                            Text("Show more", bundle: .module)
                        }
                    }
                    .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.accent)
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 500, alignment: .leading)
            .bubbleStyle(.user)
            .fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .bottomTrailing) {
                if isHoveringUserBubble {
                    HStack(spacing: 3) {
                        userActionButton(systemName: isCopied ? "checkmark" : "doc.on.doc") {
                            copyToClipboard(message.content, feedback: $isCopied)
                        }
                        userActionButton(systemName: "pencil") {
                            editText = message.content
                            isEditing = true
                        }
                    }
                    .padding(5)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
            .onHover { isHoveringUserBubble = $0 }
            .onChange(of: isEditing) { _, editing in
                if editing { isEditFocused = true }
            }
        }
    }

    // MARK: - Assistant Text Bubble

    private func assistantTextBubble(text: String, blockId: String, hasHiddenTools: Bool = false) -> some View {
        let isLastBlock = message.blocks.last?.isText == true
            && message.blocks.last?.text == text

        return HStack(alignment: .bottom, spacing: 0) {
            MarkdownContentView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.isStreaming && isLastBlock {
                Text("|")
                    .font(.system(size: ClaudeTheme.messageSize(15), weight: .light))
                    .foregroundStyle(ClaudeTheme.accent)
                    .opacity(cursorVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: cursorVisible)
                    .onAppear { cursorVisible = false }
            }
        }
        .foregroundStyle(ClaudeTheme.textPrimary)
        .padding(.vertical, 2)
        .overlay(alignment: .bottomTrailing) {
            if hoveredBlockId == blockId && !message.isStreaming {
                copyButton(for: text)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .onHover { hoveredBlockId = $0 ? blockId : nil }
        .onTapGesture {
            if hasHiddenTools {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTransientTools.toggle()
                }
            }
        }
        .accessibilityLabel("Assistant: \(text)")
    }

    // MARK: - Copy Button

    @ViewBuilder
    private func copyButton(for text: String) -> some View {
        Button {
            copyToClipboard(text, feedback: $isCopied)
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func userActionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: ClaudeTheme.messageSize(9), weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .frame(width: 20, height: 20)
                .background(ClaudeTheme.surfaceSecondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .opacity(0.6)
    }

    // MARK: - Block Fade Transition

    /// Fade-in for tool cards (Edit, Bash, PlanCard, etc.) and text blocks as they
    /// are appended to a streaming assistant message. The parent MessageBubble
    /// transition only fires on first insert of the message — without this, blocks
    /// added later snap in without animation.
    private var blockFadeTransition: AnyTransition {
        let insertion: AnyTransition = .opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading))
        return .asymmetric(insertion: insertion, removal: .identity)
    }

    // MARK: - Transient Tool Helpers

    /// Read, Grep, Glob, Bash etc. are collapsed into a summary after streaming completes
    private func isTransientTool(_ toolCall: ToolCall) -> Bool {
        let cat = ToolCategory(toolName: toolCall.name)
        return cat == .readOnly || cat == .execution
    }

    /// Merges adjacent text blocks made contiguous by hidden transient tools.
    /// Displays continuous text Claude split across turns due to tool_use as a single bubble.
    ///
    /// Join rule: respects original trailing/leading whitespace; adds a single space only when
    /// neither side has whitespace. Forced paragraph breaks would split bullets mid-list,
    /// so they are avoided — even text following a complete sentence joins naturally with a single space.
    private static func mergeAdjacentTextBlocks(in blocks: [MessageBlock]) -> [MessageBlock] {
        var result: [MessageBlock] = []
        for block in blocks {
            if block.isText,
               let lastIdx = result.indices.last,
               result[lastIdx].isText {
                let prev = result[lastIdx].text ?? ""
                let curr = block.text ?? ""
                let needsSpace = !(prev.last?.isWhitespace ?? true) && !(curr.first?.isWhitespace ?? true)
                let joined = needsSpace ? prev + " " + curr : prev + curr
                // Preserve original block id to ensure ForEach diff stability
                result[lastIdx] = .text(joined, id: result[lastIdx].id)
            } else {
                result.append(block)
            }
        }
        return result
    }

    @State private var showTransientTools = false

    private func transientToolSummary(hidden: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTransientTools.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: ClaudeTheme.messageSize(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text(String(format: String(localized: "%lld tools executed", bundle: .module), hidden.count))
                        .font(.system(size: ClaudeTheme.messageSize(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Image(systemName: showTransientTools ? "chevron.up" : "chevron.down")
                        .font(.system(size: ClaudeTheme.messageSize(9)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showTransientTools {
                ForEach(hidden, id: \.id) { toolCall in
                    ToolResultView(toolCall: toolCall, isMessageStreaming: false)
                }
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if message.role == .user {
            return UnevenRoundedRectangle(
                topLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomTrailingRadius: 4,
                topTrailingRadius: ClaudeTheme.cornerRadiusLarge
            )
        } else {
            return UnevenRoundedRectangle(
                topLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: ClaudeTheme.cornerRadiusLarge,
                topTrailingRadius: ClaudeTheme.cornerRadiusLarge
            )
        }
    }

    private func submitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isEditing = false
        Task { await chatBridge.editAndResend(messageId: message.id, newContent: trimmed) }
    }

    // MARK: - Inline Attached Images (from content markers)

    /// Render `[Attached image: /path]` markers extracted from message content as
    /// the same thumbnail style used by `attachmentPreview`. Used only when the
    /// message has no structured `attachmentPaths` (typically: sessions reloaded
    /// from CLI jsonl history where the prompt blob is the source of truth).
    private func inlineAttachedImages(paths: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(paths, id: \.self) { path in
                Group {
                    if let nsImage = NSImage(contentsOfFile: path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                                    .strokeBorder(ClaudeTheme.border, lineWidth: BubbleStyle.borderWidth)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { previewImagePath = path }
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: ClaudeTheme.messageSize(14)))
                            .foregroundStyle(ClaudeTheme.accent)
                            .frame(width: 40, height: 40)
                            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                    }
                }
            }
        }
    }

    // MARK: - Attachment Preview

    private var attachmentPreview: some View {
        HStack(spacing: 6) {
            ForEach(message.attachmentPaths, id: \.path) { info in
                HStack(spacing: 4) {
                    if info.isImage, let nsImage = NSImage(contentsOfFile: info.path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                                    .strokeBorder(ClaudeTheme.border, lineWidth: BubbleStyle.borderWidth)
                            )
                    } else {
                        Image(systemName: info.isImage ? "photo" : "doc")
                            .font(.system(size: ClaudeTheme.messageSize(14)))
                            .foregroundStyle(ClaudeTheme.accent)
                    }
                    Text(info.name)
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                }
                .padding(6)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                .contentShape(Rectangle())
                .onTapGesture {
                    if info.isImage { previewImagePath = info.path }
                }
            }
        }
    }

    /// Converts bare URLs to clickable links (without full markdown rendering)
    private func linkifiedAttributedString(_ text: String) -> AttributedString {
        let autoLinked = autoLinkURLs(text)
        return (try? AttributedString(
            markdown: autoLinked,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Renders `[Image\d+]` tokens with accent-tinted chip styling. The same tokens
    /// are inserted into the input bar by `WindowState.insertImageToken` and drawn
    /// with a rounded background there via `ChipLayoutManager`; this mirrors that
    /// treatment in the sent user bubble.
    ///
    /// Each chip also gets a `rxcode-image://<index>` link attribute; an
    /// `environment(\.openURL, ...)` handler on the Text intercepts the tap and
    /// opens the corresponding image in `MessageImagePreviewSheet`. The index
    /// matches `WindowState.imageIndex(for:)` — 1-based, image-only.
    private func chipifiedAttributedString(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        Self.imageChipRegex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let m = match,
                  let range = Range(m.range, in: attr),
                  m.numberOfRanges >= 2,
                  let indexRange = Range(m.range(at: 1), in: text),
                  let index = Int(text[indexRange]) else { return }
            attr[range].backgroundColor = ClaudeTheme.accent.opacity(0.22)
            attr[range].foregroundColor = ClaudeTheme.accent
            attr[range].font = .system(size: ClaudeTheme.messageSize(13), weight: .medium)
            attr[range].link = URL(string: "rxcode-image://\(index)")
            attr[range].underlineStyle = nil
        }
        return attr
    }

    /// Resolve `[ImageN]` chip index (1-based) to a concrete image file path.
    /// Prefers structured `attachmentPaths` (set on freshly-sent messages); falls
    /// back to `[Attached image: /path]` markers parsed from content (the only
    /// source of truth for sessions reloaded from CLI history).
    private func imagePath(forChipIndex index: Int) -> String? {
        let i = index - 1
        let structured = message.attachmentPaths.filter { $0.isImage }.map(\.path)
        if i >= 0, i < structured.count { return structured[i] }
        let extracted = ChatSession.extractDisplayedContent(from: message.content).imagePaths
        if i >= 0, i < extracted.count { return extracted[i] }
        return nil
    }

    private static let imageChipRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\[Image(\d+)\]"#)
    }()
}

// MARK: - Image Preview Sheet

/// Sheet identifier wrapper: the path doubles as the identity so SwiftUI's
/// `sheet(item:)` re-presents whenever the user taps a different thumbnail.
private struct ImagePreviewItem: Identifiable, Equatable {
    let path: String
    var id: String { path }
}

private struct MessageImagePreviewSheet: View {
    let path: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 48))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Text("Image not available", bundle: .module)
                            .font(.system(size: ClaudeTheme.messageSize(13)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(16)
            .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", bundle: .module), action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 720, minHeight: 360, idealHeight: 540)
        .background(ClaudeTheme.surfacePrimary)
    }
}
