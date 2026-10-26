import RxCodeCore
import RxCodeChatKit
import SwiftUI

struct FlowcyAgentView: View {
    @Environment(FlowcyAgentState.self) private var agent
    @Environment(FlowcyToolsState.self) private var tools
    @Environment(MobileCloudState.self) private var cloud
    @State private var prompt = ""
    @State private var voiceSession = MobileVoiceInputSession()
    @FocusState private var composerFocused: Bool
    @State private var confirmingNewChat = false
    @State private var pinnedUserMessageID: UUID?

    private var latestUserMessageID: UUID? {
        agent.messages.last(where: { $0.role == "user" })?.id
    }

    var body: some View {
        @Bindable var agent = agent
        Group {
            if agent.messages.isEmpty {
                ContentUnavailableView("Flowcy Agent", systemImage: "sparkles", description: Text("Ask about your projects, issues, and builds. Flowcy uses your signed-in account to access tools."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
        }
        .onChange(of: latestUserMessageID) { _, id in
            pinnedUserMessageID = id
        }
        .navigationTitle("Agent")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("New Chat", systemImage: "square.and.pencil") { confirmingNewChat = true }
            }
        }
        .confirmationDialog("Start a new chat?", isPresented: $confirmingNewChat, titleVisibility: .visible) {
            Button("New Chat") { agent.newChat() }
        }
        .safeAreaBar(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 8) {
                if voiceSession.isPresented {
                    MobileVoiceCancelButton { prompt = voiceSession.discard() }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                composer
                    .frame(maxWidth: .infinity)
                if agent.isStreaming {
                    MobileComposerSideButton(title: "Cancel", systemImage: "stop.fill", tint: .red) {
                        agent.cancel()
                        MobileHaptics.buttonTap()
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: agent.isStreaming)
            .animation(.snappy(duration: 0.2), value: prompt.isEmpty)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: voiceSession.mode)
            .mobileVoiceInput(session: voiceSession, text: $prompt)
            .onChange(of: voiceSession.mode) { _, mode in
                if mode != .idle { composerFocused = false }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .alert("Could Not Complete Chat", isPresented: Binding(get: { agent.error != nil }, set: { if !$0 { agent.error = nil } })) {
            Button("OK", role: .cancel) { agent.error = nil }
        } message: { Text(agent.error ?? "") }
        .overlay(alignment: .top) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if agent.canRetry || !agent.canSubmit(at: context.date) {
                    VStack(spacing: 8) {
                        Text("Flowcy is rate limited").font(.headline)
                        if let date = agent.retryAt, context.date < date {
                            Text("Retry available at \(date.formatted(date: .omitted, time: .standard))").font(.caption)
                        } else if agent.retryAt == nil {
                            Text("No retry time was provided. Wait before retrying.").font(.caption)
                        }
                        if agent.canRetry {
                            Button("Retry Response") {
                                MobileHaptics.buttonTap()
                                agent.retry(tools: tools, cloud: cloud)
                            }
                            .disabled(agent.isStreaming || !agent.canSubmit(at: context.date))
                            .accessibilityIdentifier("flowcy-agent-retry")
                        }
                    }
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
        }
        .sheet(item: $agent.pendingTool, onDismiss: { agent.approve(false) }) { pending in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Allow \(pending.tool.name)?").font(.title2.bold())
                        MarkdownContentView(text: pending.tool.description ?? "This tool can change your workspace.")
                        MarkdownContentView(text: argumentsMarkdown(pending.arguments))
                    }.padding()
                }
                .navigationTitle("Confirm Tool Action")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Deny") { agent.approve(false) } }
                    ToolbarItem(placement: .confirmationAction) { Button("Allow") { agent.approve(true) } }
                }
            }.mobileSheetPresentation()
        }
    }

    /// iMessage-style capsule shared with connected chat; voice recording and review replace the text field.
    private var composer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let canSubmit = !agent.isStreaming && agent.canSubmit(at: context.date)
            Group {
                switch voiceSession.mode {
                case .idle:
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Message Flowcy…", text: $prompt, axis: .vertical)
                            .lineLimit(1...6).textFieldStyle(.plain)
                            .padding(.vertical, 7)
                            .focused($composerFocused)
                            .accessibilityIdentifier("flowcy-agent-composer")
                        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MobileVoiceMicButton(text: $prompt, session: voiceSession)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            MobileComposerButton("Send", systemImage: "arrow.up", style: .accent) {
                                MobileHaptics.buttonTap()
                                sendPrompt()
                            }
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("flowcy-agent-send")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .transition(.blurReplace)
                case .recording:
                    MobileVoiceRecordingContent(session: voiceSession)
                        .transition(.blurReplace)
                case .review:
                    MobileVoiceReviewContent(session: voiceSession, canSend: canSubmit) {
                        prompt = voiceSession.draft
                        voiceSession.endReview()
                        sendPrompt()
                    } onEdit: {
                        prompt = voiceSession.draft
                        voiceSession.endReview()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            composerFocused = true
                        }
                    }
                    .transition(.blurReplace)
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !agent.isStreaming, agent.canSubmit() else { return }
        prompt = ""
        agent.send(text, tools: tools, cloud: cloud)
    }

    private var transcript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    let turnStart = agent.messages.lastIndex(where: { $0.role == "user" }) ?? agent.messages.startIndex
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(agent.messages[..<turnStart]) { message in
                            messageRow(message)
                        }
                        // Reserve the remaining viewport for this turn, as the
                        // existing chat does with its dynamic tail spacer. The
                        // reply grows into this space without moving the prompt.
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(agent.messages[turnStart...]) { message in
                                messageRow(message)
                            }
                            if agent.isStreaming && agent.pendingTool == nil {
                                MobileStreamingIndicator()
                                    .fixedSize(horizontal: true, vertical: true)
                                    .padding(.horizontal, 14)
                                    .background(ClaudeTheme.surfacePrimary, in: Capsule())
                                    .accessibilityIdentifier("flowcy-agent-streaming-indicator")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Reserved for restored history too, so reopening a chat keeps
                        // the same bottom spacing as when the turn was live.
                        .frame(minHeight: latestUserMessageID != nil ? max(0, geometry.size.height - 32) : 0, alignment: .top)
                        .id("latest-turn")
                    }
                    .padding(16)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollDismissesKeyboard(.interactively)
                .task(id: pinnedUserMessageID) {
                    guard pinnedUserMessageID != nil else { return }
                    // Let the new turn and its reserved space enter layout
                    // before requesting a top anchor for a short message.
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("latest-turn", anchor: .top)
                    }
                }
                .accessibilityIdentifier("flowcy-agent-transcript")
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: FlowcyChatMessage) -> some View {
        if message.role == "user" {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 40)
                MarkdownContentView(text: message.text, style: .rxCodeChatUser, expandsHorizontally: false)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(ClaudeTheme.userBubble, in: UnevenRoundedRectangle(
                        topLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                        bottomLeadingRadius: ClaudeTheme.cornerRadiusLarge,
                        bottomTrailingRadius: 4,
                        topTrailingRadius: ClaudeTheme.cornerRadiusLarge
                    ))
                    .frame(maxWidth: 500, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("flowcy-agent-user-message")
        } else if message.role != "tool", !message.text.isEmpty || !(message.toolCalls ?? []).isEmpty {
            // Tool results stay out of the transcript; calls render as a compact timeline.
            VStack(alignment: .leading, spacing: 10) {
                if !message.text.isEmpty {
                    MarkdownContentView(text: message.text)
                        .textSelection(.enabled)
                }
                if let calls = message.toolCalls, !calls.isEmpty {
                    ToolActivityGroupView(tools: calls, isStreaming: agent.isStreaming && message.id == agent.messages.last?.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func argumentsMarkdown(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return "```json\n" + String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self) + "\n```"
    }
}
