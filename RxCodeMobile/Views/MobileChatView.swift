import SwiftUI
import RxCodeCore
import RxCodeChatKit
import RxCodeSync

/// Read-write chat view. User messages are forwarded to the desktop and the
/// desktop agent's stream is mirrored back as `session_update` payloads.
struct MobileChatView: View {
    @EnvironmentObject private var state: MobileAppState
    let sessionID: String
    @State private var composer: String = ""
    @State private var submittedDraft = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ChatMessageListView(messages: messages)
                        Color.clear
                            .frame(height: 1)
                            .id("message-list-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.id) { _, _ in
                    withAnimation { proxy.scrollTo("message-list-bottom", anchor: .bottom) }
                }
            }
            Divider()
            MobileInputBar(text: $composer) { trimmed in
                Task {
                    if let projectID = draftProjectID {
                        guard !submittedDraft else { return }
                        submittedDraft = true
                        await state.requestNewSession(projectID: projectID, initialText: trimmed)
                    } else {
                        await state.sendUserMessage(trimmed, sessionID: sessionID)
                    }
                    composer = ""
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(title)
    }

    private var messages: [ChatMessage] {
        draftProjectID == nil ? state.messagesBySession[sessionID] ?? [] : []
    }

    private var title: String {
        if draftProjectID != nil { return "New Thread" }
        return state.sessions.first(where: { $0.id == sessionID })?.title ?? "Thread"
    }

    private var draftProjectID: UUID? {
        MobileDraftSessionID.projectID(from: sessionID)
    }
}
