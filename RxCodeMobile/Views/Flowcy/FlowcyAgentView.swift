import RxCodeCore
import RxCodeChatKit
import SwiftUI

struct FlowcyAgentView: View {
    @Environment(FlowcyAgentState.self) private var agent
    @Environment(FlowcyToolsState.self) private var tools
    @Environment(MobileCloudState.self) private var cloud
    @State private var prompt = ""
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
            VStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Message Flowcy…", text: $prompt, axis: .vertical)
                        .lineLimit(1...6).textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 10)
                        .accessibilityIdentifier("flowcy-agent-composer")
                    Group {
                        if agent.isStreaming {
                            Button("Cancel", systemImage: "stop.circle.fill") { agent.cancel(); MobileHaptics.buttonTap() }
                        } else {
                            Button("Send", systemImage: "arrow.up.circle.fill") {
                                let text = prompt; prompt = ""
                                MobileHaptics.buttonTap()
                                agent.send(text, tools: tools, cloud: cloud)
                            }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .padding(8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .alert("Could Not Complete Chat", isPresented: Binding(get: { agent.error != nil }, set: { if !$0 { agent.error = nil } })) {
            Button("Retry") { agent.retry(tools: tools, cloud: cloud) }.disabled(agent.isStreaming)
            Button("OK", role: .cancel) { agent.error = nil }
        } message: { Text(agent.error ?? "") }
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
                        .frame(minHeight: pinnedUserMessageID != nil && pinnedUserMessageID == latestUserMessageID ? max(0, geometry.size.height - 32) : 0, alignment: .top)
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
        } else if !message.text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if message.role == "tool" {
                    Text("Tool Result")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                MarkdownContentView(text: message.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func argumentsMarkdown(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return "```json\n" + String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self) + "\n```"
    }
}
