import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct GlobalChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge
    @State private var showsHistory = false

    /// Mirrors `ChatView`'s empty state so the welcome-page history button only
    /// appears before a conversation starts.
    private var isEmptyState: Bool {
        windowState.currentSessionId == nil
            && chatBridge.messages.isEmpty
            && !chatBridge.isStreaming
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    showsHistory = true
                } label: {
                    Label("History", systemImage: "clock")
                }
                .help("Show chat history")
                .accessibilityIdentifier("global-chat-history-toggle")

                if let project = windowState.selectedProject, !project.isGlobalChat {
                    Label(project.name, systemImage: "folder")
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(1)
                        .help(project.path)
                }

                Spacer()

                Button {
                    appState.startNewGlobalChat(in: windowState)
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("global-new-chat")
            }
            .buttonStyle(.borderless)
            .padding(12)

            ClaudeThemeDivider()

            ChatView(inputAccessory: {
                HStack(spacing: 8) {
                    ChatToolbarControls(placement: .composer)
                    if windowState.selectedProject?.isGlobalChat == false {
                        BranchPickerChip()
                    }
                }
            }, bottomAccessory: {
                if isEmptyState {
                    Button {
                        showsHistory = true
                    } label: {
                        Label("View Chat History", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: ClaudeTheme.size(13)))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("global-chat-welcome-history")
                }
            }, aboveInputAccessory: {
                VStack(spacing: 8) {
                    PermissionQueueBanner()
                    if windowState.selectedProject?.isGlobalChat == false {
                        ThreadDiffBanner()
                    }
                }
            })
            .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ChatDetailModifiers())
        }
        .background(ClaudeTheme.background)
        .sheet(isPresented: $showsHistory) {
            GlobalChatHistorySheet { showsHistory = false }
        }
        .accessibilityIdentifier("global-chat-view")
    }
}

/// History of chats started from the Chat tab. Picking a thread
/// opens it in the Chat tab and dismisses the sheet.
private struct GlobalChatHistorySheet: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat History")
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("global-chat-history-done")
            }
            .padding(16)

            ClaudeThemeDivider()

            HistoryListView(
                scopedProjectId: Project.globalChatID,
                opensInChatTab: true,
                onSelectSession: dismiss
            )
            .accessibilityIdentifier("global-chat-history")
        }
        .frame(width: 460, height: 560)
        .background(ClaudeTheme.background)
    }
}
