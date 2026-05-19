import SwiftUI
#if os(macOS)
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

    private enum AssistantRenderBlock: Identifiable {
        case text(MessageBlock)
        case tool(ToolCall)
        case transientTools(id: String, tools: [ToolCall])

        var id: String {
            switch self {
            case .text(let block):
                return block.id
            case .tool(let toolCall):
                return toolCall.id
            case .transientTools(let id, _):
                return id
            }
        }
    }

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
                    let renderBlocks = assistantRenderBlocks()
                    // While the model is paused on an undecided ExitPlanMode in this
                    // same message, sibling tools without results are effectively
                    // suspended — not running. Drop the streaming flag for those so
                    // their spinner doesn't keep ticking until the user approves.
                    let siblingsArePaused = messageHasPendingExitPlanMode
                    let siblingStreaming = message.isStreaming && !siblingsArePaused

                    ForEach(renderBlocks) { block in
                        Group {
                            switch block {
                            case .text(let textBlock):
                                if let text = textBlock.text, !text.isEmpty {
                                    assistantTextBubble(text: text, blockId: textBlock.id)
                                }
                            case .tool(let toolCall):
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
                                    ToolResultView(toolCall: toolCall, isMessageStreaming: siblingStreaming)
                                }
                            case .transientTools(let id, let tools):
                                transientToolSummary(groupId: id, tools: tools)
                            }
                        }
                        .transition(blockFadeTransition)
                    }
                    .animation(.easeOut(duration: 0.28), value: renderBlocks.map(\.id))
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
            .fixedSize(horizontal: false, vertical: true)
            .bubbleStyle(.user)
            .frame(maxWidth: 500, alignment: .trailing)
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

    private func assistantTextBubble(text: String, blockId: String) -> some View {
        let isLastBlock = message.blocks.last?.isText == true
            && message.blocks.last?.text == text
        let showsCursor = message.isStreaming && isLastBlock

        return MarkdownContentView(
            text: text,
            showsTrailingCursor: showsCursor,
            isCursorVisible: cursorVisible
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ClaudeTheme.textPrimary)
        .padding(.vertical, 2)
        .task(id: showsCursor) {
            guard showsCursor else { return }
            cursorVisible = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                cursorVisible.toggle()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hoveredBlockId == blockId && !message.isStreaming {
                copyButton(for: text)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .onHover { hoveredBlockId = $0 ? blockId : nil }
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

    // MARK: - Plan Pause Helpers

    /// True when this assistant message contains an `ExitPlanMode` tool call that
    /// the user has not yet decided on. While true, the CLI is suspended on the
    /// PreToolUse hook — sibling tool calls in the same message will never get
    /// their `tool_result` delivered until the plan is approved/rejected, so the
    /// "running" spinner on those siblings would otherwise tick forever.
    private var messageHasPendingExitPlanMode: Bool {
        for block in message.blocks {
            guard let toolCall = block.toolCall,
                  PlanCardView.isExitPlanMode(toolCall) else { continue }
            if chatBridge.planDecisionSummaries[toolCall.id] != nil { continue }
            if PlanCardView.isPlanDecided(toolCall) { continue }
            return true
        }
        return false
    }

    // MARK: - Transient Tool Helpers

    /// Read, Grep, Glob, Bash etc. are collapsed into a summary after streaming completes
    private func isTransientTool(_ toolCall: ToolCall) -> Bool {
        let cat = ToolCategory(toolName: toolCall.name)
        return cat == .readOnly || cat == .execution
    }

    /// Builds the assistant render list in source order. Completed transient
    /// tools are folded into contiguous collapsed groups, while edit/write/plan
    /// cards remain inline between those groups.
    private func assistantRenderBlocks() -> [AssistantRenderBlock] {
        var result: [AssistantRenderBlock] = []
        var pendingTransientTools: [ToolCall] = []
        var pendingTransientGroupStartId: String?

        func appendText(_ block: MessageBlock) {
            guard let text = block.text, !text.isEmpty else { return }
            if let lastIndex = result.indices.last,
               case .text(let previousBlock) = result[lastIndex] {
                let previous = previousBlock.text ?? ""
                let needsSpace = !(previous.last?.isWhitespace ?? true) && !(text.first?.isWhitespace ?? true)
                let joined = needsSpace ? previous + " " + text : previous + text
                result[lastIndex] = .text(.text(joined, id: previousBlock.id))
            } else {
                result.append(.text(block))
            }
        }

        func flushTransientTools() {
            guard !pendingTransientTools.isEmpty else { return }
            let startId = pendingTransientGroupStartId ?? pendingTransientTools[0].id
            result.append(.transientTools(
                id: "transient-tools-\(startId)-\(pendingTransientTools.count)",
                tools: pendingTransientTools
            ))
            pendingTransientTools = []
            pendingTransientGroupStartId = nil
        }

        // When the model emits an ExitPlanMode tool call together with a trailing
        // narration text ("Plan written with 'hi'. Awaiting approval."), the API
        // stream orders them tool-then-text. Lift sibling text blocks ahead of the
        // plan chip so the user sees the description with the plan rather than
        // dangling after a chip that's already been decided.
        let orderedBlocks: [MessageBlock] = {
            guard PlanCardView.containsExitPlanMode(message) else { return message.blocks }
            let textBlocks = message.blocks.filter { $0.isText }
            let nonTextBlocks = message.blocks.filter { !$0.isText }
            return textBlocks + nonTextBlocks
        }()

        for block in orderedBlocks {
            if PlanCardView.shouldHideBlock(block, in: message, allMessages: chatBridge.messages) { continue }
            if block.isText {
                flushTransientTools()
                appendText(block)
                continue
            }
            guard let toolCall = block.toolCall else { continue }
            if PlanCardView.isSupersededExitPlanMode(
                toolCall: toolCall,
                in: message,
                allMessages: chatBridge.messages
            ) { continue }

            if message.isStreaming {
                flushTransientTools()
                result.append(.tool(toolCall))
                continue
            }

            if isTransientTool(toolCall) {
                guard toolCall.result != nil || toolCall.isError else { continue }
                if pendingTransientGroupStartId == nil {
                    pendingTransientGroupStartId = toolCall.id
                }
                pendingTransientTools.append(toolCall)
                continue
            }

            if toolCall.isKeepAlways || toolCall.result != nil || toolCall.isError {
                flushTransientTools()
                result.append(.tool(toolCall))
            }
        }

        flushTransientTools()
        return result
    }

    @State private var expandedTransientGroupIds: Set<String> = []

    private func transientToolSummary(groupId: String, tools: [ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedTransientGroupIds.contains(groupId) {
                        expandedTransientGroupIds.remove(groupId)
                    } else {
                        expandedTransientGroupIds.insert(groupId)
                    }
                }
            } label: {
                let isExpanded = expandedTransientGroupIds.contains(groupId)
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: ClaudeTheme.messageSize(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Text(String(format: String(localized: "%lld tools executed", bundle: .module), tools.count))
                        .font(.system(size: ClaudeTheme.messageSize(12)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: ClaudeTheme.messageSize(9)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedTransientGroupIds.contains(groupId) {
                ForEach(tools, id: \.id) { toolCall in
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
#endif
