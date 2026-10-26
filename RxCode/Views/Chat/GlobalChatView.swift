import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct GlobalChatView: View {
    @Environment(WindowState.self) private var windowState
    @AppStorage("globalChatSidebarVisible") private var showsSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                GlobalChatSidebar()
                    .frame(width: 260)
                    .transition(.move(edge: .leading))

                Rectangle()
                    .fill(ClaudeTheme.border)
                    .frame(width: 1)
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showsSidebar.toggle() }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: ClaudeTheme.size(14)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .help(showsSidebar ? "Hide chat sidebar" : "Show chat sidebar")
                    .accessibilityIdentifier("global-chat-sidebar-toggle")

                    if !showsSidebar {
                        GlobalNewChatButton()
                    }

                    if let project = windowState.selectedProject, !project.isGlobalChat {
                        Label(project.name, systemImage: "folder")
                            .font(.system(size: ClaudeTheme.size(13)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                            .help(project.path)
                    }

                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .frame(height: GlobalChatLayout.headerHeight)

                ClaudeThemeDivider()

                ChatView(inputAccessory: {
                    HStack(spacing: 8) {
                        ChatToolbarControls(placement: .composer)
                        if windowState.selectedProject?.isGlobalChat == false {
                            BranchPickerChip()
                        }
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
        }
        .clipped()
        .accessibilityIdentifier("global-chat-view")
    }
}

private enum GlobalChatLayout {
    /// Shared by the sidebar and chat headers so their dividers line up.
    static let headerHeight: CGFloat = 44
}

private struct GlobalNewChatButton: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    var body: some View {
        Button {
            appState.startNewGlobalChat(in: windowState)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: ClaudeTheme.size(14)))
                .foregroundStyle(ClaudeTheme.textSecondary)
        }
        .buttonStyle(.borderless)
        .help("New Chat")
        .accessibilityIdentifier("global-new-chat")
    }
}

/// Collapsible list of chats started from the Chat tab. Picking a thread
/// opens it in the Chat tab.
private struct GlobalChatSidebar: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                GlobalNewChatButton()
            }
            .padding(.horizontal, 14)
            .frame(height: GlobalChatLayout.headerHeight)

            ClaudeThemeDivider()

            HistoryListView(
                scopedProjectId: Project.globalChatID,
                opensInChatTab: true
            )
            // Drop the `.sidebar` list's translucent material so the panel
            // matches the theme instead of showing the desktop through it.
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("global-chat-history")
        }
        .frame(maxHeight: .infinity)
        .background(ClaudeTheme.sidebarBackground)
    }
}
