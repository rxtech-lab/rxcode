import RxCodeChatKit
import SwiftUI

/// Explicit inputs for the native list. Keep captured app state out of its
/// rendering closure so unrelated @Published changes cannot refresh every cell.
struct MobileChatTranscriptSnapshot: Equatable {
    let sessionID: String
    var items: [ChatTranscriptListItem]
    var isStreaming: Bool
    var isThinking: Bool
    var shouldScrollToBottom: Bool
    var scrollToBottomAnimated: Bool
    var hasMorePrevious: Bool
    var tailSpacer: CGFloat
}

struct MobileChatTranscript: View, Equatable {
    let snapshot: MobileChatTranscriptSnapshot
    @Binding var isAtBottom: Bool
    let loadMorePrevious: () async throws -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        // The binding and paging action retain their destinations for this
        // session. Session identity is included so navigation replaces them.
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        #if DEBUG
        let _ = MobileChatPerformanceDiagnostics.recordTranscriptBodyUpdate()
        #endif
        ChatTranscriptList(
            items: snapshot.items,
            isStreaming: snapshot.isStreaming,
            shouldScrollToBottom: snapshot.shouldScrollToBottom,
            scrollToBottomAnimated: snapshot.scrollToBottomAnimated,
            isAtBottom: $isAtBottom,
            hasMorePrevious: { snapshot.hasMorePrevious },
            loadMorePrevious: loadMorePrevious,
            rowPadding: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16),
            accessibilityIdentifier: "chat-message-list"
        ) { accessory in
            accessoryContent(accessory)
        }
    }

    @ViewBuilder
    private func accessoryContent(_ accessory: ChatTranscriptAccessory) -> some View {
        switch accessory.kind {
        case .topPadding:
            Color.clear.frame(height: 8)
        case .loadingPrevious:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        case .loadingNext, .streamingIndicator:
            MobileStreamingIndicator(isThinking: snapshot.isThinking)
                .transition(.opacity)
        case .endActions:
            EmptyView()
        case .custom:
            if accessory.id == "mobile-bottom-spacer" {
                Color.clear.frame(height: snapshot.tailSpacer)
            }
        }
    }
}
