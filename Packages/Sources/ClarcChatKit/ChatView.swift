import Combine
import SwiftUI
import ClarcCore

public struct ChatView<InputAccessory: View, BottomAccessory: View, AboveInputAccessory: View>: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge
    @State private var shortcuts: [ChatShortcut] = []

    private let inputAccessory: InputAccessory
    private let bottomAccessory: BottomAccessory
    private let aboveInputAccessory: AboveInputAccessory

    public init(
        @ViewBuilder inputAccessory: () -> InputAccessory,
        @ViewBuilder bottomAccessory: () -> BottomAccessory = { EmptyView() },
        @ViewBuilder aboveInputAccessory: () -> AboveInputAccessory = { EmptyView() }
    ) {
        self.inputAccessory = inputAccessory()
        self.bottomAccessory = bottomAccessory()
        self.aboveInputAccessory = aboveInputAccessory()
    }

    private var isEmptyState: Bool {
        windowState.currentSessionId == nil
            && chatBridge.messages.isEmpty
            && !chatBridge.isStreaming
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isEmptyState {
                emptyStateLayout
            } else {
                messageScrollView

                aboveInputAccessory

                InputBarView(accessory: inputAccessory) {
                    if windowState.selectedProject != nil && !shortcuts.isEmpty {
                        shortcutBar
                    }
                }

                bottomAccessory
            }

            StatusLineView()
        }
        .background(ClaudeTheme.background)
        .onKeyPress(.escape, phases: .down) { _ in
            if !windowState.messageQueue.isEmpty {
                windowState.messageQueue.removeLast()
                return .handled
            }
            guard chatBridge.isStreaming else { return .ignored }
            Task { await chatBridge.cancelStreaming() }
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatShortcutsDidChange)) { _ in
            shortcuts = ChatShortcutRegistry.currentShortcuts
        }
        .onAppear {
            shortcuts = ChatShortcutRegistry.currentShortcuts
        }
    }

    // MARK: - Empty State

    private var emptyStateTitle: String {
        if let name = windowState.selectedProject?.name {
            return String(format: String(localized: "What should we build in %@?", bundle: .module), name)
        }
        return String(localized: "How can I help you?", bundle: .module)
    }

    private var emptyStateLayout: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 20) {
                Text(emptyStateTitle)
                    .font(.system(size: ClaudeTheme.size(22), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)

                aboveInputAccessory

                InputBarView(accessory: inputAccessory) {
                    if windowState.selectedProject != nil && !shortcuts.isEmpty {
                        shortcutBar
                    }
                }

                bottomAccessory
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 24)
        }
    }

    // MARK: - Shortcut Bar

    private var shortcutBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shortcuts) { shortcut in
                    Button {
                        executeShortcut(shortcut)
                    } label: {
                        HStack(spacing: 5) {
                            if shortcut.isTerminalCommand {
                                Image(systemName: "terminal").font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            }
                            Text(shortcut.name).font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        }
                        .foregroundStyle(ClaudeTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(ClaudeTheme.accentSubtle, in: Capsule())
                        .overlay(Capsule().strokeBorder(ClaudeTheme.accent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(shortcut.isTerminalCommand ? "⌨ \(shortcut.message)" : shortcut.message)
                    .disabled(chatBridge.isStreaming)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(ClaudeTheme.background)
    }

    private func executeShortcut(_ shortcut: ChatShortcut) {
        guard !chatBridge.isStreaming else { return }
        if shortcut.isTerminalCommand {
            Task { await chatBridge.runTerminalCommand(shortcut.message) }
        } else {
            windowState.inputText = shortcut.message
            Task { await chatBridge.send() }
        }
    }

    // MARK: - Messages

    private var messageScrollView: some View {
        MessageListView()
    }
}

public extension ChatView where InputAccessory == EmptyView, BottomAccessory == EmptyView, AboveInputAccessory == EmptyView {
    init() {
        self.init(inputAccessory: { EmptyView() }, bottomAccessory: { EmptyView() }, aboveInputAccessory: { EmptyView() })
    }
}

public extension ChatView where BottomAccessory == EmptyView, AboveInputAccessory == EmptyView {
    init(@ViewBuilder inputAccessory: () -> InputAccessory) {
        self.init(inputAccessory: inputAccessory, bottomAccessory: { EmptyView() }, aboveInputAccessory: { EmptyView() })
    }
}

public extension ChatView where AboveInputAccessory == EmptyView {
    init(
        @ViewBuilder inputAccessory: () -> InputAccessory,
        @ViewBuilder bottomAccessory: () -> BottomAccessory
    ) {
        self.init(inputAccessory: inputAccessory, bottomAccessory: bottomAccessory, aboveInputAccessory: { EmptyView() })
    }
}
