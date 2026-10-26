import Combine
import SwiftUI
import RxCodeCore

#if os(macOS)

public struct ChatView<InputAccessory: View, BottomAccessory: View, AboveInputAccessory: View>: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

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

                composer
                bottomAccessory
            }

            StatusLineView()
        }
        .background(ClaudeTheme.background)
        .onKeyPress(.escape, phases: .down) { _ in
            if let last = windowState.messageQueue.last {
                chatBridge.removeQueuedMessage(id: last.id)
                return .handled
            }
            guard chatBridge.isStreaming else { return .ignored }
            Task { await chatBridge.cancelStreaming() }
            return .handled
        }
    }

    private var pendingComputerUseRequest: PermissionRequest? {
        windowState.pendingPermissions.first {
            $0.sessionId == windowState.currentSessionId && ComputerUsePresentation.recognizes($0.toolName)
        }
    }

    @ViewBuilder
    private var composer: some View {
        if let request = pendingComputerUseRequest {
            // Replace the editor while approval is pending so its native text view
            // cannot retain keyboard focus behind the confirmation panel.
            VStack(alignment: .leading, spacing: 16) {
                Label("Confirm computer use for this session", systemImage: "desktopcomputer")
                    .font(.headline)
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Text("Codex is waiting to use your computer. Confirm to allow computer use for the rest of this session.")
                    .font(.callout)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Button("Deny", role: .destructive) {
                        Task { await chatBridge.computerUseDecisionHandler?(request, .deny) }
                    }
                    Button("Confirm for This Session") {
                        Task { await chatBridge.computerUseDecisionHandler?(request, .allowSessionTool) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                    .strokeBorder(ClaudeTheme.accent.opacity(0.5), lineWidth: 1)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .accessibilityIdentifier("computer-use-session-banner")
        } else {
            InputBarView(accessory: inputAccessory) {
                aboveInputAccessory
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateTitle: String {
        if let project = windowState.selectedProject, !project.isGlobalChat {
            let name = project.name
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

                composer
                bottomAccessory
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 24)
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
#endif
