import SwiftUI
import TipKit
import UniformTypeIdentifiers
import RxCodeCore

#if os(macOS)

public extension EnvironmentValues {
    @Entry var offersCodingPlan = false
}

@MainActor
final class ChatInputEditor {
    weak var textView: NSTextView?
}

struct InputBarView<Accessory: View, TopAccessory: View>: View {
    @Environment(\.offersCodingPlan) private var offersCodingPlan
    @Environment(ChatBridge.self) private var environmentChatBridge: ChatBridge?
    @Environment(WindowState.self) private var environmentWindowState: WindowState?
    @State var isInputFocused: Bool = false
    @State var inputFocusTrigger: UUID? = nil
    @State var inputEditor = ChatInputEditor()

    private let accessory: Accessory
    private let topAccessory: TopAccessory
    private let injectedChatBridge: ChatBridge?
    private let injectedWindowState: WindowState?

    @State private var showFilePicker = false
    @State var showSlashPopup = false
    @State var slashSelectedIndex = 0
    @State private var slashDetailCommand: SlashCommand?
    @State private var imagePreviewAttachment: Attachment?
    @State private var isDragOver = false
    @State var showAtPopup = false
    @State var atSelectedIndex = 0
    @State private var shortcuts: [ChatShortcut] = []
    @State var historyIndex: Int = -1
    @State var textFieldLayoutID = 0
    @State var measuredInputHeight: CGFloat = 20
    @State var inputHasMarkedText = false
    /// Queued messages whose "steer now" was declined by the running turn.
    /// Non-private because the queue UI lives in an InputBarView extension in
    /// another file; it renders these as an inline "still queued" note.
    @State var steerDeclinedIDs: Set<UUID> = []

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
            if let parent = implicitStudioParent {
                HStack {
                    StudioImplicitParentCard(path: parent) {
                        imagePreviewAttachment = Attachment(type: .image, name: URL(fileURLWithPath: parent).lastPathComponent, path: parent)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
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
            .sheet(item: $slashDetailCommand) { cmd in
                CommandDetailSheet(command: cmd)
                    .mobileSheetPresentation()
            }
            .sheet(item: $imagePreviewAttachment) { attachment in
                ImagePreviewSheet(attachment: attachment)
                    .mobileSheetPresentation()
            }
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
                            agent: chatBridge.agentProvider,
                            onSelect: { cmd in selectSlashCommand(cmd) },
                            selectedIndex: $slashSelectedIndex
                        )
                        .transition(.offset(y: 10).combined(with: .opacity))
                    }
                    if showAtPopup && atCombinedCount > 0 {
                        AtMentionPopup(
                            shortcuts: atShortcutMatches,
                            files: atFileFilteredEntries,
                            onSelectShortcut: { shortcut in selectShortcut(shortcut) },
                            onSelectFile: { relativePath in selectAtFile(relativePath) },
                            selectedIndex: $atSelectedIndex
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
            shortcuts = ChatShortcutRegistry.currentShortcuts
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatShortcutsDidChange)) { _ in
            shortcuts = ChatShortcutRegistry.currentShortcuts
        }
        .onChange(of: windowState.selectedProject?.path) { _, newPath in
            if let path = newPath {
                AtFileSearch.prefetch(projectPath: path)
            }
        }
        .frame(maxWidth: .infinity)
        .rxCodeAttachmentPreviews()
        .contentShape(Rectangle())
        .onTapGesture { inputFocusTrigger = UUID() }
    }

    // MARK: - Input Composer

    private var awaitingPlanDecision: Bool {
        chatBridge.hasPendingPlanDecision && chatBridge.interruptedSessionID == nil
    }

    @ViewBuilder
    private var inputComposer: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputTextField
            composerActionRow
        }
        .disabled(awaitingPlanDecision)
        .opacity(awaitingPlanDecision ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: awaitingPlanDecision)
    }

    private var composerActionRow: some View {
        HStack(spacing: 10) {
            attachButton

            if chatBridge.studioKind.isStudio {
                studioControls
                studioModeChip
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                StudioSetupButton(kind: chatBridge.studioKind)
            }

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
        .animation(.easeInOut(duration: 0.15), value: chatBridge.studioKind)
    }

    private var hasComposerContent: Bool {
        !windowState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || inputHasMarkedText
            || !windowState.attachments.isEmpty
    }

    @ViewBuilder
    private var sendOrStopControls: some View {
        HStack(spacing: 8) {
            if let id = chatBridge.interruptedSessionID {
                Button {
                    Task { await chatBridge.resumeInterruptedTurnHandler?(id) }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .controlSize(.small)
                .help("Resume the interrupted conversation")
                .accessibilityIdentifier("resume-interrupted-turn")
            }
            // While streaming, show the send button only when the user has typed
            // something to enqueue. When idle, always show send (disabled when empty).
            if (!chatBridge.isStreaming && chatBridge.interruptedSessionID == nil) || hasComposerContent {
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

            if offersCodingPlan {
                Button {
                    windowState.chatCreationIntent = ChatCreationIntent(.plan, sessionID: windowState.currentSessionId, goal: windowState.inputText)
                } label: {
                    Label("Plan Mode…", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("composer-plan-mode")
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
        .help("Add")
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

    /// The selected studio's quality and generation settings.
    @ViewBuilder
    private var studioControls: some View {
        switch chatBridge.studioKind {
        case .video:
            VideoQualityPicker()
            StudioModelConfigControl(kind: .video)
        case .image:
            ImageQualityPicker()
            StudioModelConfigControl(kind: .image)
        case .audio:
            AudioSettingsPicker()
            StudioModelConfigControl(kind: .audio)
        case .decision: DecisionSettingsPicker()
        case .chat: EmptyView()
        }
    }

    /// Shown while the selected model is a studio model. Not a toggle: the
    /// model itself decides it, so it is informational and switches with the
    /// picker. An attached image turns the image chip into Refine.
    private var studioModeChip: some View {
        let kind = chatBridge.studioKind
        let isRefining = kind == .image && windowState.attachments.contains { $0.type == .image }
        return HStack(spacing: 5) {
            Image(systemName: isRefining ? "wand.and.stars" : kind.systemImage)
                .font(.system(size: ClaudeTheme.size(10), weight: .semibold))

            Text(isRefining ? String(localized: "Refine", bundle: .module) : kind.title)
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(ClaudeTheme.accentText)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(ClaudeTheme.accentSubtle, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(ClaudeTheme.accent.opacity(0.35), lineWidth: 1)
        )
        .help(studioChipHelp(kind, isRefining: isRefining))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(kind == .video ? "video-mode-chip" : "studio-mode-chip")
    }

    private func studioChipHelp(_ kind: LocalStudioKind, isRefining: Bool) -> String {
        switch kind {
        case .video: String(localized: "This model generates a video from your message", bundle: .module)
        case .image: isRefining
            ? String(localized: "The attached image is refined with your message", bundle: .module)
            : String(localized: "This model generates an image from your message", bundle: .module)
        case .audio: String(localized: "This model speaks your message, or transcribes an attached audio file", bundle: .module)
        case .decision: String(localized: "This model judges your question against the options above", bundle: .module)
        case .chat: ""
        }
    }

    var composerPlaceholder: String {
        switch chatBridge.studioKind {
        case .video: String(localized: "Describe a video…", bundle: .module)
        case .image: String(localized: "Describe an image…", bundle: .module)
        case .audio: String(localized: "Type what to say, or attach audio to transcribe…", bundle: .module)
        case .decision: String(localized: "Ask a question to decide…", bundle: .module)
        case .chat: String(localized: "Type a message...", bundle: .module)
        }
    }

    // MARK: - Slash / At Queries

    private var slashQuery: String {
        let text = windowState.inputText
        guard !text.contains(" ") else { return "" }
        guard text.hasPrefix("/") else { return "" }
        return text
    }

    var slashFilteredCommands: [SlashCommand] {
        SlashCommandRegistry.filtered(by: slashQuery, agent: chatBridge.agentProvider)
    }

    var userMessageHistory: [String] {
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

    private var atShortcutMatches: [ChatShortcut] {
        let query = atFileQuery.lowercased()
        guard !query.isEmpty else { return Array(shortcuts.prefix(20)) }
        return shortcuts.filter {
            $0.name.lowercased().contains(query) || $0.message.lowercased().contains(query)
        }
    }

    /// Total rows in the unified `@` popup — shortcuts followed by files.
    var atCombinedCount: Int {
        atShortcutMatches.count + atFileFilteredEntries.count
    }

    func selectSlashCommand(_ cmd: SlashCommand) {
        withAnimation(.easeOut(duration: 0.15)) { showSlashPopup = false }
        if cmd.acceptsInput && !cmd.isInteractive {
            windowState.inputText = cmd.command + " "
        } else {
            windowState.inputText = ""
            chatBridge.markUserSendRequested()
            Task { await chatBridge.sendSlashCommand(cmd.command) }
        }
    }

    private func selectAtFile(_ relativePath: String) {
        withAnimation(.easeOut(duration: 0.15)) { showAtPopup = false }
        var text = windowState.inputText
        if let atRange = text.range(of: "@", options: .backwards) {
            text.replaceSubrange(atRange.lowerBound..., with: "@\(relativePath) ")
        }
        windowState.inputText = text
    }

    /// Dispatches a flat `@` popup index to the shortcut or file at that row.
    func selectAtMention(at index: Int) {
        let shortcutMatches = atShortcutMatches
        if index < shortcutMatches.count {
            selectShortcut(shortcutMatches[index])
            return
        }
        let fileIndex = index - shortcutMatches.count
        let entries = atFileFilteredEntries
        if fileIndex >= 0 && fileIndex < entries.count {
            selectAtFile(entries[fileIndex].relativePath)
        }
    }

    private func selectShortcut(_ shortcut: ChatShortcut) {
        withAnimation(.easeOut(duration: 0.15)) { showAtPopup = false }
        var text = windowState.inputText
        if let atRange = text.range(of: "@", options: .backwards) {
            text.replaceSubrange(atRange.lowerBound..., with: "")
        }
        if shortcut.isTerminalCommand {
            windowState.inputText = text
            guard !chatBridge.isStreaming else { return }
            Task { await chatBridge.runTerminalCommand(shortcut.message) }
        } else {
            // Insert the shortcut's message so the user can review/edit before sending.
            windowState.inputText = text + shortcut.message
        }
    }

    func hasActiveAtQuery(in text: String) -> Bool {
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

    /// The image studio continues from the thread's newest image unless an
    /// image is attached; shown so the parent of the next prompt is visible.
    private var implicitStudioParent: String? {
        guard chatBridge.studioKind == .image, !windowState.attachments.contains(where: { $0.type == .image }),
              let toolName = LocalStudioKind.image.toolName else { return nil }
        for message in chatBridge.messages.reversed() {
            for call in message.toolCalls.reversed() where call.name.lowercased() == toolName.lowercased() && !call.isError {
                // Same pick as the harness, even if the file is gone, so the
                // card never shows a parent the next prompt won't use.
                if let path = GenerationTake.decode(call.result)["savedPath"]?.stringValue, !path.isEmpty { return path }
            }
        }
        return nil
    }

    // MARK: - Send / Return

    private func sendMessage() {
        guard !awaitingPlanDecision else { return }
        guard !windowState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !windowState.attachments.isEmpty else { return }
        historyIndex = -1

        // A decision travels as its question plus the options above the composer.
        if chatBridge.studioKind == .decision {
            let request = DecisionRequest(question: windowState.inputText, options: windowState.decisionDraft.options)
            windowState.inputText = request.messageText
        }

        if chatBridge.isStreaming {
            // Sending mid-turn queues by default: the message goes out when the
            // current response finishes. The queued row is where the user
            // overrides that — steering it into the running turn, or
            // interrupting to send it straight away.
            withAnimation(.easeOut(duration: 0.2)) {
                chatBridge.enqueueMessage(text: windowState.inputText, attachments: windowState.attachments)
            }
            windowState.inputText = ""
            windowState.attachments = []
            resetIMEState()
            return
        }

        chatBridge.markUserSendRequested()
        Task { await chatBridge.send() }
        resetIMEState()
    }

    func handleReturnKey() {
        // IMETextView dispatches doCommand(insertNewline:) only after the IME has finalized any
        // composing text, so windowState.inputText is already up-to-date here.
        if showSlashPopup && !slashFilteredCommands.isEmpty {
            let commands = slashFilteredCommands
            if slashSelectedIndex < commands.count {
                selectSlashCommand(commands[slashSelectedIndex])
            }
            return
        }
        if showAtPopup && atCombinedCount > 0 {
            selectAtMention(at: atSelectedIndex)
            return
        }
        sendMessage()
    }

}
#endif
