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

                aboveInputAccessory

                InputBarView(accessory: inputAccessory) {
                    EmptyView()
                }

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
                    EmptyView()
                }

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
