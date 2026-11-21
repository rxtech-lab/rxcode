import AppKit
import RxAgentVoice
import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Pet Companion Window & Transcript View

struct PetCompanionView: View {
    @Bindable var controller: PetController
    @Environment(WorkspaceManager.self) private var workspaceManager
    @State private var composerText: String = ""
    @State private var chatBridge = ChatBridge()
    @State private var isAtBottom = true
    @State private var transcriptStartedAt = Date()
    @FocusState private var isComposerFocused: Bool
    @State private var tapDebouncer = PetTapDebouncer()

    private var appState: AppState {
        controller.appState ?? workspaceManager.frontmostAppState
    }

    private enum PresentedModal: Identifiable {
        case destination(PetSheetDestination)
        case confirmation(AgentConfirmation)

        var id: String {
            switch self {
            case .destination(let dest): "dest-\(dest.id)"
            case .confirmation(let item): "confirm-\(item.id.uuidString)"
            }
        }
    }

    private var activeModal: PresentedModal? {
        if !controller.configuration.isEnabled, let confirm = appState.agentPrompts.confirmations.first(where: {
            $0.sessionKey.hasPrefix("pet-") && !$0.isMinimized
        }) {
            return .confirmation(confirm)
        }
        if let sheet = controller.activeSheet {
            return .destination(sheet)
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                companionHeader
                Divider()
                transcriptBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomTrailing) {
                        if controller.isSendingText {
                            HStack {
                                PetLoadingSpinner()
                                Text(controller.activeToolDescription ?? "Agent is responding…")
                                    .font(.caption)
                            }
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding()
                        }
                    }
                composerFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ClaudeTheme.background)
            .navigationTitle("\(controller.character.displayName) Companion")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        if let report = controller.latestDailyReport {
                            _ = report
                            controller.activeSheet = .dailyReport
                        } else {
                            Task { await controller.triggerDailyReport(speakAloud: true, openSheet: true) }
                        }
                    } label: {
                        Label("Daily Report", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("View or generate today's workspace daily report")

                    Button {
                        controller.openSettingsWindow()
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .help("Configure general agent, voice, music, and desktop pet")
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 700, maxWidth: .infinity,
               minHeight: 560, idealHeight: 660, maxHeight: .infinity)
        .task(id: controller.displayedHistoryScope) { await controller.loadDisplayedHistory() }
        .environment(chatBridge)
        .onChange(of: transcriptMessages, initial: true) { _, messages in
            chatBridge.messages = messages
            chatBridge.isStreaming = isTranscriptStreaming
        }
        .overlay {
            if let overlayText = controller.actionStatusOverlayMessage {
                PetActionStatusOverlay(message: overlayText)
            }
        }
        .sheet(item: Binding(
            get: { activeModal },
            set: { nextValue in
                guard nextValue == nil, let current = activeModal else { return }
                switch current {
                case .destination:
                    controller.activeSheet = nil
                case .confirmation(let item):
                    appState.setAgentConfirmationMinimized(id: item.id, minimized: true)
                }
            }
        )) { modal in
            switch modal {
            case .destination(.dailyReport):
                PetDailyReportSheet(controller: controller)
                    .environment(appState)
            case .confirmation(let confirmation):
                PetAgentConfirmationSheet(confirmation: confirmation)
                    .environment(appState)
            }
        }
        .alert(
            "Voice Companion Notice",
            isPresented: Binding(
                get: { controller.alertErrorMessage != nil },
                set: { if !$0 { controller.alertErrorMessage = nil } }
            )
        ) {
            Button("Open Settings") {
                controller.alertErrorMessage = nil
                controller.openSettingsWindow()
            }
            Button("OK", role: .cancel) {
                controller.alertErrorMessage = nil
            }
        } message: {
            Text(controller.alertErrorMessage ?? "")
        }
        .alert("Screen Recording Access", isPresented: Binding(
            get: { controller.screenCapture.permissionIssueMessage != nil },
            set: { if !$0 { controller.screenCapture.permissionIssueMessage = nil } }
        )) {
            Button("Open System Settings") {
                controller.screenCapture.permissionIssueMessage = nil
                controller.screenCapture.openPermissionSettings()
            }
            Button("Cancel", role: .cancel) { controller.screenCapture.permissionIssueMessage = nil }
        } message: {
            Text(controller.screenCapture.permissionIssueMessage ?? "")
        }
    }

    // MARK: - Header

    private var companionHeader: some View {
        HStack(spacing: 12) {
            PetSpriteView(
                character: controller.character,
                state: controller.petState,
                inputLevel: controller.inputLevel,
                outputLevel: controller.outputLevel,
                speechPlayback: controller.speechPlayback,
                size: 44,
                isVoiceActive: controller.isVoiceActive
            )
            .onTapGesture { controller.pat() }
            .help("Click to pat \(controller.character.displayName)")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(controller.character.displayName)
                        .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)

                    statusBadge

                }

                Text(activeModeSubtitle)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)

                if let tool = controller.activeToolDescription {
                    HStack(spacing: 6) {
                        PetLoadingSpinner()
                        Text(tool)
                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.accentText)
                            .lineLimit(1)
                    }
                } else if !controller.livePartialUserText.isEmpty {
                    Text("“\(controller.livePartialUserText)”")
                        .font(.system(size: ClaudeTheme.size(11)).italic())
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Toggle("Show on Desktop", isOn: Binding(
                    get: { controller.configuration.isEnabled },
                    set: { controller.setPetEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: ClaudeTheme.size(11)))

                if controller.isVoiceActive {
                    HStack(spacing: 8) {
                        levelMeter(label: controller.isMuted ? "Microphone muted" : "Microphone level",
                                   systemImage: controller.isMuted ? "mic.slash.fill" : "mic.fill",
                                   value: controller.inputLevel, tint: .cyan, isEnabled: !controller.isMuted)
                        levelMeter(label: controller.isMuted ? "Speaker muted" : "\(controller.character.displayName) voice level",
                                   systemImage: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   value: controller.outputLevel, tint: .blue, isEnabled: !controller.isMuted)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(ClaudeTheme.surfacePrimary)
    }

    private var statusBadge: some View {
        Text(controller.petState.status.label)
            .font(.system(size: ClaudeTheme.size(10), weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(statusTint.opacity(0.16), in: Capsule())
            .foregroundStyle(statusTint)
    }

    private var activeModeSubtitle: String {
        if !controller.isVoiceActive {
            let agent = controller.configuration.customAgent ?? appState.defaultTaskAgent()
            return "General Agent: \(appState.taskAgentLabel(agent))"
        }
        switch controller.configuration.voiceMode {
        case .codexRealtime:
            let transport = controller.configuration.codexTransport == .webRTC ? "WebRTC" : "WebSocket"
            return "Codex Realtime (\(transport)) · Voice: \(controller.configuration.codexVoice.capitalized)"
        case .localPipeline:
            let agent = controller.configuration.customAgent ?? appState.defaultTaskAgent()
            let agentLabel = appState.taskAgentLabel(agent)
            let voiceLabel: String
            if let selection = controller.configuration.flowcyVoice {
                voiceLabel = "Flowcy · \(selection.voice.name)"
            } else if controller.configuration.localTTSModelID == PetConfiguration.systemTTSModelID {
                voiceLabel = "System Voice"
            } else {
                voiceLabel = appState.localModels.installed.first {
                    $0.id == controller.configuration.localTTSModelID
                }?.displayName ?? "Local TTS"
            }
            return "Agent: \(agentLabel) · Voice: \(voiceLabel)"
        }
    }

    private func levelMeter(label: String, systemImage: String, value: Float, tint: Color, isEnabled: Bool = true) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(9), weight: .semibold))
                .foregroundStyle(isEnabled ? tint : ClaudeTheme.textTertiary)
                .frame(width: 12)
            PetVoiceWaveform(level: value, tint: tint, isEnabled: isEnabled, barWidth: 2, barSpacing: 1.5)
                .frame(width: 46, height: 14)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.7), in: Capsule())
        .help(label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var statusTint: Color {
        switch controller.petState.status {
        case .listening, .userSpeaking: .cyan
        case .thinking, .working: .orange
        case .speaking: .blue
        case .celebrating: .green
        case .failed: .red
        case .idle, .sleeping: ClaudeTheme.textSecondary
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptBody: some View {
        if transcriptMessages.isEmpty {
            ContentUnavailableView {
                Label("Talk to \(controller.character.displayName)", systemImage: "waveform.and.mic")
            } description: {
                Text("Type a message below to chat with your general agent, or start Voice Mode to speak. Choose your model in Pet Settings → General Agent.")
            } actions: {
                HStack(spacing: 10) {
                    Button {
                        Task { await controller.startVoice() }
                    } label: {
                        Label(
                            controller.isVoiceActive ? "Listening…" : "Start Voice Mode",
                            systemImage: "phone.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isVoiceActive)

                    Button {
                        Task { await controller.triggerDailyReport(speakAloud: true, openSheet: true) }
                    } label: {
                        Label("Daily Report", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChatTranscriptList(
                items: ChatTranscriptListItem.items(for: transcriptMessages),
                isStreaming: isTranscriptStreaming,
                isAtBottom: $isAtBottom,
                accessibilityIdentifier: "pet-chat-transcript"
            ) { _ in
                EmptyView()
            }
        }
    }

    private var isTranscriptStreaming: Bool {
        if controller.isVoiceActive {
            return controller.voiceSession?.transcript.last.map { !$0.isFinal } ?? false
        }
        return controller.isSendingText
    }

    // Keep row and text-block identities stable as each reply streams in.
    private var transcriptMessages: [ChatMessage] {
        let archive = controller.displayedHistory
        let saved = archive?.scope == controller.displayedHistoryScope ? archive?.turns ?? [] : []
        let live: [ChatMessage]
        if controller.isVoiceActive, controller.voiceHistoryBinding?.scope == controller.displayedHistoryScope {
            live = (controller.voiceSession?.transcript ?? []).map { entry in
                transcriptMessage(id: entry.id, isUser: entry.isUser, text: entry.text, isStreaming: !entry.isFinal)
            }
        } else if controller.isSendingText, controller.textHistoryID == archive?.id,
                  archive?.scope == controller.displayedHistoryScope {
            live = controller.chatTranscript.map { entry in
                transcriptMessage(id: entry.id, isUser: entry.isUser, text: entry.text, isStreaming: !entry.isUser)
            }
        } else {
            live = []
        }
        let liveIDs = Set(live.map(\.id))
        return saved.filter { !liveIDs.contains($0.id) }.map {
            transcriptMessage(id: $0.id, isUser: $0.isUser, text: $0.text, isStreaming: false)
        } + live
    }

    private func transcriptMessage(id: UUID, isUser: Bool, text: String, isStreaming: Bool) -> ChatMessage {
        ChatMessage(
            id: id,
            role: isUser ? .user : .assistant,
            blocks: text.isEmpty ? [] : [.text(text, id: "\(id.uuidString)-text")],
            isStreaming: isStreaming,
            isResponseComplete: !isUser && !isStreaming,
            timestamp: transcriptStartedAt
        )
    }

    // MARK: - Composer & Voice Controls

    private var composerFooter: some View {
        VStack(spacing: 10) {
            if let minimized = appState.agentPrompts.confirmations.first(where: {
                $0.sessionKey.hasPrefix("pet-") && $0.isMinimized
            }) {
                HStack {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(ClaudeTheme.statusWarning)
                    Text(minimized.request.title)
                        .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button("Review") {
                        appState.setAgentConfirmationMinimized(id: minimized.id, minimized: false)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Message \(controller.character.displayName)…", text: $composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: ClaudeTheme.size(13)))
                    .lineLimit(2...6)
                    .focused($isComposerFocused)
                    .onSubmit { submitTypedMessage() }
                    .accessibilityIdentifier("pet-chat-composer")

                HStack(spacing: 10) {
                    Button {
                        tapDebouncer.run("voice") { controller.toggleVoice() }
                    } label: {
                        Label(
                            controller.isVoiceActive ? "Stop Voice" : "Start Voice",
                            systemImage: controller.isVoiceActive ? "phone.down.fill" : "phone.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(controller.isVoiceActive ? .red : ClaudeTheme.accent)

                    muteButton

                    if controller.isVoiceActive, let session = controller.voiceSession {
                        if session.activity == .agentSpeaking || controller.isStandaloneSpeaking {
                            Button {
                                controller.interruptSpeaking()
                            } label: {
                                Label("Interrupt", systemImage: "hand.raised.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if controller.isStandaloneSpeaking {
                        Button {
                            controller.interruptSpeaking()
                        } label: {
                            Label("Stop Speaking", systemImage: "speaker.slash.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer(minLength: 0)

                    Button {
                        submitTypedMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.borderless)
                    .disabled(controller.isSendingText || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(controller.isVoiceActive ? "Send message to voice session" : "Send message to general agent")
                    .accessibilityLabel("Send message")
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isComposerFocused ? ClaudeTheme.accent.opacity(0.6) : ClaudeTheme.border)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }

    private var muteButton: some View {
        let muted = controller.isMuted
        let live = controller.isVoiceActive && !muted
        return Button {
            tapDebouncer.run("mute") { controller.toggleMute() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(muted ? Color.orange : (live ? Color.cyan : ClaudeTheme.textSecondary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14)
                if live {
                    PetVoiceWaveform(level: controller.inputLevel, tint: .cyan, barWidth: 2, barSpacing: 1.5)
                        .frame(width: 40, height: 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                } else if muted {
                    Text("Muted")
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                        .foregroundStyle(ClaudeTheme.statusWarning)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule().fill(muted ? Color.orange.opacity(0.14)
                               : (live ? Color.cyan.opacity(0.12) : ClaudeTheme.surfaceSecondary))
            )
            .overlay(Capsule().strokeBorder(muted ? Color.orange.opacity(0.35)
                                            : (live ? Color.cyan.opacity(0.3) : ClaudeTheme.border)))
            .contentShape(Capsule())
            .animation(.snappy(duration: 0.22), value: muted)
            .animation(.snappy(duration: 0.22), value: live)
        }
        .buttonStyle(.plain)
        .help(muted ? "Unmute Microphone and Speaker" : "Mute Microphone and Speaker")
        .accessibilityLabel(muted ? "Unmute Microphone and Speaker" : "Mute Microphone and Speaker")
    }

    private func submitTypedMessage() {
        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !controller.isSendingText else { return }
        composerText = ""
        Task {
            await controller.sendTextMessage(message)
        }
    }
}

// MARK: - Shared Status Overlay

struct PetActionStatusOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text(message)
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Pet Agent Prompt Views

struct PetAgentConfirmationSheet: View {
    @Environment(AppState.self) private var appState
    let confirmation: AgentConfirmation
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(confirmation.request.title)
                        .font(.headline)
                    if let message = confirmation.request.message, !message.isEmpty {
                        MarkdownContentView(text: message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, 320))

            Divider()

            HStack {
                Button("Close", systemImage: "xmark") {
                    appState.setAgentConfirmationMinimized(id: confirmation.id, minimized: true)
                }
                Spacer(minLength: 12)
                Button(confirmation.request.cancelLabel) {
                    appState.resolveAgentConfirmation(id: confirmation.id, confirmed: false)
                }
                .keyboardShortcut(.cancelAction)
                Button(
                    confirmation.request.confirmLabel,
                    role: confirmation.request.isDestructive ? .destructive : nil
                ) {
                    appState.resolveAgentConfirmation(id: confirmation.id, confirmed: true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 300, idealWidth: 400, maxWidth: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
