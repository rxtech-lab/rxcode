import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Compact chat shown above an expanded inspector: the latest assistant reply,
/// pending approvals, and a one-line composer. It minimizes to a single button.
struct FloatingChatBubble: View {
    private static let margin: CGFloat = 16

    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var draft = ""
    @State private var position = CGSize.zero
    @State private var bubbleSize = CGSize.zero
    @GestureState private var translation = CGSize.zero
    @FocusState private var focused: Bool

    private var isStreaming: Bool { appState.isStreaming(in: windowState) }

    private var lastReply: ChatMessage? {
        appState.messages(in: windowState).last { message in
            message.role == .assistant && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var title: String {
        if let id = windowState.currentSessionId,
           let title = appState.allSessionSummaries.first(where: { $0.id == id })?.title, !title.isEmpty {
            return title
        }
        return String(localized: "New chat")
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if windowState.floatingChatMinimized {
                    minimizedButton(in: geometry.size)
                } else {
                    expandedCard(in: geometry.size)
                }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { bubbleSize = $0 }
            .offset(offset(after: translation, in: geometry.size))
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: windowState.floatingChatMinimized)
        }
    }

    private func minimizedButton(in availableSize: CGSize) -> some View {
        Button {
            windowState.floatingChatMinimized = false
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textOnAccent)
                    .frame(width: 48, height: 48)
                if isStreaming || !windowState.pendingPermissions.isEmpty {
                    Circle()
                        .fill(windowState.pendingPermissions.isEmpty ? Color.green : Color.orange)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                }
            }
            .contentShape(Circle())
            .glassEffect(.regular.tint(ClaudeTheme.accent).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .highPriorityGesture(dragGesture(in: availableSize))
        .pointerStyle(dragPointer)
        .help("Show chat or drag to move")
        .accessibilityLabel("Show chat")
        .accessibilityIdentifier("floating-chat-restore")
        .transition(.scale.combined(with: .opacity))
    }

    private func expandedCard(in availableSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(in: availableSize)
            Divider()
            replyContent
            VStack(spacing: 8) {
                AgentConfirmationBanner()
                PermissionQueueBanner()
            }
            .padding(.horizontal, 10)
            composer
        }
        .frame(width: min(400, max(0, availableSize.width - Self.margin * 2)))
        .contentShape(.rect(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floating-chat")
    }

    private func header(in availableSize: CGSize) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(ClaudeTheme.accent)
                Text(title)
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .frame(minHeight: 26)
            .padding(.leading, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .gesture(dragGesture(in: availableSize))
            .pointerStyle(dragPointer)
            .help("Drag to move chat")
            Button {
                windowState.inspectorExpanded = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .help("Exit full width")
            .accessibilityLabel("Exit full width")
            Button {
                windowState.floatingChatMinimized = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.size(12), weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(ClaudeTheme.surfaceElevated, in: .circle)
                    .overlay { Circle().strokeBorder(ClaudeTheme.border) }
                    .contentShape(Circle())
            }
            .help("Close floating chat")
            .accessibilityLabel("Close floating chat")
            .accessibilityIdentifier("floating-chat-minimize")
        }
        .foregroundStyle(ClaudeTheme.textPrimary)
        .buttonStyle(.plain)
        .padding(.trailing, 12)
    }

    private var dragPointer: PointerStyle { translation == .zero ? .grabIdle : .grabActive }

    private func dragGesture(in availableSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($translation) { value, translation, transaction in
                translation = value.translation
                transaction.animation = nil
            }
            .onEnded { value in
                position = offset(after: value.translation, in: availableSize)
            }
    }

    private func offset(after translation: CGSize, in availableSize: CGSize) -> CGSize {
        let origin = clamped(position, in: availableSize)
        return clamped(
            CGSize(width: origin.width + translation.width, height: origin.height + translation.height),
            in: availableSize
        )
    }

    private func clamped(_ offset: CGSize, in availableSize: CGSize) -> CGSize {
        CGSize(
            width: min(0, max(offset.width, bubbleSize.width + Self.margin * 2 - availableSize.width)),
            height: min(0, max(offset.height, bubbleSize.height + Self.margin * 2 - availableSize.height))
        )
    }

    @ViewBuilder
    private var replyContent: some View {
        if let reply = lastReply {
            ScrollViewReader { reader in
                ScrollView {
                    MarkdownContentView(text: reply.content, showsTrailingCursor: reply.isStreaming)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("reply")
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: reply.content) { reader.scrollTo("reply", anchor: .bottom) }
            }
        } else {
            Text(isStreaming ? "Working…" : "Ask the agent about what you see.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message the agent", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(send)
                .accessibilityIdentifier("floating-chat-input")
                // Keep typing out of the hidden chat composer underneath.
                .onAppear { focused = true }
            if isStreaming {
                Button {
                    Task { await appState.cancelStreaming(in: windowState) }
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? ClaudeTheme.accent : ClaudeTheme.textSecondary.opacity(0.5))
                .disabled(!canSend)
                .help("Send")
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ClaudeTheme.background.opacity(0.7), in: .rect(cornerRadius: 10))
        .padding(10)
    }

    private var canSend: Bool {
        !isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        Task { await appState.sendPrompt(prompt, useProjectEffortForNewChat: true, in: windowState) }
    }
}
